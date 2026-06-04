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
