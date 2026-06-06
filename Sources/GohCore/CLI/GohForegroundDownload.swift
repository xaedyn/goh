import Dispatch
import Foundation
import Synchronization
import XPC

public struct GohProgressSubscriptionSession {
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

public typealias GohForegroundDownloadSession = GohProgressSubscriptionSession

public enum GohXPCNotificationInboxError: Error, Sendable, Equatable {
    case malformedProgressNotification(String)
    case sessionInvalidated(String)
    case interrupted
}

/// A synchronous bridge between asynchronous XPC notification delivery and a
/// blocking `receive()` consumer used by `goh top` and the foreground download.
///
/// `@unchecked Sendable` invariant: every mutable field is protected by a
/// dedicated synchronization primitive — `Mutex` for `messages` and the
/// `interrupted` flag, `DispatchSemaphore` for the wake signal. The class
/// never exposes mutable state without holding the lock; `handle`,
/// `sessionInvalidated`, and `interrupt` may be called from arbitrary
/// XPC-delivery threads while `receive` blocks on the consumer thread.
public final class GohXPCNotificationInbox: @unchecked Sendable {
    private typealias Message = Result<
        GohEnvelope<ProgressEvent>, GohXPCNotificationInboxError
    >

    private let messages = Mutex<[Message]>([])
    private let interrupted = Mutex(false)
    private let semaphore = DispatchSemaphore(value: 0)

    public init() {}

    public var isInterrupted: Bool {
        interrupted.withLock { $0 }
    }

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
        interrupted.withLock { $0 = true }
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
    public var shouldInterrupt: () -> Bool
    public var standardOutput: (String) -> Void
    public var standardError: (String) -> Void

    public init(
        request: AddRequest,
        session: GohForegroundDownloadSession,
        reconnect: (() throws -> GohForegroundDownloadSession)? = nil,
        reconnectWindow: Duration = .milliseconds(2_500),
        reconnectPollInterval: Duration = .milliseconds(100),
        shouldInterrupt: @escaping () -> Bool = { false },
        standardOutput: @escaping (String) -> Void = { _ in },
        standardError: @escaping (String) -> Void = { _ in }
    ) {
        self.request = request
        self.session = session
        self.reconnect = reconnect
        self.reconnectWindow = reconnectWindow
        self.reconnectPollInterval = reconnectPollInterval
        self.shouldInterrupt = shouldInterrupt
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
            if shouldInterrupt() {
                standardError(Self.detachMessage(jobID: job.id))
                return GohCommandLineResult(exitCode: 0)
            }
            if let terminal = terminalResult(in: baseline.snapshot, jobID: job.id) {
                return GohCommandLineResult(exitCode: terminal)
            }

            while true {
                do {
                    let notification = try activeSession.receiveNotification()
                    guard let event = try decodeNotification(
                        notification,
                        requestID: subscribeRequestID)
                    else {
                        // Stale notification from a prior subscription (e.g. an
                        // in-flight message arriving just after a reconnect):
                        // skip it and keep listening (audit M3).
                        continue
                    }
                    standardOutput(event.snapshot.map(Self.progressLine).joined())
                    if let terminal = terminalResult(in: event.snapshot, jobID: job.id) {
                        return GohCommandLineResult(exitCode: terminal)
                    }
                } catch GohXPCNotificationInboxError.interrupted {
                    standardError(Self.detachMessage(jobID: job.id))
                    return GohCommandLineResult(exitCode: 0)
                } catch GohXPCNotificationInboxError.sessionInvalidated {
                    standardError(Self.reconnectingMessage())
                    switch try reconnect(to: job.id) {
                    case .interrupted:
                        standardError(Self.detachMessage(jobID: job.id))
                        return GohCommandLineResult(exitCode: 0)

                    case .gaveUp:
                        standardError(Self.backgroundContinuationMessage(jobID: job.id))
                        return GohCommandLineResult(exitCode: 0)

                    case .reconnected(let session, let requestID, let baseline):
                        activeSession = session
                        subscribeRequestID = requestID
                        standardOutput(baseline.snapshot.map(Self.progressLine).joined())
                        if shouldInterrupt() {
                            standardError(Self.detachMessage(jobID: job.id))
                            return GohCommandLineResult(exitCode: 0)
                        }
                        if let terminal = terminalResult(
                            in: baseline.snapshot,
                            jobID: job.id)
                        {
                            return GohCommandLineResult(exitCode: terminal)
                        }
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

        switch response.decodeGohReply(as: Reply.self) {
        case .reply(let id, let payload):
            guard id == requestID else {
                throw ForegroundError(
                    "daemon reply requestID did not match the request")
            }
            return (requestID, payload)
        case .daemonError(let id, let error):
            guard id == requestID else {
                throw ForegroundError(
                    "daemon error requestID did not match the request")
            }
            throw error
        case .malformed:
            throw ForegroundError("daemon returned an unrecognized reply")
        }
    }

    private enum ReconnectResult {
        case reconnected(
            session: GohForegroundDownloadSession,
            requestID: UUID,
            baseline: SubscribeReply
        )
        case gaveUp
        case interrupted
    }

    private func reconnect(to jobID: UInt64) throws -> ReconnectResult {
        if shouldInterrupt() {
            return .interrupted
        }
        guard let reconnect else {
            return .gaveUp
        }

        var reconnected: (
            session: GohForegroundDownloadSession,
            requestID: UUID,
            baseline: SubscribeReply
        )?
        var reconnectedDaemonError: Error?
        var interrupted = false
        let outcome = XPCReconnect.attempt(
            within: reconnectWindow,
            pollInterval: reconnectPollInterval
        ) {
            if shouldInterrupt() {
                interrupted = true
                return true
            }
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
                    if shouldInterrupt() {
                        interrupted = true
                        return true
                    }
                    return false
                }
            } catch {
                if shouldInterrupt() {
                    interrupted = true
                    return true
                }
                return false
            }
        }

        switch outcome {
        case .reconnected:
            if interrupted {
                return .interrupted
            }
            if let reconnectedDaemonError {
                throw reconnectedDaemonError
            }
            guard let reconnected else {
                return .gaveUp
            }
            return .reconnected(
                session: reconnected.session,
                requestID: reconnected.requestID,
                baseline: reconnected.baseline)
        case .gaveUp:
            return .gaveUp
        }
    }

    /// Decodes a progress notification for the current subscription. Returns
    /// `nil` for a *stale* notification — one carrying a previous subscription's
    /// requestID, as can arrive in-flight just after a reconnect — so the caller
    /// skips it rather than failing the whole foreground session (audit M3). A
    /// non-notification message on this channel is still treated as malformed.
    private func decodeNotification(
        _ notification: GohEnvelope<ProgressEvent>,
        requestID: UUID
    ) throws -> ProgressEvent? {
        guard notification.messageType == .notification else {
            throw ForegroundError("daemon sent a non-notification progress message")
        }
        guard notification.requestID == requestID else {
            return nil
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
        return "Job \(job.id) \(job.state.rawValue): \(JobDisplayFormatter.progressText(job.progress)) at \(JobDisplayFormatter.formatBytes(job.progress.bytesPerSecond))/s\n"
    }

    static func daemonErrorMessage(_ error: GohError) -> String {
        if let message = error.message, !message.isEmpty {
            return "gohd: \(message)\n"
        }
        return "gohd: \(error.code.rawValue)\n"
    }
}
