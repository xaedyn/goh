import CryptoKit
import Foundation

/// At-rest SHA-256 streaming digest for a file on disk.
///
/// The re-hash entry point for `goh sync`/`goh verify`. Distinct from
/// ChunkAssembler (download-bound). Streams the file in 1 MiB chunks to
/// keep peak memory flat regardless of file size.
public struct FileDigest {

    // MARK: - Error

    public enum DigestError: Error, Equatable {
        case cannotOpen(String)
    }

    // MARK: - Public API

    /// Streams `path` through SHA-256.
    ///
    /// - Returns: A tuple of `("sha256:<lowercase-hex>", byteCount)`.
    /// - Throws: `DigestError.cannotOpen` when the file cannot be opened for reading;
    ///   re-throws `FileHandle` read errors (e.g. I/O errors on partially-written files).
    public static func sha256WithSize(path: String) throws -> (String, Int) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw DigestError.cannotOpen(path)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var totalBytes = 0
        let chunkSize = 1 << 20  // 1 MiB

        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            totalBytes += chunk.count
        }

        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ("sha256:" + hex, totalBytes)
    }

    /// Convenience overload returning only the digest string.
    public static func sha256(path: String) throws -> String {
        try sha256WithSize(path: path).0
    }
}
