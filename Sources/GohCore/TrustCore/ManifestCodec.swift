import CryptoKit
import Foundation

/// Parses a `gohfile.toml` manifest file per the frozen §7 schema.
public struct ManifestCodec {

    // MARK: - Error

    public struct CodecError: Error, Equatable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    // MARK: - Output types

    public struct ManifestFile: Sendable {
        /// `"sha256:<hex>"` of the raw TOML bytes — used as the lock file's `manifestHash`.
        public var manifestHash: String
        public var base: String?
        public var assets: [AssetEntry]
    }

    public struct AssetEntry: Sendable {
        public var url: String
        public var path: String
        public var sha256: String?    // nil = unpinned (TOFU)
        public var verify: Bool       // default true
    }

    // MARK: - Allowed key sets

    private static let allowedTopLevelKeys: Set<String> = ["version", "base"]
    private static let allowedAssetKeys: Set<String> = ["url", "path", "dest", "sha256", "verify", "auth"]

    // MARK: - Public API

    /// Parses `toml` into a `ManifestFile`.
    ///
    /// - Throws: `CodecError` for schema violations; unknown keys; unsupported version;
    ///   malformed sha256; reserved fields.
    public static func parse(_ toml: String) throws -> ManifestFile {
        // Compute manifest hash from raw bytes before any parsing.
        let hashBytes = SHA256.hash(data: Data(toml.utf8))
        let manifestHash = "sha256:" + hashBytes.map { String(format: "%02x", $0) }.joined()

        let doc: MinimalTOMLDocument
        do {
            doc = try MinimalTOMLReader.parse(
                toml,
                allowedTopLevelKeys: allowedTopLevelKeys,
                allowedAssetKeys: allowedAssetKeys
            )
        } catch let e as MinimalTOMLReader.ParseError {
            throw CodecError(e.message)
        }

        // Version check — default to 1 if omitted.
        if let versionVal = doc.topLevel["version"] {
            guard let v = versionVal.intValue, v == 1 else {
                throw CodecError("unsupported manifest version; goh supports version 1")
            }
        }

        let base = doc.topLevel["base"]?.stringValue

        var assets: [AssetEntry] = []
        for raw in doc.arrayOfTables("asset") {
            // §4.4 / §7.1 — 'auth' is reserved.
            if raw["auth"] != nil {
                throw CodecError("'auth' is reserved and not supported in this version of goh")
            }

            guard let url = raw["url"]?.stringValue else {
                throw CodecError("[[asset]] entry missing required 'url' field")
            }

            let pathVal = raw["path"]?.stringValue
            let destVal = raw["dest"]?.stringValue
            let path: String
            switch (pathVal, destVal) {
            case (let p?, nil):
                path = p
            case (nil, let d?):
                path = d
            case (let p?, let d?) where p == d:
                path = p
            case (nil, nil):
                throw CodecError("[[asset]] entry missing required 'path' (or 'dest') field")
            default:
                throw CodecError("[[asset]] entry has both 'path' and 'dest'; use only one")
            }

            let sha256: String?
            if let sha = raw["sha256"]?.stringValue {
                guard Sha256Format.isValid(sha) else {
                    throw CodecError("invalid sha256 format '\(sha)'; expected sha256:<64 lowercase hex>")
                }
                sha256 = sha
            } else {
                sha256 = nil
            }

            let verify = raw["verify"]?.boolValue ?? true
            assets.append(AssetEntry(url: url, path: path, sha256: sha256, verify: verify))
        }

        return ManifestFile(manifestHash: manifestHash, base: base, assets: assets)
    }
}
