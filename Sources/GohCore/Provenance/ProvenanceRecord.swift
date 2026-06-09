import Foundation

/// Versioned root of the provenance ledger (`provenance.plist`).
///
/// Frozen on-disk format. `currentVersion` is independent of every other
/// contract in the system (`protocolVersion`, `JobCatalog.currentVersion`,
/// `lockfileVersion`, `DownloadCheckpoint` version, `HostScheduling.currentVersion`).
/// Bumping it requires a four-round design pass.
public struct ProvenanceRecord: Codable, Sendable, Equatable {
    /// The frozen format version. Bump only via a four-round design pass.
    public static let currentVersion = 1

    public var version: Int
    public var entries: [ProvenanceEntry]

    public init(version: Int = currentVersion, entries: [ProvenanceEntry] = []) {
        self.version = version
        self.entries = entries
    }

    /// An empty record at the current version.
    public static let empty = ProvenanceRecord(version: currentVersion, entries: [])
}

/// One recorded download, keyed logically by `destinationPath`.
///
/// The key is always a **canonical absolute path string** produced by
/// `URL(fileURLWithPath: rawPath).standardizedFileURL.path` — a purely lexical
/// normalization (collapses `..`/`.`/trailing-slash; does NOT resolve symlinks).
/// Write-side and read-side apply the same transform, so comparisons are
/// consistent. Callers pass raw paths; `ProvenanceStore.lookup` canonicalizes
/// internally.
public struct ProvenanceEntry: Codable, Sendable, Equatable {
    /// Source URL exactly as the completed `JobSummary.url` carries it.
    /// May contain query-string credentials — never commit or export this file.
    public var url: String
    /// Stored WITH the `"sha256:"` prefix: `"sha256:<lowercase-hex>"`.
    /// Matches `FileDigest.sha256WithSize` output and `LockEntry.sha256`.
    public var sha256: String
    /// Byte size of the completed file. `0` is valid (empty download).
    public var size: Int
    /// Completion time. Encoded by `PropertyListEncoder` as a binary-plist
    /// `Date` (real seconds since the 2001 reference epoch).
    public var downloadedAt: Date
    /// Canonical absolute path string (the logical key).
    /// `record(entry:)` replaces an existing entry with the same string,
    /// else appends. Always stored in canonical form.
    public var destinationPath: String

    /// When `goh sync` confirmed these exact bytes present WITHOUT downloading them.
    /// `nil` for entries recorded by the download engine (download-only entries).
    /// When non-nil and `downloadedAt == verifiedAt`, goh never downloaded these bytes —
    /// `downloadedAt` is the best "first observed" time.
    /// Additive-optional: absent from old records (decodes to nil); nil entries
    /// serialize without this key. `ProvenanceRecord.currentVersion` stays 1 — no format bump.
    public var verifiedAt: Date?

    /// Stat baseline captured by `fstat(2)` on the engine's file descriptor at the
    /// moment SHA-256 finalization completes. All five fields are present iff the
    /// engine ran `DownloadFile.fileStat()` successfully; any nil → `.notBaselined`.
    ///
    /// Stored as raw integers (exact through binary plist — Swift `Date` would lose
    /// `st_mtimespec` nanoseconds to a Double). Additive-optional: absent from old
    /// records (decode to nil); nil fields serialize without the key.
    /// `ProvenanceRecord.currentVersion` stays 1.
    public var recordedStatSize: Int64?          // st_size (off_t)
    public var recordedMtimeSeconds: Int64?      // st_mtimespec.tv_sec
    public var recordedMtimeNanoseconds: Int64?  // st_mtimespec.tv_nsec
    public var recordedInode: UInt64?            // st_ino (ino_t = __uint64_t)
    public var recordedDevice: Int64?            // st_dev (dev_t = Int32) widened losslessly

    public init(
        url: String,
        sha256: String,
        size: Int,
        downloadedAt: Date,
        destinationPath: String,
        verifiedAt: Date? = nil,
        recordedStatSize: Int64? = nil,
        recordedMtimeSeconds: Int64? = nil,
        recordedMtimeNanoseconds: Int64? = nil,
        recordedInode: UInt64? = nil,
        recordedDevice: Int64? = nil
    ) {
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.downloadedAt = downloadedAt
        self.destinationPath = destinationPath
        self.verifiedAt = verifiedAt
        self.recordedStatSize = recordedStatSize
        self.recordedMtimeSeconds = recordedMtimeSeconds
        self.recordedMtimeNanoseconds = recordedMtimeNanoseconds
        self.recordedInode = recordedInode
        self.recordedDevice = recordedDevice
    }
}
