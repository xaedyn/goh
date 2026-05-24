import Dispatch
import Foundation
import Synchronization
import XPC

public struct GohForegroundDownloadSession {
    public var sendSync: (XPCDictionary) throws -> XPCDictionary
    public var receiveNotification: () throws -> GohEnvelope<ProgressEvent>
    public var cancel: () -> Void

    public init(
        sendSync: @escaping (XPCDictionary) throws -> XPCDictionary,
        receiveNotification: @escaping () throws -> GohEnvelope<ProgressEvent>,
        cancel: @escaping () -> Void
    ) {
        self.sendSync = sendSync
        self.receiveNotification = receiveNotification
        self.cancel = cancel
    }
}

public enum GohXPCNotificationInboxError: Error, Sendable, Equatable {
    case malformedProgressNotification(String)
    case sessionInvalidated(String)
    case interrupted
}

public final class GohXPCNotificationInbox: @unchecked Sendable {
    private typealias Message = Result<
        GohEnvelope<ProgressEvent>, GohXPCNotificationInboxError
    >

    private let messages = Mutex<[Message]>([])
    private let semaphore = DispatchSemaphore(value: 0)

    public init() {}

    private func enqueue(_ message: Message) {
        messages.withLock { $0.append(message) }
        semaphore.signal()
    }

    public func handle(_ message: XPCDictionary) -> XPCDictionary? {
        let decoded: Message
        do {
            let envelope = try message.withUnsafeUnderlyingDictionary { object in
                try GohEnvelope<ProgressEvent>(xpcDictionary: object)
            }
            decoded = .success(envelope)
        } catch {
            decoded = .failure(.malformedProgressNotification("\(error)"))
        }
        enqueue(decoded)
        return nil
    }

    public func sessionInvalidated(_ reason: String) {
        enqueue(.failure(.sessionInvalidated(reason)))
    }

    public func interrupt() {
        enqueue(.failure(.interrupted))
    }

    public func receive() throws -> GohEnvelope<ProgressEvent> {
        semaphore.wait()
        return try messages.withLock { $0.removeFirst() }.get()
    }
}

public struct GohForegroundDownload {
    public var request: AddRequest
    public var session: GohForegroundDownloadSession
    public var reconnect: (() throws -> GohForegroundDownloadSession)?
    public var reconnectWindow: Duration
    public var reconnectPollInterval: Duration
    public var standardOutput: (String) -> Void
    public var standardError: (String) -> Void

    public init(
        request: AddRequest,
        session: GohForegroundDownloadSession,
        reconnect: (() throws -> GohForegroundDownloadSession)? = nil,
        reconnectWindow: Duration = .milliseconds(2_500),
        reconnectPollInterval: Duration = .milliseconds(100),
        standardOutput: @escaping (String) -> Void = { _ in },
        standardError: @escaping (String) -> Void = { _ in }
    ) {
        self.request = request
        self.session = session
        self.reconnect = reconnect
        self.reconnectWindow = reconnectWindow
        self.reconnectPollInterval = reconnectPollInterval
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public func run() -> GohCommandLineResult {
        do {
            var activeSession = session
            defer { activeSession.cancel() }

            let (_, job): (UUID, JobSummary) = try sendCommand(
                .add(request: request),
                expecting: JobSummary.self,
                using: activeSession)
            var subscribeRequestID: UUID
            let baseline: SubscribeReply
            (subscribeRequestID, baseline) = try sendCommand(
                .subscribe(request: SubscribeRequest(scope: .job, jobID: job.id)),
                expecting: SubscribeReply.self,
                using: activeSession)

            standardOutput(Self.addedMessage(job))
            standardOutput(baseline.snapshot.map(Self.progressLine).joined())
            if let terminal = terminalResult(in: baseline.snapshot, jobID: job.id) {
                return GohCommandLineResult(exitCode: terminal)
            }

            while true {
                do {
                    let notification = try activeSession.receiveNotification()
                    let event = try decodeNotification(
                        notification,
                        requestID: subscribeRequestID)
                    standardOutput(event.snapshot.map(Self.progressLine).joined())
                    if let terminal = terminalResult(in: event.snapshot, jobID: job.id) {
                        return GohCommandLineResult(exitCode: terminal)
                    }
                } catch GohXPCNotificationInboxError.interrupted {
                    standardError(Self.detachMessage(jobID: job.id))
                    return GohCommandLineResult(exitCode: 0)
                } catch GohXPCNotificationInboxError.sessionInvalidated {
                    standardError(Self.reconnectingMessage())
                    guard let reconnected = try reconnect(to: job.id) else {
                        standardError(Self.backgroundContinuationMessage(jobID: job.id))
                        return GohCommandLineResult(exitCode: 0)
                    }

                    activeSession = reconnected.session
                    subscribeRequestID = reconnected.requestID
                    standardOutput(reconnected.baseline.snapshot.map(Self.progressLine).joined())
                    if let terminal = terminalResult(
                        in: reconnected.baseline.snapshot,
                        jobID: job.id)
                    {
                        return GohCommandLineResult(exitCode: terminal)
                    }
                } catch GohXPCNotificationInboxError.malformedProgressNotification(let message) {
                    throw ForegroundError(
                        "daemon sent a malformed progress notification: \(message)")
                }
            }
        } catch let error as GohError {
            standardError(Self.daemonErrorMessage(error))
            return GohCommandLineResult(exitCode: 1)
        } catch let error as ForegroundError {
            standardError("gohd returned an invalid reply: \(error.message)\n")
            return GohCommandLineResult(exitCode: 1)
        } catch {
            standardError(
                "Could not reach gohd.\nStart the daemon with: brew services start goh\n\n\(error)\n")
            return GohCommandLineResult(
                exitCode: 1)
        }
    }

    private func sendCommand<Reply: Codable & Sendable>(
        _ command: Command,
        expecting _: Reply.Type,
        using session: GohForegroundDownloadSession
    ) throws -> (UUID, Reply) {
        let requestID = UUID()
        let request = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .request,
            payload: command)
            .xpcDictionary()
        let response = try session.sendSync(XPCDictionary(request))

        return try response.withUnsafeUnderlyingDictionary { object in
            if let reply = try? GohEnvelope<Reply>(xpcDictionary: object),
               reply.messageType == .reply
            {
                guard reply.requestID == requestID else {
                    throw ForegroundError(
                        "daemon reply requestID did not match the request")
                }
                return (requestID, reply.payload)
            }

            if let error = try? GohEnvelope<GohError>(xpcDictionary: object),
               error.messageType == .error
            {
                guard error.requestID == requestID else {
                    throw ForegroundError(
                        "daemon error requestID did not match the request")
                }
                throw error.payload
            }

            throw ForegroundError("daemon returned an unrecognized reply")
        }
    }

