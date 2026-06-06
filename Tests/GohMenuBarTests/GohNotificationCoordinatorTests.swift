import Foundation
import Testing
import GohCore
@testable import GohMenuBar

@Suite @MainActor struct GohNotificationCoordinatorTests {
    final class StubPreferences: GohMenuPreferences, @unchecked Sendable {
        var notificationsEnabled: Bool
        var launchAtLoginEnabled: Bool = false
        init(notificationsEnabled: Bool) { self.notificationsEnabled = notificationsEnabled }
    }

    @Test func seedSuppressesPreLaunchTerminalJobs() {
        // AC2: a download already complete before the app started must NOT notify.
        let coord = GohNotificationCoordinator(preferences: StubPreferences(notificationsEnabled: true))
        let out = coord.evaluate([makeSnapshot(id: 1, state: .completed)]) // seed
        #expect(out.isEmpty)
    }

    @Test func postSeedTransitionFiresOnce() {
        let coord = GohNotificationCoordinator(preferences: StubPreferences(notificationsEnabled: true))
        _ = coord.evaluate([makeSnapshot(id: 1, state: .active)])          // seed (non-terminal)
        let out1 = coord.evaluate([makeSnapshot(id: 1, state: .completed)]) // transition → fire
        let out2 = coord.evaluate([makeSnapshot(id: 1, state: .completed)]) // repeat → no refire
        #expect(out1.count == 1)
        #expect(out2.isEmpty)
    }

    @Test func disabledSuppressesButAdvancesState() {
        let prefs = StubPreferences(notificationsEnabled: false)
        let coord = GohNotificationCoordinator(preferences: prefs)
        _ = coord.evaluate([makeSnapshot(id: 1, state: .active)])          // seed
        let outOff = coord.evaluate([makeSnapshot(id: 1, state: .completed)]) // disabled → []
        #expect(outOff.isEmpty)
        prefs.notificationsEnabled = true
        let outOn = coord.evaluate([makeSnapshot(id: 1, state: .completed)]) // already terminal → no replay
        #expect(outOn.isEmpty)
    }

    // Helper — self-contained (the P1-2 helper is `private` to the detector suite).
    // Mirrors the P1-2 fixture exactly; `.active` is the real non-terminal JobState case
    // (the enum is queued/active/paused/completed/failed — there is no `.running`).
    private func makeSnapshot(id: UInt64, state: JobState) -> ProgressSnapshot {
        ProgressSnapshot(
            job: JobSummary(
                id: id,
                url: "https://example.com/\(id).bin",
                destination: "/tmp/\(id).bin",
                state: state,
                progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
                createdAt: Date(timeIntervalSince1970: 0),
                lastProgressAt: nil,
                requestedConnectionCount: 1,
                actualConnectionCount: 0),
            lanes: [])
    }
}
