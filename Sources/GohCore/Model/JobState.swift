/// The lifecycle state of a download job (`DESIGN.md` §2.2). Encoded as the wire
/// string of its case name. `completed` and `failed` are terminal.
public enum JobState: String, Codable, Sendable, CaseIterable {
    case queued
    case active
    case paused
    case completed
    case failed
}

/// Why a job is paused (`DESIGN.md` §2.2). A `network` pause auto-resumes when
/// connectivity returns; a `user` pause does not.
public enum PauseReason: String, Codable, Sendable, CaseIterable {
    case user
    case network
}

/// A job's scheduling priority (`DESIGN.md` §3.1). Orders selection among
/// `queued` jobs; running jobs are never preempted (§2.2 "Priority and
/// preemption").
public enum Priority: String, Codable, Sendable, CaseIterable {
    case low
    case normal
    case high
}
