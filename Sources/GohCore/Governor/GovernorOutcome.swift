// Sources/GohCore/Governor/GovernorOutcome.swift

/// Daemon-internal result from a governed download.
///
/// Carries the governor's converged operating point to the completion sink
/// (`completedDownloadHandler`) so the bandit can record a candidate-aligned
/// observation. This struct is NEVER on the wire — it is not part of `JobSummary`
/// and carries no protocolVersion annotation.
///
/// `effectiveN` is non-nil iff the governor's steady-state operating N is a bandit
/// candidate {2, 4, 8, 16}. Off-candidate convergence (e.g. binary-search to 6)
/// produces nil — no observation is recorded in that case, so the frozen EWMA
/// never receives a biased/snapped value.
public struct GovernorOutcome: Sendable, Equatable {
    /// The candidate-aligned representative operating N during cruise, or nil
    /// if the governor converged off-candidate or did not stabilize.
    public var effectiveN: UInt8?
    /// Whether the governor reached stable cruise before the download ended.
    public var stabilized: Bool

    public init(effectiveN: UInt8?, stabilized: Bool) {
        self.effectiveN = effectiveN
        self.stabilized = stabilized
    }

    /// A sentinel meaning "governor not engaged" (explicit N or tiny file).
    public static let governorOff = GovernorOutcome(effectiveN: nil, stabilized: false)
}
