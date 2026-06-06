import Darwin
import Foundation
import CryptoKit

/// Errors from SecureEnclaveSigner operations.
public enum SecureEnclaveSignerError: Error {
    /// Secure Enclave is not available on this machine (VM / no SE hardware).
    case secureEnclaveUnavailable
    /// Failed to create the SE key.
    case keyCreationFailed(underlying: Error)
    /// Failed to re-open an existing SE key handle.
    case keyOpenFailed(underlying: Error)
    /// Failed to sign the given data.
    case signingFailed(underlying: Error)
    /// Atomic write to the handle file failed.
    case handleWriteFailed(path: String, underlying: Error)
    /// O_EXCL create raced — the handle already exists, caller should re-open.
    case handleAlreadyExists
}

/// A create-or-open wrapper for a `SecureEnclave.P256.Signing.PrivateKey`.
///
/// Private material is persisted ONLY as the opaque `dataRepresentation` (~284B)
/// to a 0600 file (the "handle"). The public key's 65-byte `x963Representation`
/// is exportable and is embedded in every signed artifact.
///
/// **Concurrency:** the signer is `Sendable`; each method is safe to call from
/// any context. The SE key handle is immutable after `createOrOpen`.
///
/// **SE availability:** `SecureEnclave.isAvailable` must be checked before calling
/// `createOrOpen`. If the Secure Enclave is unavailable (e.g. in a CI VM),
/// `createOrOpen` throws `SecureEnclaveSignerError.secureEnclaveUnavailable`.
public struct SecureEnclaveSigner: Sendable {

    /// The 8-hex key identifier: `hex(SHA256(publicKey.x963Representation)[0..3])`.
    public let kid: String

    /// The 65-byte x963 public key, exportable for embedding in the signed artifact.
    public let publicKeyX963: Data

    private let privateKey: SecureEnclave.P256.Signing.PrivateKey

    // MARK: - Create or open

    /// Opens the SE key from `handleURL` if the file exists; otherwise creates a new
    /// `SecureEnclave.P256.Signing.PrivateKey`, persists the handle with `O_CREAT|O_EXCL`
    /// (exclusive create — if two concurrent first-run `attest` calls race, one wins and
    /// the loser opens the winner's handle), and returns the signer.
    ///
    /// **Handle file:** `handleURL` parent directory must already exist (caller's responsibility
    /// via `AttestKeyLocation.attestDirectoryURL(create: true)`).
    ///
    /// **Crash safety:** the handle is written via a full `write(2)` + `fsync` + `close`
    /// sequence on a file opened with `O_CREAT|O_EXCL|O_WRONLY`. A crash before the `write`
    /// completes leaves no file (clean retry); a crash after `fsync` + `close` leaves a valid,
    /// reusable handle. No key material is ever lost.
    ///
    /// - Throws: `SecureEnclaveSignerError.secureEnclaveUnavailable` if SE is absent.
    public static func createOrOpen(handleURL: URL) throws -> SecureEnclaveSigner {
        guard SecureEnclave.isAvailable else {
            throw SecureEnclaveSignerError.secureEnclaveUnavailable
        }

        if FileManager.default.fileExists(atPath: handleURL.path) {
            return try openExisting(handleURL: handleURL)
        } else {
            return try createNew(handleURL: handleURL)
        }
    }

    // MARK: - Sign

    /// Signs the given PAE bytes with the SE key.
    ///
    /// Returns the 64-byte raw representation (`r ‖ s`) of the ECDSA-P256-SHA256 signature.
    /// ECDSA is non-deterministic: signing the same data twice yields different bytes.
    ///
    /// - Parameter pae: The DSSE Pre-Authentication Encoding bytes to sign.
    /// - Returns: 64 bytes: `signature.rawRepresentation`.
    /// - Throws: `SecureEnclaveSignerError.signingFailed` if the SE rejects the operation.
    public func sign(pae: Data) throws -> Data {
        do {
            let sig = try privateKey.signature(for: pae)
            return sig.rawRepresentation
        } catch {
            throw SecureEnclaveSignerError.signingFailed(underlying: error)
        }
    }

