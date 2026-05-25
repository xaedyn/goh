import Darwin
import Foundation
import Synchronization

/// A failure reading or writing a download on disk.
public enum DownloadFileError: Error {
    case openFailed(path: String, errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case syncFailed(errno: Int32)
}

/// The disk side of a download — positioned reads and writes over one file
/// descriptor (`DESIGN.md` §Persistence).
///
/// `pwrite(2)` and `pread(2)` are offset-addressed, so range writers and the
/// hash assembler share one descriptor with no cursor contention; `DownloadFile`
/// is therefore `Sendable`. The file is fsynced roughly every 1 MiB of writes —
/// the checkpoint. When the total size is known up front, the extents are
/// preallocated (`F_PREALLOCATE`) for contiguity. Hashing is not `DownloadFile`'s
/// concern — the ``ChunkAssembler`` owns it.
public final class DownloadFile: Sendable {

    /// The fsync cadence — the 1 MiB checkpoint.
    private static let checkpointInterval: UInt64 = 1 << 20

    private let descriptor: Int32
    private let bytesSinceSync = Mutex<UInt64>(0)
    private let closed = Mutex(false)

    /// Opens the file at `path`. Fresh downloads create and truncate; resumed
    /// downloads open the existing partial without truncating it. When
    /// `expectedSize` is known, the file's extents are preallocated for
    /// contiguity.
    public init(path: String, expectedSize: UInt64?, truncate: Bool = true) throws {
        Self.createParentDirectory(for: path)
        let flags = O_RDWR | O_CREAT | (truncate ? O_TRUNC : 0)
        descriptor = open(path, flags, 0o644)
        guard descriptor >= 0 else {
            throw DownloadFileError.openFailed(path: path, errno: errno)
        }
        if let expectedSize, expectedSize > 0 {
            Self.preallocate(descriptor, size: expectedSize)
        }
    }

    /// Writes `data` at `offset`, and fsyncs once a checkpoint interval of
    /// writes has accumulated across all callers.
    public func write(_ data: Data, at offset: UInt64) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var done = 0
            while done < raw.count {
                let count = pwrite(
                    descriptor, base + done, raw.count - done,
                    off_t(offset) + off_t(done))
                guard count > 0 else { throw DownloadFileError.writeFailed(errno: errno) }
                done += count
            }
        }
        let shouldSync = bytesSinceSync.withLock { accumulated -> Bool in
            accumulated += UInt64(data.count)
            if accumulated >= Self.checkpointInterval {
                accumulated = 0
                return true
            }
            return false
        }
        if shouldSync { try sync() }
    }

    /// Reads up to `count` bytes from `offset` — fewer only at end of file.
    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = Data(count: count)
        let got = try buffer.withUnsafeMutableBytes {
            (raw: UnsafeMutableRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var done = 0
            while done < count {
                let n = pread(descriptor, base + done, count - done, off_t(offset) + off_t(done))
                if n == 0 { break }  // end of file
                guard n > 0 else { throw DownloadFileError.readFailed(errno: errno) }
                done += n
            }
            return done
        }
        return Data(buffer.prefix(got))
    }

    /// Makes all writes durable and resets the accumulated checkpoint counter.
    public func sync() throws {
        guard fsync(descriptor) == 0 else {
            throw DownloadFileError.syncFailed(errno: errno)
        }
        bytesSinceSync.withLock { $0 = 0 }
    }

    /// fsyncs and closes the file.
    public func finish() throws {
        let shouldClose = closed.withLock { closed in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        defer { close(descriptor) }
        try sync()
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

    private static func createParentDirectory(for path: String) {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true)
    }
}
