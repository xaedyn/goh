import Darwin
import Dispatch
import Foundation

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

do {
    let supportDirectory = try supportDirectoryURL()
    let catalogStore = CatalogStore(fileURL: supportDirectory.appending(path: "catalog.plist"))
    let loaded = catalogStore.load()
    if let sidecar = loaded.corruptionSidecar {
        warn("the job catalog was unreadable and has been reset; "
            + "the damaged file was kept at \(sidecar.path)")
    }
    let writer = CatalogWriter(store: catalogStore)
    let store = JobStore(catalog: loaded.catalog, writer: writer)
    let checkpointStore = CheckpointStore(
        directoryURL: supportDirectory.appending(path: "checkpoints", directoryHint: .isDirectory))
    let reconciliation = store.reconcileActiveJobsOnStartup(checkpoints: checkpointStore)
    if !reconciliation.requeuedJobIDs.isEmpty || !reconciliation.failedJobIDs.isEmpty {
        writer.flush()
    }
    for jobID in reconciliation.failedJobIDs {
        warn("job \(jobID) could not safely resume after restart and was marked retryable")
    }

    let downloadControl = DownloadControl()
    // The download engine runs a job whenever a command leaves it `queued` —
    // a fresh `add`, or a `resume`. Each run is its own detached task.
    let engine = DownloadEngine(
        session: URLSession(configuration: GohCore.downloadSessionConfiguration()),
        checkpointStore: checkpointStore,
        control: downloadControl)
    let dispatcher = CommandDispatcher(
        store: store, control: downloadControl,
        onJobQueued: { jobID in
            Task { await engine.run(jobID: jobID, in: store) }
        })
    let service = CommandService(dispatcher: dispatcher)

    // Resume any jobs that were still `queued` when the daemon last stopped.
    for job in store.allJobs() where job.state == .queued {
        Task { await engine.run(jobID: job.id, in: store) }
    }

    let validationMode = GohXPCService.peerValidationMode(
        environment: ProcessInfo.processInfo.environment)
    let listener = try GohXPCListener(
        machServiceName: GohXPCService.machServiceName,
        mode: validationMode,
        handler: { service.handle($0) })

    // Flush the catalog on a graceful stop — launchd sends SIGTERM. Handled on a
    // dispatch source, not a raw async-signal handler, so the flush runs in a
    // normal context.
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termination.setEventHandler {
        writer.flush()
        exit(0)
    }
    termination.resume()

    // The listener and the signal source are active; serve forever.
    withExtendedLifetime((listener, termination)) {
        dispatchMain()
    }
} catch {
    warn("could not start: \(error)")
    exit(1)
}
