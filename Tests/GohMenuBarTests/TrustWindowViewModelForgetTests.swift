import Foundation
import Testing
import GohCore
@testable import GohMenuBar

// ── Recording spy client ───────────────────────────────────────────────────────
//
// `SpyMenuClient` in TrustWindowViewModelBackfillTests.swift is `private` and so is
// not visible across files; this file defines its own minimal recording spy that
// records `forget` calls and can be forced to throw. All other protocol methods are
// no-ops (this suite only exercises `forgetRow`).

@MainActor
private final class ForgetSpyClient: GohMenuClient {
    /// Each successful `forget(paths:)` appends its `paths` argument verbatim.
    private(set) var forgotPaths: [[String]] = []
    /// When true, `forget` throws BEFORE recording — modelling a dead daemon.
    var forgetShouldThrow = false

    func progressSnapshots() -> AsyncThrowingStream<[ProgressSnapshot], any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func add(_ request: AddRequest) async throws -> JobSummary { fatalError("unused") }
    func pause(jobID: UInt64) async throws {}
    func resume(jobID: UInt64) async throws {}
    func remove(jobID: UInt64, keepPartialFile: Bool) async throws {}
    func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry]) async throws {}
    func ls() async throws -> LsReply { LsReply(jobs: [], featureLevel: nil) }

    func forget(paths: [String]) async throws {
        if forgetShouldThrow { throw GohMenuError.daemonUnavailable("spy forced") }
        forgotPaths.append(paths)
    }
}

// ── Fake ledger reader ──────────────────────────────────────────────────────────

private struct StubProvenanceReader: ProvenanceReading {
    let outcome: ProvenanceReadOutcome
    func read() -> ProvenanceReadOutcome { outcome }
}

// ── Stub file-stat probe ────────────────────────────────────────────────────────
//
// Returns a fixed `FileProbeResult` for every path. `.notFound` models a deleted
// file (→ fast-check `.missing`); `.stat(...)` models a present file.

private struct StubProbe: FileStatProbing {
    let result: FileProbeResult
    func probe(path: String) -> FileProbeResult { result }
}

// A present, regular file whose stat exactly matches the baseline below
// (so the fast-check resolves to `.unchanged`, NOT `.missing`).
private let presentStat = FileStat(
    size: 11,
    mtimeSeconds: 1_700_000_000,
    mtimeNanoseconds: 123,
    inode: 42,
    device: 1,
    isRegularFile: true)

/// Builds a FULLY-BASELINED entry (all five recorded* fields non-nil) so the
/// fast-check consults the probe instead of short-circuiting to `.notBaselined`.
/// `verifiedAt` is set so `displayStatus` would be `.verified(at:)` — the regression
/// case the gate must see through.
private func baselinedEntry(
    path: String,
    verifiedAt: Date? = Date(timeIntervalSince1970: 1_748_000_000)
) -> ProvenanceEntry {
    ProvenanceEntry(
        url: "https://example.com/gone.bin",
        sha256: "sha256:" + String(repeating: "a", count: 64),
        size: 11,
        downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
        destinationPath: path,
        verifiedAt: verifiedAt,
        recordedStatSize: presentStat.size,
        recordedMtimeSeconds: presentStat.mtimeSeconds,
        recordedMtimeNanoseconds: presentStat.mtimeNanoseconds,
        recordedInode: presentStat.inode,
        recordedDevice: presentStat.device)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

@Suite("TrustWindowViewModel.forgetRow") @MainActor
struct TrustWindowViewModelForgetTests {

    // MARK: - isForgettable gate

    @Test("AC5 gate: a verified-then-deleted entry IS forgettable (fast-check missing, not displayStatus)")
    func verifiedThenDeletedIsForgettable() async throws {
        // The entry carries verifiedAt != nil (displayStatus would be .verified(at:)),
        // but the file is gone on disk — probe returns .notFound → fast-check .missing.
        // The gate MUST key off the fast-check, so this row is still forgettable.
        let reader = StubProvenanceReader(
            outcome: .entries([baselinedEntry(path: "/tmp/gone.bin")]))
        let vm = TrustWindowViewModel(
            reader: reader,
            provenanceStorePath: "/tmp/x.plist",
            probe: StubProbe(result: .notFound),
            client: ForgetSpyClient())
        await vm.loadOverview()
        #expect(vm.fastStatuses["/tmp/gone.bin"] == .missing,
            "precondition: a full baseline + .notFound probe must yield .missing, not .notBaselined")
        #expect(vm.isForgettable(path: "/tmp/gone.bin"))
    }

    @Test("AC5 gate: a present file is NOT forgettable")
    func presentFileNotForgettable() async throws {
        let reader = StubProvenanceReader(
            outcome: .entries([baselinedEntry(path: "/tmp/here.bin")]))
        let vm = TrustWindowViewModel(
            reader: reader,
            provenanceStorePath: "/tmp/x.plist",
            probe: StubProbe(result: .stat(presentStat)),
            client: ForgetSpyClient())
        await vm.loadOverview()
        #expect(vm.fastStatuses["/tmp/here.bin"] == .unchanged,
            "precondition: a present matching file must be .unchanged")
        #expect(!vm.isForgettable(path: "/tmp/here.bin"))
    }

    // MARK: - forgetRow behaviour

    @Test("AC5: forgetRow sends exactly the row's path to the client, verbatim")
    func forgetRowSendsPathVerbatim() async throws {
        let spy = ForgetSpyClient()
        let reader = StubProvenanceReader(
            outcome: .entries([baselinedEntry(path: "/tmp/gone.bin")]))
        let vm = TrustWindowViewModel(
            reader: reader,
            provenanceStorePath: "/tmp/x.plist",
            probe: StubProbe(result: .notFound),
            client: spy)
        await vm.loadOverview()
        await vm.forgetRow(path: "/tmp/gone.bin")
        #expect(spy.forgotPaths == [["/tmp/gone.bin"]])   // verbatim, single path
    }

    @Test("AC5: a client error is swallowed — no crash, no error surfaced")
    func forgetRowSwallowsClientError() async throws {
        let spy = ForgetSpyClient()
        spy.forgetShouldThrow = true
        let reader = StubProvenanceReader(
            outcome: .entries([baselinedEntry(path: "/tmp/gone.bin")]))
        let vm = TrustWindowViewModel(
            reader: reader,
            provenanceStorePath: "/tmp/x.plist",
            probe: StubProbe(result: .notFound),
            client: spy)
        await vm.loadOverview()
        await vm.forgetRow(path: "/tmp/gone.bin")   // must not throw
        #expect(spy.forgotPaths.isEmpty)            // threw before recording
        // runState must not have flipped to a failure/error state.
        #expect(vm.runState == .idle)
    }

    @Test("forgetRow with a nil client is a no-op that still refreshes")
    func forgetRowNilClientNoOp() async throws {
        let reader = StubProvenanceReader(
            outcome: .entries([baselinedEntry(path: "/tmp/gone.bin")]))
        let vm = TrustWindowViewModel(
            reader: reader,
            provenanceStorePath: "/tmp/x.plist",
            probe: StubProbe(result: .notFound),
            client: nil)
        await vm.loadOverview()
        await vm.forgetRow(path: "/tmp/gone.bin")   // no client → no send, no crash
        // Refresh ran: fast-check still reports the (still-missing) row.
        #expect(vm.fastStatuses["/tmp/gone.bin"] == .missing)
        #expect(vm.runState == .idle)
    }
}
