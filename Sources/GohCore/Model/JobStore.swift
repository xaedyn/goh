import Foundation
import Synchronization

/// Summary of the daemon's startup repair pass over jobs that were `active`
/// when the previous daemon process exited.
public struct StartupReconciliationResult: Sendable, Equatable {
    public var requeuedJobIDs: [UInt64]
    public var failedJobIDs: [UInt64]

    public init(requeuedJobIDs: [UInt64] = [], failedJobIDs: [UInt64] = []) {
        self.requeuedJobIDs = requeuedJobIDs
        self.failedJobIDs = failedJobIDs
    }
}

private enum StartupReconciliationDecision: Sendable {
    case requeue(progress: JobProgress, lastProgressAt: Date)
    case fail(message: String)
}

/// The daemon's in-memory store of download jobs (`DESIGN.md` §2).
///
/// Jobs are held behind a `Mutex` so the synchronous XPC dispatch path can reach
/// the store from any thread. State transitions go through ``JobLifecycle``;
/// `pause` and `resume` are no-ops on a job the lifecycle does not permit the
/// transition for, which is exactly the contract's §3.3 / §3.4 no-op behaviour.
///
/// The store may be seeded from a ``JobCatalog`` (restored on daemon startup)
/// and, given a ``CatalogWriter``, persists every mutation. This slice has no
/// engine, so a created job rests in `queued`; the `active` / `completed` /
/// `failed` transitions arrive with the HTTP-transport slice.
public final class JobStore: Sendable {

    private struct State {
        var jobs: [JobSummary]
        var nextID: UInt64
    }

    private let state: Mutex<State>
    /// Serializes each state mutation through its progress-broker side effect,
    /// so a publish cannot race after a later removal and resurrect stale
    /// progress.
    private let mutationOrder = Mutex(())
    private let writer: CatalogWriter?
    private let progress: ProgressBrokerHub?

    /// Creates a store seeded from `catalog` and persisting mutations through
    /// `writer`. The defaults give an empty, non-persisting store.
    public init(
        catalog: JobCatalog = .empty,
        writer: CatalogWriter? = nil,
        progress: ProgressBrokerHub? = nil
    ) {
        self.state = Mutex(State(jobs: catalog.jobs, nextID: catalog.nextID))
        self.writer = writer
        self.progress = progress
    }

