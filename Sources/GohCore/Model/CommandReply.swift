/// The `ls` command's success reply (`DESIGN.md` §3.2) — every job in creation
/// order. `add`, `pause`, and `resume` reply with a bare ``JobSummary``.
public struct LsReply: Codable, Sendable, Equatable {
    public var jobs: [JobSummary]

    public init(jobs: [JobSummary]) {
        self.jobs = jobs
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
