import Foundation

/// Routes a decoded ``Command`` to the ``JobStore`` and produces a
/// ``CommandOutcome`` (`DESIGN.md` §3).
///
/// The dispatcher is pure with respect to the wire — it neither decodes the
/// request envelope nor encodes the reply; the XPC adapter does that and
/// translates the outcome into a `reply`- or `error`-kind envelope.
public struct CommandDispatcher: Sendable {

    /// The frozen default connection count when `add` omits it (`DESIGN.md` §4).
    public static let defaultConnectionCount: UInt8 = 8

    /// The maximum accepted connection count (`DESIGN.md` §3.1).
    public static let maximumConnectionCount: UInt8 = 16

    private let store: JobStore
    private let control: DownloadControl?
    private let checkpointStore: CheckpointStore?
    private let importedCookies: ImportedCookieStore?
    private let onJobQueued: (@Sendable (UInt64) -> Void)?
    private let queuedJobAdmission: (@Sendable (UInt64) -> JobSummary?)?

    /// Creates a dispatcher over `store`. `onJobQueued`, when provided, is called
    /// with a job's id whenever a command leaves that job `queued` — after
    /// `add`, and after a `resume` that returns a job to `queued` — so the
    /// daemon can hand it to the download engine. `queuedJobAdmission`, when
    /// provided, owns that admission step and may return a fresher summary after
    /// applying daemon policy such as network auto-pause.
    public init(
        store: JobStore,
        control: DownloadControl? = nil,
        checkpointStore: CheckpointStore? = nil,
        importedCookies: ImportedCookieStore? = nil,
        onJobQueued: (@Sendable (UInt64) -> Void)? = nil,
        queuedJobAdmission: (@Sendable (UInt64) -> JobSummary?)? = nil
    ) {
        self.store = store
        self.control = control
        self.checkpointStore = checkpointStore
        self.importedCookies = importedCookies
        self.onJobQueued = onJobQueued
        self.queuedJobAdmission = queuedJobAdmission
    }

    /// Handles `command`, mutating the job store, and returns the outcome.
    public func reply(to command: Command) -> CommandOutcome {
        do {
            switch command {
            case .add(let request):
                let requestedConnectionCount = request.connectionCount
                    ?? Self.defaultConnectionCount
                guard requestedConnectionCount > 0 else {
                    return .failure(GohError(
                        code: .invalidArgument,
                        message: "connectionCount must be 1-16; got 0"))
                }
                let destination = request.destination
                    ?? Self.defaultDestination(forURL: request.url)
                let cappedConnectionCount = min(
                    requestedConnectionCount, Self.maximumConnectionCount)
                let checkpoint = checkpointStore?.adoptionCandidate(
                    url: request.url, destination: destination)
                let progress = checkpoint?.adoptionProgress(
                    url: request.url, destination: destination)
                let job = store.create(
                    url: request.url,
                    destination: destination,
                    requestedConnectionCount: cappedConnectionCount,
                    progress: progress ?? JobProgress(
                        bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
                    lastProgressAt: progress == nil ? nil : checkpoint?.updatedAt)
                var savedAdoptedCheckpoint = false
                do {
                    if let checkpoint, let checkpointStore {
                        try checkpointStore.save(checkpoint.adopted(jobID: job.id))
                        savedAdoptedCheckpoint = true
                        if checkpoint.jobID != job.id {
                            try checkpointStore.delete(jobID: checkpoint.jobID)
                        }
                    }
                } catch {
                    if savedAdoptedCheckpoint {
                        try? checkpointStore?.delete(jobID: job.id)
                    }
                    try? store.remove(id: job.id)
                    throw error
                }
                if request.useImportedCookies ?? true,
                   let url = URL(string: request.url)
                {
                    importedCookies?.snapshotHeader(forJobID: job.id, url: url)
                }
                return .job(admitQueuedJob(job))

            case .ls:
                return .list(LsReply(jobs: store.allJobs()))

            case .pause(let jobID):
                if store.job(id: jobID)?.state == .active {
                    _ = control?.requestStop(jobID: jobID, reason: .pause)
                }
                return .job(try store.pause(id: jobID))

            case .resume(let jobID):
                var summary = try store.resume(id: jobID)
                if summary.state == .queued {
                    summary = admitQueuedJob(summary)
                }
                return .job(summary)

            case .rm(let request):
                var job = try store.requireJob(id: request.jobID)
                let keepPartialFile = request.keepPartialFile ?? false
                let wasActiveBeforeStopRequest = job.state == .active
                if wasActiveBeforeStopRequest {
                    let stopResult = control?.requestStop(
                        jobID: request.jobID,
                        reason: .remove(keepPartialFile: keepPartialFile))
                    if stopResult == .alreadyFinished,
                       let refreshed = store.job(id: request.jobID)
                    {
                        job = refreshed
                    }
                }
                if !keepPartialFile,
                   job.state != .completed,
                   ownsPartial(for: job, wasActiveBeforeStopRequest: wasActiveBeforeStopRequest)
                {
                    deletePartial(for: job)
                }
                try store.remove(id: request.jobID)
                importedCookies?.removeHeader(forJobID: request.jobID)
                return .removed(RmReply(removedJobID: request.jobID))

            case .authImportSafari:
                return .failure(GohError(
                    code: .invalidArgument,
                    message: "authImportSafari requires an auth.safariCookieFile XPC fd sibling"))

            case .subscribe:
                return .failure(GohError(
                    code: .invalidArgument,
                    message: "subscribe requires a progress subscription handler"))
            }
        } catch let error as GohError {
            return .failure(error)
        } catch {
            // The store throws only `GohError`; this is an unreachable guard.
            return .failure(GohError(code: .cancelled, message: "\(error)"))
        }
    }

    /// Derives a destination when `add` omits one — the URL's last path
    /// component in the user's Downloads directory.
    static func defaultDestination(forURL url: String) -> String {
        let lastComponent = URL(string: url)?.lastPathComponent ?? ""
        let filename = lastComponent.isEmpty ? "download" : lastComponent
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Downloads")
            .appending(path: filename)
            .path
    }

    private func admitQueuedJob(_ summary: JobSummary) -> JobSummary {
        if let admitted = queuedJobAdmission?(summary.id) {
            return admitted
        }
        onJobQueued?(summary.id)
        return summary
    }

    private func deletePartial(for job: JobSummary) {
        try? checkpointStore?.delete(jobID: job.id)
        try? FileManager.default.removeItem(atPath: job.destination)
    }

    private func ownsPartial(
        for job: JobSummary,
        wasActiveBeforeStopRequest: Bool
    ) -> Bool {
        wasActiveBeforeStopRequest
            || job.progress.bytesCompleted > 0
            || checkpointStore?.load(jobID: job.id).checkpoint != nil
    }
}
