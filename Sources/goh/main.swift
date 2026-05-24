import Darwin
import Foundation

import GohCore

// goh — CLI client. Thin. Talks to the daemon (`gohd`) over XPC and exits fast.

func write(_ text: String, to handle: FileHandle) {
    guard !text.isEmpty else { return }
    handle.write(Data(text.utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
let validationMode = GohXPCService.peerValidationMode(
    environment: ProcessInfo.processInfo.environment)

let result = GohCommandLine(
    arguments: arguments,
    foreground: { request in
        let inbox = GohXPCNotificationInbox()
        let client = try GohXPCClient(
            machServiceName: GohXPCService.machServiceName,
            mode: validationMode,
            incomingMessageHandler: { message in
                inbox.handle(message)
            })
        return GohForegroundDownload(
            request: request,
            session: GohForegroundDownloadSession(
                sendSync: { message in try client.sendSync(message) },
                receiveNotification: { try inbox.receive() },
                cancel: { client.cancel() })
        ).run()
    }
) { request in
    let client = try GohXPCClient(
        machServiceName: GohXPCService.machServiceName,
        mode: validationMode)
    defer { client.cancel() }
    return try client.sendSync(request)
}.run()

write(result.standardOutput, to: .standardOutput)
write(result.standardError, to: .standardError)
exit(result.exitCode)
