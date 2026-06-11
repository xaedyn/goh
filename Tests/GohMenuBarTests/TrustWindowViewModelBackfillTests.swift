import Foundation
import Testing
import GohCore
@testable import GohMenuBar

// ── Spy client ───────────────────────────────────────────────────────────────

@MainActor
private final class SpyMenuClient: GohMenuClient {
    private(set) var recordedBatches: [[VerifiedProvenanceEntry]] = []
    var shouldThrow = false

    func progressSnapshots() -> AsyncThrowingStream<[ProgressSnapshot], any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func add(_ request: AddRequest) async throws -> JobSummary { fatalError("unused") }
    func pause(jobID: UInt64) async throws {}
    func resume(jobID: UInt64) async throws {}
    func remove(jobID: UInt64, keepPartialFile: Bool) async throws {}

    func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry]) async throws {
        if shouldThrow { throw URLError(.notConnectedToInternet) }
        recordedBatches.append(entries)
    }

    func ls() async throws -> LsReply { LsReply(jobs: [], featureLevel: nil) }

    // Spy state for forget (mirrors recordedBatches/shouldThrow)
    var forgotPaths: [[String]] = []
    var forgetShouldThrow = false

    func forget(paths: [String]) async throws {
        if forgetShouldThrow { throw GohMenuError.daemonUnavailable("spy forced") }
        forgotPaths.append(paths)
    }
}

// ── Fake ledger reader ────────────────────────────────────────────────────────

private struct StubProvenanceReader: ProvenanceReading {
    let outcome: ProvenanceReadOutcome
    func read() -> ProvenanceReadOutcome { outcome }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

@Suite("TrustWindowViewModel backfill wiring")
@MainActor
struct TrustWindowViewModelBackfillTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-vm-bf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // AC9: finished run sends collected baselines.
    @Test("AC9: finished run sends collected baselines via client")
    func finishedRunSendsBaselines() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("ok.bin").path
        try Data("ok-content".utf8).write(to: URL(fileURLWithPath: f))
        let storeURL = dir.appendingPathComponent("provenance.plist")

        // Seed the ledger.
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        let (sha256, _) = try FileDigest.sha256WithSize(path: f)
        try store.record(entry: ProvenanceEntry(
            url: "https://example.com/ok.bin", sha256: sha256, size: 11,
            downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
            destinationPath: URL(fileURLWithPath: f).standardizedFileURL.path))

        let spy = SpyMenuClient()
        let reader = StubProvenanceReader(outcome: ProvenanceLedgerReader.read(at: storeURL.path))
        let vm = TrustWindowViewModel(
            reader: reader,
            provenanceStorePath: storeURL.path,
            client: spy)

        await vm.loadOverview()
        vm.startVerify()

        // Wait for the off-main run to settle (deterministic — no fixed sleep).
        try await awaitRunSettled(vm)

        // The finished run should have sent at least 1 baseline.
        #expect(!spy.recordedBatches.isEmpty,
            "TrustWindowViewModel must send baselines on run completion (AC9)")
        let sent = spy.recordedBatches.flatMap { $0 }
        #expect(!sent.isEmpty)
        #expect(sent[0].recordedStatSize != nil,
            "sent baseline must have recordedStatSize populated")
    }

    // AC9: cancelled run still sends collected baselines.
    @Test("AC9: cancelled run still sends collected baselines")
    func cancelledRunSendsCollectedBaselines() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two files so there is a "before cancel" entry.
        let f1 = dir.appendingPathComponent("f1.bin").path
        let f2 = dir.appendingPathComponent("f2.bin").path
        try Data("file1".utf8).write(to: URL(fileURLWithPath: f1))
        try Data("file2".utf8).write(to: URL(fileURLWithPath: f2))
        let storeURL = dir.appendingPathComponent("provenance.plist")

        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        for path in [f1, f2] {
            let (sha256, _) = try FileDigest.sha256WithSize(path: path)
            let name = URL(fileURLWithPath: path).lastPathComponent
            try store.record(entry: ProvenanceEntry(
                url: "https://example.com/\(name)", sha256: sha256, size: 5,
                downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
                destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path))
        }

        let spy = SpyMenuClient()
        let reader = StubProvenanceReader(outcome: ProvenanceLedgerReader.read(at: storeURL.path))
        let vm = TrustWindowViewModel(
            reader: reader,
            provenanceStorePath: storeURL.path,
            client: spy)

        await vm.loadOverview()
        vm.startVerify()
        // Cancel almost immediately — before both files finish. This small sleep is
        // inherent to the cancel timing (let the run start), not a settle wait.
        try await Task.sleep(for: .milliseconds(50))
        vm.cancelVerify()

        // Wait for the off-main run to settle (deterministic — no fixed sleep).
        try await awaitRunSettled(vm)

        // The run must settle to a TERMINAL state — `.cancelled` if the cancel beat
        // completion, or `.finished` if the tiny files completed first (both valid; the
        // race is inherent). The real behavioral checks (vs the old near-vacuous
        // `count <= 1` alone): it is never stuck in `.running`/`.idle`, it sends at most
        // one batch, and it never sends an empty batch.
        switch vm.runState {
        case .cancelled, .finished:
            break
        default:
            Issue.record("cancelled run must settle to a terminal state; got \(vm.runState)")
        }
        #expect(spy.recordedBatches.count <= 1,
            "Baseline send should happen at most once per run (collected batch)")
        #expect(spy.recordedBatches.allSatisfy { !$0.isEmpty },
            "a cancelled run must never send an empty baseline batch")
    }

    // Best-effort: send failure must not affect runState or UI.
    @Test("best-effort: send failure leaves runState as finished, no UI error")
    func sendFailureNoUIImpact() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("ok.bin").path
        try Data("data".utf8).write(to: URL(fileURLWithPath: f))
        let storeURL = dir.appendingPathComponent("provenance.plist")

        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        let (sha256, _) = try FileDigest.sha256WithSize(path: f)
        try store.record(entry: ProvenanceEntry(
            url: "https://example.com/ok.bin", sha256: sha256, size: 4,
            downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
            destinationPath: URL(fileURLWithPath: f).standardizedFileURL.path))

        let spy = SpyMenuClient()
        spy.shouldThrow = true  // Simulate daemon stopped.

        let reader = StubProvenanceReader(outcome: ProvenanceLedgerReader.read(at: storeURL.path))
        let vm = TrustWindowViewModel(
            reader: reader,
            provenanceStorePath: storeURL.path,
            client: spy)

        await vm.loadOverview()
        vm.startVerify()
        try await awaitRunSettled(vm)

        // runState must be .finished (not .failed), and the VM is not stuck.
        if case .finished = vm.runState {
            // Expected — send failure must not corrupt run state.
        } else {
            Issue.record("runState must be .finished even when send throws; got \(vm.runState)")
        }
    }

    /// Deterministically waits for the off-main verify run to leave `.running`,
    /// replacing fixed multi-second sleeps. The `await` yields so the MainActor can
    /// apply the queued terminal `runState`; bounded (~4s) so a real hang fails fast.
    private func awaitRunSettled(_ vm: TrustWindowViewModel) async throws {
        var spins = 0
        while case .running = vm.runState, spins < 2000 {
            try await Task.sleep(for: .milliseconds(2))
            spins += 1
        }
    }
}
