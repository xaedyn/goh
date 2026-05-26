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

    private func snapshot(
        id: UInt64,
        state: JobState,
        completed: UInt64,
        total: UInt64,
        speed: UInt64
    ) -> ProgressSnapshot {
        ProgressSnapshot(
            job: JobSummary(
                id: id,
                url: "https://example.com/\(id).iso",
                destination: "/tmp/\(id).iso",
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
}
