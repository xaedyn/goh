// Sources/GohCore/Governor/ParallelismGovernor.swift

// MARK: — Governor decision

public enum GovernorDecision: Sendable, Equatable {
    case hold
    case addWorkers(Int)
    /// Reserved for cruise/throttle-response wiring: the live worker pool
    /// cooperatively sheds workers when excess concurrency is detected.
    case dropWorkers(Int)
    case commit(Int)
    case backOffPinLow
}

// MARK: — Governor

/// In-flight parallelism governor (spec §6). A BBR-style controller lifted to
/// *connection count*: it watches the **aggregate** delivery rate of the whole
/// download and hill-climbs the connection count up the bandit candidate ladder
/// `{2, 4, 8, 16}`, keeping a step only when it raised aggregate throughput by
/// at least `kneeGainThreshold`. The signal is the total bytes/sec across all
/// connections — NOT per-connection steadiness, which is far too noisy on a real
/// network to gate on (the per-worker "all within 5%" detector this replaces
/// never converged in the field; see the OVH long-fat-network benchmark).
///
/// Pure value type: deterministic and unit-testable. The engine feeds it one
/// aggregate sample per control tick via `record(aggregateBytesPerSecond:)` and
/// asks for a `decide(operatingN:remainingBytes:)` at each reap.
public struct ParallelismGovernor: Sendable {

    public struct Config: Sendable {
        /// Aggregate samples to accumulate at a connection count before judging
        /// it — long enough for the EWMA to settle and for newly-added
        /// connections to ramp past TCP slow-start. Replaces the old
        /// per-worker steady-state window/threshold.
        public var settleSamples: Int
        /// Minimum fractional aggregate-throughput gain to justify keeping a
        /// step up the ladder. Below this, the higher N isn't worth the extra
        /// connections and the governor settles at the lower N.
        public var kneeGainThreshold: Double
        public var hardCap: Int
        public var tinyFileThreshold: UInt64
        /// Cruise re-probe cadence: after this many cruise ticks the governor
        /// re-enters probe to re-test the next candidate (conditions change
        /// mid-transfer — the whole point of an in-flight governor).
        public var reprobeCadence: Int
        /// EWMA smoothing factor for the aggregate rate (0..1; higher = more
        /// responsive, noisier).
        public var rateAlpha: Double

        // First-cut values tuned against the OVH long-fat-network benchmark
        // (2026-06-02). The measured aggregate gain from 8→16 connections on a
        // real LFN path is ~10%, so kneeGainThreshold sits below that (0.07) to
        // reliably KEEP the higher N through per-sample noise, while still
        // rejecting the ~0% gain of a saturated link. settleSamples is short
        // enough to reach the optimal N quickly (less probe overhead) yet long
        // enough for added connections to ramp past TCP slow-start.
        public static let `default` = Config(
            settleSamples: 8,
            kneeGainThreshold: 0.07,
            hardCap: 16,
            tinyFileThreshold: 4 * 1024 * 1024,
            reprobeCadence: 40,
            rateAlpha: 0.3)

        public init(
            settleSamples: Int,
            kneeGainThreshold: Double,
            hardCap: Int,
            tinyFileThreshold: UInt64,
            reprobeCadence: Int,
            rateAlpha: Double
        ) {
            self.settleSamples = settleSamples
            self.kneeGainThreshold = kneeGainThreshold
            self.hardCap = hardCap
            self.tinyFileThreshold = tinyFileThreshold
            self.reprobeCadence = reprobeCadence
            self.rateAlpha = rateAlpha
        }
    }

    public enum Phase: Sendable, Equatable {
        case probe
        case cruise(operatingN: Int)
        case pinned(n: Int)
    }

    private var config: Config
    /// Smoothed aggregate delivery rate (bytes/sec across ALL connections).
    private var aggregateSmoothed: Double?
    /// Samples accumulated since the last connection-count change.
    private var samplesSinceStep: Int
    /// Aggregate measured at the connection count we stepped *up from* — the
    /// baseline the current N is judged against.
    private var aggregateBeforeStep: Double?
    private var nBeforeStep: Int?
    private var phase: Phase
    private var cruiseTicks: Int
    private var throttleDetected: Bool

