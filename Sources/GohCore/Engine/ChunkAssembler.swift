import CryptoKit
import Foundation
import Synchronization

/// A contiguous byte range of a download.
public struct ByteRange: Sendable, Equatable {
    public var start: UInt64
    public var length: UInt64

    public init(start: UInt64, length: UInt64) {
        self.start = start
        self.length = length
    }

    /// Splits `[0, total)` into contiguous ranges — at most `requested`, and
    /// never so many that a range would fall below `minChunk`. The last range
    /// takes any remainder; the result always has at least one range.
    public static func split(
        total: UInt64, requested: UInt8, minChunk: UInt64
    ) -> [ByteRange] {
        let maxByChunk = max(1, total / max(1, minChunk))
        let count = max(1, min(UInt64(requested), maxByChunk))
        let base = total / count
        var ranges: [ByteRange] = []
        var start: UInt64 = 0
        for index in 0..<count {
            let length = (index == count - 1) ? (total - start) : base
            ranges.append(ByteRange(start: start, length: length))
            start += length
        }
        return ranges
    }
}

/// The outcome of assembling a download's hash.
public enum ChunkAssemblerResult: Sendable, Equatable {
    case digest(String)
    case failed(GohError)
}

/// Computes the SHA-256 of a range-parallel download in order, while the bytes
/// arrive out of order (`DESIGN.md` §Hashing).
///
/// Range writers report progress with ``advance(range:writtenBytes:)``. The
/// assembler hashes the *contiguous-from-zero frontier* — the largest prefix
/// every byte of which is on disk — reading those bytes back from the file in
/// fixed chunks. Memory stays bounded by the chunk size, not the file size.
///
/// A monotonic progress snapshot can only *under*-estimate the frontier, never
/// over, so the assembler never reads an unwritten byte; correctness needs
/// monotonic counters, not an atomic snapshot. Single-connection is the
/// one-range case — the final range's `length` may be `.max` when the server
/// gave no `Content-Length`; ``finish()`` ends the download either way.
public final class ChunkAssembler: Sendable {

    /// The read-back granularity.
    private static let readChunk = 1 << 20

    private let file: DownloadFile
    private let ranges: [ByteRange]
    private let written: Mutex<[UInt64]>
    private let failure = Mutex<GohError?>(nil)
    private let finished = Mutex<Bool>(false)
    private let ticks: AsyncStream<Void>
    private let tick: AsyncStream<Void>.Continuation

    public init(file: DownloadFile, ranges: [ByteRange]) {
        self.file = file
        self.ranges = ranges
        self.written = Mutex(Array(repeating: 0, count: ranges.count))
        (self.ticks, self.tick) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// A writer reports that range `index` now has `writtenBytes` bytes on disk.
    public func advance(range index: Int, writtenBytes: UInt64) {
        written.withLock { $0[index] = writtenBytes }
        tick.yield()
    }

    /// A writer reports a failure; the assembler will abort, first writer wins.
    public func recordFailure(_ error: GohError) {
        failure.withLock { if $0 == nil { $0 = error } }
        tick.yield()
    }

    /// Signals that every byte has been written — no more is coming.
    public func finish() {
        finished.withLock { $0 = true }
        tick.yield()
    }

    /// Hashes the contiguous frontier to completion. Returns the lowercase-hex
    /// digest, or `.failed` when a writer reported a failure first.
    public func hashToCompletion() async -> ChunkAssemblerResult {
        var hasher = SHA256()
        var hashedUpTo: UInt64 = 0
        for await _ in ticks {
            if let error = failure.withLock({ $0 }) {
                return .failed(error)
            }
            let frontier = currentFrontier()
            while hashedUpTo < frontier {
                let count = Int(min(UInt64(Self.readChunk), frontier - hashedUpTo))
                let chunk: Data
                do {
                    chunk = try file.read(at: hashedUpTo, count: count)
                } catch {
                    return .failed(GohError(
                        code: .destinationUnwritable,
                        message: "reading back the download to hash it: \(error)"))
                }
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                hashedUpTo += UInt64(chunk.count)
            }
            if finished.withLock({ $0 }) && hashedUpTo == currentFrontier() {
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                return .digest(digest)
            }
        }
        return .failed(GohError(code: .cancelled, message: "the assembler ended early"))
    }

    /// The largest `F` such that every byte in `[0, F)` is written: full ranges
    /// contribute fully; the first incomplete range contributes its prefix and
    /// stops the walk.
    private func currentFrontier() -> UInt64 {
        let snapshot = written.withLock { $0 }
        var frontier: UInt64 = 0
        for index in ranges.indices {
            frontier += snapshot[index]
            if snapshot[index] < ranges[index].length { break }
        }
        return frontier
    }
}
