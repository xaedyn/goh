import Darwin
import Foundation

/// A failure writing a checkpoint file to disk.
public enum CheckpointStoreError: Error {
    case fsyncOpenFailed(path: String, errno: Int32)
    case fsyncFailed(path: String, errno: Int32)
    case renameFailed(errno: Int32)
}

/// The outcome of loading a single checkpoint.
public struct CheckpointLoadResult: Sendable {
    public var checkpoint: DownloadCheckpoint?
    public var corruptionSidecar: URL?
}

/// Reads and writes daemon-owned download checkpoints.
public struct CheckpointStore: Sendable {
    private let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// The on-disk checkpoint path for `jobID`.
    public func fileURL(jobID: UInt64) -> URL {
        directoryURL.appending(path: "\(jobID).checkpoint.plist")
    }

    /// Atomically and durably writes `checkpoint` to disk.
    public func save(_ checkpoint: DownloadCheckpoint) throws {
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(checkpoint)
        let destination = fileURL(jobID: checkpoint.jobID)
        let temporaryURL = directoryURL.appending(
            path: ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")

        do {
            try data.write(to: temporaryURL)
            // Owner-only: checkpoints hold the URL, validators (ETag/Last-Modified),
            // and byte-range progress and must not be world-readable to other
            // same-user processes (audit H2; matches HostProfileStore/ProvenanceStore).
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            try Self.fsync(path: temporaryURL.path)
            guard rename(temporaryURL.path, destination.path) == 0 else {
                throw CheckpointStoreError.renameFailed(errno: errno)
            }
            try Self.fsync(path: directoryURL.path)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// Loads `jobID`'s checkpoint, recovering corrupt or unsupported files to
    /// `nil` and preserving their bytes in a sidecar.
    public func load(jobID: UInt64) -> CheckpointLoadResult {
        let url = fileURL(jobID: jobID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CheckpointLoadResult(checkpoint: nil, corruptionSidecar: nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let checkpoint = try PropertyListDecoder().decode(DownloadCheckpoint.self, from: data)
            guard checkpoint.version == DownloadCheckpoint.currentVersion,
                  checkpoint.jobID == jobID
            else {
                return recoverToNil(url)
            }
            return CheckpointLoadResult(checkpoint: checkpoint, corruptionSidecar: nil)
        } catch {
            return recoverToNil(url)
        }
    }

    /// Deletes `jobID`'s checkpoint when one exists.
    public func delete(jobID: UInt64) throws {
        let url = fileURL(jobID: jobID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Returns the newest kept checkpoint that can be adopted for `url` and
    /// `destination`.
    public func adoptionCandidate(url: String, destination: String) -> DownloadCheckpoint? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil)
        else { return nil }

        let candidates = urls.compactMap { fileURL -> DownloadCheckpoint? in
            guard let jobID = Self.jobID(from: fileURL) else { return nil }
            guard let checkpoint = load(jobID: jobID).checkpoint,
                  checkpoint.adoptionProgress(url: url, destination: destination) != nil
            else { return nil }
            return checkpoint
        }
        return candidates.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }.first
    }

    private func recoverToNil(_ url: URL) -> CheckpointLoadResult {
        let timestamp = Int(Date().timeIntervalSince1970)
        let sidecar = directoryURL.appending(
            path: "\(url.lastPathComponent).corrupt-\(timestamp)")
        try? FileManager.default.copyItem(at: url, to: sidecar)
        let sidecarExists = FileManager.default.fileExists(atPath: sidecar.path)
        return CheckpointLoadResult(
            checkpoint: nil,
            corruptionSidecar: sidecarExists ? sidecar : nil)
    }

    private static func jobID(from url: URL) -> UInt64? {
        let suffix = ".checkpoint.plist"
        let filename = url.lastPathComponent
        guard filename.hasSuffix(suffix) else { return nil }
        return UInt64(filename.dropLast(suffix.count))
    }

    private static func fsync(path: String) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CheckpointStoreError.fsyncOpenFailed(path: path, errno: errno)
        }
        defer { close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw CheckpointStoreError.fsyncFailed(path: path, errno: errno)
        }
    }
}
