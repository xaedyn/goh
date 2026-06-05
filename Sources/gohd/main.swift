import Darwin
import Dispatch
import Foundation
import Network

import GohCore

// gohd — the download daemon. Runs under launchd as a LaunchAgent; owns the job
// model, persists it across restarts, runs the download engine, and serves
// commands from `goh` over XPC.
//
// Single-connection downloads in this slice; range-parallel orchestration is
// slice 3b.

func warn(_ message: String) {
    FileHandle.standardError.write(Data("gohd: \(message)\n".utf8))
}

func makeScheduleJob(
    engine: DownloadEngine,
    store: JobStore,
    explicitConnectionCounts: ExplicitConnectionCounts
) -> @Sendable (UInt64) -> Void {
    { jobID in
        // Consume the daemon-internal explicit-N entry (set at admission for a
        // user-supplied --connections). Removing it means a later resume of the
        // same job has no entry → the governor may run on the resume path, which
        // is fine (resume excludes observations via D8 and never hits the
        // fetchRanged governor anyway).
        let explicitN = explicitConnectionCounts.consume(jobID: jobID)
        Task { await engine.run(jobID: jobID, in: store, explicitConnectionCount: explicitN) }
    }
}

func makeNetworkPathMonitor(
    networkCoordinator: NetworkPauseCoordinator
) -> NWPathMonitor {
    let pathMonitor = NWPathMonitor()
    let pathQueue = DispatchQueue(label: "dev.goh.daemon.network-path")
    let pathPolicyQueue = DispatchQueue(label: "dev.goh.daemon.network-policy", qos: .utility)
    pathMonitor.pathUpdateHandler = { path in
        let pathState = NetworkPathState(path: path)
        pathPolicyQueue.async {
            networkCoordinator.handlePathUpdate(pathState)
        }
    }
    pathMonitor.start(queue: pathQueue)
    networkCoordinator.handlePathUpdate(NetworkPathState(path: pathMonitor.currentPath))
    return pathMonitor
}

func makeProgressFlushTimer(progress: ProgressBrokerHub) -> DispatchSourceTimer {
    let progressFlushQueue = DispatchQueue(label: "dev.goh.daemon.progress-flush", qos: .utility)
    let progressFlush = DispatchSource.makeTimerSource(queue: progressFlushQueue)
    progressFlush.schedule(deadline: .now() + 0.1, repeating: 0.1)
    progressFlush.setEventHandler {
        progress.flushDue()
    }
    progressFlush.resume()
    return progressFlush
}

private extension NetworkPathState {
    init(path: NWPath) {
        guard path.status == .satisfied else {
            self = .unavailable
            return
        }
        if path.usesInterfaceType(.cellular) {
            self = .satisfiedCellular
        } else {
            self = .satisfiedNonCellular
        }
    }
}

