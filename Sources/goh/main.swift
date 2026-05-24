import Darwin
import Dispatch
import Foundation

import GohCore
import GohTUI

// goh — CLI client. Thin. Talks to the daemon (`gohd`) over XPC and exits fast.

func write(_ text: String, to handle: FileHandle) {
    guard !text.isEmpty else { return }
    handle.write(Data(text.utf8))
}

func makeInterruptSource(_ handler: @escaping @Sendable () -> Void) -> DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(
        signal: SIGINT,
        queue: DispatchQueue.global(qos: .userInitiated))
    source.setEventHandler(handler: handler)
    source.resume()
    return source
}

func makeForegroundSession(
    inbox: GohXPCNotificationInbox,
    validationMode: PeerValidationMode
) throws -> GohForegroundDownloadSession {
    let client = try GohXPCClient(
        machServiceName: GohXPCService.machServiceName,
        mode: validationMode,
        incomingMessageHandler: { message in
            inbox.handle(message)
        },
        cancellationHandler: { error in
            inbox.sessionInvalidated("\(error)")
        })
    return GohForegroundDownloadSession(
        sendSync: { message in try client.sendSync(message) },
        receiveNotification: { try inbox.receive() },
        cancel: { client.cancel() })
}

let arguments = Array(CommandLine.arguments.dropFirst())
let validationMode = GohXPCService.peerValidationMode(
    environment: ProcessInfo.processInfo.environment)

let result = GohCommandLine(
    arguments: arguments,
    foreground: { request in
        let inbox = GohXPCNotificationInbox()
        let interruptSource = makeInterruptSource {
            inbox.interrupt()
        }
        defer { interruptSource.cancel() }

        return GohForegroundDownload(
            request: request,
            session: try makeForegroundSession(
                inbox: inbox,
                validationMode: validationMode),
            reconnect: {
                try makeForegroundSession(
                    inbox: inbox,
                    validationMode: validationMode)
            },
            shouldInterrupt: {
                inbox.isInterrupted
            },
            standardOutput: { text in
                write(text, to: .standardOutput)
            },
            standardError: { text in
                write(text, to: .standardError)
            }
        ).run()
    },
    top: {
        let inbox = GohXPCNotificationInbox()
        let interruptSource = makeInterruptSource {
            inbox.interrupt()
        }
        defer { interruptSource.cancel() }

        return GohTop(
            session: try makeForegroundSession(
                inbox: inbox,
                validationMode: validationMode),
            reconnect: {
                try makeForegroundSession(
                    inbox: inbox,
                    validationMode: validationMode)
            },
            shouldInterrupt: {
                inbox.isInterrupted
            },
            render: { snapshots in
                GohTUI.renderTopDashboard(snapshots: snapshots) + "\n"
            },
            standardOutput: { text in
                write(text, to: .standardOutput)
            },
            standardError: { text in
                write(text, to: .standardError)
            }
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
