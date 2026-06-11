import Foundation
import Testing
import GohCore
@testable import GohMenuBar

@Suite("GohMenuPresenter")
struct GohMenuPresenterTests {
    @Test func summarizesActiveDownloadsAndAggregateSpeed() {
        let snapshots = [
            snapshot(id: 1, state: .active, completed: 512, total: 1024, speed: 1000),
            snapshot(id: 2, state: .active, completed: 256, total: 1024, speed: 2000),
            snapshot(id: 3, state: .completed, completed: 1024, total: 1024, speed: 0),
        ]

        let state = GohMenuPresenter().state(
            health: .connected,
            snapshots: snapshots,
            clipboardURL: URL(string: "https://example.com/big.iso"))

        #expect(state.activeCount == 2)
        #expect(state.aggregateSpeedText == "2.9 KB/s")
        #expect(state.primaryAction == .addClipboardURL(URL(string: "https://example.com/big.iso")!))
        #expect(state.rows.map(\.id) == [1, 2, 3])
    }

    @Test func mapsControlsExactlyByJobState() {
        let snapshots = [
            snapshot(id: 1, state: .queued, completed: 0, total: 1024, speed: 0),
            snapshot(id: 2, state: .active, completed: 512, total: 1024, speed: 1000),
            snapshot(id: 3, state: .paused, completed: 512, total: 1024, speed: 0),
            snapshot(id: 4, state: .completed, completed: 1024, total: 1024, speed: 0),
            snapshot(id: 5, state: .failed, completed: 512, total: 1024, speed: 0),
        ]

        let state = GohMenuPresenter().state(
            health: .connected,
            snapshots: snapshots,
            clipboardURL: nil)

        #expect(state.rows.map(\.id) == [1, 2, 3, 4, 5])
        #expect(state.rows[0].controls == Set<GohMenuControl>([.remove, .copyURL, .copyDestination]))
        #expect(state.rows[1].controls == Set<GohMenuControl>([.pause, .copyURL, .copyDestination]))
        #expect(state.rows[2].controls == Set<GohMenuControl>([.resume, .remove, .copyURL, .copyDestination]))
        #expect(state.rows[3].controls == Set<GohMenuControl>([.revealInFinder, .remove, .copyURL, .copyDestination]))
        #expect(state.rows[4].controls == Set<GohMenuControl>([.remove, .copyURL, .copyDestination]))
    }

    @Test func mapsStateTextForEveryJobState() {
        let snapshots = [
            snapshot(id: 1, state: .queued, completed: 0, total: 1024, speed: 0),
            snapshot(id: 2, state: .active, completed: 512, total: 1024, speed: 1000),
            snapshot(id: 3, state: .paused, completed: 512, total: 1024, speed: 0),
            snapshot(id: 4, state: .completed, completed: 1024, total: 1024, speed: 0),
            snapshot(id: 5, state: .failed, completed: 512, total: 1024, speed: 0),
        ]

        let state = GohMenuPresenter().state(
            health: .connected,
            snapshots: snapshots,
            clipboardURL: nil)

        #expect(state.rows.map(\.stateText) == ["Queued", "Active", "Paused", "Completed", "Failed"])
    }

    @Test func clampsProgressPercentWhenCompletedExceedsTotal() {
        let state = GohMenuPresenter().state(
            health: .connected,
            snapshots: [
                snapshot(id: 1, state: .active, completed: 2048, total: 1024, speed: 0),
            ],
            clipboardURL: nil)

        #expect(state.rows[0].progressText == "2 KB/1 KB (100%)")
    }

    @Test("isPaused is true for a paused job and false otherwise")
    func isPausedReflectsJobState() {
        let state = GohMenuPresenter().state(
            health: .connected,
            snapshots: [
                snapshot(id: 1, state: .paused, completed: 512, total: 1024, speed: 0),
                snapshot(id: 2, state: .active, completed: 512, total: 1024, speed: 0),
            ],
            clipboardURL: nil)

        let paused = state.rows.first { $0.id == 1 }
        let active = state.rows.first { $0.id == 2 }
        #expect(paused?.isPaused == true)
        #expect(active?.isPaused == false)
    }

    @Test("sizeText shows downloaded/total without the redundant percent")
    func sizeTextOmitsPercentWhileProgressTextKeepsIt() {
        let state = GohMenuPresenter().state(
            health: .connected,
            snapshots: [
                snapshot(id: 1, state: .active, completed: 512, total: 1024, speed: 0),
            ],
            clipboardURL: nil)

        let row = state.rows[0]
        #expect(row.sizeText == "512 B/1 KB")
        #expect(!row.sizeText.contains("%"))
        #expect(row.progressText == "512 B/1 KB (50%)")
        #expect(row.progressText.contains("%"))
    }

    @Test func explainsPeerValidationFailure() {
        let error = GohMenuError.peerValidation("Peer forbidden (code signing)")

        let state = GohMenuPresenter().state(
            health: .failed(error),
            snapshots: [],
            clipboardURL: nil)

        #expect(state.healthTitle == "Peer validation blocked")
        #expect(state.healthDetail?.contains("GOH_XPC_ALLOW_UNVALIDATED_PEERS=1") == true)
        #expect(state.recoveryAction == .copyCommand("export GOH_XPC_ALLOW_UNVALIDATED_PEERS=1"))
    }

