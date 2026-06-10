import Darwin
import Dispatch
import Foundation
import XPC

import GohCore
import GohTUI

// goh — CLI client. Thin. Talks to the daemon (`gohd`) over XPC and exits fast.

enum DoctorQueueReadError: Error, CustomStringConvertible {
    case requestIDMismatch
    case daemon(GohError)
    case malformedReply

    var description: String {
        switch self {
        case .requestIDMismatch:
            return "daemon reply requestID did not match the request"
        case .daemon(let error):
            if let message = error.message, !message.isEmpty {
                return message
            }
            return error.code.rawValue
        case .malformedReply:
            return "daemon returned an unrecognized reply"
        }
    }
}

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

func sendOneShot(_ request: XPCDictionary, validationMode: PeerValidationMode) throws -> XPCDictionary {
    let client = try GohXPCClient(
        machServiceName: GohXPCService.machServiceName,
        mode: validationMode)
    defer { client.cancel() }
    return try client.sendSync(request)
}

func readQueueForDoctor(validationMode: PeerValidationMode) throws -> LsReply {
    let requestID = UUID()
    let request = try GohEnvelope(
        protocolVersion: CommandService.protocolVersion,
        requestID: requestID,
        messageType: .request,
        payload: Command.ls)
        .xpcDictionary()
    let response = try sendOneShot(XPCDictionary(request), validationMode: validationMode)

    switch response.decodeGohReply(as: LsReply.self) {
    case .reply(let id, let payload):
        guard id == requestID else {
            throw DoctorQueueReadError.requestIDMismatch
        }
        return payload
    case .daemonError(let id, let error):
        guard id == requestID else {
            throw DoctorQueueReadError.requestIDMismatch
        }
        throw DoctorQueueReadError.daemon(error)
    case .malformed:
        throw DoctorQueueReadError.malformedReply
    }
}

func makeDoctorProbes(
    validationMode: PeerValidationMode,
    environment: [String: String]
) -> GohDoctorProbes {
    let fileManager = FileManager.default
    let homeDirectory = fileManager.homeDirectoryForCurrentUser
    let executable = resolvedExecutablePath(
        CommandLine.arguments.first ?? "goh",
        environment: environment)
    let executableURL = URL(filePath: executable)
    let daemonURL = executableURL
        .deletingLastPathComponent()
        .appending(path: "gohd")
    let dogfoodRoot = dogfoodRoot(for: executable)
    let downloadsURL = dogfoodRoot?.appending(path: "downloads")
        ?? homeDirectory.appending(path: "Downloads")
    let logsURL = dogfoodRoot?.appending(path: "logs")
        ?? homebrewPrefix(for: executable)?.appending(path: "var/log")
        ?? URL(filePath: "/opt/homebrew/var/log", directoryHint: .isDirectory)
    let logURL = dogfoodRoot?.appending(path: "logs/goh.log")
        ?? logsURL.appending(path: "goh.log")
    let launchAgentURL = homeDirectory
        .appending(path: "Library")
        .appending(path: "LaunchAgents")
        .appending(path: "\(GohXPCService.machServiceName).plist")

    return GohDoctorProbes(
        executablePath: executable,
        daemonExecutablePath: daemonURL.path,
        launchAgentPath: launchAgentURL.path,
        downloadsDirectoryPath: downloadsURL.path,
        logsDirectoryPath: logsURL.path,
        logPath: logURL.path,
        environment: environment,
        userID: { Int(getuid()) },
        fileExists: { fileManager.fileExists(atPath: $0) },
        isExecutableFile: { fileManager.isExecutableFile(atPath: $0) },
        isWritableDirectory: { path in
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return false
            }
            return fileManager.isWritableFile(atPath: path)
        },
        fileContents: { path in
            try? String(contentsOfFile: path, encoding: .utf8)
        },
        launchctlPrint: { target in
            launchctlPrint(target)
        },
        readQueue: {
            try readQueueForDoctor(validationMode: validationMode)
        })
}

func resolvedExecutablePath(
    _ rawPath: String,
    environment: [String: String]
) -> String {
    let rawURL: URL
    if rawPath.contains("/") {
        rawURL = URL(filePath: rawPath)
    } else if let resolved = executableNamed(rawPath, path: environment["PATH"]) {
        rawURL = resolved
    } else {
        rawURL = URL(filePath: rawPath)
    }
    return rawURL.standardizedFileURL.resolvingSymlinksInPath().path
}

