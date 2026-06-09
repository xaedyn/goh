/// The baseline captured when one file passes a deep-verify SHA-256 check.
///
/// Travels the side channel from `VerifyAllRunner` to the caller — never inside
/// `VerifyAllReport` (which is frozen at reportVersion 1). The caller converts
/// this into a `VerifiedProvenanceEntry` and sends it to the daemon.
///
/// **Field semantics:**
/// - `stat.size` → `VerifiedProvenanceEntry.recordedStatSize` (fstat st_size; fast-check baseline)
/// - `hashedByteCount` → `VerifiedProvenanceEntry.size` (streaming byte count; display/download)
/// For a normal regular file they are equal. They are kept distinct so the wiring is
/// unambiguous (B1 invariant: recordedStatSize is ALWAYS from stat.size).
nonisolated public struct VerifiedBaseline: Sendable, Equatable {
    /// Canonical destination path (standardizedFileURL.path form, as stored in the ledger).
    public let destinationPath: String
    /// Source URL as stored in the ledger entry.
    public let url: String
    /// "sha256:"-prefixed hash — the confirmed hash that matched the ledger record.
    public let sha256: String
    /// Streaming byte count from `FileDigest`. Feeds `VerifiedProvenanceEntry.size`.
    public let hashedByteCount: Int
    /// Filesystem metadata from `fstat(2)` on the open hash handle at EOF.
    /// `stat.size` feeds `VerifiedProvenanceEntry.recordedStatSize`.
    public let stat: FileStat

    public init(
        destinationPath: String,
        url: String,
        sha256: String,
        hashedByteCount: Int,
        stat: FileStat
    ) {
        self.destinationPath = destinationPath
        self.url = url
        self.sha256 = sha256
        self.hashedByteCount = hashedByteCount
        self.stat = stat
    }
}