    // MARK: - Private helpers

    private init(privateKey: SecureEnclave.P256.Signing.PrivateKey) {
        self.privateKey = privateKey
        let pub = privateKey.publicKey
        self.publicKeyX963 = pub.x963Representation
        self.kid = SignedVerifyReport.deriveKid(from: pub)
    }

    private static func createNew(handleURL: URL) throws -> SecureEnclaveSigner {
        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey()
        } catch {
            throw SecureEnclaveSignerError.keyCreationFailed(underlying: error)
        }

        // Persist handle with O_CREAT|O_EXCL — exclusive create-if-absent.
        // On EEXIST: another concurrent first-run `attest` won the race → open its handle.
        let handleData = key.dataRepresentation
        do {
            try writeExclusive(data: handleData, to: handleURL)
        } catch SecureEnclaveSignerError.handleAlreadyExists {
            // Race: another `attest` call created the handle first — open the winner's key.
            return try openExisting(handleURL: handleURL)
        }

        return SecureEnclaveSigner(privateKey: key)
    }

    private static func openExisting(handleURL: URL) throws -> SecureEnclaveSigner {
        guard let handleData = try? Data(contentsOf: handleURL) else {
            throw SecureEnclaveSignerError.keyOpenFailed(
                underlying: CocoaError(.fileReadNoSuchFile))
        }
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: handleData)
            return SecureEnclaveSigner(privateKey: key)
        } catch {
            throw SecureEnclaveSignerError.keyOpenFailed(underlying: error)
        }
    }

    /// Exclusive create-and-write: `open(O_CREAT|O_EXCL|O_WRONLY, 0o600)` → full write loop →
    /// `fsync` → `close` → `fsync(dir)`.
    ///
    /// This is the spec §4 "O_EXCL create-if-absent" guarantee. Unlike `rename(2)` (which
    /// atomically REPLACES its destination and never returns EEXIST), `O_CREAT|O_EXCL` fails
    /// with EEXIST when the file already exists — giving a true exclusive-create semantic.
    ///
    /// On EEXIST: throws `SecureEnclaveSignerError.handleAlreadyExists`; caller opens existing.
    /// On any other error: throws `SecureEnclaveSignerError.handleWriteFailed`.
    private static func writeExclusive(data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR) // 0o600
        if fd < 0 {
            let e = errno
            if e == EEXIST {
                throw SecureEnclaveSignerError.handleAlreadyExists
            }
            throw SecureEnclaveSignerError.handleWriteFailed(
                path: url.path,
                underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(e)))
        }
        defer { Darwin.close(fd) }

        // Full write loop (handles short writes on large data, though SE handles are ~284B)
        var written = 0
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            while written < data.count {
                let n = Darwin.write(fd, ptr.baseAddress!.advanced(by: written), data.count - written)
                if n < 0 {
                    let e = errno
                    throw SecureEnclaveSignerError.handleWriteFailed(
                        path: url.path,
                        underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(e)))
                }
                written += n
            }
        }

        guard Darwin.fsync(fd) == 0 else {
            throw SecureEnclaveSignerError.handleWriteFailed(
                path: url.path,
                underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        // fsync the parent directory to flush the new directory entry
        try fsyncFile(path: url.deletingLastPathComponent().path)
    }

    /// Fsync a file or directory at `path` for durability.
    ///
    /// Matches `ProvenanceStore.fsync(path:)` convention: throws on BOTH data-fd AND
    /// dir-fd fsync failures (the project treats both as durability-critical).
    /// `guard fd >= 0 else { return }` is retained for the directory-open case to mirror
    /// the ProvenanceStore pattern (a missing directory is not a crash-safety issue here —
    /// the handle itself was already fsynced above before this call).
    private static func fsyncFile(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard Darwin.fsync(fd) == 0 else {
            throw SecureEnclaveSignerError.handleWriteFailed(
                path: path,
                underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
    }
}
