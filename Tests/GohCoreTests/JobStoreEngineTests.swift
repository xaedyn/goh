import Foundation
import Testing

import GohCore

@Suite("Job store — engine transitions")
struct JobStoreEngineTests {

    private func queuedJob(_ store: JobStore) -> JobSummary {
        store.create(
            url: "https://example.com/f", destination: "/tmp/f", requestedConnectionCount: 8)
    }

    @Test("start moves a queued job to active")
    func startActivatesQueuedJob() throws {
        let store = JobStore()
        let job = queuedJob(store)
        let active = try store.start(id: job.id)
        #expect(active.state == .active)
        #expect(active.actualConnectionCount == 1)
    }

    @Test("start is a no-op on a job that is not queued")
    func startNoOpOnNonQueued() throws {
        let store = JobStore()
        let job = queuedJob(store)
        _ = try store.start(id: job.id)
        let again = try store.start(id: job.id)
        #expect(again.state == .active)
    }

    @Test("recordProgress updates an active job's progress and lastProgressAt")
    func recordProgressUpdatesActiveJob() throws {
        let store = JobStore()
        let job = queuedJob(store)
        _ = try store.start(id: job.id)
        let updated = try store.recordProgress(
            id: job.id,
            JobProgress(bytesCompleted: 1024, bytesTotal: 4096, bytesPerSecond: 512))
        #expect(updated.progress.bytesCompleted == 1024)
        #expect(updated.lastProgressAt != nil)
    }

    @Test("complete moves an active job to completed with a completion time")
    func completeFinishesActiveJob() throws {
        let store = JobStore()
        let job = queuedJob(store)
        _ = try store.start(id: job.id)
        let done = try store.complete(id: job.id)
        #expect(done.state == .completed)
        #expect(done.completedAt != nil)
        #expect(done.actualConnectionCount == 0)
    }

    @Test("fail moves an active job to failed, recording the error")
    func failRecordsError() throws {
        let store = JobStore()
        let job = queuedJob(store)
        _ = try store.start(id: job.id)
        let failed = try store.fail(
            id: job.id,
            error: GohError(code: .timedOut, message: "timed out"),
            retryEligible: true)
        #expect(failed.state == .failed)
        #expect(failed.error?.code == .timedOut)
        #expect(failed.failedAt != nil)
        #expect(failed.retryEligible == true)
        #expect(failed.retryCount == 0)
    }

    @Test("pause of an active job is a no-op in this slice")
    func pauseOfActiveJobIsNoOp() throws {
        let store = JobStore()
        let job = queuedJob(store)
        _ = try store.start(id: job.id)
        let result = try store.pause(id: job.id)
        #expect(result.state == .active)
        #expect(result.pauseReason == nil)
    }

    @Test("pause still works on a queued job")
    func pauseStillWorksOnQueuedJob() throws {
        let store = JobStore()
        let job = queuedJob(store)
        let paused = try store.pause(id: job.id)
        #expect(paused.state == .paused)
        #expect(paused.pauseReason == .user)
    }
}
