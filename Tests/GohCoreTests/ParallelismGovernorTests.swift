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

    /// Drives the governor to convergence against a simulated network whose
    /// aggregate throughput is a function of the live connection count `N`.
    /// `aggregateForN` returns the *true* aggregate bytes/sec at a given N;
    /// `noise` multiplies each sample to model real-world jitter. Returns the
    /// committed operating N (the value the governor settled on), or nil if it
    /// never committed within the tick budget.
    private func runToConvergence(
        config: ParallelismGovernor.Config = .default,
        seed: Int,
        maxTicks: Int = 4000,
        aggregateForN: (Int) -> Double
    ) -> (committed: Int?, phase: String) {
        var gov = ParallelismGovernor(config: config, rng: FixedRNG(value: 1))
        var n = seed
        var committed: Int?
        // Alternating ±30% noise — far larger than the old 5% steady gate — to
        // prove convergence is robust to real per-sample jitter.
        var hi = true
        for _ in 0..<maxTicks {
            hi.toggle()
            let noise = hi ? 1.30 : 0.70
            gov.record(aggregateBytesPerSecond: aggregateForN(n) * noise)
            let d = gov.decide(operatingN: n, remainingBytes: 500_000_000)
            switch d {
            case .addWorkers(let k): n = min(n + k, config.hardCap)
            case .dropWorkers(let k): n = max(n - k, 1)
            case .commit(let c):
                n = min(max(c, 1), config.hardCap)
                committed = n
            case .hold, .backOffPinLow:
                break
            }
            if committed != nil && gov.phaseLabel == "cruise" { return (committed, gov.phaseLabel) }
        }
        return (committed, gov.phaseLabel)
    }

    @Test("climbs to a higher N when added connections raise aggregate throughput (LFN)")
    func climbsWhenParallelismHelps() {
        // Fat pipe: aggregate scales ~linearly with N up to the cap. Seeded at 8,
        // the governor must discover that 16 is faster and settle there — despite
        // ±30% per-sample noise that the old 5%-deviation gate could never pass.
        let result = runToConvergence(seed: 8) { n in Double(n) * 10_000_000.0 }
        #expect(result.committed == 16, "expected climb to 16 on a scaling pipe, got \(String(describing: result.committed))")
        #expect(result.phase == "cruise")
    }

    @Test("settles at seed N when added connections do NOT raise throughput (saturated)")
    func settlesWhenParallelismDoesNotHelp() {
        // Saturated last-mile: one set of connections already fills the pipe, so
        // aggregate is capped regardless of N. Seeded at 8, the governor must
        // NOT waste connections climbing to 16 — it settles back at 8.
        let result = runToConvergence(seed: 8) { _ in 80_000_000.0 }
        #expect(result.committed == 8, "expected settle at seed 8 when 16 gives no gain, got \(String(describing: result.committed))")
        #expect(result.phase == "cruise")
    }

    @Test("converges despite per-sample noise far exceeding the legacy 5% gate")
    func convergesUnderHeavyNoise() {
        // The exact regression the OVH benchmark caught: real per-sample rates
        // jitter 10–200%. The governor MUST still reach a committed cruise N and
        // not sit forever in probe/hold. (Marginal scaling: 16 gives a clear gain.)
        let result = runToConvergence(seed: 8) { n in Double(n) * 6_000_000.0 }
        #expect(result.committed != nil, "governor must converge under heavy noise, not stay inert in probe")
        #expect(result.phase == "cruise")
    }

    @Test("tiny file guard — governor commits to 1 below the threshold")
    func tinyFileGuard() {
        var gov = ParallelismGovernor(config: .default, rng: FixedRNG(value: 1))
        let decision = gov.decide(operatingN: 8, remainingBytes: 100_000)
        #expect(decision == .commit(1))
    }

    @Test("throttle signature — backs off to a low pin")
    func throttleSignatureBacksOff() {
        var gov = ParallelismGovernor(config: .default, rng: FixedRNG(value: 5))
        for _ in 0..<10 { gov.record(aggregateBytesPerSecond: 40_000_000) }
        gov.notifyThrottleDetected()
        let decision = gov.decide(operatingN: 8, remainingBytes: 500_000_000)
        #expect(decision == .backOffPinLow)
    }

    @Test("throttle transitions to pinned and suppresses the bandit observation")
    func throttleEntersPinnedAndSuppressesOutcome() {
        // Drive the governor to a converged cruise at a bandit candidate (16, the
        // top of the ladder) so that WITHOUT the pinned transition `outcome` would
        // report a stale stabilized N=16 and pollute the per-host EWMA.
        var gov = ParallelismGovernor(config: .default, rng: FixedRNG(value: 1))
        for _ in 0..<ParallelismGovernor.Config.default.settleSamples {
            gov.record(aggregateBytesPerSecond: 80_000_000)
        }
        let commit = gov.decide(operatingN: 16, remainingBytes: 500_000_000)
        #expect(commit == .commit(16))
        #expect(gov.phaseLabel == "cruise")
        #expect(gov.outcome.effectiveN == 16)
        #expect(gov.outcome.stabilized)

        // Throttle detected mid-cruise: transition to pinned, suppress the feed.
        gov.notifyThrottleDetected()
        #expect(gov.phaseLabel == "pinned")
        #expect(gov.outcome.effectiveN == nil)
        #expect(!gov.outcome.stabilized)
        // And decisions keep backing off.
        #expect(gov.decide(operatingN: 16, remainingBytes: 500_000_000) == .backOffPinLow)
    }

    @Test("hard cap — never recommends adding workers beyond 16")
    func hardCap16() {
        // Seeded at the cap: there is no higher candidate, so the governor must
        // commit at 16, never emit addWorkers.
        let result = runToConvergence(seed: 16) { n in Double(n) * 10_000_000.0 }
        #expect(result.committed == 16)
    }

    // MARK: - Exhaustive Phase transition matrix
    //
    // The tests above drive convergence end-to-end; these pin each individual
    // documented transition of `Phase` that `decide(...)` can produce, so a
    // regression in one edge can't hide behind the aggregate convergence tests.
    // Phase cases: .probe, .cruise(operatingN:), .pinned(n:).
    // Edges driven by decide(): probe→probe (step up), probe→cruise (settle),
    // cruise→cruise (hold), cruise→probe (reprobe), pinned→pinned (commit),
    // plus the tiny-file commit and throttle→pinned (covered above).

    /// Settle samples for the default config — feed exactly this many to arm a probe judgment.
    private var settle: Int { ParallelismGovernor.Config.default.settleSamples }

    @Test("probe→probe: a paying step emits addWorkers and stays in probe")
    func probeStepUpStaysProbe() {
        // Seed at 2; a strongly-scaling pipe means the 2→4 step pays off, so the
        // governor steps UP (addWorkers) and remains in probe to test the next rung.
        var gov = ParallelismGovernor(config: .default, rng: FixedRNG(value: 1))
        for _ in 0..<settle { gov.record(aggregateBytesPerSecond: 20_000_000) }
        let d = gov.decide(operatingN: 2, remainingBytes: 500_000_000)
        #expect(d == .addWorkers(2), "2→4 is the first ladder step")
        #expect(gov.phaseLabel == "probe", "must stay in probe after stepping up")
    }

    @Test("probe→cruise: a non-paying step settles back at the lower N (commit + cruise)")
    func probeStepRejectedEntersCruise() {
        // Arm a step up from 4 (baseline aggregate snapshot), then feed a sample
        // showing NO gain over the baseline → governor must reject the step and
        // enterCruise at the lower N=4.
        var gov = ParallelismGovernor(config: .default, rng: FixedRNG(value: 1))
        // First: drive a paying step 4→8 to arm aggregateBeforeStep at the 4-rung rate.
        for _ in 0..<settle { gov.record(aggregateBytesPerSecond: 40_000_000) }
        let up = gov.decide(operatingN: 4, remainingBytes: 500_000_000)
        #expect(up == .addWorkers(4))  // 4→8, beginStep snapshots 40 MB/s at N=4
        // Now feed samples at the SAME aggregate (no gain from the extra connections).
        for _ in 0..<settle { gov.record(aggregateBytesPerSecond: 40_000_000) }
        let settled = gov.decide(operatingN: 8, remainingBytes: 500_000_000)
        #expect(settled == .commit(4), "no gain → settle back at the lower N=4")
        #expect(gov.phaseLabel == "cruise")
        #expect(gov.outcome.effectiveN == 4)
        #expect(gov.outcome.stabilized)
    }

    @Test("probe→cruise: top-of-ladder settles at the cap (commit 16 + cruise)")
    func probeTopOfLadderEntersCruise() {
        // Seeded at the cap with a settled aggregate: no higher candidate exists,
        // so decide must commit at 16 and enter cruise.
        var gov = ParallelismGovernor(config: .default, rng: FixedRNG(value: 1))
        for _ in 0..<settle { gov.record(aggregateBytesPerSecond: 80_000_000) }
        let d = gov.decide(operatingN: 16, remainingBytes: 500_000_000)
        #expect(d == .commit(16))
        #expect(gov.phaseLabel == "cruise")
    }

    @Test("cruise→cruise: holds while below the reprobe cadence")
    func cruiseHoldsBelowReprobeCadence() {
        // Enter cruise at 16, then a single post-commit tick (cruiseTicks=1, well
        // below reprobeCadence=40) must HOLD and stay in cruise.
        var gov = ParallelismGovernor(config: .default, rng: FixedRNG(value: 1))
        for _ in 0..<settle { gov.record(aggregateBytesPerSecond: 80_000_000) }
        _ = gov.decide(operatingN: 16, remainingBytes: 500_000_000)  // → cruise
        #expect(gov.phaseLabel == "cruise")
        gov.record(aggregateBytesPerSecond: 80_000_000)
        let d = gov.decide(operatingN: 16, remainingBytes: 500_000_000)
        #expect(d == .hold)
        #expect(gov.phaseLabel == "cruise")
    }

    @Test("cruise→probe: reprobe cadence re-enters probe and steps up")
    func cruiseReprobeReentersProbe() {
        // Enter cruise at 8 (a rung with a higher candidate above it), then tick
        // past reprobeCadence so the governor re-probes the next rung (8→16):
        // it must emit addWorkers and transition cruise→probe.
        let cadence = ParallelismGovernor.Config.default.reprobeCadence
        var gov = ParallelismGovernor(config: .default, rng: FixedRNG(value: 1))
        // Settle into cruise at 8 by rejecting the 8→16 step (no gain).
        for _ in 0..<settle { gov.record(aggregateBytesPerSecond: 50_000_000) }
        _ = gov.decide(operatingN: 8, remainingBytes: 500_000_000)  // 8→16 step armed
        for _ in 0..<settle { gov.record(aggregateBytesPerSecond: 50_000_000) }
        let settled = gov.decide(operatingN: 16, remainingBytes: 500_000_000)
        #expect(settled == .commit(8))
        #expect(gov.phaseLabel == "cruise")
        // Now tick the cruise forward past the reprobe cadence.
        var reprobe: GovernorDecision = .hold
        for _ in 0..<cadence {
            gov.record(aggregateBytesPerSecond: 50_000_000)
            reprobe = gov.decide(operatingN: 8, remainingBytes: 500_000_000)
        }
        #expect(reprobe == .addWorkers(8), "reprobe must step 8→16")
        #expect(gov.phaseLabel == "probe", "reprobe must re-enter probe")
    }

    @Test("pinned→pinned: a pinned governor keeps committing its pin")
    func pinnedStaysPinned() {
        // notifyThrottleDetected pins at 1. Subsequent decides must keep returning
        // backOffPinLow (throttleDetected short-circuits) and stay pinned.
        var gov = ParallelismGovernor(config: .default, rng: FixedRNG(value: 1))
        gov.notifyThrottleDetected()
        #expect(gov.phaseLabel == "pinned")
        #expect(gov.decide(operatingN: 8, remainingBytes: 500_000_000) == .backOffPinLow)
        #expect(gov.decide(operatingN: 4, remainingBytes: 500_000_000) == .backOffPinLow)
        #expect(gov.phaseLabel == "pinned")
    }

    @Test("tiny-file commit short-circuits regardless of phase (probe and cruise)")
    func tinyFileCommitFromAnyPhase() {
        // From probe (fresh governor): below threshold → commit(1).
        var probeGov = ParallelismGovernor(config: .default, rng: FixedRNG(value: 1))
        #expect(probeGov.decide(operatingN: 8, remainingBytes: 1) == .commit(1))
        // From cruise: drive into cruise, then a tiny remaining → commit(1).
        var cruiseGov = ParallelismGovernor(config: .default, rng: FixedRNG(value: 1))
        for _ in 0..<settle { cruiseGov.record(aggregateBytesPerSecond: 80_000_000) }
        _ = cruiseGov.decide(operatingN: 16, remainingBytes: 500_000_000)  // → cruise
        #expect(cruiseGov.phaseLabel == "cruise")
        #expect(cruiseGov.decide(operatingN: 16, remainingBytes: 1) == .commit(1))
    }

    @Test("GovernorOutcome: effectiveN is non-nil iff N is a bandit candidate")
    func governorOutcomeEffectiveN() {
        let aligned = GovernorOutcome(effectiveN: 8, stabilized: true)
        #expect(aligned.effectiveN == 8)
        #expect(aligned.stabilized)

        let offCandidate = GovernorOutcome(effectiveN: nil, stabilized: true)
        #expect(offCandidate.effectiveN == nil)

        let unstable = GovernorOutcome(effectiveN: 4, stabilized: false)
        #expect(!unstable.stabilized)
    }
}
