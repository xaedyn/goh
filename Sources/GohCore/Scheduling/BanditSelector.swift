import Foundation

/// D4 — Selection reason for diagnostics and test assertions.
public enum SelectionReason: Sendable, Equatable {
    /// No profile exists, the profile's all arms are cold, or hostKey is nil.
    case cold
    /// Best-EWMA arm chosen; all arms have ≥ `minSamples` observations.
    case exploit
    /// Random draw (epsilon draw or under-sampled arm forced exploration).
    case explore
    /// The caller supplied an explicit `--connections` count; the bandit was not consulted.
    case explicit
}

/// Pure epsilon-greedy bandit selector over the fixed candidate set.
///
/// Accepts an injected `RandomNumberGenerator` so tests can seed it
/// for determinism. The `select` method is nonisolated and synchronous —
/// it reads only its arguments; all mutable state lives in the caller's RNG.
public struct BanditSelector: Sendable {

    // MARK: — Candidate set and tuning (non-frozen constants per D3)

    /// The connection counts the bandit selects from (D4).
    public static let candidateSet: [UInt8] = [2, 4, 8, 16]

    /// Cold-start / nil-profile default.
    public static let defaultN: UInt8 = 8

    /// Exploration probability (non-frozen, tuned empirically).
    public let epsilon: Double

    /// Minimum arm samples before the arm is considered settled (non-frozen).
    public let minSamples: UInt32

    public init(
        epsilon: Double = 0.15,
        minSamples: UInt32 = 2
    ) {
        self.epsilon = epsilon
        self.minSamples = minSamples
    }

    // MARK: — Selection

    /// Returns `(chosenN, reason)`.
    ///
    /// - If `profile` is nil: `(defaultN, .cold)`.
    /// - If any arm in the candidate set has fewer than `minSamples` observations:
    ///   pick an under-sampled arm at random (`.explore`).
    /// - Else with probability `epsilon`: pick a random arm (`.explore`).
    /// - Else: pick the arm with the highest `throughputEWMA` (`.exploit`).
    ///
    /// An arm is only considered if its `connectionCount` is in `candidateSet`.
    /// A candidate count with no arm record is treated as having 0 samples and
    /// 0 throughput (cold arm — forces exploration until it has enough samples).
    public func select(
        profile: HostProfile?,
        rng: inout some RandomNumberGenerator
    ) -> (n: UInt8, reason: SelectionReason) {
        guard let profile else {
            return (Self.defaultN, .cold)
        }

        let candidates = Self.candidateSet
        // Map candidate set to (count, observation?).
        let arms: [(n: UInt8, obs: ConnObservation?)] = candidates.map { n in
            (n, profile.arms.first { $0.connectionCount == n })
        }

        // If any arm is under-sampled, explore: pick uniformly from cold arms.
        let coldArms = arms.filter { (_, obs) in
            (obs?.sampleCount ?? 0) < minSamples
        }
        if !coldArms.isEmpty {
            let chosen = coldArms.randomElement(using: &rng)!
            return (chosen.n, .explore)
        }

        // Epsilon draw — explore uniformly.
        let draw = Double(rng.next()) / Double(UInt64.max)
        if draw < epsilon {
            let chosen = arms.randomElement(using: &rng)!
            return (chosen.n, .explore)
        }

        // Exploit: best EWMA.
        let best = arms.max { lhs, rhs in
            (lhs.obs?.throughputEWMA ?? 0) < (rhs.obs?.throughputEWMA ?? 0)
        }!
        return (best.n, .exploit)
    }
}
