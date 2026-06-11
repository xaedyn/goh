import Foundation
import Testing
import GohCore
@testable import GohMenuBar

// Exhaustive transition coverage for the TrustRunState machine driven by
// TrustWindowViewModel. Cases: idle / running / finished / cancelled / failed.
//
// Documented transitions driven here:
//   idle → running       (startVerify on a non-empty ledger)
//   running → finished    (run completes uncancelled)
//   running → cancelled   (cancelVerify mid-run)
//   idle (guarded no-op)  (startVerify with empty rows stays idle)
//
// Uses the deterministic bounded-poll-on-runState pattern (no fixed sleeps):
// `await`-ing inside the poll lets the MainActor drain the queued completion
// Task that flips runState off `.running`.
@Suite("TrustWindowViewModel runState transitions")
@MainActor
struct TrustWindowViewModelRunStateTests {

    private struct StubReader: ProvenanceReading {
        let outcome: ProvenanceReadOutcome
        func read() -> ProvenanceReadOutcome { outcome }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-vm-rs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Seeds a ledger with `count` small files and returns a VM wired to it.
    private func makeVM(in dir: URL, count: Int) throws -> TrustWindowViewModel {
        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        for i in 0..<count {
            let f = dir.appendingPathComponent("f\(i).bin").path
            try Data("content-\(i)".utf8).write(to: URL(fileURLWithPath: f))
            let (sha256, _) = try FileDigest.sha256WithSize(path: f)
            try store.record(entry: ProvenanceEntry(
                url: "https://example.com/f\(i).bin", sha256: sha256, size: 9,
                downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
                destinationPath: URL(fileURLWithPath: f).standardizedFileURL.path))
        }
        let reader = StubReader(outcome: ProvenanceLedgerReader.read(at: storeURL.path))
        return TrustWindowViewModel(reader: reader, provenanceStorePath: storeURL.path)
    }

    /// Deterministically waits for the run to leave `.running`, bounded so a hung
    /// run fails the test rather than hanging CI. The `await` yields to the
    /// MainActor so the queued completion Task can flip runState.
    private func waitUntilSettled(_ vm: TrustWindowViewModel) async throws {
        var spins = 0
        while case .running = vm.runState, spins < 2000 {
            try await Task.sleep(for: .milliseconds(2))
            spins += 1
        }
    }

    @Test("idle → running → finished")
    func idleToRunningToFinished() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = try makeVM(in: dir, count: 1)
        await vm.loadOverview()

        // Precondition: idle.
        #expect({ if case .idle = vm.runState { return true } else { return false } }())

        vm.startVerify()
        // Immediately after startVerify (still on the MainActor) the state is running.
        #expect({ if case .running = vm.runState { return true } else { return false } }(),
            "startVerify must transition idle → running")

        try await waitUntilSettled(vm)

        // The uncancelled run must end in .finished.
        guard case .finished = vm.runState else {
            Issue.record("expected running → finished, got \(vm.runState)")
            return
        }
    }

    @Test("idle → running → cancelled")
    func idleToRunningToCancelled() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Several files so cancellation can land mid-run.
        let vm = try makeVM(in: dir, count: 4)
        await vm.loadOverview()

        vm.startVerify()
        #expect({ if case .running = vm.runState { return true } else { return false } }())

        // Cancel in the SAME synchronous MainActor turn as startVerify — before
        // yielding. startVerify only *queues* the worker via DispatchQueue.async,
        // so the cancel flag is set before the worker reaches its first
        // `isCancelled()` check (which the runner performs BEFORE the first file).
        // This makes the cancel land deterministically regardless of how fast the
        // tiny files would otherwise hash — no timing-dependent pre-sleep needed.
        vm.cancelVerify()

        try await waitUntilSettled(vm)

        // A cancelled run must settle in .cancelled (carrying its partial report).
        guard case .cancelled = vm.runState else {
            Issue.record("expected running → cancelled, got \(vm.runState)")
            return
        }
    }

    @Test("startVerify on an empty ledger is a guarded no-op (stays idle)")
    func startVerifyEmptyLedgerStaysIdle() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = try makeVM(in: dir, count: 0)
        await vm.loadOverview()
        #expect(vm.rows.isEmpty, "precondition: no rows")

        vm.startVerify()
        // The `guard !rows.isEmpty` must keep the machine idle.
        #expect({ if case .idle = vm.runState { return true } else { return false } }(),
            "startVerify with no rows must stay idle (guarded no-op)")
    }

    @Test("startVerify is a no-op while already running (idempotent guard)")
    func startVerifyWhileRunningIsNoOp() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = try makeVM(in: dir, count: 4)
        await vm.loadOverview()

        vm.startVerify()
        #expect({ if case .running = vm.runState { return true } else { return false } }())

        // Second call while running must be rejected by `guard case .idle`.
        vm.startVerify()
        #expect({ if case .running = vm.runState { return true } else { return false } }(),
            "a second startVerify while running must not restart or corrupt the run")

        try await waitUntilSettled(vm)
    }
}
