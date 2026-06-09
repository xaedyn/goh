import Darwin

/// Captured filesystem metadata for one file — the fast-check baseline.
///
/// All fields are raw integers (exact; no floating-point conversion).
/// `isRegularFile` is derived from `st_mode` via `(st_mode & S_IFMT) == S_IFREG` at probe time.
/// (`S_ISREG` is a function-like C macro and cannot be imported into Swift; use the bit-test instead.)
public struct FileStat: Sendable, Equatable {
    public let size: Int64           // st_size (off_t)
    public let mtimeSeconds: Int64   // st_mtimespec.tv_sec
    public let mtimeNanoseconds: Int64 // st_mtimespec.tv_nsec
    public let inode: UInt64         // st_ino (ino_t = __uint64_t)
    public let device: Int64         // st_dev (dev_t = Int32) widened losslessly to Int64
    public let isRegularFile: Bool   // (st_mode & S_IFMT) == S_IFREG

    public init(
        size: Int64,
        mtimeSeconds: Int64,
        mtimeNanoseconds: Int64,
        inode: UInt64,
        device: Int64,
        isRegularFile: Bool
    ) {
        self.size = size
        self.mtimeSeconds = mtimeSeconds
        self.mtimeNanoseconds = mtimeNanoseconds
        self.inode = inode
        self.device = device
        self.isRegularFile = isRegularFile
    }
}

/// The result of probing a path's filesystem metadata.
///
/// `lstat(2)` is used — symlinks at the path are not followed.
public enum FileProbeResult: Sendable, Equatable {
    /// The stat succeeded and the file is accessible.
    case stat(FileStat)
    /// `lstat` failed with `ENOENT` — the path does not exist.
    case notFound
    /// `lstat` failed with any other errno (e.g. `EACCES`, `ELOOP`, `ENOTDIR`).
    /// A present-but-unreadable file is never reported as `notFound`.
    case unreadable(Int32)
}

/// Injectable protocol for probing file metadata.
///
/// The real implementation uses `lstat(2)` (does NOT follow symlinks); tests
/// inject a stub so the comparison logic is exercised with zero real file I/O.
public protocol FileStatProbing: Sendable {
    /// Probes `path` with `lstat(2)` and returns the classified result.
    /// Never throws — errors are mapped to `FileProbeResult`.
    func probe(path: String) -> FileProbeResult
}

/// The real `FileStatProbing` implementation — uses `lstat(2)` directly.
///
/// Mapping:
///   - `ENOENT` → `.notFound`
///   - any other non-zero errno → `.unreadable(errno)`
///   - success → `.stat(FileStat)` with `isRegularFile` derived from `st_mode`
public struct LiveFileStatProbe: FileStatProbing {
    public init() {}

    public nonisolated func probe(path: String) -> FileProbeResult {
        var st = stat()
        let rc = path.withCString { Darwin.lstat($0, &st) }
        if rc != 0 {
            let err = errno
            if err == ENOENT {
                return .notFound
            }
            return .unreadable(err)
        }
        let fs = FileStat(
            size: Int64(st.st_size),
            mtimeSeconds: Int64(st.st_mtimespec.tv_sec),
            mtimeNanoseconds: Int64(st.st_mtimespec.tv_nsec),
            inode: UInt64(st.st_ino),
            device: Int64(st.st_dev),
            isRegularFile: (st.st_mode & S_IFMT) == S_IFREG)
        return .stat(fs)
    }
}
