import Darwin
import Dispatch
import Foundation

import GohCore

// gohd — the download daemon. Runs under launchd as a LaunchAgent; owns the job
// model, persists it across restarts, and serves commands from `goh` over XPC.
//
// This slice has no download engine: a created job rests in `queued`. The
// HTTP-transport slice replaces that with real downloading.

/// The daemon's catalog file —
/// `~/Library/Application Support/dev.goh.daemon/catalog.plist`. The containing
/// directory is created if absent.
func catalogFileURL() throws -> URL {
    let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
    let directory = support.appending(
        path: GohXPCService.machServiceName, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "catalog.plist")
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("gohd: \(message)\n".utf8))
}

do {
    let catalogStore = CatalogStore(fileURL: try catalogFileURL())
    let loaded = catalogStore.load()
    if let sidecar = loaded.corruptionSidecar {
        warn("the job catalog was unreadable and has been reset; "
            + "the damaged file was kept at \(sidecar.path)")
    }
    let writer = CatalogWriter(store: catalogStore)
    let store = JobStore(catalog: loaded.catalog, writer: writer)
    let service = CommandService(dispatcher: CommandDispatcher(store: store))

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