    /// Creates a new job in `queued`, assigns it the next monotonic id, and
    /// returns its summary.
    public func create(
        url: String,
        destination: String,
        requestedConnectionCount: UInt8,
        progress: JobProgress = JobProgress(
            bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
        lastProgressAt: Date? = nil
    ) -> JobSummary {
        mutationOrder.withLock { _ in
            let summary = withMutation { state in
                let id = state.nextID
                state.nextID += 1
                let summary = JobSummary(
                    id: id,
                    url: url,
                    destination: destination,
                    state: .queued,
                    progress: progress,
                    createdAt: Date(),
                    lastProgressAt: lastProgressAt,
                    requestedConnectionCount: requestedConnectionCount,
                    actualConnectionCount: 0)
                state.jobs.append(summary)
                return summary
            }
            publishProgress(summary)
            return summary
        }
    }

    /// Every job, in creation order.
    public func allJobs() -> [JobSummary] {
        state.withLock { $0.jobs }
    }

    /// The job with `id`, or `nil` when none exists.
    public func job(id: UInt64) -> JobSummary? {
        state.withLock { $0.jobs.first { $0.id == id } }
    }

    /// The job with `id`, throwing `jobNotFound` when none exists.
    public func requireJob(id: UInt64) throws -> JobSummary {
        guard let job = job(id: id) else {
            throw GohError(code: .jobNotFound, message: "no job with id \(id)")
        }
        return job
    }

    /// Pauses a `queued` job immediately, or an `active` job after the engine
    /// has acknowledged its checkpoint boundary through ``DownloadControl``.
    /// `pause` of `paused` / `completed` / `failed` is the §3.3 no-op.
    public func pause(id: UInt64, reason: PauseReason = .user) throws -> JobSummary {
        try mutateJob(id: id) { job in
            guard JobLifecycle.isLegal(from: job.state, to: .paused) else { return }
            job.state = .paused
            job.pauseReason = reason
            job.actualConnectionCount = 0
        }
    }

    /// Resumes the job to `queued`. A no-op when the lifecycle does not permit
    /// `→ queued` (the job is not paused) — §3.4.
    public func resume(id: UInt64) throws -> JobSummary {
        try mutateJob(id: id) { job in
            guard JobLifecycle.isLegal(from: job.state, to: .queued) else { return }
            job.state = .queued
            job.pauseReason = nil
        }
    }

    // MARK: Engine transitions
    //
    // The download engine drives a job through its working states. Each
    // transition is guarded by ``JobLifecycle``; a call on a job in the wrong
    // state is a no-op (the engine is expected to call these in order).

    /// Atomically claims a `queued` job for the engine: transitions it to
    /// `active` and returns `true`. Returns `false` when the job exists but is
    /// not `queued` — already claimed, or terminal — so a second caller cannot
    /// also start downloading it. Throws `jobNotFound` if no such job exists.
    public func start(id: UInt64) throws -> Bool {
        try mutationOrder.withLock { _ in
            let (started, summary): (Bool, JobSummary?) = try withMutation { state in
                guard let index = state.jobs.firstIndex(where: { $0.id == id }) else {
                    throw GohError(code: .jobNotFound, message: "no job with id \(id)")
                }
                guard JobLifecycle.isLegal(from: state.jobs[index].state, to: .active) else {
                    return (false, Optional<JobSummary>.none)
                }
                state.jobs[index].state = .active
                state.jobs[index].actualConnectionCount = 1  // single-connection in this slice
                return (true, state.jobs[index])
            }
            if let summary {
                publishProgress(summary)
            }
            return started
        }
    }

    /// Records download progress for an `active` job.
    public func recordProgress(id: UInt64, _ progress: JobProgress) throws -> JobSummary {
        try mutateJob(id: id) { job in
            guard job.state == .active else { return }
            job.progress = progress
            job.lastProgressAt = Date()
        }
    }

    /// Records the peak concurrent connection count the engine has used.
    ///
    /// Each call updates the stored value to the running maximum — a count that
    /// falls back below a previously-seen peak does not lower the stored value.
    /// The hard ceiling is 16 (the in-flight governor may push N above the
    /// admission-time `requestedConnectionCount`). Silently skips when the job is
    /// not `active` or `count` is 0 (`DESIGN.md` §Adaptive host scheduling,
    /// "`actualConnectionCount` lifecycle").
    public func setActualConnectionCount(id: UInt64, _ count: UInt8) throws -> JobSummary {
        try mutateJob(id: id) { job in
            guard job.state == .active else { return }
            guard count > 0 else { return }
            // Peak-max: store the highest N seen over the transfer. Cap is the
            // hard ceiling 16 — the governor may exceed requestedConnectionCount.
            job.actualConnectionCount = max(job.actualConnectionCount, min(count, 16))
        }
    }

    /// Marks an `active` job `completed`. `actualConnectionCount` is kept — on a
    /// completed job it is the historical record of the connection count the
    /// download used (`DESIGN.md` §2.2, "`actualConnectionCount` lifecycle").
    public func complete(id: UInt64) throws -> JobSummary {
        try mutateJob(id: id) { job in
            guard JobLifecycle.isLegal(from: job.state, to: .completed) else { return }
            job.state = .completed
            job.completedAt = Date()
        }
    }

    /// Marks an `active` job `failed`, recording the error. `retryEligible` is
    /// the daemon's judgement that a fresh attempt could succeed. There is no
    /// in-place retry operation, so `retryCount` is 0.
    public func fail(
        id: UInt64, error: GohError, retryEligible: Bool
    ) throws -> JobSummary {
        try mutateJob(id: id) { job in
            guard JobLifecycle.isLegal(from: job.state, to: .failed) else { return }
            job.state = .failed
            job.error = error
            job.failedAt = Date()
            job.retryEligible = retryEligible
            job.retryCount = 0
            job.actualConnectionCount = 0
        }
    }

    /// Repairs jobs that were persisted as `active` before a daemon restart.
    ///
    /// This is the one intentional `active → queued` path. It is not a normal
    /// lifecycle transition: after a restart no engine task owns those jobs, so
    /// the store either proves a checkpoint is safe enough to schedule or marks
    /// the job failed with a retryable recovery error.
    public func reconcileActiveJobsOnStartup(
        checkpoints: CheckpointStore
    ) -> StartupReconciliationResult {
        let activeJobs = state.withLock { state in
            state.jobs.filter { $0.state == .active }
        }
        guard !activeJobs.isEmpty else { return StartupReconciliationResult() }

        var decisions: [UInt64: StartupReconciliationDecision] = [:]
        for job in activeJobs {
            let loaded = checkpoints.load(jobID: job.id)
            if let checkpoint = loaded.checkpoint,
               let progress = checkpoint.startupResumeProgress(for: job)
            {
                decisions[job.id] = .requeue(
                    progress: progress, lastProgressAt: checkpoint.updatedAt)
            } else {
                decisions[job.id] = .fail(
                    message: Self.unsafeResumeMessage(sidecar: loaded.corruptionSidecar))
            }
        }

        return mutationOrder.withLock { _ in
            let (result, changedJobs) = withMutation { state in
                var result = StartupReconciliationResult()
                var changedJobs: [JobSummary] = []
                for index in state.jobs.indices where state.jobs[index].state == .active {
                    let jobID = state.jobs[index].id
                    guard let decision = decisions[jobID] else { continue }
                    switch decision {
                    case .requeue(let progress, let lastProgressAt):
                        state.jobs[index].state = .queued
                        state.jobs[index].progress = progress
                        state.jobs[index].lastProgressAt = lastProgressAt
                        state.jobs[index].actualConnectionCount = 0
                        state.jobs[index].pauseReason = nil
                        state.jobs[index].completedAt = nil
                        state.jobs[index].error = nil
                        state.jobs[index].retryEligible = nil
                        state.jobs[index].failedAt = nil
                        state.jobs[index].retryCount = nil
                        result.requeuedJobIDs.append(jobID)
                        changedJobs.append(state.jobs[index])
                    case .fail(let message):
                        state.jobs[index].state = .failed
                        state.jobs[index].progress.bytesPerSecond = 0
                        state.jobs[index].actualConnectionCount = 0
                        state.jobs[index].pauseReason = nil
                        state.jobs[index].completedAt = nil
                        state.jobs[index].error = GohError(
                            code: .connectionFailed, message: message)
                        state.jobs[index].failedAt = Date()
                        state.jobs[index].retryEligible = true
                        state.jobs[index].retryCount = 0
                        result.failedJobIDs.append(jobID)
                        changedJobs.append(state.jobs[index])
                    }
                }
                return (result, changedJobs)
            }
            for job in changedJobs {
                publishProgress(job)
            }
            return result
        }
    }

    /// Removes the job's tracking record (`DESIGN.md` §3.5 "File ownership
    /// boundary" — the record, not any file on disk).
    public func remove(id: UInt64) throws {
        try mutationOrder.withLock { _ in
            try withMutation { state in
                guard let index = state.jobs.firstIndex(where: { $0.id == id }) else {
                    throw GohError(code: .jobNotFound, message: "no job with id \(id)")
                }
                state.jobs.remove(at: index)
            }
            progress?.remove(jobID: id)
        }
    }

    /// Runs `body` under the lock, then schedules a catalog save of the new
    /// state. When `body` throws, the state is unchanged and no save is
    /// scheduled.
    private func withMutation<R>(_ body: (inout State) throws -> R) rethrows -> R {
        let (result, snapshot) = try state.withLock { state -> (R, JobCatalog) in
            let result = try body(&state)
            let snapshot = JobCatalog(
                version: JobCatalog.currentVersion, nextID: state.nextID, jobs: state.jobs)
            return (result, snapshot)
        }
        writer?.scheduleSave(snapshot)
        return result
    }

    /// Applies `change` to the job with `id`, returns the updated summary, and
    /// persists — throwing `jobNotFound` when no such job exists.
    private func mutateJob(
        id: UInt64, _ change: (inout JobSummary) -> Void
    ) throws -> JobSummary {
        try mutationOrder.withLock { _ in
            let (summary, changed) = try withMutation { state in
                guard let index = state.jobs.firstIndex(where: { $0.id == id }) else {
                    throw GohError(code: .jobNotFound, message: "no job with id \(id)")
                }
                let original = state.jobs[index]
                change(&state.jobs[index])
                return (state.jobs[index], state.jobs[index] != original)
            }
            if changed {
                publishProgress(summary)
            }
            return summary
        }
    }

    private static func unsafeResumeMessage(sidecar: URL?) -> String {
        var message = "resume metadata was unavailable or unsafe after daemon restart"
        if sidecar != nil {
            // Note that a sidecar was kept, but not its path — the message
            // crosses the XPC progress channel and must not disclose daemon
            // filesystem paths to other same-user subscribers (audit L3). The
            // operator can locate it via the daemon's local log.
            message += "; a copy of the damaged checkpoint was preserved for diagnostics"
        }
        message += "; retry to start a fresh download"
        return message
    }

    private func publishProgress(_ summary: JobSummary) {
        progress?.publish(ProgressSnapshot(job: summary, lanes: []))
    }
}
