import Foundation
import Testing
import GohCore
@testable import GohMenuBar

@Suite("TrustWindowViewModel.liveStats")
@MainActor
struct TrustWindowViewModelLiveStatsTests {

    // MARK: - Helpers

    private func makeVM() -> TrustWindowViewModel {
        TrustWindowViewModel(
            reader: StubProvenanceReader(outcome: .absent),
            provenanceStorePath: "/tmp/fake-provenance.plist"
        )
    }

    // MARK: - fraction / byteText

    @Test("fraction ≈ 0.5 and byteText non-empty when bytesHashed is half of totalBytes")
    func fractionAndByteText() {
        let vm = makeVM()
        let progress = VerifyProgress(
            completed: 0,
            total: 1,
            currentPath: "/x",
            bytesHashed: 50,
            totalBytes: 100
        )
        // Use a fixed now far enough past start to be past the warm-up guard.
        let fakeStart = Date(timeIntervalSinceNow: -10)
        vm.verifyStartedAt = fakeStart
        let stats = vm.liveStats(for: progress, now: fakeStart.addingTimeInterval(10))
        #expect(abs(stats.fraction - 0.5) < 0.001)
        #expect(!stats.byteText.isEmpty)
    }

    // MARK: - ETA

    @Test("ETA ≈ 10s when rate is 10 B/s with 100 bytes remaining")
    func etaComputation() {
        let vm = makeVM()
        // bytesHashed = 100, elapsed = 10s → rate = 10 B/s; remaining = 100 → ETA = 10s
        let fakeStart = Date(timeIntervalSince1970: 1_000_000)
        vm.verifyStartedAt = fakeStart
        let progress = VerifyProgress(
            completed: 0,
            total: 2,
            currentPath: "/x",
            bytesHashed: 100,
            totalBytes: 200
        )
        let now = fakeStart.addingTimeInterval(10)
        let stats = vm.liveStats(for: progress, now: now)
        #expect(stats.etaText != nil)
        // ETA = 100 B / (100 B/10 s) = 10 s → "ETA 10s"
        #expect(stats.etaText == "ETA 10s")
    }

    // MARK: - Warm-up / unknown

    @Test("totalBytes == 0 → fraction 0, byteText empty, etaText nil")
    func totalBytesZero() {
        let vm = makeVM()
        let progress = VerifyProgress(
            completed: 0,
            total: 1,
            currentPath: nil,
            bytesHashed: 0,
            totalBytes: 0
        )
        let stats = vm.liveStats(for: progress, now: Date())
        #expect(stats.fraction == 0)
        #expect(stats.byteText.isEmpty)
        #expect(stats.etaText == nil)
    }

    @Test("bytesHashed == 0 → etaText nil (no rate yet)")
    func bytesHashedZeroSuppressesETA() {
        let vm = makeVM()
        let fakeStart = Date(timeIntervalSince1970: 1_000_000)
        vm.verifyStartedAt = fakeStart
        let progress = VerifyProgress(
            completed: 0,
            total: 1,
            currentPath: "/x",
            bytesHashed: 0,
            totalBytes: 1024 * 1024
        )
        let now = fakeStart.addingTimeInterval(10)
        let stats = vm.liveStats(for: progress, now: now)
        #expect(stats.etaText == nil)
    }

    @Test("warm-up guard: elapsed < 0.5s suppresses ETA")
    func warmUpGuard() {
        let vm = makeVM()
        let fakeStart = Date(timeIntervalSince1970: 1_000_000)
        vm.verifyStartedAt = fakeStart
        let progress = VerifyProgress(
            completed: 0,
            total: 1,
            currentPath: "/x",
            bytesHashed: 500,
            totalBytes: 1000
        )
        // Only 0.1s elapsed — below the 0.5s warm-up guard
        let now = fakeStart.addingTimeInterval(0.1)
        let stats = vm.liveStats(for: progress, now: now)
        #expect(stats.etaText == nil)
    }
}

// MARK: - Stub

private struct StubProvenanceReader: ProvenanceReading {
    let outcome: ProvenanceReadOutcome
    func read() -> ProvenanceReadOutcome { outcome }
}
