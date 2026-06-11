import Darwin
import Foundation

/// The outcome of an exclusive, mode-pinned file create+write.
///
/// Distinguishes the open failure from the write failure so each caller can map
/// it onto its own typed error (`ProvenanceStoreError`, the attest path's error).
enum AtomicFileWriteError: Error {
    /// `open(2)` with `O_CREAT|O_EXCL|O_WRONLY` failed (errno carried).
    case openFailed(path: String, errno: Int32)
    /// `write(2)` failed partway through (errno carried).
    case writeFailed(path: String, errno: Int32)
}

/// Creates `path` with `open(O_WRONLY|O_CREAT|O_EXCL, mode)` and writes every
/// byte of `data`, then closes.
///
/// The file is created AT `mode` from the very first instant it exists — there is
/// no window where it sits at the process umask (e.g. world-readable 0644) before
/// a later `chmod`/`setAttributes` tightens it. This closes the leak for the 0600
/// sensitive writes (the provenance ledger may carry credential-bearing URLs; the
/// attest `keys.json`).
///
/// `O_EXCL` means this refuses to clobber an existing file — callers use a
/// fresh-UUID temp name, so a collision (which would surface as `.openFailed`
/// with `EEXIST`) is effectively impossible and would be a bug to silently
/// overwrite anyway.
///
/// Short writes are handled with a full write loop, so a partial `write(2)`
/// (possible on large payloads) still results in all bytes landing on disk.
/// The caller is responsible for the subsequent `fsync(file)` / `rename(2)` /
/// `fsync(dir)` durability sequence.
func writeFileExclusively(_ data: Data, to path: String, mode: mode_t) throws {
    let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, mode)
    if fd < 0 {
        throw AtomicFileWriteError.openFailed(path: path, errno: errno)
    }
    defer { Darwin.close(fd) }

    // Full write loop: a single write(2) may transfer fewer bytes than requested.
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        guard let base = buffer.baseAddress else { return } // empty data → nothing to write
        var written = 0
        while written < data.count {
            let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
            if n < 0 {
                throw AtomicFileWriteError.writeFailed(path: path, errno: errno)
            }
            written += n
        }
    }
}
