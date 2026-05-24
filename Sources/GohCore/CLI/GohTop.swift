import Foundation
import XPC

public struct GohTop {
    public var session: GohProgressSubscriptionSession
    public var makeReconnectSession: (() throws -> GohProgressSubscriptionSession)?
    public var reconnectWindow: Duration
    public var reconnectPollInterval: Duration
    public var shouldInterrupt: () -> Bool
    public var render: ([ProgressSnapshot]) -> String
    public var standardOutput: (String) -> Void
    public var standardError: (String) -> Void

    public init(
        session: GohProgressSubscriptionSession,
        reconnect: (() throws -> GohProgressSubscriptionSession)? = nil,
        reconnectWindow: Duration = .milliseconds(2_500),
        reconnectPollInterval: Duration = .milliseconds(100),
        shouldInterrupt: @escaping () -> Bool = { false },
        render: @escaping ([ProgressSnapshot]) -> String,
        standardOutput: @escaping (String) -> Void = { _ in },
        standardError: @escaping (String) -> Void = { _ in }
    ) {
        self.session = session
        self.makeReconnectSession = reconnect
        self.reconnectWindow = reconnectWindow
        self.reconnectPollInterval = reconnectPollInterval
        self.shouldInterrupt = shouldInterrupt
        self.render = render
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public func run() -> GohCommandLineResult {
        do {
            var activeSession = session
            defer { activeSession.cancel() }

            var subscribeRequestID: UUID
            let baseline: SubscribeReply
            (subscribeRequestID, baseline) = try sendCommand(
                .subscribe(request: SubscribeRequest(scope: .all)),
                expecting: SubscribeReply.self,
                using: activeSession)

            repaint(baseline.snapshot)
            if shouldInterrupt() {
                return GohCommandLineResult(exitCode: 0)
            }

            while true {
                do {
                    let notification = try activeSession.receiveNotification()
                    let event = try decodeNotification(
                        notification,
                        requestID: subscribeRequestID)
                    repaint(event.snapshot)
                    if shouldInterrupt() {
                        return GohCommandLineResult(exitCode: 0)
                    }
                } catch GohXPCNotificationInboxError.interrupted {
                    return GohCommandLineResult(exitCode: 0)
                } catch GohXPCNotificationInboxError.sessionInvalidated {
                    standardError(Self.reconnectingMessage())
                    switch try attemptReconnect() {
                    case .interrupted:
                        return GohCommandLineResult(exitCode: 0)

                    case .gaveUp:
                        standardError(Self.reconnectFailedMessage())
                        return GohCommandLineResult(exitCode: 1)

                    case .reconnected(let session, let requestID, let baseline):
                        activeSession = session
                        subscribeRequestID = requestID
                        repaint(baseline.snapshot)
                        if shouldInterrupt() {
                            return GohCommandLineResult(exitCode: 0)
                        }
                    }
                } catch GohXPCNotificationInboxError.malformedProgressNotification(let message) {
                    throw TopError("daemon sent a malformed progress notification: \(message)")
                }
            }
        } catch let error as GohError {
            standardError(Self.daemonErrorMessage(error))
            return GohCommandLineResult(exitCode: 1)
        } catch let error as TopError {
            standardError("gohd returned an invalid reply: \(error.message)\n")
            return GohCommandLineResult(exitCode: 1)
        } catch {
            standardError(
                "Could not reach gohd.\nStart the daemon with: brew services start goh\n\n\(error)\n")
            return GohCommandLineResult(exitCode: 1)
        }
    }

    private func repaint(_ snapshots: [ProgressSnapshot]) {
        standardOutput(Self.clearScreenPrefix + render(snapshots))
    }

    private func sendCommand<Reply: Codable & Sendable>(
        _ command: Command,
        expecting _: Reply.Type,
        using session: GohProgressSubscriptionSession
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
                    throw TopError("daemon reply requestID did not match the request")
                }
                return (requestID, reply.payload)
            }

            if let error = try? GohEnvelope<GohError>(xpcDictionary: object),
               error.messageType == .error
            {
                guard error.requestID == requestID else {
                    throw TopError("daemon error requestID did not match the request")
                }
                throw error.payload
            }

            throw TopError("daemon returned an unrecognized reply")
        }
    }

    private enum ReconnectResult {
        case reconnected(
            session: GohProgressSubscriptionSession,
            requestID: UUID,
            baseline: SubscribeReply
        )
        case gaveUp
        case interrupted
    }

    private func attemptReconnect() throws -> ReconnectResult {
        if shouldInterrupt() {
            return .interrupted
        }
        guard let makeReconnectSession else {
            return .gaveUp
        }

        var reconnected: (
            session: GohProgressSubscriptionSession,
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
                let candidate = try makeReconnectSession()
                do {
                    let (requestID, baseline): (UUID, SubscribeReply) = try sendCommand(
                        .subscribe(request: SubscribeRequest(scope: .all)),
                        expecting: SubscribeReply.self,
                        using: candidate)
                    reconnected = (candidate, requestID, baseline)
                    return true
                } catch let error as GohError {
                    reconnectedDaemonError = error
                    candidate.cancel()
                    return true
                } catch let error as TopError {
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

    private func decodeNotification(
        _ notification: GohEnvelope<ProgressEvent>,
        requestID: UUID
    ) throws -> ProgressEvent {
        guard notification.messageType == .notification else {
            throw TopError("daemon sent a non-notification progress message")
        }
        guard notification.requestID == requestID else {
            throw TopError(
                "daemon notification requestID did not match the subscription")
        }
        return notification.payload
    }

    private struct TopError: Error, Equatable {
        var message: String

        init(_ message: String) {
            self.message = message
        }
    }
}

private extension GohTop {
    static let clearScreenPrefix = "\u{1B}[2J\u{1B}[H"

    static func reconnectingMessage() -> String {
        "gohd connection lost; reconnecting...\n"
    }

    static func reconnectFailedMessage() -> String {
        "Could not reconnect to gohd.\nStart the daemon with: brew services start goh\n"
    }

    static func daemonErrorMessage(_ error: GohError) -> String {
        if let message = error.message, !message.isEmpty {
            return "gohd: \(message)\n"
        }
        return "gohd: \(error.code.rawValue)\n"
    }
}
