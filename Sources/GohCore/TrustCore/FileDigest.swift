import CryptoKit
import Foundation

/// At-rest SHA-256 streaming digest for a file on disk.
///
/// The re-hash entry point for `goh sync`/`goh verify`. Distinct from
/// ChunkAssembler (download-bound). Streams the file in 1 MiB chunks,
/// draining an `autoreleasepool` every chunk, to keep peak memory flat
/// regardless of file size.
///
/// The per-chunk `autoreleasepool` is load-bearing, not cosmetic:
/// `FileHandle.read(upToCount:)` returns `Data` backed by an autoreleased
/// buffer. This loop runs inside one long `DispatchQueue.global().async`
/// block (the tray verify, and `goh verify`/`goh sync`), whose autorelease
/// pool is only drained when the whole block returns. Without an inner pool,
/// every chunk's backing buffer accumulates for the entire read — tens of GB
/// on a multi-GB file — until the OS jetsam-kills the process (a silent
/// SIGKILL with no crash report). Draining per chunk frees each buffer
/// immediately, so peak memory really is flat.
public struct FileDigest {

    // MARK: - Error

    public enum DigestError: Error, Equatable {
        case cannotOpen(String)
        /// The caller's `isCancelled` closure returned `true` mid-read. Thrown
        /// before reading the next chunk so a multi-GB hash can be aborted partway.
        case cancelled
    }

    // MARK: - Public API

    /// Streams `path` through SHA-256.
    ///
    /// - Parameters:
    ///   - path: Absolute path of the file to hash.
    ///   - onBytesHashed: Optional, called after each chunk is hashed with THIS chunk's
    ///     byte count. Lets the caller report streaming intra-file progress. Nil disables it
    ///     (zero extra work on the hot path).
    ///   - isCancelled: Optional, checked BEFORE reading each chunk. Returning `true` aborts
    ///     the hash mid-file by throwing `DigestError.cancelled`. Nil disables cancellation.
    /// - Returns: A tuple of `("sha256:<lowercase-hex>", byteCount)`.
    /// - Throws: `DigestError.cannotOpen` when the file cannot be opened for reading;
    ///   `DigestError.cancelled` when `isCancelled` returns true mid-read;
    ///   re-throws `FileHandle` read errors (e.g. I/O errors on partially-written files).
    public static func sha256WithSize(
        path: String,
        onBytesHashed: ((Int) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> (String, Int) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw DigestError.cannotOpen(path)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var totalBytes = 0
        let chunkSize = 1 << 20  // 1 MiB

        while true {
            // Drain the autorelease pool every chunk so the autoreleased buffer
            // backing FileHandle.read(upToCount:) is freed immediately rather than
            // accumulating for the whole (possibly multi-GB) read. See the type doc.
            let reachedEOF = try autoreleasepool { () throws -> Bool in
                // Check cancellation BEFORE reading the next chunk so a long hash can
                // be aborted partway rather than only between files.
                if isCancelled?() == true { throw DigestError.cancelled }
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { return true }
                hasher.update(data: chunk)
                totalBytes += chunk.count
                onBytesHashed?(chunk.count)
                return false
            }
            if reachedEOF { break }
        }

        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ("sha256:" + hex, totalBytes)
    }

    /// Convenience overload returning only the digest string.
    public static func sha256(path: String) throws -> String {
        try sha256WithSize(path: path).0
    }
}
