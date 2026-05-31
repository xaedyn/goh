import Testing

import GohCore

// A seeded deterministic RNG for testing.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    // xorshift64 has a zero trap state; ensure state is never zero.
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt64 {
        // xorshift64
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

@Suite("Bandit selector")
struct BanditSelectorTests {

    // AC5: cold profile → default 8.
    @Test("AC: nil profile returns (8, .cold)")
    func ac5NilProfileReturnsDefault() {
        var rng = SeededRNG(seed: 42)
        let (n, reason) = BanditSelector().select(profile: nil, rng: &rng)
        #expect(n == 8)
        #expect(reason == .cold)
    }

    // AC5: all arms cold (sampleCount < minSamples) → explore.
    @Test("AC: all arms under-sampled returns explore")
    func ac5AllArmsColdExplore() {
        let profile = HostProfile(
            host: "https://example.com:443",
            arms: [
                ConnObservation(connectionCount: 8, throughputEWMA: 10_000_000,
                                sampleCount: 1, updatedAt: .now),  // sampleCount < 2
            ],
            updatedAt: .now)
        var rng = SeededRNG(seed: 1)
        let (_, reason) = BanditSelector().select(profile: profile, rng: &rng)
        #expect(reason == .explore)
    }

    // AC5: best-EWMA arm exploited when all arms have >= minSamples and no epsilon draw.
    // exploit is only reachable once EVERY candidate arm ({2,4,8,16}) has >= minSamples.
    @Test("AC: exploits best-EWMA arm when all four candidate arms are settled")
    func ac5ExploitsBestArm() {
        let selector = BanditSelector(epsilon: 0.0)
        let profile = HostProfile(
            host: "https://example.com:443",
            arms: [
                ConnObservation(connectionCount: 2, throughputEWMA: 3_000_000,
                                sampleCount: 3, updatedAt: .now),
                ConnObservation(connectionCount: 4, throughputEWMA: 5_000_000,
                                sampleCount: 3, updatedAt: .now),
                ConnObservation(connectionCount: 8, throughputEWMA: 10_000_000,
                                sampleCount: 3, updatedAt: .now),
                ConnObservation(connectionCount: 16, throughputEWMA: 20_000_000,
                                sampleCount: 3, updatedAt: .now),
            ],
            updatedAt: .now)
        var rng = SeededRNG(seed: 1)
        let (n, reason) = selector.select(profile: profile, rng: &rng)
        #expect(n == 16)  // highest EWMA
        #expect(reason == .exploit)
    }

    // AC5: chosen N is always in the candidate set.
    @Test("AC: chosen N is always in the candidate set")
    func ac5ChosenNInCandidateSet() {
        let profile = HostProfile(
            host: "https://example.com:443",
            arms: [
                ConnObservation(connectionCount: 8, throughputEWMA: 10_000_000,
                                sampleCount: 5, updatedAt: .now),
            ],
            updatedAt: .now)
        let selector = BanditSelector()
        for seed in UInt64(0)..<100 {
            var rng = SeededRNG(seed: seed)
            let (n, _) = selector.select(profile: profile, rng: &rng)
            #expect(BanditSelector.candidateSet.contains(n))
        }
    }

    // AC5: seeded-deterministic — same seed produces same result.
    @Test("AC: seeded RNG gives deterministic output")
    func ac5SeedDeterminism() {
        let profile = HostProfile(
            host: "https://example.com:443",
            arms: [
                ConnObservation(connectionCount: 2, throughputEWMA: 3_000_000,
                                sampleCount: 3, updatedAt: .now),
                ConnObservation(connectionCount: 4, throughputEWMA: 8_000_000,
                                sampleCount: 3, updatedAt: .now),
                ConnObservation(connectionCount: 8, throughputEWMA: 10_000_000,
                                sampleCount: 3, updatedAt: .now),
                ConnObservation(connectionCount: 16, throughputEWMA: 15_000_000,
                                sampleCount: 3, updatedAt: .now),
            ],
            updatedAt: .now)
        let selector = BanditSelector()
        var rng1 = SeededRNG(seed: 12345)
        var rng2 = SeededRNG(seed: 12345)
        let (n1, r1) = selector.select(profile: profile, rng: &rng1)
        let (n2, r2) = selector.select(profile: profile, rng: &rng2)
        #expect(n1 == n2)
        #expect(r1 == r2)
    }

    // AC5: epsilon = 1.0 forces exploration even when all arms are settled.
    @Test("AC: epsilon = 1.0 always explores (all arms settled)")
    func ac5EpsilonOneAlwaysExplores() {
        let selector = BanditSelector(epsilon: 1.0)
        let profile = HostProfile(
            host: "https://example.com:443",
            arms: [
                ConnObservation(connectionCount: 2, throughputEWMA: 2_000_000,
                                sampleCount: 5, updatedAt: .now),
                ConnObservation(connectionCount: 4, throughputEWMA: 5_000_000,
                                sampleCount: 5, updatedAt: .now),
                ConnObservation(connectionCount: 8, throughputEWMA: 10_000_000,
                                sampleCount: 5, updatedAt: .now),
                ConnObservation(connectionCount: 16, throughputEWMA: 20_000_000,
                                sampleCount: 5, updatedAt: .now),
            ],
            updatedAt: .now)
        for seed in UInt64(0)..<20 {
            var rng = SeededRNG(seed: seed)
            let (_, reason) = selector.select(profile: profile, rng: &rng)
            #expect(reason == .explore)
        }
    }
}
