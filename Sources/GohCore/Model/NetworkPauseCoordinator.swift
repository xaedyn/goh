import Foundation
import Synchronization

/// The daemon's coarse view of whether downloads are allowed on the current
/// network path.
public enum NetworkPathState: Sendable, Equatable {
    case satisfiedNonCellular
    case satisfiedCellular
    case unavailable

    var allowsDownloads: Bool {
        self == .satisfiedNonCellular
    }
}

/// Applies daemon-local network policy to jobs as path conditions change.
///
/// A satisfied non-cellular path allows scheduling. Cellular and unavailable
/// paths hold work as ``PauseReason.network`` so the daemon can resume it
/// automatically when an acceptable path returns.
public final class NetworkPauseCoordinator: Sendable {
    private struct State {
        var path: NetworkPathState?
    }

    private let store: JobStore
    private let requestActiveStop: @Sendable (UInt64) -> DownloadStopResult?
    private let scheduleJob: @Sendable (UInt64) -> Void
    private let state = Mutex(State(path: nil))

    public init(
        store: JobStore,
        requestActiveStop: @escaping @Sendable (UInt64) -> DownloadStopResult? = { _ in nil },
        scheduleJob: @escaping @Sendable (UInt64) -> Void = { _ in }
    ) {
        self.store = store
        self.requestActiveStop = requestActiveStop
        self.scheduleJob = scheduleJob
    }

    public convenience init(
        store: JobStore,
        control: DownloadControl,
        scheduleJob: @escaping @Sendable (UInt64) -> Void = { _ in }
    ) {
        self.init(
            store: store,
            requestActiveStop: { jobID in
                control.requestStop(jobID: jobID, reason: .pause)
            },
            scheduleJob: scheduleJob)
    }

    public func handlePathUpdate(_ path: NetworkPathState) {
        state.withLock { $0.path = path }
        if path.allowsDownloads {
            resumeNetworkPausedJobs()
        } else {
            pauseJobsForNetwork()
        }
    }

    /// Applies current network admission to a job that just became `queued`.
    ///
    /// Unknown paths are treated as not-yet-admitted: the job is held as
    /// network-paused until the monitor reports a satisfied non-cellular path.
    @discardableResult
    public func jobBecameQueued(_ jobID: UInt64) -> JobSummary? {
        guard let job = store.job(id: jobID) else { return nil }
        guard job.state == .queued else { return job }

        if downloadsAllowed {
            scheduleJob(jobID)
            return job
        }
        return try? store.pause(id: jobID, reason: .network)
    }

    private var downloadsAllowed: Bool {
        state.withLock { $0.path?.allowsDownloads == true }
    }

    private func pauseJobsForNetwork() {
        let jobs = store.allJobs()
        for job in jobs where job.state == .queued || job.state == .active {
            if job.state == .active {
                _ = requestActiveStop(job.id)
            }
            guard let paused = try? store.pause(id: job.id, reason: .network),
                  paused.state == .paused,
                  paused.pauseReason == .network
            else {
                continue
            }
            if downloadsAllowed {
                resumeNetworkPausedJob(paused.id)
            }
        }
    }

    private func resumeNetworkPausedJobs() {
        let jobIDs = store.allJobs()
            .filter { $0.state == .paused && $0.pauseReason == .network }
            .map(\.id)
        for jobID in jobIDs {
            resumeNetworkPausedJob(jobID)
        }
    }

    private func resumeNetworkPausedJob(_ jobID: UInt64) {
        guard let job = store.job(id: jobID),
              job.state == .paused,
              job.pauseReason == .network,
              let resumed = try? store.resume(id: jobID),
              resumed.state == .queued
        else {
            return
        }
        scheduleJob(jobID)
    }
}
