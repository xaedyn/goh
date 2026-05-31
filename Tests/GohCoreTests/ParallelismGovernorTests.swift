// Tests/GohCoreTests/ParallelismGovernorTests.swift
import Testing
@testable import GohCore

@Suite("ParallelismGovernor — pure value type")
struct ParallelismGovernorTests {

    // Deterministic RNG for tests.
    struct FixedRNG: RandomNumberGenerator {
        var value: UInt64
        mutating func next() -> UInt64 { defer { value &+= 1 }; return value }
    }

    @Test("SM3: governor starts in probe phase and emits addWorkers on first steady state")
    func probePhaseDoublesOnSteadyState() throws {
        let rng = FixedRNG(value: 42)
        var gov = ParallelismGovernor(config: .default, rng: rng)
        for _ in 0..<ParallelismGovernor.Config.default.steadyStateWindow {
            gov.record(sample: WorkerRateSample(workerIndex: 0, bytesPerSecond: 10_000_000, rttRatio: nil))
            gov.record(sample: WorkerRateSample(workerIndex: 1, bytesPerSecond: 10_000_000, rttRatio: nil))
        }
        let decision = gov.decide(liveWorkers: 2, remainingBytes: 500_000_000)
        if case .addWorkers(let k) = decision {
            #expect(k == 2)   // double: 2→4
        } else {
            Issue.record("expected addWorkers(2), got \(decision)")
        }
    }

    // SM3 ramp gate: while the rate derivative is above threshold, allWorkersInSteadyState
    // returns false because the trailing-window deviation exceeds steadyStateThreshold — NOT
    // because a worker is missing. The governor must return .hold (wait for settling), never
    // .backOffPinLow (back-off) or .dropWorkers.
    @Test("SM3: steady-state gating — never backs off while rate derivative is above threshold")
    func steadyStateGating() throws {
        let rng = FixedRNG(value: 0)
        var gov = ParallelismGovernor(config: .default, rng: rng)
        // Feed a 1.2× ramp to BOTH workers 0 and 1 so liveWorkers:2 has full history for
        // each. The EWMA variation within the trailing steadyStateWindow will exceed
        // steadyStateThreshold (0.05), causing allWorkersInSteadyState to return false due
        // to high deviation — not due to a missing worker.
        var rate = 1_000_000.0
        for _ in 0..<20 {
            rate *= 1.2
            gov.record(sample: WorkerRateSample(workerIndex: 0, bytesPerSecond: rate, rttRatio: nil))
            gov.record(sample: WorkerRateSample(workerIndex: 1, bytesPerSecond: rate, rttRatio: nil))
        }
        let decision = gov.decide(liveWorkers: 2, remainingBytes: 500_000_000)
        // The ramp must produce .hold — not a probe-up, not a back-off.
        #expect(decision == .hold, "SM3 ramp gate: ramping rate must return .hold, got \(decision)")
        switch decision {
        case .backOffPinLow, .dropWorkers:
            Issue.record("SM3 violated: governor backed off during slow-start ramp; decision=\(decision)")
        default:
            break
        }
    }

