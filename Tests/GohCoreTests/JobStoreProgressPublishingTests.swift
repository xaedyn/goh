import Foundation
import Synchronization
import Testing

import GohCore

@Suite("Job store progress publishing")
struct JobStoreProgressPublishingTests {

    @Test("job mutations publish progress snapshots and removals")
    func jobMutationsPublishProgressSnapshotsAndRemovals() throws {
        let progress = ProgressBrokerHub(cadence: 0)
        let store = JobStore(progress: progress)
        let created = store.create(
            url: "https://example.com/big.zip",
            destination: "/tmp/big.zip",
            requestedConnectionCount: 8)
        let received = Mutex<[ProgressEvent]>([])

        let baseline = try progress.subscribe(SubscribeRequest(scope: .all)) { event in
            received.withLock { $0.append(event) }
        }
        #expect(baseline.reply.snapshot.map(\.job.id) == [created.id])
        #expect(baseline.reply.snapshot.first?.job.state == .queued)

        #expect(try store.start(id: created.id) == true)
        _ = try store.recordProgress(
            id: created.id,
            JobProgress(bytesCompleted: 256, bytesTotal: 1_024, bytesPerSecond: 512))
        try store.remove(id: created.id)

        let events = received.withLock { $0 }
        #expect(events.map(\.sequence) == [1, 2, 3])
        #expect(events[0].snapshot.first?.job.state == .active)
        #expect(events[1].snapshot.first?.job.progress.bytesCompleted == 256)
        #expect(events[2].snapshot == [])
    }
}
