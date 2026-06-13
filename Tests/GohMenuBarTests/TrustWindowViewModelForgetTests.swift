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

// A reader that returns the entry on the first read and an empty ledger after —
// models a forget that actually removed the row, so the post-forget refresh drops
// it (and `forgetRow` therefore surfaces NO error).
private final class VanishingReader: ProvenanceReading, @unchecked Sendable {
    private let entry: ProvenanceEntry
    private var reads = 0
    init(entry: ProvenanceEntry) { self.entry = entry }
    func read() -> ProvenanceReadOutcome {
        reads += 1
        return reads == 1 ? .entries([entry]) : .entries([])
    }
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

    @Test("AC5: forgetRow sends the row's path verbatim, and a successful prune surfaces no error")
    func forgetRowSendsPathVerbatim() async throws {
        let spy = ForgetSpyClient()
        // VanishingReader drops the row on the post-forget refresh, modelling a
        // prune that actually removed the ledger entry → the happy path.
        let reader = VanishingReader(entry: baselinedEntry(path: "/tmp/gone.bin"))
        let vm = TrustWindowViewModel(
            reader: reader,
            provenanceStorePath: "/tmp/x.plist",
            probe: StubProbe(result: .notFound),
            client: spy)
        await vm.loadOverview()
        await vm.forgetRow(path: "/tmp/gone.bin")
        #expect(spy.forgotPaths == [["/tmp/gone.bin"]])   // verbatim, single path
        #expect(vm.forgetError == nil)                    // row removed → success, no error surfaced
    }

    @Test("AC5: a client (daemon) error is surfaced via forgetError, not swallowed")
    func forgetRowSurfacesClientError() async throws {
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
        #expect(vm.forgetError != nil)              // failure surfaced to the user, not swallowed
        #expect(vm.runState == .idle)               // the verify run-state is untouched
    }

    @Test("AC5: a forget that removes nothing (row still present after refresh) surfaces an error")
    func forgetRowNoOpMatchSurfacesError() async throws {
        let spy = ForgetSpyClient()   // forget succeeds, but the static reader keeps returning the row
        let reader = StubProvenanceReader(
            outcome: .entries([baselinedEntry(path: "/tmp/gone.bin")]))
        let vm = TrustWindowViewModel(
            reader: reader,
            provenanceStorePath: "/tmp/x.plist",
            probe: StubProbe(result: .notFound),
            client: spy)
        await vm.loadOverview()
        await vm.forgetRow(path: "/tmp/gone.bin")
        #expect(spy.forgotPaths == [["/tmp/gone.bin"]])   // the send happened
        #expect(vm.forgetError != nil)                    // but nothing was removed → surfaced
    }

    @Test("forgetRow with a nil client surfaces an 'unavailable' error (does not refresh)")
    func forgetRowNilClientSurfacesError() async throws {
        let reader = StubProvenanceReader(
            outcome: .entries([baselinedEntry(path: "/tmp/gone.bin")]))
        let vm = TrustWindowViewModel(
            reader: reader,
            provenanceStorePath: "/tmp/x.plist",
            probe: StubProbe(result: .notFound),
            client: nil)
        await vm.loadOverview()
        await vm.forgetRow(path: "/tmp/gone.bin")   // no client → no send, no crash
        #expect(vm.forgetError != nil)              // "Forget is unavailable …" surfaced
        // fastStatuses stays populated from setup's loadOverview — the nil-client
        // path returns before re-refreshing (it does not call loadOverview again).
        #expect(vm.fastStatuses["/tmp/gone.bin"] == .missing)
        #expect(vm.runState == .idle)
    }
}
