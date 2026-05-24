import Foundation
import Synchronization
import Testing

import GohCore

@Suite("Progress broker hub")
struct ProgressBrokerHubTests {

    private func job(id: UInt64, completed: UInt64 = 0) -> JobSummary {
        JobSummary(
            id: id,
            url: "https://example.com/file-\(id).zip",
            destination: "/tmp/file-\(id).zip",
            state: .active,
            progress: JobProgress(
                bytesCompleted: completed,
                bytesTotal: 1_000,
                bytesPerSecond: completed),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastProgressAt: Date(timeIntervalSince1970: 1_800_000_001),
            requestedConnectionCount: 8,
            actualConnectionCount: 2)
    }

    @Test("failed delivery removes that subscriber only")
    func failedDeliveryRemovesThatSubscriberOnly() throws {
        let hub = ProgressBrokerHub(
            cadence: 0,
            initialSnapshots: [ProgressSnapshot(job: job(id: 1), lanes: [])])
        let failedAttempts = Mutex(0)
        let received = Mutex<[ProgressEvent]>([])

        _ = try hub.subscribe(SubscribeRequest(scope: .all)) { _ in
            failedAttempts.withLock { $0 += 1 }
            throw GohError(code: .cancelled)
        }
        _ = try hub.subscribe(SubscribeRequest(scope: .all)) { event in
            received.withLock { $0.append(event) }
        }

        hub.publish(ProgressSnapshot(job: job(id: 1, completed: 10), lanes: []))
        hub.publish(ProgressSnapshot(job: job(id: 1, completed: 20), lanes: []))

        #expect(failedAttempts.withLock { $0 } == 1)
        #expect(received.withLock { $0.map(\.sequence) } == [1, 2])
    }

    @Test("explicit unsubscribe removes a subscriber without waiting for delivery failure")
    func explicitUnsubscribeRemovesSubscriber() throws {
        let hub = ProgressBrokerHub(
            cadence: 0,
            initialSnapshots: [ProgressSnapshot(job: job(id: 1), lanes: [])])
        let received = Mutex<[ProgressEvent]>([])

        let subscription = try hub.subscribe(SubscribeRequest(scope: .all)) { event in
            received.withLock { $0.append(event) }
        }

        hub.unsubscribe(subscription.id)
        hub.publish(ProgressSnapshot(job: job(id: 1, completed: 10), lanes: []))

        #expect(received.withLock { $0 }.isEmpty)
    }
}
