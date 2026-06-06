import Foundation

/// Resolves paths for the CLI-owned attest key store.
///
/// The attest key store lives at `~/Library/Application Support/dev.goh.attest/`
/// — a SEPARATE top-level directory from the daemon-owned `dev.goh.daemon/`.
/// This separation is intentional: the CLI's `attest` verb is a legitimate writer
/// of its own store; the daemon's provenance store is untouched.
///
/// The `create: true` path is ONLY taken by `goh attest` (which creates the key).
/// All read paths — including `goh verify-attestation` — use `create: false` and
/// never touch this directory.
public enum AttestKeyLocation {

    /// The attest support directory bundle identifier.
    static let bundleID = "dev.goh.attest"

    /// `~/Library/Application Support/dev.goh.attest/signing-key.handle`
    ///
    /// - Parameter create: When `true`, creates the `dev.goh.attest` directory
    ///   (mode 0700) with `withIntermediateDirectories: true`. When `false`,
    ///   no directory is created; a missing directory is "no key" (caller handles).
    public static func signingKeyHandleURL(create: Bool) throws -> URL {
        try attestDirectoryURL(create: create).appending(path: "signing-key.handle")
    }

    /// `~/Library/Application Support/dev.goh.attest/keys.json`
    ///
    /// - Parameter create: Same semantics as `signingKeyHandleURL(create:)`.
    public static func keysJSONURL(create: Bool) throws -> URL {
        try attestDirectoryURL(create: create).appending(path: "keys.json")
    }

    // MARK: - Private

    static func attestDirectoryURL(create: Bool) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: create)
        let directory = support.appending(path: bundleID, directoryHint: .isDirectory)
        if create {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        return directory
    }
}
