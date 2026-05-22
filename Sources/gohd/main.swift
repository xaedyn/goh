import Dispatch
import Foundation

import GohCore

// gohd — the download daemon. Runs under launchd as a LaunchAgent; owns the job
// model and serves commands from `goh` over XPC.
//
// This slice has no download engine: a created job rests in `queued`. The
// HTTP-transport slice replaces that with real downloading.

let store = JobStore()
let service = CommandService(dispatcher: CommandDispatcher(store: store))
let validationMode = GohXPCService.peerValidationMode(
    environment: ProcessInfo.processInfo.environment)

do {
    let listener = try GohXPCListener(
        machServiceName: GohXPCService.machServiceName,
        mode: validationMode,
        handler: { service.handle($0) })
    // The listener is active on creation; keep it alive and serve forever.
    withExtendedLifetime(listener) {
        dispatchMain()
    }
} catch {
    FileHandle.standardError.write(
        Data("gohd: could not start the XPC listener: \(error)\n".utf8))
    exit(1)
}