do {
    let supportDirectory = try ProvenanceStoreLocation.supportDirectoryURL(create: true)
    let catalogStore = CatalogStore(fileURL: supportDirectory.appending(path: "catalog.plist"))
    let loaded = catalogStore.load()
    if let sidecar = loaded.corruptionSidecar {
        warn("the job catalog was unreadable and has been reset; "
            + "the damaged file was kept at \(sidecar.path)")
    }
    let writer = CatalogWriter(store: catalogStore)
    let progress = ProgressBrokerHub(initialSnapshots: loaded.catalog.jobs.map {
        ProgressSnapshot(job: $0, lanes: [])
    })
    let store = JobStore(catalog: loaded.catalog, writer: writer, progress: progress)
    let checkpointStore = CheckpointStore(
        directoryURL: supportDirectory.appending(path: "checkpoints", directoryHint: .isDirectory))
    let hostProfileStore = HostProfileStore(
        fileURL: supportDirectory.appending(path: "host-scheduling.plist"),
        persistFailureReporter: { operation, error in
            warn("host-profile store persist failed (\(operation)): \(error)")
        })
    let hostProfileLoadResult = hostProfileStore.load()
    if let sidecar = hostProfileLoadResult.corruptionSidecar {
        warn("the host-scheduling file was unreadable and has been reset; "
            + "the damaged file was kept at \(sidecar.path)")
    }
    let provenanceStore = ProvenanceStore(
        fileURL: try ProvenanceStoreLocation.defaultURL(create: true))
    let provenanceLoad = provenanceStore.load()
    if let sidecar = provenanceLoad.corruptionSidecar {
        warn("the provenance ledger was unreadable and has been reset; "
            + "the damaged file was kept at \(sidecar.path)")
    }
    let reconciliation = store.reconcileActiveJobsOnStartup(checkpoints: checkpointStore)
    if !reconciliation.requeuedJobIDs.isEmpty || !reconciliation.failedJobIDs.isEmpty {
        writer.flush()
    }
    for jobID in reconciliation.failedJobIDs {
        warn("job \(jobID) could not safely resume after restart and was marked retryable")
    }

    let downloadControl = DownloadControl()
    // Daemon-global per-host connection budget (spec §8). One shared instance
    // spans all concurrent downloads — that's the point: the 16-connection cap
    // is per-host across ALL jobs, not per-job.
    let connectionBudget = ConnectionBudget(maxPerHost: 16)
    // Daemon-internal explicit-`--connections` channel (NOT on the wire). The
    // dispatcher records a job's user-supplied N here at admission; makeScheduleJob
    // consumes it to run that job's governor in "off" mode (static pinned N).
    let explicitConnectionCounts = ExplicitConnectionCounts()
    let importedCookies = ImportedCookieStore()
    let metadataTagger = SpotlightMetadataTagger()
    let sleepAssertions = SleepAssertionController()
    // The download engine runs a job whenever a command leaves it `queued` —
    // a fresh `add`, or a `resume`. Each run is its own detached task.
    let engine = DownloadEngine(
        session: URLSession(configuration: GohCore.downloadSessionConfiguration()),
        checkpointStore: checkpointStore,
        control: downloadControl,
        cookieHeaderProvider: { jobID, _ in
            importedCookies.header(forJobID: jobID)
        },
        sleepAssertionController: sleepAssertions,
        completedDownloadHandler: { completed, transferDuration, isResume, sha256, governorOutcome in
            // D5/D8 gates — all must hold to record a valid observation.
            // wasSolo is checked BEFORE end() runs (end() is in a defer in
            // run(), which fires after this handler returns) — so the
            // whole-duration solo answer is correct here.
            let observationKey = hostKey(for: completed.url)
            if let key = observationKey {
                // The bandit records an observation only when the governor
                // converged to a candidate-aligned, stabilized N. Governor-off
                // paths (explicit --connections, tiny files, kill-switch) carry
                // .governorOff (effectiveN nil) so the gate rejects them.
                let req = ObservationRequest(
                    isResume: isResume,
                    transferDuration: transferDuration,
                    bytesCompleted: completed.progress.bytesCompleted,
                    wasSolo: hostProfileStore.wasSolo(jobID: completed.id),
                    governorOutcome: governorOutcome)
                hostProfileStore.recordObservationIfEligible(
                    req,
                    hostKey: key,
                    totalBytes: completed.progress.bytesCompleted,
                    transferDuration: transferDuration)
            }
            do {
                try metadataTagger.tagCompletedDownload(
                    destination: completed.destination,
                    sourceURL: completed.url,
                    downloadedAt: completed.completedAt ?? Date())
            } catch {
                warn("job \(completed.id) completed but Spotlight metadata tagging failed: \(error)")
            }
            if let sha256 {
                do {
                    try provenanceStore.record(
                        entry: ProvenanceEntry(
                            url: completed.url,
                            sha256: "sha256:" + sha256,          // stored WITH prefix (spec §6.2)
                            size: Int(completed.progress.bytesCompleted),
                            downloadedAt: completed.completedAt ?? Date(),
                            // THE one canonicalization (spec §5.3, BLOCK-1)
                            destinationPath: URL(fileURLWithPath: completed.destination)
                                .standardizedFileURL.path))
                } catch {
                    warn("job \(completed.id) completed but provenance recording failed: \(error)")
                }
            }
        },
        unexpectedStoreError: { jobID, operation, error in
            warn("job \(jobID) store.\(operation) failed unexpectedly: \(error)")
        },
        hostProfileStore: hostProfileStore,
        connectionBudget: connectionBudget)
    let scheduleJob = makeScheduleJob(
        engine: engine, store: store,
        explicitConnectionCounts: explicitConnectionCounts)
    let networkCoordinator = NetworkPauseCoordinator(
        store: store, control: downloadControl, scheduleJob: scheduleJob)
    let dispatcher = CommandDispatcher(
        store: store, control: downloadControl,
        checkpointStore: checkpointStore,
        hostProfileStore: hostProfileStore,
        importedCookies: importedCookies,
        explicitConnectionCounts: explicitConnectionCounts,
        queuedJobAdmission: { networkCoordinator.jobBecameQueued($0) })
    let authImportHandler = SafariAuthImportHandler(importedCookies: importedCookies)
    let service = CommandService(
        dispatcher: dispatcher,
        authImportSafari: { authImportHandler.reply(fileDescriptor: $0) },
        progress: progress)

    let pathMonitor = makeNetworkPathMonitor(networkCoordinator: networkCoordinator)
    let progressFlush = makeProgressFlushTimer(progress: progress)

    // Resume any jobs that were still `queued` when the daemon last stopped,
    // subject to the current network policy.
    for job in store.allJobs() where job.state == .queued {
        networkCoordinator.jobBecameQueued(job.id)
    }

    let validationMode = GohXPCService.peerValidationMode(
        environment: ProcessInfo.processInfo.environment)
    let listener = try GohXPCListener(
        machServiceName: GohXPCService.machServiceName,
        mode: validationMode,
        sessionHandler: { session, request in
            service.handle(request, session: session)
        })

    // Flush the catalog on a graceful stop — launchd sends SIGTERM. Handled on a
    // dispatch source, not a raw async-signal handler, so the flush runs in a
    // normal context.
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termination.setEventHandler {
        pathMonitor.cancel()
        progressFlush.cancel()
        writer.flush()
        exit(0)
    }
    termination.resume()

    // The listener and the signal source are active; serve forever.
    withExtendedLifetime((listener, termination, pathMonitor, progressFlush)) {
        dispatchMain()
    }
} catch {
    warn("could not start: \(error)")
    exit(1)
}
