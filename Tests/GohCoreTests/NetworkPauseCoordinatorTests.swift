import Dispatch
import Foundation
import Synchronization
import Testing

@testable import GohCore

@Suite("Network pause coordinator")
struct NetworkPauseCoordinatorTests {

    private final class BlockingStop: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let requestedJobIDs = Mutex<[UInt64]>([])

        func request(jobID: UInt64) -> DownloadStopResult? {
            requestedJobIDs.withLock { $0.append(jobID) }
            started.signal()
            release.wait()
            return .stopped
        }
    }

    private func newJob(_ store: JobStore, url: String = "https://example.com/file") -> JobSummary {
        store.create(url: url, destination: "/tmp/file", requestedConnectionCount: 8)
    }

    @Test("a cellular path pauses queued jobs with a network pause reason")
    func cellularPathPausesQueuedJobs() throws {
        let store = JobStore()
        let job = newJob(store)
        let coordinator = NetworkPauseCoordinator(store: store)

        coordinator.handlePathUpdate(.satisfiedCellular)

        let paused = try #require(store.job(id: job.id))
        #expect(paused.state == .paused)
        #expect(paused.pauseReason == .network)
    }

    @Test("a satisfied non-cellular path resumes only network-paused jobs")
    func nonCellularPathResumesOnlyNetworkPausedJobs() throws {
        let store = JobStore()
        let networkPaused = newJob(store, url: "https://example.com/network")
        let userPaused = newJob(store, url: "https://example.com/user")
        let scheduled = Mutex<[UInt64]>([])
        let coordinator = NetworkPauseCoordinator(
            store: store,
            scheduleJob: { id in scheduled.withLock { $0.append(id) } })

        coordinator.handlePathUpdate(.satisfiedCellular)
        _ = try store.resume(id: userPaused.id)
        _ = try store.pause(id: userPaused.id)

        coordinator.handlePathUpdate(.satisfiedNonCellular)

        let resumed = try #require(store.job(id: networkPaused.id))
        let stillPaused = try #require(store.job(id: userPaused.id))
        #expect(resumed.state == .queued)
        #expect(resumed.pauseReason == nil)
        #expect(stillPaused.state == .paused)
        #expect(stillPaused.pauseReason == .user)
        #expect(scheduled.withLock { $0 } == [networkPaused.id])
    }

    @Test("a cellular path asks active jobs to stop before recording a network pause")
    func cellularPathStopsActiveJobsBeforePausing() throws {
        let store = JobStore()
        let job = newJob(store)
        #expect(try store.start(id: job.id))
        let stops = Mutex<[UInt64]>([])
        let coordinator = NetworkPauseCoordinator(
            store: store,
            requestActiveStop: { id in
                #expect(store.job(id: id)?.state == .active)
                stops.withLock { $0.append(id) }
                return .stopped
            })

        coordinator.handlePathUpdate(.satisfiedCellular)

        let paused = try #require(store.job(id: job.id))
        #expect(stops.withLock { $0 } == [job.id])
        #expect(paused.state == .paused)
        #expect(paused.pauseReason == .network)
        #expect(paused.actualConnectionCount == 0)
    }

    @Test("if Wi-Fi returns while an active cellular pause is waiting, the job is rescheduled")
    func restoredPathAfterStopRequestReschedulesActiveJob() throws {
        let store = JobStore()
        let job = newJob(store)
        #expect(try store.start(id: job.id))
        let stop = BlockingStop()
        let scheduled = Mutex<[UInt64]>([])
        let coordinator = NetworkPauseCoordinator(
            store: store,
            requestActiveStop: { stop.request(jobID: $0) },
            scheduleJob: { id in scheduled.withLock { ids in ids.append(id) } })

        let group = DispatchGroup()
        group.enter()
        Thread {
            coordinator.handlePathUpdate(.satisfiedCellular)
            group.leave()
        }.start()
        #expect(stop.started.wait(timeout: .now() + 30) == .success)

        coordinator.handlePathUpdate(.satisfiedNonCellular)
        stop.release.signal()
        #expect(group.wait(timeout: .now() + 30) == .success)

        let resumed = try #require(store.job(id: job.id))
        #expect(resumed.state == .queued)
        #expect(resumed.pauseReason == nil)
        #expect(scheduled.withLock { $0 } == [job.id])
    }

    @Test("dispatcher admission returns a network-paused job instead of scheduling on cellular")
    func dispatcherAdmissionPausesAddOnCellular() {
        let store = JobStore()
        let scheduled = Mutex<[UInt64]>([])
        let coordinator = NetworkPauseCoordinator(
            store: store,
            scheduleJob: { id in scheduled.withLock { $0.append(id) } })
        coordinator.handlePathUpdate(.satisfiedCellular)
        let dispatcher = CommandDispatcher(
            store: store,
            queuedJobAdmission: { coordinator.jobBecameQueued($0) })

        guard case .job(let summary) = dispatcher.reply(
            to: .add(request: AddRequest(url: "https://example.com/file")))
        else {
            Issue.record("expected .job")
            return
        }

        #expect(summary.state == .paused)
        #expect(summary.pauseReason == .network)
        #expect(scheduled.withLock { $0 }.isEmpty)
    }

    @Test("queued admission does not strand a job when Wi-Fi returns during the pause decision")
    func queuedAdmissionDoesNotStrandJobWhenPathRestores() throws {
        let store = JobStore()
        let scheduled = Mutex<[UInt64]>([])
        let holder = Mutex<NetworkPauseCoordinator?>(nil)
        let coordinator = NetworkPauseCoordinator(
            store: store,
            scheduleJob: { id in scheduled.withLock { $0.append(id) } },
            beforeQueuedNetworkPause: {
                holder.withLock { $0 }?.handlePathUpdate(.satisfiedNonCellular)
            })
        holder.withLock { $0 = coordinator }
        coordinator.handlePathUpdate(.satisfiedCellular)
        let job = newJob(store)

        let summary = try #require(coordinator.jobBecameQueued(job.id))
        let current = try #require(store.job(id: job.id))
        #expect(summary.state == .queued)
        #expect(summary.pauseReason == nil)
        #expect(current.state == .queued)
        #expect(current.pauseReason == nil)
        #expect(scheduled.withLock { $0 } == [job.id])
    }
}
