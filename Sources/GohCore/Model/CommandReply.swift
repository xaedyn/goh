/// The `ls` command's success reply (`DESIGN.md` §3.2) — every job in creation
/// order. `add`, `pause`, and `resume` reply with a bare ``JobSummary``.
public struct LsReply: Codable, Sendable, Equatable {
    public var jobs: [JobSummary]
    /// The daemon's compiled-in ``GohFeatureLevel/current``.
    /// `nil` from a pre-feature daemon (older than featureLevel 1).
    /// Additive-optional: old clients ignore it; new clients treat nil as stale.
    /// `protocolVersion` stays 4.
    public var featureLevel: Int?

    public init(jobs: [JobSummary], featureLevel: Int? = nil) {
        self.jobs = jobs
        self.featureLevel = featureLevel
    }

    private enum CodingKeys: String, CodingKey {
        case jobs, featureLevel
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobs = try c.decode([JobSummary].self, forKey: .jobs)
        featureLevel = try c.decodeIfPresent(Int.self, forKey: .featureLevel)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobs, forKey: .jobs)
        try c.encodeIfPresent(featureLevel, forKey: .featureLevel)
    }
}

/// The `rm` command's success reply (`DESIGN.md` §3.5).
public struct RmReply: Codable, Sendable, Equatable {
    public var removedJobID: UInt64

    public init(removedJobID: UInt64) {
        self.removedJobID = removedJobID
    }
}

/// The `recordVerifiedProvenance` command's success reply — zero-payload acknowledgement.
public struct AckReply: Codable, Sendable, Equatable {
    public init() {}
}

/// The `forgetProvenance` command's success reply.
/// `forgotCount` is the number of ledger entries actually removed by this call
/// (entries whose canonical `destinationPath` matched a requested path).
///
/// `ProvenanceStore.forget(paths:)` is idempotent at the store layer — a path
/// matching no entry is silently skipped. The CLI, however, only ever sends paths
/// it has *just* confirmed are tracked (`forget <path>` after a ledger lookup match;
/// `forget --missing --confirm` from a fresh enumeration of stored entries), so under
/// that invariant `forgotCount` is expected to equal `paths.count`. A smaller count
/// therefore means an entry was concurrently removed between the CLI's read and the
/// daemon's write — a race the CLI surfaces as a non-success outcome rather than a
/// clean success line. (Store-write failure is a separate path: it throws and the
/// dispatcher returns `.failure`, not this reply.)
public struct ForgetProvenanceReply: Codable, Sendable, Equatable {
    public var forgotCount: Int
    public init(forgotCount: Int) { self.forgotCount = forgotCount }
}
