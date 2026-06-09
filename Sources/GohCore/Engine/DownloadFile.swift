import Darwin
import Foundation
import Synchronization

/// A failure reading or writing a download on disk.
public enum DownloadFileError: Error {
    case openFailed(path: String, errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case syncFailed(errno: Int32)

    /// A path-free rendering safe to surface over the XPC progress channel. The
    /// raw `openFailed` case embeds the destination path, which must not leak to
    /// other same-user subscribers via a job's error message (audit M1).
    public var redactedDescription: String {
        switch self {
        case .openFailed(_, let errno):
            return "could not open the destination file (errno \(errno))"
        case .writeFailed(let errno):
            return "writing to the destination failed (errno \(errno))"
        case .readFailed(let errno):
            return "reading from the destination failed (errno \(errno))"
        case .syncFailed(let errno):
            return "syncing the destination failed (errno \(errno))"
        }
    }
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
        descriptor = try Self.openConfined(path: path, truncate: truncate)
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

    /// Captures the current file metadata via `fstat(2)` on the open descriptor.
    ///
    /// Call this BEFORE `finish()` — the descriptor is closed inside `finish()`.
    /// Maps `struct stat` fields to `FileStat` exactly as `LiveFileStatProbe.probe` does.
    ///
    /// - Throws: `DownloadFileError.syncFailed(errno:)` on `fstat` failure.
    ///   This should never happen on a successfully opened, written file. The caller
    ///   should use `try? file.fileStat()` so a should-never-happen failure leaves the
    ///   baseline nil (→ `.notBaselined`), never blocking the download.
    public func fileStat() throws -> FileStat {
        var st = stat()
        guard Darwin.fstat(descriptor, &st) == 0 else {
            throw DownloadFileError.syncFailed(errno: errno)
        }
        return FileStat(
            size: Int64(st.st_size),
            mtimeSeconds: Int64(st.st_mtimespec.tv_sec),
            mtimeNanoseconds: Int64(st.st_mtimespec.tv_nsec),
            inode: UInt64(st.st_ino),
            device: Int64(st.st_dev),
            isRegularFile: (st.st_mode & S_IFMT) == S_IFREG)
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

    // MARK: Symlink-safe open (trust core, `DESIGN.md` §Persistence)

    /// Opens (creating if needed) the file at the absolute `path` while refusing
    /// to follow a symlink at the destination's **immediate parent** or at the
    /// **final component** itself.
    ///
    /// The path is descended one component at a time relative to a *proven*
    /// parent file descriptor — an `openat(2)` chain that is never re-resolved
    /// by a second absolute `open(2)`, so there is no TOCTOU window for a swapped
    /// symlink at the protected hops to slip through. Missing intermediate
    /// directories are created in place with `mkdirat(2)` (curl `--create-dirs`
    /// behaviour), and the proven-parent-relative final `openat` uses
    /// `O_NOFOLLOW` (never `O_EXCL`, so resume can reopen in place to append).
    ///
    /// Confinement boundary (and its accepted residual, `DESIGN.md`
    /// §Persistence): the descent **anchors at `/` and follows pre-existing
    /// symlinks in the path prefix** — macOS ships legitimate ones such as
    /// `/var` → `/private/var` and `/tmp`, so refusing them would break every
    /// real download. What it refuses is a symlink at the destination's
    /// immediate parent component or at the final component — i.e. the hops an
    /// attacker would swap to redirect *this* file's bytes outside the intended
    /// directory. A symlink/non-directory there surfaces as `ELOOP`/`ENOTDIR`
    /// and maps to `GohError(.symlinkComponentRefused)` (CLI exit 5); any other
    /// open failure keeps the `DownloadFileError.openFailed(path:errno:)` path
    /// (CLI exit 8). Lexical `..`/base confinement is the CLI's job (Phase 6),
    /// not this method's, so `..` is not resolved here.
    private static func openConfined(path: String, truncate: Bool) throws -> Int32 {
        // Non-empty components, dropping the leading "/" and any "."/empty
        // segments. (The daemon receives an already lexically-confined absolute
        // path, so no ".." resolution is needed.)
        let components = path.split(separator: "/").map(String.init).filter {
            $0 != "." && !$0.isEmpty
        }
        // Defense-in-depth: refuse any ".." component rather than follow it
        // upward. The CLI lexically normalizes paths before the daemon sees them,
        // so ".." never legitimately arrives — but the daemon must not depend on
        // that. A ".." here would let the openat descent escape the destination's
        // directory (audit M4).
        guard !components.contains("..") else {
            throw GohError(
                code: .destinationUnwritable,
                message: "refused a destination path containing a '..' component")
        }
        guard let finalComponent = components.last else {
            // No usable final component (e.g. "/" or ""): nothing to open.
            throw DownloadFileError.openFailed(path: path, errno: ENOENT)
        }
        let intermediates = components.dropLast()

        // Anchor at the real filesystem root. "/" is a directory, not a symlink.
        var parentFd = open("/", O_DIRECTORY | O_RDONLY | O_CLOEXEC)
        guard parentFd >= 0 else {
            throw DownloadFileError.openFailed(path: path, errno: errno)
        }

        // Descend through (and create) each intermediate directory component.
        // The destination's *immediate parent* is the last intermediate; it is
        // opened with O_NOFOLLOW so a symlink there is refused. Every shallower
        // intermediate is part of the trusted existing prefix and may legitimately
        // be (or pass through) a system symlink, so it is opened without
        // O_NOFOLLOW. `descend` closes `parentFd` on every throw path.
        let lastIntermediateIndex = intermediates.count - 1
        for (offset, comp) in intermediates.enumerated() {
            let isImmediateParent = offset == lastIntermediateIndex
            let childFd = try descend(
                into: comp, from: parentFd,
                refuseSymlink: isImmediateParent, fullPath: path)
            _ = Foundation.close(parentFd)
            parentFd = childFd
        }

        // Open the final component relative to the proven parent. O_NOFOLLOW so a
        // symlinked destination is refused; no O_EXCL so resume reopens in place.
        var flags = O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC
        if truncate { flags |= O_TRUNC }
        let fd = openAt(parentFd, finalComponent, flags, 0o644)
        if fd < 0 {
            let err = errno
            _ = Foundation.close(parentFd)
            if err == ELOOP || err == ENOTDIR {
                throw GohError(
                    code: .symlinkComponentRefused,
                    message: "refused to follow a symlink at the final path component of \(path)")
            }
            throw DownloadFileError.openFailed(path: path, errno: err)
        }
        _ = Foundation.close(parentFd)
        return fd
    }

    /// Opens (creating if missing) directory `comp` relative to `parentFd`,
    /// returning the opened directory's descriptor.
    ///
    /// When `refuseSymlink` is true the open uses `O_NOFOLLOW`, so a symlink (or
    /// non-directory) at this component is refused with
    /// `GohError(.symlinkComponentRefused)`; this is used for the destination's
    /// immediate parent. When false, a pre-existing symlink is followed (the
    /// trusted system prefix, e.g. `/var`), but a *newly created* component is
    /// still made and opened with `O_NOFOLLOW` so it can never be a symlink.
    ///
    /// On any throw, `parentFd` is closed before the error propagates so the
    /// caller never double-closes or leaks it. On success, `parentFd` is left
    /// open and owned by the caller.
    private static func descend(
        into comp: String, from parentFd: Int32, refuseSymlink: Bool, fullPath: String
    ) throws -> Int32 {
        let strictFlags = O_DIRECTORY | O_NOFOLLOW | O_RDONLY | O_CLOEXEC
        // For an existing prefix component we tolerate a system symlink; for the
        // immediate parent we refuse one.
        let openFlags = refuseSymlink ? strictFlags : (O_DIRECTORY | O_RDONLY | O_CLOEXEC)

        var fd = openAt(parentFd, comp, openFlags, 0)
        if fd >= 0 { return fd }

        let openErr = errno
        if openErr == ENOENT {
            // Missing directory: create it in place (tolerating a creation race),
            // then open it with O_NOFOLLOW. Because we just created it relative to
            // the proven parent, a symlink appearing here is an active swap and is
            // refused regardless of `refuseSymlink`.
            let made = comp.withCString { mkdirat(parentFd, $0, 0o755) }
            if made != 0 && errno != EEXIST {
                let mkErr = errno
                _ = Foundation.close(parentFd)
                throw DownloadFileError.openFailed(path: fullPath, errno: mkErr)
            }
            fd = openAt(parentFd, comp, strictFlags, 0)
            if fd >= 0 { return fd }
            let reErr = errno
            _ = Foundation.close(parentFd)
            if reErr == ELOOP || reErr == ENOTDIR {
                throw GohError(
                    code: .symlinkComponentRefused,
                    message: "refused to follow a symlink at an intermediate path component of \(fullPath)")
            }
            throw DownloadFileError.openFailed(path: fullPath, errno: reErr)
        }

        _ = Foundation.close(parentFd)
        if openErr == ELOOP || openErr == ENOTDIR {
            throw GohError(
                code: .symlinkComponentRefused,
                message: "refused to follow a symlink at an intermediate path component of \(fullPath)")
        }
        throw DownloadFileError.openFailed(path: fullPath, errno: openErr)
    }

    /// `openat(2)` for a single path component held as a Swift `String`.
    private static func openAt(
        _ parentFd: Int32, _ comp: String, _ flags: Int32, _ mode: mode_t
    ) -> Int32 {
        comp.withCString { openat(parentFd, $0, flags, mode) }
    }
}