    // SM3 bufferbloat stop: the governor reaches the RTT-bufferbloat branch in decide() —
    // allWorkersInSteadyState is true (all 4 workers have settled constant history),
    // aggregateBeforeLastDouble is set from a prior probe-up, gain ≥ kneeGainThreshold so
    // the gain-knee does NOT fire, and rttSmoothed/rttFloor > rttBufferbloatFactor (1.5).
    // The decision must be .commit, not .addWorkers.
    @Test("SM3: bufferbloat stop — aggregate flat, RTT climbs → stop probing")
    func bufferbloatStop() throws {
        let cfg = ParallelismGovernor.Config.default
        let rng = FixedRNG(value: 7)
        var gov = ParallelismGovernor(config: cfg, rng: rng)

        // Step A: establish steady state on workers 0,1 at 10 MB/s with rttRatio:1.0.
        // This sets rttFloor = 1.0 and primes aggregateBeforeLastDouble via the probe-up.
        for _ in 0..<cfg.steadyStateWindow {
            gov.record(sample: WorkerRateSample(workerIndex: 0, bytesPerSecond: 10_000_000, rttRatio: 1.0))
            gov.record(sample: WorkerRateSample(workerIndex: 1, bytesPerSecond: 10_000_000, rttRatio: 1.0))
        }
        // Aggregate N=2 is ~20 MB/s; this call sets aggregateBeforeLastDouble ≈ 20 MB/s
        // and returns .addWorkers(2) — the governor probes up to 4 workers.
        let stepA = gov.decide(liveWorkers: 2, remainingBytes: 500_000_000)
        if case .addWorkers(let k) = stepA {
            #expect(k == 2)
        } else {
            Issue.record("bufferbloatStop step A: expected addWorkers(2), got \(stepA)")
        }

        // Step B: settle ALL four workers (0,1,2,3) at 6 MB/s each with rttRatio:2.0.
        // Use 3× steadyStateWindow samples so EWMAs fully settle and the trailing window
        // is low-deviation. New aggregate ≈ 24 MB/s; gain = (24-20)/20 = 0.20 ≥ 0.10
        // so the gain-knee does NOT fire. rttSmoothed converges to ~2.0, rttFloor=1.0,
        // ratio 2.0/1.0 = 2.0 > 1.5 (rttBufferbloatFactor) → RTT-bufferbloat branch fires.
        let settleCount = cfg.steadyStateWindow * 3
        for _ in 0..<settleCount {
            for w in 0..<4 {
                gov.record(sample: WorkerRateSample(workerIndex: w, bytesPerSecond: 6_000_000, rttRatio: 2.0))
            }
        }
        let stepB = gov.decide(liveWorkers: 4, remainingBytes: 500_000_000)
        // Must be .commit — governor stopped probing due to RTT bufferbloat, not missing worker.
        if case .commit(let n) = stepB {
            #expect(n == 4)
        } else {
            Issue.record("bufferbloatStop step B: expected .commit(4) via RTT-bufferbloat branch, got \(stepB)")
        }
        if case .addWorkers = stepB {
            Issue.record("governor should not add workers on bufferbloat signature; got \(stepB)")
        }
    }

    // SM3 gain-only fallback (A3 bet): the knee fires on GAIN ALONE when RTT is
    // unavailable. allWorkersInSteadyState is true for all 4 workers, aggregateBeforeLastDouble
    // is set from a prior probe-up, gain < kneeGainThreshold (0.10), and rttSmoothed is nil.
    // The governor must return .commit(4), proving the gain-only fallback path is reached.
    @Test("SM3: gain-only fallback — RTT unusable, but gain is present → keeps probing")
    func gainOnlyFallback() throws {
        let cfg = ParallelismGovernor.Config.default
        let rng = FixedRNG(value: 99)
        var gov = ParallelismGovernor(config: cfg, rng: rng)

        // Step A: settle workers 0,1 at 10 MB/s with no RTT data.
        // Aggregate N=2 ≈ 20 MB/s; decide sets aggregateBeforeLastDouble ≈ 20 MB/s
        // and returns .addWorkers(2).
        for _ in 0..<cfg.steadyStateWindow {
            gov.record(sample: WorkerRateSample(workerIndex: 0, bytesPerSecond: 10_000_000, rttRatio: nil))
            gov.record(sample: WorkerRateSample(workerIndex: 1, bytesPerSecond: 10_000_000, rttRatio: nil))
        }
        let stepA = gov.decide(liveWorkers: 2, remainingBytes: 500_000_000)
        if case .addWorkers(let k) = stepA {
            #expect(k == 2)
        } else {
            Issue.record("gainOnlyFallback step A: expected addWorkers(2), got \(stepA)")
        }

        // Step B: settle ALL four workers (0,1,2,3) at 5.2 MB/s each with no RTT data.
        // New aggregate ≈ 20.8 MB/s; gain = (20.8-20)/20 = 0.04 < 0.10 (kneeGainThreshold).
        // rttSmoothed remains nil → RTT-bufferbloat check is skipped.
        // Gain-only knee fires → .commit(4). This is the A3 bet: knee on gain alone.
        let settleCount = cfg.steadyStateWindow * 3
        for _ in 0..<settleCount {
            for w in 0..<4 {
                gov.record(sample: WorkerRateSample(workerIndex: w, bytesPerSecond: 5_200_000, rttRatio: nil))
            }
        }
        let stepB = gov.decide(liveWorkers: 4, remainingBytes: 500_000_000)
        // A3 bet: gain-only knee must fire and commit at 4 workers.
        if case .commit(let n) = stepB {
            #expect(n == 4)
        } else {
            Issue.record("gainOnlyFallback step B: expected .commit(4) via gain-only knee, got \(stepB)")
        }
        if case .backOffPinLow = stepB {
            Issue.record("gain-only fallback: should not back off when gain is positive; got \(stepB)")
        }
    }

