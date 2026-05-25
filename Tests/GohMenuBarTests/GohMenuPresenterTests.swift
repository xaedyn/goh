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
        #expect(state.rows[0].controls.contains(.pause))
        #expect(state.rows[1].controls.contains(.pause))
        #expect(state.rows[2].controls.contains(.revealInFinder))
    }

    @Test func explainsPeerValidationFailure() {
        let error = GohMenuError.peerValidation("Peer forbidden (code signing)")

        let state = GohMenuPresenter().state(
            health: .failed(error),
            snapshots: [],
            clipboardURL: nil)

        #expect(state.healthTitle == "Peer validation blocked")
        #expect(state.healthDetail.contains("GOH_XPC_ALLOW_UNVALIDATED_PEERS=1"))
        #expect(state.recoveryAction == .copyCommand("export GOH_XPC_ALLOW_UNVALIDATED_PEERS=1"))
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