    private func reconnect(
        to jobID: UInt64
    ) throws -> (session: GohForegroundDownloadSession, requestID: UUID, baseline: SubscribeReply)? {
        guard let reconnect else {
            return nil
        }

        var reconnected: (
            session: GohForegroundDownloadSession,
            requestID: UUID,
            baseline: SubscribeReply
        )?
        var reconnectedDaemonError: Error?
        let outcome = XPCReconnect.attempt(
            within: reconnectWindow,
            pollInterval: reconnectPollInterval
        ) {
            do {
                let candidate = try reconnect()
                do {
                    let (requestID, baseline): (UUID, SubscribeReply) = try sendCommand(
                        .subscribe(request: SubscribeRequest(scope: .job, jobID: jobID)),
                        expecting: SubscribeReply.self,
                        using: candidate)
                    reconnected = (candidate, requestID, baseline)
                    return true
                } catch let error as GohError {
                    reconnectedDaemonError = error
                    candidate.cancel()
                    return true
                } catch let error as ForegroundError {
                    reconnectedDaemonError = error
                    candidate.cancel()
                    return true
                } catch {
                    candidate.cancel()
                    return false
                }
            } catch {
                return false
            }
        }

        switch outcome {
        case .reconnected:
            if let reconnectedDaemonError {
                throw reconnectedDaemonError
            }
            return reconnected
        case .gaveUp:
            return nil
        }
    }

    private func decodeNotification(
        _ notification: GohEnvelope<ProgressEvent>,
        requestID: UUID
    ) throws -> ProgressEvent {
        guard notification.messageType == .notification else {
            throw ForegroundError("daemon sent a non-notification progress message")
        }
        guard notification.requestID == requestID else {
            throw ForegroundError(
                "daemon notification requestID did not match the subscription")
        }
        return notification.payload
    }

    private func terminalResult(in snapshots: [ProgressSnapshot], jobID: UInt64) -> Int32? {
        guard let snapshot = snapshots.first(where: { $0.job.id == jobID }) else { return 1 }
        switch snapshot.job.state {
        case .completed:
            return 0
        case .failed:
            return 1
        case .queued, .active, .paused:
            return nil
        }
    }

    private struct ForegroundError: Error, Equatable {
        var message: String

        init(_ message: String) {
            self.message = message
        }
    }
}

private extension GohForegroundDownload {
    static func addedMessage(_ summary: JobSummary) -> String {
        "Added job \(summary.id) (\(summary.state.rawValue)): \(summary.url) -> \(summary.destination)\n"
    }

    static func detachMessage(jobID: UInt64) -> String {
        "^C - download continues in background as job \(jobID). 'goh ls' to check, 'goh rm \(jobID)' to cancel.\n"
    }

    static func reconnectingMessage() -> String {
        "gohd connection lost; reconnecting...\n"
    }

    static func backgroundContinuationMessage(jobID: UInt64) -> String {
        "download continues in background as job \(jobID). 'goh ls' to check.\n"
    }

    static func progressLine(_ snapshot: ProgressSnapshot) -> String {
        let job = snapshot.job
        return "Job \(job.id) \(job.state.rawValue): \(progressText(job.progress)) at \(formatBytes(job.progress.bytesPerSecond))/s\n"
    }

    static func progressText(_ progress: JobProgress) -> String {
        guard let total = progress.bytesTotal else {
            return "\(formatBytes(progress.bytesCompleted))/?"
        }
        let percent = total == 0
            ? 100
            : Int((Double(progress.bytesCompleted) / Double(total) * 100).rounded())
        return "\(formatBytes(progress.bytesCompleted))/\(formatBytes(total)) (\(percent)%)"
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        guard bytes >= 1024 else {
            return "\(bytes) B"
        }

        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            return "\(Int(rounded)) \(units[unitIndex])"
        }
        return String(
            format: "%.1f %@",
            locale: Locale(identifier: "en_US_POSIX"),
            value,
            units[unitIndex])
    }

    static func daemonErrorMessage(_ error: GohError) -> String {
        if let message = error.message, !message.isEmpty {
            return "gohd: \(message)\n"
        }
        return "gohd: \(error.code.rawValue)\n"
    }
}
