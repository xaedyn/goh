import Foundation
import Synchronization

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
    private let writer: CatalogWriter?

    /// Creates a store seeded from `catalog` and persisting mutations through
    /// `writer`. The defaults give an empty, non-persisting store.
    public init(catalog: JobCatalog = .empty, writer: CatalogWriter? = nil) {
        self.state = Mutex(State(jobs: catalog.jobs, nextID: catalog.nextID))
        self.writer = writer
    }

    /// Creates a new job in `queued`, assigns it the next monotonic id, and
    /// returns its summary.
    public func create(
        url: String, destination: String, requestedConnectionCount: UInt8
    ) -> JobSummary {
        withMutation { state in
            let id = state.nextID
            state.nextID += 1
            let summary = JobSummary(
                id: id,
                url: url,
                destination: destination,
                state: .queued,
                progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
                createdAt: Date(),
                lastProgressAt: nil,
                requestedConnectionCount: requestedConnectionCount,
                actualConnectionCount: 0)
            state.jobs.append(summary)
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

    /// Pauses a `queued` job with a `user` pause reason.
    ///
    /// This slice pauses only a `queued` job. `pause` of an `active` job is a
    /// no-op — 3a cannot interrupt a live transfer (that is slice 3c), and
    /// reporting `paused` while the engine still moves bytes would lie to
    /// `goh ls`. `pause` of `paused` / `completed` / `failed` is the §3.3 no-op.
    public func pause(id: UInt64) throws -> JobSummary {
        try mutateJob(id: id) { job in
            guard job.state == .queued else { return }
            job.state = .paused
            job.pauseReason = .user
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
        try withMutation { state in
            guard let index = state.jobs.firstIndex(where: { $0.id == id }) else {
                throw GohError(code: .jobNotFound, message: "no job with id \(id)")
            }
            guard JobLifecycle.isLegal(from: state.jobs[index].state, to: .active) else {
                return false
            }
            state.jobs[index].state = .active
            state.jobs[index].actualConnectionCount = 1  // single-connection in this slice
            return true
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

    /// Marks an `active` job `completed`.
    public func complete(id: UInt64) throws -> JobSummary {
        try mutateJob(id: id) { job in
            guard JobLifecycle.isLegal(from: job.state, to: .completed) else { return }
            job.state = .completed
            job.completedAt = Date()
            job.actualConnectionCount = 0
        }
    }

    /// Marks an `active` job `failed`, recording the error. `retryEligible` is
    /// the daemon's judgement that a fresh attempt could succeed; 3a does not
    /// retry, so `retryCount` is 0 (the retry policy is slice 3c).
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

    /// Removes the job's tracking record (`DESIGN.md` §3.5 "File ownership
    /// boundary" — the record, not any file on disk).
    public func remove(id: UInt64) throws {
        try withMutation { state in
            guard let index = state.jobs.firstIndex(where: { $0.id == id }) else {
                throw GohError(code: .jobNotFound, message: "no job with id \(id)")
            }
            state.jobs.remove(at: index)
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
        try withMutation { state in
            guard let index = state.jobs.firstIndex(where: { $0.id == id }) else {
                throw GohError(code: .jobNotFound, message: "no job with id \(id)")
            }
            change(&state.jobs[index])
            return state.jobs[index]
        }
    }
}
