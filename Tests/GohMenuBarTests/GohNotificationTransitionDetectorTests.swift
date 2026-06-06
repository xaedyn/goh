import Foundation
import Testing
import GohCore
@testable import GohMenuBar

// AC2: pure transition detector — seed suppression, dedup, both terminal variants.
@Suite("GohNotificationTransitionDetector")
struct GohNotificationTransitionDetectorTests {

    // AC2: seed snapshot (previous == nil) must not fire any notifications,
    // even if jobs are already completed/failed.
    @Test func seedSnapshotSuppressesAllNotifications() {
        let snapshots = [
            snapshot(id: 1, state: .completed),
            snapshot(id: 2, state: .failed),
            snapshot(id: 3, state: .active),
        ]
        let detector = GohNotificationTransitionDetector()
        let (toPost, next) = detector.evaluate(previous: nil, snapshots: snapshots)

        #expect(toPost.isEmpty)
        // Seeds the prior-state map with current states.
        #expect(next[1] == .completed)
        #expect(next[2] == .failed)
        #expect(next[3] == .active)
    }

    // AC2: non-terminal → completed fires exactly one notification.
    @Test func activeToCompletedFiresOneNotification() {
        let detector = GohNotificationTransitionDetector()
        let prior: [UInt64: JobState] = [1: .active]
        let (toPost, next) = detector.evaluate(
            previous: prior,
            snapshots: [snapshot(id: 1, state: .completed)])

        #expect(toPost.count == 1)
        #expect(toPost[0].title.lowercased().contains("complete"))
        #expect(next[1] == .completed)
    }

    // AC2: non-terminal → failed fires exactly one notification.
    @Test func activeToFailedFiresOneNotification() {
        let detector = GohNotificationTransitionDetector()
        let prior: [UInt64: JobState] = [1: .active]
        let (toPost, next) = detector.evaluate(
            previous: prior,
            snapshots: [snapshot(id: 1, state: .failed)])

        #expect(toPost.count == 1)
        #expect(toPost[0].title.lowercased().contains("fail"))
        #expect(next[1] == .failed)
    }

    // AC2: repeat snapshot of an already-terminal job must not re-fire.
    @Test func alreadyTerminalDoesNotRefire() {
        let detector = GohNotificationTransitionDetector()
        let prior: [UInt64: JobState] = [1: .completed]
        let (toPost, _) = detector.evaluate(
            previous: prior,
            snapshots: [snapshot(id: 1, state: .completed)])

        #expect(toPost.isEmpty)
    }

    // AC2: job disappears from snapshot set — no notification, removed from next map.
    @Test func disappearingJobDroppedFromMap() {
        let detector = GohNotificationTransitionDetector()
        let prior: [UInt64: JobState] = [1: .active, 2: .active]
        // Job 1 disappears; job 2 remains active.
        let (toPost, next) = detector.evaluate(
            previous: prior,
            snapshots: [snapshot(id: 2, state: .active)])

        #expect(toPost.isEmpty)
        #expect(next[1] == nil)
        #expect(next[2] == .active)
    }

    // AC2: bulk — N concurrent terminal transitions → one notification each.
    @Test func bulkCompletionFiresOnePerJob() {
        let detector = GohNotificationTransitionDetector()
        let prior: [UInt64: JobState] = [1: .active, 2: .active, 3: .paused]
        let (toPost, _) = detector.evaluate(
            previous: prior,
            snapshots: [
                snapshot(id: 1, state: .completed),
                snapshot(id: 2, state: .failed),
                snapshot(id: 3, state: .completed),
            ])

        #expect(toPost.count == 3)
    }

    // AC2: terminal → terminal (e.g. completed → completed) should not re-fire.
    @Test func terminalToSameTerminalDoesNotRefire() {
        let detector = GohNotificationTransitionDetector()
        let prior: [UInt64: JobState] = [1: .failed]
        let (toPost, _) = detector.evaluate(
            previous: prior,
            snapshots: [snapshot(id: 1, state: .failed)])

        #expect(toPost.isEmpty)
    }

    // AC2: a job absent from a non-nil previous map that appears ALREADY TERMINAL
    // in the current snapshots must fire exactly one notification — it was observed
    // live after the seed, not pre-existing history.
    @Test func postSeedFirstSeenTerminalFiresOneNotification() {
        let detector = GohNotificationTransitionDetector()

        // Step 1: seed with an unrelated job so previous is non-nil.
        let (_, seedNext) = detector.evaluate(
            previous: nil,
            snapshots: [snapshot(id: 99, state: .active)])

        // Step 2: evaluate with previous = seedNext; introduce a brand-new job (id: 42)
        // that was never in the prior map but is already in .completed state.
        let (toPost, next) = detector.evaluate(
            previous: seedNext,
            snapshots: [
                snapshot(id: 99, state: .active),
                snapshot(id: 42, state: .completed),
            ])

        #expect(toPost.count == 1)
        #expect(next[42] == .completed)
    }

    // Helper
    private func snapshot(id: UInt64, state: JobState) -> ProgressSnapshot {
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
