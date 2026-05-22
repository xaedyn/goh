import Foundation
import Testing

import GohCore

@Suite("Job store")
struct JobStoreTests {

    private func newJob(_ store: JobStore, url: String = "https://example.com/f") -> JobSummary {
        store.create(url: url, destination: "/tmp/f", requestedConnectionCount: 8)
    }

    @Test("create assigns monotonic ids and a queued job")
    func createAssignsIds() {
        let store = JobStore()
        let first = newJob(store)
        let second = newJob(store)
        #expect(first.id == 1)
        #expect(second.id == 2)
        #expect(first.state == .queued)
        #expect(first.requestedConnectionCount == 8)
        #expect(first.actualConnectionCount == 0)
        #expect(first.progress.bytesCompleted == 0)
        #expect(first.lastProgressAt == nil)
    }

    @Test("allJobs returns jobs in creation order")
    func allJobsInCreationOrder() {
        let store = JobStore()
        _ = newJob(store, url: "u1")
        _ = newJob(store, url: "u2")
        #expect(store.allJobs().map(\.id) == [1, 2])
    }

    @Test("job(id:) finds an existing job and is nil for an unknown id")
    func jobLookup() {
        let store = JobStore()
        let job = newJob(store, url: "https://example.com/x")
        #expect(store.job(id: job.id)?.url == "https://example.com/x")
        #expect(store.job(id: 999) == nil)
    }

    @Test("pause moves a queued job to paused with a user pause reason")
    func pauseQueuedJob() throws {
        let store = JobStore()
        let job = newJob(store)
        let paused = try store.pause(id: job.id)
        #expect(paused.state == .paused)
        #expect(paused.pauseReason == .user)
    }

    @Test("pausing an already-paused job is a no-op")
    func pauseAlreadyPausedIsNoOp() throws {
        let store = JobStore()
        let job = newJob(store)
        _ = try store.pause(id: job.id)
        let again = try store.pause(id: job.id)
        #expect(again.state == .paused)
        #expect(again.pauseReason == .user)
    }

    @Test("resume returns a paused job to queued and clears the pause reason")
    func resumePausedJob() throws {
        let store = JobStore()
        let job = newJob(store)
        _ = try store.pause(id: job.id)
        let resumed = try store.resume(id: job.id)
        #expect(resumed.state == .queued)
        #expect(resumed.pauseReason == nil)
    }

    @Test("resuming a non-paused job is a no-op")
    func resumeNonPausedIsNoOp() throws {
        let store = JobStore()
        let job = newJob(store)
        let resumed = try store.resume(id: job.id)
        #expect(resumed.state == .queued)
    }

    @Test("remove deletes a job's tracking record")
    func removeJob() throws {
        let store = JobStore()
        let job = newJob(store)
        try store.remove(id: job.id)
        #expect(store.job(id: job.id) == nil)
        #expect(store.allJobs().isEmpty)
    }

    @Test("pause, resume, and remove of an unknown id throw jobNotFound")
    func unknownIdThrowsJobNotFound() {
        let store = JobStore()
        let pauseError = #expect(throws: GohError.self) { _ = try store.pause(id: 404) }
        #expect(pauseError?.code == .jobNotFound)
        let resumeError = #expect(throws: GohError.self) { _ = try store.resume(id: 404) }
        #expect(resumeError?.code == .jobNotFound)
        let removeError = #expect(throws: GohError.self) { try store.remove(id: 404) }
        #expect(removeError?.code == .jobNotFound)
    }
}