func executableNamed(_ name: String, path: String?) -> URL? {
    let fileManager = FileManager.default
    for directory in path?.split(separator: ":") ?? [] {
        let candidate = URL(filePath: String(directory)).appending(path: name)
        if fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

func dogfoodRoot(for executablePath: String) -> URL? {
    guard let range = executablePath.range(of: "/.build/dogfood") else {
        return nil
    }
    return URL(filePath: String(executablePath[..<range.upperBound]), directoryHint: .isDirectory)
}

func homebrewPrefix(for executablePath: String) -> URL? {
    guard let cellarRange = executablePath.range(of: "/Cellar/") else {
        return nil
    }
    return URL(filePath: String(executablePath[..<cellarRange.lowerBound]), directoryHint: .isDirectory)
}

func launchctlPrint(_ target: String) -> Bool {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/launchctl")
    process.arguments = ["print", target]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment
let validationMode = GohXPCService.peerValidationMode(environment: environment)

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
        let exitMonitor = GohTerminalExitMonitor {
            inbox.interrupt()
        }
        defer { interruptSource.cancel() }
        defer { exitMonitor.cancel() }
        exitMonitor.start()

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
    },
    doctor: {
        GohDoctor(probes: makeDoctorProbes(
            validationMode: validationMode,
            environment: environment))
            .run()
    },
    diagnose: { url, full, json, connections in
        var args = [url]
        if full { args.append("--full") }
        if json { args.append("--json") }
        if let c = connections { args += ["--connections", "\(c)"] }
        return GohDiagnoseCommand.run(arguments: args)
    },
    daemon: { force in
        // Step 1: Read current queue to get active count and featureLevel.
        let requestID = UUID()
        let lsRequest = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .request,
            payload: Command.ls)
            .xpcDictionary()
        let lsResponse = try sendOneShot(
            XPCDictionary(lsRequest), validationMode: validationMode)
        let lsReply: LsReply
        switch lsResponse.decodeGohReply(as: LsReply.self) {
        case .reply(_, let payload): lsReply = payload
        case .daemonError(_, let err):
            return GohCommandLineResult(exitCode: 1,
                standardError: "goh: daemon error reading queue: \(err)\n")
        case .malformed:
            return GohCommandLineResult(exitCode: 1,
                standardError: "goh: malformed daemon reply\n")
        }
        let activeCount = lsReply.jobs.filter { $0.state == .active }.count

        // Step 2: Idle-gate (unless --force).
        if !force && activeCount > 0 {
            return GohCommandLineResult(
                exitCode: 64,
                standardError: "goh: \(activeCount) active download(s) running."
                    + " Use --force to restart anyway.\n")
        }
        if force && activeCount > 0 {
            fputs("goh: Restarting background service (force) —"
                + " active downloads may be interrupted.\n", stderr)
        }

        // Step 3: Kickstart. (No uid: — LaunchctlDaemonRestarter defaults it internally in its
        // own Darwin-importing file, so getuid() is never called here. See B-1 fix.)
        let restarter = LaunchctlDaemonRestarter(
            machServiceName: GohXPCService.machServiceName)
        do {
            try restarter.kickstart()
        } catch {
            return GohCommandLineResult(
                exitCode: 1,
                standardError: "goh: could not restart background service: \(error)\n")
        }

        // Step 4: Poll up to 5s / 250ms for the new daemon.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            if let polled = try? GohCommandClient(
                    send: { req in try sendOneShot(req, validationMode: validationMode) })
                .send(.ls, expecting: LsReply.self),
               let level = polled.featureLevel,
               level >= GohFeatureLevel.current {
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: "Background service restarted.\n")
            }
        }
        return GohCommandLineResult(
            exitCode: 0,
            standardOutput: "Background service restart initiated"
                + " (did not confirm new version within 5s — run: goh doctor).\n")
    }
) { request in
    try sendOneShot(request, validationMode: validationMode)
}.run()

write(result.standardOutput, to: .standardOutput)
write(result.standardError, to: .standardError)
exit(result.exitCode)
