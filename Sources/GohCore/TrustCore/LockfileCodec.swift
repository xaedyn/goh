import Foundation

/// Encodes and decodes `gohfile.lock` per the frozen §8 schema.
public struct LockfileCodec {

    // MARK: - Error

    public struct CodecError: Error, Equatable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    // MARK: - Output types

    public struct Lockfile: Sendable {
        public var lockfileVersion: Int
        public var manifestHash: String
        public var entries: [LockEntry]

        public init(manifestHash: String, entries: [LockEntry]) {
            self.lockfileVersion = 1
            self.manifestHash = manifestHash
            self.entries = entries
        }
    }

    public struct LockEntry: Sendable {
        public var url: String
        public var path: String
        public var sha256: String
        public var size: Int
        public var downloadedAt: String

        public init(url: String, path: String, sha256: String, size: Int, downloadedAt: String) {
            self.url = url
            self.path = path
            self.sha256 = sha256
            self.size = size
            self.downloadedAt = downloadedAt
        }
    }

    // MARK: - Public API

    /// Decodes `toml` into a `Lockfile`.
    ///
    /// - Throws: `CodecError` for schema violations; unknown version; missing required fields;
    ///   reserved fields; malformed sha256.
    public static func decode(_ toml: String) throws -> Lockfile {
        let doc: MinimalTOMLDocument
        do {
            doc = try MinimalTOMLReader.parse(
                toml,
                allowedTopLevelKeys: ["lockfileVersion", "manifestHash"],
                allowedAssetKeys: ["url", "path", "sha256", "size", "downloadedAt", "chunks"]
            )
        } catch let e as MinimalTOMLReader.ParseError {
            throw CodecError(e.message)
        }

        guard let versionVal = doc.topLevel["lockfileVersion"]?.intValue else {
            throw CodecError("lockfile missing required 'lockfileVersion'")
        }
        guard versionVal == 1 else {
            throw CodecError("unsupported lockfileVersion \(versionVal); upgrade goh")
        }

        guard let manifestHash = doc.topLevel["manifestHash"]?.stringValue else {
            throw CodecError("lockfile missing required 'manifestHash'")
        }

        var entries: [LockEntry] = []
        for raw in doc.arrayOfTables("entry") {
            // §8.1 — 'chunks' is reserved.
            if raw["chunks"] != nil {
                throw CodecError("'chunks' is reserved and not supported in this version of goh")
            }

            guard let url = raw["url"]?.stringValue else {
                throw CodecError("[[entry]] missing required 'url'")
            }
            guard let path = raw["path"]?.stringValue else {
                throw CodecError("[[entry]] missing required 'path'")
            }
            guard let sha256 = raw["sha256"]?.stringValue else {
                throw CodecError("[[entry]] missing required 'sha256'")
            }
            guard Sha256Format.isValid(sha256) else {
                throw CodecError("invalid sha256 in lock entry: '\(sha256)'")
            }
            guard let size = raw["size"]?.intValue else {
                throw CodecError("[[entry]] missing required 'size'")
            }
            guard let downloadedAt = raw["downloadedAt"]?.stringValue else {
                throw CodecError("[[entry]] missing required 'downloadedAt'")
            }

            entries.append(LockEntry(
                url: url,
                path: path,
                sha256: sha256,
                size: size,
                downloadedAt: downloadedAt
            ))
        }

        var lockfile = Lockfile(manifestHash: manifestHash, entries: entries)
        lockfile.lockfileVersion = versionVal
        return lockfile
    }

    /// Encodes `lock` to a TOML string suitable for writing to `gohfile.lock`.
    ///
    /// `lockfileVersion` is always the first field.
    private static func escapeTOML(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func encode(_ lock: Lockfile) -> String {
        var out = "lockfileVersion = \(lock.lockfileVersion)\n"
        out += "manifestHash = \"\(Self.escapeTOML(lock.manifestHash))\"\n"
        for entry in lock.entries {
            out += "\n[[entry]]\n"
            out += "url = \"\(Self.escapeTOML(entry.url))\"\n"
            out += "path = \"\(Self.escapeTOML(entry.path))\"\n"
            out += "sha256 = \"\(entry.sha256)\"\n"
            out += "size = \(entry.size)\n"
            out += "downloadedAt = \"\(entry.downloadedAt)\"\n"
        }
        return out
    }
}
