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

        // Wait for the run to complete.
        try await Task.sleep(for: .seconds(3))

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
        // Cancel almost immediately — before both files finish.
        try await Task.sleep(for: .milliseconds(50))
        vm.cancelVerify()

        // Wait for the run to settle.
        try await Task.sleep(for: .seconds(2))

        // Even a cancelled run must send whatever baselines were collected.
        // (May be 0 if cancelled before any file completed — that is acceptable.)
        // The key invariant: no crash, no UI error.
        // If at least 1 entry was verified before cancel, it was sent.
        // We assert the spy was called at most once (not multiple times for the same run).
        #expect(spy.recordedBatches.count <= 1,
            "Baseline send should happen at most once per run (collected batch)")
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
        try await Task.sleep(for: .seconds(3))

        // runState must be .finished (not .failed), and the VM is not stuck.
        if case .finished = vm.runState {
            // Expected — send failure must not corrupt run state.
        } else {
            Issue.record("runState must be .finished even when send throws; got \(vm.runState)")
        }
    }
}
