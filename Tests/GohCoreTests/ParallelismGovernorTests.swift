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

    @Test("SM3: steady-state gating — never backs off while rate derivative is above threshold")
    func steadyStateGating() throws {
        let rng = FixedRNG(value: 0)
        var gov = ParallelismGovernor(config: .default, rng: rng)
        var rate = 1_000_000.0
        for _ in 0..<20 {
            rate *= 1.2
            gov.record(sample: WorkerRateSample(workerIndex: 0, bytesPerSecond: rate, rttRatio: nil))
        }
        let decision = gov.decide(liveWorkers: 2, remainingBytes: 500_000_000)
        switch decision {
        case .backOffPinLow, .dropWorkers:
            Issue.record("SM3 violated: governor backed off during slow-start ramp; decision=\(decision)")
        default:
            break
        }
    }

    @Test("SM3: bufferbloat stop — aggregate flat, RTT climbs → stop probing")
    func bufferbloatStop() throws {
        let rng = FixedRNG(value: 7)
        var gov = ParallelismGovernor(config: .default, rng: rng)
        for _ in 0..<ParallelismGovernor.Config.default.steadyStateWindow {
            gov.record(sample: WorkerRateSample(workerIndex: 0, bytesPerSecond: 10_000_000, rttRatio: 1.0))
        }
        for _ in 0..<ParallelismGovernor.Config.default.steadyStateWindow {
            gov.record(sample: WorkerRateSample(workerIndex: 0, bytesPerSecond: 5_000_000, rttRatio: 2.0))
            gov.record(sample: WorkerRateSample(workerIndex: 1, bytesPerSecond: 5_000_000, rttRatio: 2.0))
        }
        let decision = gov.decide(liveWorkers: 4, remainingBytes: 500_000_000)
        if case .addWorkers = decision {
            Issue.record("governor should not add workers on bufferbloat signature; got \(decision)")
        }
    }

    @Test("SM3: gain-only fallback — RTT unusable, but gain is present → keeps probing")
    func gainOnlyFallback() throws {
        let rng = FixedRNG(value: 99)
        var gov = ParallelismGovernor(config: .default, rng: rng)
        for _ in 0..<ParallelismGovernor.Config.default.steadyStateWindow {
            gov.record(sample: WorkerRateSample(workerIndex: 0, bytesPerSecond: 20_000_000, rttRatio: nil))
            gov.record(sample: WorkerRateSample(workerIndex: 1, bytesPerSecond: 20_000_000, rttRatio: nil))
        }
        let decision = gov.decide(liveWorkers: 2, remainingBytes: 500_000_000)
        if case .backOffPinLow = decision {
            Issue.record("gain-only fallback: should not back off when gain is positive; got \(decision)")
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
}