    public init(config: Config = .default, rng: some RandomNumberGenerator) {
        self.config = config
        self.aggregateSmoothed = nil
        self.samplesSinceStep = 0
        self.aggregateBeforeStep = nil
        self.nBeforeStep = nil
        self.phase = .probe
        self.cruiseTicks = 0
        self.throttleDetected = false
        // RNG reserved for future epsilon-draw probe jitter; ignored here.
        _ = rng
    }

    /// A short label for the current phase, for the GOH_ENGINE_TRACE governor line.
    public var phaseLabel: String {
        switch phase {
        case .probe: return "probe"
        case .cruise: return "cruise"
        case .pinned: return "pinned"
        }
    }

    /// Feed one aggregate delivery-rate sample (total bytes/sec across all live
    /// connections, measured over the last control interval).
    public mutating func record(aggregateBytesPerSecond bps: Double) {
        let prev = aggregateSmoothed ?? bps
        aggregateSmoothed = config.rateAlpha * bps + (1 - config.rateAlpha) * prev
        samplesSinceStep += 1
    }

    public mutating func notifyThrottleDetected() {
        throttleDetected = true
        // Transition into `.pinned` so `outcome` reports `stabilized: false`
        // (suppressing the bandit observation): a throttled tail pinned to a
        // single connection is NOT a representative converged sample for the
        // operating N, and feeding it back would bias the per-host EWMA. This
        // also makes the `.pinned` phase reachable. (The throttle signal itself
        // is reserved for the deferred "back off, don't hard-fail, on 429"
        // wiring; until then `notifyThrottleDetected()` is unused at runtime.)
        phase = .pinned(n: 1)
    }

    /// The governor's converged outcome for the bandit feed. `effectiveN` is
    /// non-nil ONLY when the representative steady-state operating N is a bandit
    /// candidate {2, 4, 8, 16} AND cruise was reached.
    public var outcome: GovernorOutcome {
        switch phase {
        case .cruise(let opN):
            let eff: UInt8? = [2, 4, 8, 16].contains(opN) ? UInt8(opN) : nil
            return GovernorOutcome(effectiveN: eff, stabilized: true)
        case .probe, .pinned:
            return GovernorOutcome(effectiveN: nil, stabilized: false)
        }
    }

    public mutating func decide(operatingN: Int, remainingBytes: UInt64) -> GovernorDecision {
        if remainingBytes < config.tinyFileThreshold {
            return .commit(1)
        }
        if throttleDetected {
            return .backOffPinLow
        }
        switch phase {
        case .pinned(let n):
            return .commit(n)

        case .cruise(let opN):
            cruiseTicks += 1
            if cruiseTicks >= config.reprobeCadence,
               let target = candidateAbove(opN), target <= config.hardCap {
                // Re-test the next candidate — conditions may have changed.
                beginStep(from: opN)
                return .addWorkers(target - opN)
            }
            return .hold

        case .probe:
            // Dwell: wait for the EWMA to settle (and new connections to ramp)
            // before judging this connection count.
            guard samplesSinceStep >= config.settleSamples,
                  let aggregate = aggregateSmoothed, aggregate > 0 else {
                return .hold
            }
            // If we just stepped up, judge whether the step paid off.
            if let before = aggregateBeforeStep, let n0 = nBeforeStep, before > 0 {
                let gain = (aggregate - before) / before
                if gain < config.kneeGainThreshold {
                    // The higher N didn't earn its keep — settle at the lower N.
                    enterCruise(n0)
                    return .commit(n0)
                }
                // It paid off — fall through and try the next candidate.
            }
            if let target = candidateAbove(operatingN), target <= config.hardCap {
                beginStep(from: operatingN)
                return .addWorkers(target - operatingN)
            }
            // No higher candidate — we're at the top of the ladder. Settle.
            enterCruise(operatingN)
            return .commit(operatingN)
        }
    }

    // MARK: — Helpers

    /// Snapshot the current aggregate as the baseline and arm the dwell for a
    /// probe step up from `n`.
    private mutating func beginStep(from n: Int) {
        aggregateBeforeStep = aggregateSmoothed
        nBeforeStep = n
        samplesSinceStep = 0
        phase = .probe
    }

    private mutating func enterCruise(_ operatingN: Int) {
        phase = .cruise(operatingN: operatingN)
        cruiseTicks = 0
        aggregateBeforeStep = nil
        nBeforeStep = nil
    }

    private func candidateAbove(_ n: Int) -> Int? {
        let candidates = [2, 4, 8, 16]
        return candidates.first { $0 > n }
    }
}