    @Test func connectedHealthHasNoDetail() {
        let state = GohMenuPresenter().state(
            health: .connected,
            snapshots: [],
            clipboardURL: nil)

        #expect(state.healthDetail == nil)
    }

    @Test func daemonUnavailablePromotesDoctorPrimaryAction() {
        let state = GohMenuPresenter().state(
            health: .failed(.daemonUnavailable("launchd service is not loaded")),
            snapshots: [],
            clipboardURL: URL(string: "https://example.com/big.iso"))

        #expect(state.primaryAction == .diagnose)
        #expect(state.recoveryAction == .openDoctor)
    }

    // AC3: progressFraction is nil when bytesTotal is nil
    @Test("progressFraction is nil when bytesTotal is nil")
    func progressFractionNilWhenTotalUnknown() {
        let state = GohMenuPresenter().state(
            health: .connected,
            snapshots: [snapshot(id: 1, state: .active, completed: 500, total: nil, speed: 100)],
            clipboardURL: nil)
        #expect(state.rows[0].progressFraction == nil)
    }

    @Test("etaText is nil when bytesTotal is nil")
    func etaTextNilWhenTotalUnknown() {
        let state = GohMenuPresenter().state(
            health: .connected,
            snapshots: [snapshot(id: 1, state: .active, completed: 500, total: nil, speed: 1000)],
            clipboardURL: nil)
        #expect(state.rows[0].etaText == nil)
    }

    @Test("etaText is nil for non-active (paused) jobs")
    func etaTextNilForPausedJob() {
        let state = GohMenuPresenter().state(
            health: .connected,
            snapshots: [snapshot(id: 1, state: .paused, completed: 500, total: 1024, speed: 1000)],
            clipboardURL: nil)
        #expect(state.rows[0].etaText == nil)
    }

    @Test("completed row gets verifyStatus 'recorded' from ledger entry without verifiedAt")
    func completedRowVerifyStatusRecorded() {
        let entry = ProvenanceEntry(
            url: "https://x.com/f.bin", sha256: "sha256:abc", size: 1024,
            downloadedAt: Date(timeIntervalSince1970: 0), destinationPath: "/tmp/1.iso", verifiedAt: nil)
        let outcome = ProvenanceReadOutcome.entries([entry])
        let state = GohMenuPresenter().state(
            health: .connected,
            snapshots: [snapshot(id: 1, state: .completed, completed: 1024, total: 1024, speed: 0,
                                 destination: "/tmp/1.iso")],
            clipboardURL: nil,
            ledgerOutcome: outcome)
        #expect(state.rows[0].verifyStatus == "recorded")
    }

    @Test("completed row gets verifyStatus 'verified <date>' from ledger entry with verifiedAt")
    func completedRowVerifyStatusVerified() {
        let verifiedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = ProvenanceEntry(
            url: "https://x.com/f.bin", sha256: "sha256:abc", size: 1024,
            downloadedAt: verifiedDate, destinationPath: "/tmp/2.iso", verifiedAt: verifiedDate)
        let outcome = ProvenanceReadOutcome.entries([entry])
        let state = GohMenuPresenter().state(
            health: .connected,
            snapshots: [snapshot(id: 1, state: .completed, completed: 1024, total: 1024, speed: 0,
                                 destination: "/tmp/2.iso")],
            clipboardURL: nil,
            ledgerOutcome: outcome)
        #expect(state.rows[0].verifyStatus?.hasPrefix("verified") == true)
    }

    @Test("completed row with no ledger entry has nil verifyStatus")
    func completedRowVerifyStatusNilWhenAbsent() {
        let state = GohMenuPresenter().state(
            health: .connected,
            snapshots: [snapshot(id: 1, state: .completed, completed: 1024, total: 1024, speed: 0)],
            clipboardURL: nil,
            ledgerOutcome: .absent)
        #expect(state.rows[0].verifyStatus == nil)
    }

    private func snapshot(
        id: UInt64,
        state: JobState,
        completed: UInt64,
        total: UInt64?,
        speed: UInt64,
        destination: String? = nil
    ) -> ProgressSnapshot {
        ProgressSnapshot(
            job: JobSummary(
                id: id,
                url: "https://example.com/\(id).iso",
                destination: destination ?? "/tmp/\(id).iso",
                state: state,
                progress: JobProgress(
                    bytesCompleted: completed,
                    bytesTotal: total,
                    bytesPerSecond: speed),
                createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
                lastProgressAt: Date(timeIntervalSince1970: TimeInterval(id + 10)),
                requestedConnectionCount: 8,
                actualConnectionCount: state == .active ? 8 : 0),
            lanes: [])
    }

    @Test("presenter includes daemonSkewNotice when daemonSkew is staleBusy")
    func presenterIncludesStaleBusyNotice() {
        let presenter = GohMenuPresenter()
        let state = presenter.state(
            health: .connected,
            snapshots: [],
            clipboardURL: nil,
            daemonSkew: .staleBusy)
        #expect(state.daemonSkewNotice != nil)
        #expect(state.daemonSkewNotice?.contains("downloads finish") == true)
    }

    @Test("presenter daemonSkewNotice is nil when current")
    func presenterNilNoticeWhenCurrent() {
        let presenter = GohMenuPresenter()
        let state = presenter.state(
            health: .connected,
            snapshots: [],
            clipboardURL: nil,
            daemonSkew: .current)
        #expect(state.daemonSkewNotice == nil)
    }
}
