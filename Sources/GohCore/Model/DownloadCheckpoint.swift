import Foundation

/// A durable byte interval in a partially downloaded file.
public struct CheckpointPiece: Codable, Sendable, Equatable {
    public var start: UInt64
    public var length: UInt64

    public init(start: UInt64, length: UInt64) {
        self.start = start
        self.length = length
    }

    var end: UInt64 {
        let result = start.addingReportingOverflow(length)
        return result.overflow ? UInt64.max : result.partialValue
    }

    var hasOverflowingEnd: Bool {
        start.addingReportingOverflow(length).overflow
    }
}

/// Engine-owned resume metadata for an unfinished download (`DESIGN.md`
/// §Persistence, "Checkpoint / Resume Contract").
public struct DownloadCheckpoint: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let defaultPieceSize: UInt64 = 1 << 20

    public var version: Int
    public var jobID: UInt64
    public var url: String
    public var destination: String
    public var partialFileSize: UInt64
    public var totalBytes: UInt64?
    public var strongETag: String?
    public var lastModified: String?
    public var pieceSize: UInt64
    public var completedPieces: [CheckpointPiece]
    public var updatedAt: Date

    public init(
        version: Int = currentVersion,
        jobID: UInt64,
        url: String,
        destination: String,
        partialFileSize: UInt64,
        totalBytes: UInt64? = nil,
        strongETag: String? = nil,
        lastModified: String? = nil,
        pieceSize: UInt64 = Self.defaultPieceSize,
        completedPieces: [CheckpointPiece] = [],
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.jobID = jobID
        self.url = url
        self.destination = destination
        self.partialFileSize = partialFileSize
        self.totalBytes = totalBytes
        self.strongETag = strongETag
        self.lastModified = lastModified
        self.pieceSize = pieceSize
        // Build completedPieces in a single sort + merge pass, identical to
        // applying recordCompletedPiece sequentially but O(N log N) instead of
        // O(N² log N), and without recordCompletedPiece's updatedAt = Date()
        // side effect (which the old trailing re-assignment had to undo).
        self.completedPieces = Self.mergedPieces(completedPieces)
        self.updatedAt = updatedAt
    }

    /// Sorts pieces by start and merges overlapping/adjacent intervals once,
    /// matching `recordCompletedPiece`'s semantics: zero-length and
    /// end-overflowing pieces are dropped, and pieces touching or overlapping
    /// (`piece.start <= last.end`) coalesce.
    private static func mergedPieces(_ pieces: [CheckpointPiece]) -> [CheckpointPiece] {
        let sorted = pieces
            .filter { $0.length > 0 && !$0.hasOverflowingEnd }
            .sorted { $0.start < $1.start }

        var merged: [CheckpointPiece] = []
        for piece in sorted {
            guard var last = merged.popLast() else {
                merged.append(piece)
                continue
            }
            if piece.start <= last.end {
                last.length = max(last.end, piece.end) - last.start
                merged.append(last)
            } else {
                merged.append(last)
                merged.append(piece)
            }
        }
        return merged
    }

    /// Records a durable interval, maintaining sorted non-overlapping pieces.
    public mutating func recordCompletedPiece(start: UInt64, length: UInt64) {
        guard length > 0 else { return }
        let newPiece = CheckpointPiece(start: start, length: length)
        guard !newPiece.hasOverflowingEnd else { return }
        completedPieces.append(newPiece)
        completedPieces.sort { lhs, rhs in lhs.start < rhs.start }

        var merged: [CheckpointPiece] = []
        for piece in completedPieces {
            guard var last = merged.popLast() else {
                merged.append(piece)
                continue
            }
            if piece.start <= last.end {
                last.length = max(last.end, piece.end) - last.start
                merged.append(last)
            } else {
                merged.append(last)
                merged.append(piece)
            }
        }
        completedPieces = merged
        updatedAt = Date()
    }

    func startupResumeProgress(for job: JobSummary) -> JobProgress? {
        guard isUsableForStartupResume(of: job),
              let completedBytes
        else { return nil }
        return JobProgress(
            bytesCompleted: completedBytes,
            bytesTotal: totalBytes,
            bytesPerSecond: 0)
    }

    func adoptionProgress(url expectedURL: String, destination expectedDestination: String) -> JobProgress? {
        guard isUsableForAdoption(url: expectedURL, destination: expectedDestination),
              let completedBytes
        else { return nil }
        return JobProgress(
            bytesCompleted: completedBytes,
            bytesTotal: totalBytes,
            bytesPerSecond: 0)
    }

    func adopted(jobID newJobID: UInt64) -> DownloadCheckpoint {
        var checkpoint = self
        checkpoint.jobID = newJobID
        return checkpoint
    }

    var durableBytesCompleted: UInt64? { completedBytes }

    var ifRangeValidator: String? {
        if let etag = strongETag?.trimmingCharacters(in: .whitespacesAndNewlines),
           !etag.isEmpty,
           !etag.lowercased().hasPrefix("w/")
        {
            return etag
        }
        if let lastModified = lastModified?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lastModified.isEmpty
        {
            return lastModified
        }
        return nil
    }

    var missingByteRanges: [ByteRange]? {
        guard let totalBytes,
              piecesAreInternallyConsistent
        else { return nil }

        var missing: [ByteRange] = []
        var cursor: UInt64 = 0
        for piece in completedPieces {
            if cursor < piece.start {
                missing.append(ByteRange(start: cursor, length: piece.start - cursor))
            }
            cursor = max(cursor, piece.end)
        }
        if cursor < totalBytes {
            missing.append(ByteRange(start: cursor, length: totalBytes - cursor))
        }
        return missing
    }

    private var completedBytes: UInt64? {
        var total: UInt64 = 0
        for piece in completedPieces {
            let result = total.addingReportingOverflow(piece.length)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    private func isUsableForStartupResume(of job: JobSummary) -> Bool {
        guard version == Self.currentVersion,
              jobID == job.id,
              url == job.url,
              destination == job.destination,
              isStructurallyUsable
        else { return false }
        return true
    }

    private func isUsableForAdoption(url expectedURL: String, destination expectedDestination: String) -> Bool {
        guard version == Self.currentVersion,
              url == expectedURL,
              destination == expectedDestination,
              isStructurallyUsable
        else { return false }
        return true
    }

    private var isStructurallyUsable: Bool {
        guard pieceSize == Self.defaultPieceSize,
              ifRangeValidator != nil,
              let totalBytes,
              totalBytes >= partialFileSize,
              piecesAreInternallyConsistent,
              destinationSizeMatchesPartialSize()
        else { return false }
        return true
    }

    private var piecesAreInternallyConsistent: Bool {
        var previousEnd: UInt64?
        for piece in completedPieces {
            guard piece.length > 0,
                  !piece.hasOverflowingEnd,
                  piece.end <= partialFileSize
            else { return false }
            if let previousEnd, piece.start < previousEnd {
                return false
            }
            previousEnd = piece.end
        }
        return true
    }

    private func destinationSizeMatchesPartialSize() -> Bool {
        if partialFileSize == 0,
           !FileManager.default.fileExists(atPath: destination)
        {
            return true
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: destination),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.uint64Value == partialFileSize
    }
}
