import Foundation
import Synchronization

/// The daemon's in-memory store of download jobs (`DESIGN.md` §2).
///
/// Jobs are held behind a `Mutex` so the synchronous XPC dispatch path can reach
/// the store from any thread. State transitions go through ``JobLifecycle``;
/// `pause` and `resume` are no-ops on a job the lifecycle does not permit the
/// transition for, which is exactly the contract's §3.3 / §3.4 no-op behaviour.
///
/// This slice has no engine, so a created job rests in `queued`; the
/// `active` / `completed` / `failed` transitions arrive with the HTTP-transport
/// slice.
public final class JobStore: Sendable {

    private struct State {
        var jobs: [JobSummary] = []
        var nextID: UInt64 = 1
    }

    private let state = Mutex(State())

    public init() {}

    /// Creates a new job in `queued`, assigns it the next monotonic id, and
    /// returns its summary.
    public func create(
        url: String, destination: String, requestedConnectionCount: UInt8
    ) -> JobSummary {
        state.withLock { state in
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

    /// Pauses the job with a `user` pause reason. A no-op when the lifecycle does
    /// not permit `→ paused` (already paused, or terminal) — §3.3.
    public func pause(id: UInt64) throws -> JobSummary {
        try mutate(id: id) { job in
            guard JobLifecycle.isLegal(from: job.state, to: .paused) else { return }
            job.state = .paused
            job.pauseReason = .user
        }
    }

    /// Resumes the job to `queued`. A no-op when the lifecycle does not permit
    /// `→ queued` (the job is not paused) — §3.4.
    public func resume(id: UInt64) throws -> JobSummary {
        try mutate(id: id) { job in
            guard JobLifecycle.isLegal(from: job.state, to: .queued) else { return }
            job.state = .queued
            job.pauseReason = nil
        }
    }

    /// Removes the job's tracking record (`DESIGN.md` §3.5 "File ownership
    /// boundary" — the record, not any file on disk).
    public func remove(id: UInt64) throws {
        try state.withLock { state in
            guard let index = state.jobs.firstIndex(where: { $0.id == id }) else {
                throw GohError(code: .jobNotFound, message: "no job with id \(id)")
            }
            state.jobs.remove(at: index)
        }
    }

    /// Applies `change` to the job with `id` and returns the updated summary,
    /// throwing `jobNotFound` when no such job exists.
    private func mutate(
        id: UInt64, _ change: (inout JobSummary) -> Void
    ) throws -> JobSummary {
        try state.withLock { state in
            guard let index = state.jobs.firstIndex(where: { $0.id == id }) else {
                throw GohError(code: .jobNotFound, message: "no job with id \(id)")
            }
            change(&state.jobs[index])
            return state.jobs[index]
        }
    }
}
