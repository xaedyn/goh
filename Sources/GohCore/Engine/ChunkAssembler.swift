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

/// Computes the SHA-256 of a download in order while bytes may arrive out of order.
///
/// Interval-set design (P2): workers call `complete(interval:)` when an interval is on disk; the
/// assembler coalesces intervals (ADDITIVE-MERGE ONLY — never whole-set replace) under a Mutex. The
/// frontier is the end of the single coalesced interval that starts at byte 0 (or 0 if none). The
/// hasher advances only when the byte-0 interval extends — out-of-order bytes sit in the set, durable
/// on disk, unhashed until the frontier reaches them (in-order SHA-256 invariant, single pass, no
/// re-hash). End condition (when `totalBytes` is known): the coalesced set is exactly one interval
/// `[0, totalBytes)`. When `totalBytes` is nil (unknown length, no Content-Length), `finish()` ends the
/// download and the end-condition interval check is skipped — identical to the prior `.max`-range behaviour.
///
/// `advance(range:writtenBytes:)` is DELETED (not a shim): keeping it alongside `complete(interval:)`
/// was a dual-writer hazard (both did whole-set replace under the Mutex; concurrent callers clobber).
public final class ChunkAssembler: Sendable {
    private static let readChunk = 1 << 20

    private let file: DownloadFile
    private let totalBytes: UInt64?                       // nil = unknown length (skip end-condition)
    private let completedIntervals: Mutex<[ByteInterval]> // sole writer path: complete(interval:), additive-merge
    private let failure = Mutex<GohError?>(nil)
    private let finished = Mutex<Bool>(false)
    private let ticks: AsyncStream<Void>
    private let tick: AsyncStream<Void>.Continuation

    public init(file: DownloadFile, totalBytes: UInt64?) {
        self.file = file
        self.totalBytes = totalBytes
        self.completedIntervals = Mutex([])
        (self.ticks, self.tick) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Report that `interval` is fully written. ADDITIVE-MERGE ONLY — insert into the existing set and
    /// coalesce; never replace the whole set (prevents the dual-writer clobber hazard).
    public func complete(interval: ByteInterval) {
        completedIntervals.withLock { existing in
            existing = Self.coalesce(existing + [interval])
        }
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
            if let error = failure.withLock({ $0 }) { return .failed(error) }
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
                if chunk.isEmpty {
                    return .failed(GohError(
                        code: .connectionFailed,
                        message: "the download file ended before the reported frontier"))
                }
                hasher.update(data: chunk)
                hashedUpTo += UInt64(chunk.count)
            }
            let finishedNow = finished.withLock { $0 }
            let finalFrontier = currentFrontier()
            if finishedNow, let total = totalBytes, finalFrontier < total {
                return .failed(GohError(
                    code: .connectionFailed,
                    message: "download ended after \(finalFrontier) of \(total) expected bytes"))
            }
            if finishedNow && hashedUpTo == finalFrontier {
                if let total = totalBytes {
                    let coalesced = completedIntervals.withLock { $0 }
                    let isComplete = coalesced.count == 1
                        && coalesced[0].start == 0
                        && coalesced[0].length == total
                    if !isComplete {
                        return .failed(GohError(
                            code: .connectionFailed,
                            message: "download ended with gaps in the completed interval set"))
                    }
                }
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                return .digest(digest)
            }
        }
        return .failed(GohError(code: .cancelled, message: "the assembler ended early"))
    }

    /// Frontier = end of the single coalesced interval that starts at byte 0 (else 0).
    private func currentFrontier() -> UInt64 {
        let intervals = completedIntervals.withLock { $0 }
        guard let first = intervals.first, first.start == 0 else { return 0 }
        return first.length
    }

    /// Merge overlapping/adjacent intervals, sorted by start.
    static func coalesce(_ intervals: [ByteInterval]) -> [ByteInterval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var merged: [ByteInterval] = []
        for iv in sorted {
            guard var last = merged.popLast() else { merged.append(iv); continue }
            if iv.start <= last.end {
                let newEnd = max(last.end, iv.end)
                last.length = newEnd - last.start
                merged.append(last)
            } else {
                merged.append(last)
                merged.append(iv)
            }
        }
        return merged
    }
}
