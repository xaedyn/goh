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

/// The daemon's support directory —
/// `~/Library/Application Support/dev.goh.daemon`. Created if absent.
func supportDirectoryURL() throws -> URL {
    let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
    let directory = support.appending(
        path: GohXPCService.machServiceName, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("gohd: \(message)\n".utf8))
}

func makeScheduleJob(
    engine: DownloadEngine,
    store: JobStore
) -> @Sendable (UInt64) -> Void {
    { jobID in
        Task { await engine.run(jobID: jobID, in: store) }
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
    let supportDirectory = try supportDirectoryURL()
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
    let reconciliation = store.reconcileActiveJobsOnStartup(checkpoints: checkpointStore)
    if !reconciliation.requeuedJobIDs.isEmpty || !reconciliation.failedJobIDs.isEmpty {
        writer.flush()
    }
    for jobID in reconciliation.failedJobIDs {
        warn("job \(jobID) could not safely resume after restart and was marked retryable")
    }

    let downloadControl = DownloadControl()
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
        completedDownloadHandler: { completed, transferDuration, isResume in
            // D8: skip observation for the resume path.
            if !isResume {
                // D5 gates — all must hold to record a valid observation.
                // wasSolo is checked BEFORE end() runs (end() is in a defer in
                // run(), which fires after this handler returns) — so the
                // whole-duration solo answer is correct here.
                let minDuration = Duration.seconds(10)
                let minBytes: UInt64 = 8 * 1024 * 1024
                let urlKey = hostKey(for: completed.url)
                if let key = urlKey,
                   transferDuration >= minDuration,
                   completed.progress.bytesCompleted >= minBytes,
                   hostProfileStore.wasSolo(jobID: completed.id),
                   completed.actualConnectionCount == completed.requestedConnectionCount
                {
                    hostProfileStore.recordObservation(
                        hostKey: key,
                        connectionCount: completed.actualConnectionCount,
                        totalBytes: completed.progress.bytesCompleted,
                        transferDuration: transferDuration)
                }
            }
            do {
                try metadataTagger.tagCompletedDownload(
                    destination: completed.destination,
                    sourceURL: completed.url,
                    downloadedAt: completed.completedAt ?? Date())
            } catch {
                warn("job \(completed.id) completed but Spotlight metadata tagging failed: \(error)")
            }
        },
        unexpectedStoreError: { jobID, operation, error in
            warn("job \(jobID) store.\(operation) failed unexpectedly: \(error)")
        },
        hostProfileStore: hostProfileStore)
    let scheduleJob = makeScheduleJob(engine: engine, store: store)
    let networkCoordinator = NetworkPauseCoordinator(
        store: store, control: downloadControl, scheduleJob: scheduleJob)
    let dispatcher = CommandDispatcher(
        store: store, control: downloadControl,
        checkpointStore: checkpointStore,
        hostProfileStore: hostProfileStore,
        importedCookies: importedCookies,
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
