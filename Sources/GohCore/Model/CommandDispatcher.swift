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
    private let hostProfileStore: HostProfileStore?
    private let importedCookies: ImportedCookieStore?
    private let provenanceStore: ProvenanceStore?
    /// Daemon-internal explicit-`--connections` channel (NOT on the wire). When a
    /// job is admitted with a user-supplied connection count, the dispatcher
    /// records `job.id → cappedConnectionCount` here so the scheduler can run that
    /// job with the governor OFF (statically pinned N). nil in test/headless use.
    private let explicitConnectionCounts: ExplicitConnectionCounts?
    private let onJobQueued: (@Sendable (UInt64) -> Void)?
    private let queuedJobAdmission: (@Sendable (UInt64) -> JobSummary?)?
    private let warn: (@Sendable (String) -> Void)?

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
        hostProfileStore: HostProfileStore? = nil,
        importedCookies: ImportedCookieStore? = nil,
        provenanceStore: ProvenanceStore? = nil,
        explicitConnectionCounts: ExplicitConnectionCounts? = nil,
        onJobQueued: (@Sendable (UInt64) -> Void)? = nil,
        queuedJobAdmission: (@Sendable (UInt64) -> JobSummary?)? = nil,
        warn: (@Sendable (String) -> Void)? = nil
    ) {
        self.store = store
        self.control = control
        self.checkpointStore = checkpointStore
        self.hostProfileStore = hostProfileStore
        self.importedCookies = importedCookies
        self.provenanceStore = provenanceStore
        self.explicitConnectionCounts = explicitConnectionCounts
        self.onJobQueued = onJobQueued
        self.queuedJobAdmission = queuedJobAdmission
        self.warn = warn
    }

    /// Handles `command`, mutating the job store, and returns the outcome.
    public func reply(to command: Command) -> CommandOutcome {
        do {
            switch command {
            case .add(let request):
                // D6: hoist hostKey and selectionReason so the AC12 trace (added in Task 9)
                // can emit all four fields from this same site.
                let admissionHostKey = hostKey(for: request.url)
                let requestedConnectionCount: UInt8
                let selectionReason: SelectionReason
                if let explicit = request.connectionCount {
                    requestedConnectionCount = explicit
                    selectionReason = .explicit  // user-supplied count; bandit not consulted
                } else {
                    let chosen = hostProfileStore?.selectN(hostKey: admissionHostKey)
                        ?? (n: Self.defaultConnectionCount, reason: .cold)
                    requestedConnectionCount = chosen.n
                    selectionReason = chosen.reason
                }
                // AC12: emit scheduling-decision trace (GOH_ENGINE_TRACE=1).
                // Emitted here because this is the only site where all four fields are
                // simultaneously in scope. The engine knows neither reason nor arm EWMAs.
                let armEWMAs: [UInt8: Double]
                if let key = admissionHostKey,
                   let profile = hostProfileStore?.profile(hostKey: key) {
                    // `uniquingKeysWith` (not `uniqueKeysWithValues`) so a corrupt
                    // on-disk profile with duplicate connectionCount arms can never
                    // trap the daemon at admission — mirrors the trap-safe `.first { }`
                    // the selector uses. The store dedupes arms on write; this guards
                    // a tampered/corrupt plist that slipped past the TTL filter.
                    armEWMAs = Dictionary(
                        profile.arms.map { ($0.connectionCount, $0.throughputEWMA) },
                        uniquingKeysWith: { first, _ in first })
                } else {
                    armEWMAs = [:]
                }
                // SM4: annotate exploit+no-explicit-N+governor-on as warmStart in the trace.
                // warmStart is ONLY emitted in this precise triple — exploit alone is not enough
                // (an explicit --connections exploit would be misleading; a governor-off exploit
                // has no live governor to warm-start from). selectN never returns .warmStart;
                // it is a trace-only annotation set here in the dispatcher.
                let traceReason: SelectionReason
                if selectionReason == .exploit,
                   request.connectionCount == nil,
                   DownloadEngine.governorEnabled {
                    traceReason = .warmStart   // exploit arm + governor will run live → warm-start from converged N
                } else {
                    traceReason = selectionReason
                }
                EngineDiagnostics().recordSchedulingDecision(
                    hostKey: admissionHostKey,
                    chosenN: requestedConnectionCount,
                    reason: traceReason,
                    armEWMAs: armEWMAs)
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
                // Daemon-internal explicit-N channel: a user-supplied --connections
                // pins N and turns the governor off for this job. Resume/cold/bandit
                // paths never write here, so those jobs get explicitN == nil and the
                // governor may run. Set AFTER create (need job.id) and BEFORE
                // admission (which schedules the run that consumes this entry).
                if selectionReason == .explicit {
                    explicitConnectionCounts?.set(jobID: job.id, count: cappedConnectionCount)
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

            case .recordVerifiedProvenance(let request):
                guard let provenanceStore else {
                    warn?("recordVerifiedProvenance: provenance store unavailable; skipped \(request.entries.count) entr\(request.entries.count == 1 ? "y" : "ies")")
                    return .ack
                }
                let validEntries = request.entries.filter {
                    $0.sha256.hasPrefix("sha256:") && !$0.destinationPath.isEmpty
                }
                if validEntries.count != request.entries.count {
                    let dropped = request.entries.count - validEntries.count
                    warn?("recordVerifiedProvenance: dropped \(dropped) invalid entr\(dropped == 1 ? "y" : "ies")")
                }
                do {
                    try provenanceStore.recordVerified(entries: validEntries)
                } catch {
                    // Best-effort: a store write failure is non-fatal for the daemon
                    // (mirrors the download completion handler). The reply is still .ack;
                    // the CLI's best-effort path does not depend on a structured error here.
                    warn?("recordVerifiedProvenance: provenance store write failed for \(validEntries.count) entr\(validEntries.count == 1 ? "y" : "ies"): \(error)")
                }
                return .ack
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
        let filename = lastComponent.isEmpty || lastComponent == "/"
            ? "download"
            : lastComponent
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
