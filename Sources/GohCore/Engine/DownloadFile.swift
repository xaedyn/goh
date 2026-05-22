import CryptoKit
import Darwin
import Foundation

/// A failure writing a download to disk.
public enum DownloadFileError: Error {
    case openFailed(path: String, errno: Int32)
    case writeFailed(errno: Int32)
    case syncFailed(errno: Int32)
}

/// The disk side of a download (`DESIGN.md` §Persistence).
///
/// Bytes are written with `pwrite(2)` at an explicit offset; a streaming
/// SHA-256 is folded over them as they land; the file is fsynced roughly every
/// 1 MiB, so a crash loses at most one checkpoint interval of progress. When the
/// total size is known up front, the file's extents are preallocated
/// (`F_PREALLOCATE`) for contiguity — best-effort.
///
/// Single-connection in this slice: appends are sequential and the offset
/// advances by itself. The explicit-offset `pwrite` is what 3b's concurrent
/// range writers will build on.
public final class DownloadFile {

    /// The fsync cadence — the 1 MiB checkpoint.
    private static let checkpointInterval: UInt64 = 1 << 20

    private let descriptor: Int32
    private var offset: UInt64 = 0
    private var bytesSinceSync: UInt64 = 0
    private var hasher = SHA256()

    /// The number of bytes appended so far.
    public var bytesWritten: UInt64 { offset }

    /// Opens — creating and truncating — the file at `path`. When `expectedSize`
    /// is known, the file's extents are preallocated for contiguity.
    public init(path: String, expectedSize: UInt64?) throws {
        descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else {
            throw DownloadFileError.openFailed(path: path, errno: errno)
        }
        if let expectedSize, expectedSize > 0 {
            Self.preallocate(descriptor, size: expectedSize)
        }
    }

    /// Writes `data` at the current offset, folds it into the running digest,
    /// and fsyncs once a checkpoint interval has accumulated.
    public func append(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = pwrite(
                    descriptor, base + written, raw.count - written,
                    off_t(offset) + off_t(written))
                guard count > 0 else { throw DownloadFileError.writeFailed(errno: errno) }
                written += count
            }
        }
        hasher.update(data: data)
        offset += UInt64(data.count)
        bytesSinceSync += UInt64(data.count)
        if bytesSinceSync >= Self.checkpointInterval {
            _ = fsync(descriptor)
            bytesSinceSync = 0
        }
    }

    /// fsyncs, closes the file, and returns the lowercase-hex SHA-256 of every
    /// appended byte.
    public func finalize() throws -> String {
        guard fsync(descriptor) == 0 else {
            throw DownloadFileError.syncFailed(errno: errno)
        }
        close(descriptor)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Best-effort extent preallocation; failure is ignored — it is an
    /// optimisation, not a correctness requirement.
    private static func preallocate(_ descriptor: Int32, size: UInt64) {
        var store = fstore_t(
            fst_flags: UInt32(F_ALLOCATECONTIG),
            fst_posmode: F_PEOFPOSMODE,
            fst_offset: 0,
            fst_length: off_t(size),
            fst_bytesalloc: 0)
        if fcntl(descriptor, F_PREALLOCATE, &store) != 0 {
            // Contiguous allocation failed — retry allowing fragmentation.
            store.fst_flags = UInt32(F_ALLOCATEALL)
            _ = fcntl(descriptor, F_PREALLOCATE, &store)
        }
    }
}
