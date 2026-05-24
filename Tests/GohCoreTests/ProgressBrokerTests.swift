import Foundation
import Testing

import GohCore

@Suite("Progress broker")
struct ProgressBrokerTests {

    private func expectErrorCode(_ expected: ErrorCode, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected \(expected), but no error was thrown")
        } catch let error as GohError {
            #expect(error.code == expected)
        } catch {
            Issue.record("expected GohError.\(expected), got \(error)")
        }
    }

    private func job(
        id: UInt64,
        state: JobState = .active,
        completed: UInt64 = 0
    ) -> JobSummary {
        JobSummary(
            id: id,
            url: "https://example.com/file-\(id).zip",
            destination: "/tmp/file-\(id).zip",
            state: state,
            progress: JobProgress(
                bytesCompleted: completed,
                bytesTotal: 1_000,
                bytesPerSecond: completed),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastProgressAt: completed == 0
                ? nil
                : Date(timeIntervalSince1970: 1_700_000_001),
            requestedConnectionCount: 8,
            actualConnectionCount: state == .active ? 2 : 0)
    }

    @Test("subscribe returns a full baseline and validates scope invariants")
    func subscribeBaselineAndValidation() throws {
        let snapshot = ProgressSnapshot(job: job(id: 1), lanes: [])
        var broker = ProgressBroker(initialSnapshots: [snapshot])

        let jobSubscription = try broker.subscribe(SubscribeRequest(scope: .job, jobID: 1))
        #expect(jobSubscription.reply == SubscribeReply(revision: 0, snapshot: [snapshot]))

        let allSubscription = try broker.subscribe(SubscribeRequest(scope: .all))
        #expect(allSubscription.reply == SubscribeReply(revision: 0, snapshot: [snapshot]))

        expectErrorCode(.invalidArgument) {
            _ = try broker.subscribe(SubscribeRequest(scope: .job))
        }
        expectErrorCode(.invalidArgument) {
            _ = try broker.subscribe(SubscribeRequest(scope: .all, jobID: 1))
        }
        expectErrorCode(.jobNotFound) {
            _ = try broker.subscribe(SubscribeRequest(scope: .job, jobID: 404))
        }
    }

    @Test("coalescing overwrites intermediate updates with the latest snapshot")
    func coalescingKeepsLatestSnapshot() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var broker = ProgressBroker(
            cadence: 0.100,
            initialSnapshots: [ProgressSnapshot(job: job(id: 1), lanes: [])])
        let subscription = try broker.subscribe(SubscribeRequest(scope: .all))

        let first = broker.publish(
            ProgressSnapshot(job: job(id: 1, completed: 10), lanes: []),
            at: start)
        #expect(first.map(\.subscriptionID) == [subscription.id])
        #expect(first.map(\.event.sequence) == [1])
        #expect(first.map(\.event.revision) == [1])
        #expect(first.first?.event.snapshot.first?.job.progress.bytesCompleted == 10)

        let second = broker.publish(
            ProgressSnapshot(job: job(id: 1, completed: 20), lanes: []),
            at: start.addingTimeInterval(0.050))
        #expect(second.isEmpty)

        let third = broker.publish(
            ProgressSnapshot(job: job(id: 1, completed: 30), lanes: []),
            at: start.addingTimeInterval(0.075))
        #expect(third.isEmpty)

        let due = broker.flushDue(at: start.addingTimeInterval(0.100))
        #expect(due.map(\.subscriptionID) == [subscription.id])
        #expect(due.map(\.event.sequence) == [2])
        #expect(due.map(\.event.revision) == [3])
        #expect(due.first?.event.snapshot.first?.job.progress.bytesCompleted == 30)
    }

    @Test("terminal removal flushes immediately and job subscribers see an empty snapshot")
    func removalFlushesImmediately() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var broker = ProgressBroker(
            initialSnapshots: [ProgressSnapshot(job: job(id: 1), lanes: [])])
        let subscription = try broker.subscribe(SubscribeRequest(scope: .job, jobID: 1))

        let deliveries = broker.remove(jobID: 1, at: start)

        #expect(deliveries.map(\.subscriptionID) == [subscription.id])
        #expect(deliveries.map(\.event.sequence) == [1])
        #expect(deliveries.map(\.event.revision) == [1])
        #expect(deliveries.first?.event.snapshot == [])
        expectErrorCode(.jobNotFound) {
            _ = try broker.subscribe(SubscribeRequest(scope: .job, jobID: 1))
        }
    }
}