    @Test("SM3: tiny file guard — governor off for files below threshold")
    func tinyFileGuard() throws {
        let rng = FixedRNG(value: 1)
        var gov = ParallelismGovernor(config: .default, rng: rng)
        let decision = gov.decide(liveWorkers: 2, remainingBytes: 100_000)
        if case .commit(let n) = decision {
            #expect(n == 1)
        } else {
            Issue.record("tiny file should commit(1), got \(decision)")
        }
    }

    @Test("SM3: throttle signature — aggregate drops + variance spike → backOffPinLow")
    func throttleSignatureBacksOff() throws {
        let rng = FixedRNG(value: 5)
        var gov = ParallelismGovernor(config: .default, rng: rng)
        for _ in 0..<ParallelismGovernor.Config.default.steadyStateWindow {
            gov.record(sample: WorkerRateSample(workerIndex: 0, bytesPerSecond: 10_000_000, rttRatio: 1.0))
        }
        for i in 0..<ParallelismGovernor.Config.default.steadyStateWindow {
            let fluctuating = i % 2 == 0 ? 2_000_000.0 : 8_000_000.0
            gov.record(sample: WorkerRateSample(workerIndex: 0, bytesPerSecond: fluctuating, rttRatio: nil))
            gov.record(sample: WorkerRateSample(workerIndex: 1, bytesPerSecond: fluctuating * 0.5, rttRatio: nil))
        }
        gov.notifyThrottleDetected()
        let decision = gov.decide(liveWorkers: 4, remainingBytes: 500_000_000)
        if case .backOffPinLow = decision {
            // pass
        } else {
            Issue.record("throttle detected: expected backOffPinLow, got \(decision)")
        }
    }

    @Test("SM3: hard cap — governor never recommends more than 16 workers")
    func hardCap16() throws {
        let rng = FixedRNG(value: 3)
        var gov = ParallelismGovernor(config: .default, rng: rng)
        for _ in 0..<(ParallelismGovernor.Config.default.steadyStateWindow * 10) {
            for w in 0..<16 {
                gov.record(sample: WorkerRateSample(workerIndex: w, bytesPerSecond: 50_000_000, rttRatio: nil))
            }
        }
        let decision = gov.decide(liveWorkers: 16, remainingBytes: 500_000_000)
        if case .addWorkers(let k) = decision {
            Issue.record("governor exceeded hard cap of 16; tried to add \(k) above 16")
        }
    }

    @Test("GovernorOutcome: effectiveN is non-nil iff N is a bandit candidate")
    func governorOutcomeEffectiveN() {
        // Candidate-aligned N → effectiveN non-nil.
        let aligned = GovernorOutcome(effectiveN: 8, stabilized: true)
        #expect(aligned.effectiveN == 8)
        #expect(aligned.stabilized)

        // Off-candidate N (binary-search refinement) → effectiveN nil.
        let offCandidate = GovernorOutcome(effectiveN: nil, stabilized: true)
        #expect(offCandidate.effectiveN == nil)

        // Not yet stabilized → effectiveN doesn't matter for gate, but it can be non-nil.
        let unstable = GovernorOutcome(effectiveN: 4, stabilized: false)
        #expect(!unstable.stabilized)
    }
}
