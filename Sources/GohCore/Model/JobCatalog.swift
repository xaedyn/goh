/// The daemon's persisted job catalog (`DESIGN.md` §2) — the on-disk form of the
/// `JobStore`'s state.
///
/// Daemon-owned: it is written and read only by `gohd`, never by an external
/// tool, so it is not a wire contract. It still carries a `version` so the load
/// path can migrate an older on-disk schema as the daemon evolves.
public struct JobCatalog: Codable, Sendable, Equatable {
    /// The catalog schema version — checked on load for forward migration.
    public var version: Int
    /// The next job id the store will assign.
    public var nextID: UInt64
    /// The persisted jobs, in creation order.
    public var jobs: [JobSummary]

    public init(version: Int, nextID: UInt64, jobs: [JobSummary]) {
        self.version = version
        self.nextID = nextID
        self.jobs = jobs
    }

    /// The current catalog schema version.
    public static let currentVersion = 1

    /// An empty catalog at the current schema version.
    public static var empty: JobCatalog {
        JobCatalog(version: currentVersion, nextID: 1, jobs: [])
    }
}
