import Foundation
import XPC

import GohCore
import GohMenuBar

@MainActor
final class LiveGohMenuClient: GohMenuClient {
    private let validationMode: PeerValidationMode

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        validationMode = GohXPCService.peerValidationMode(environment: environment)
    }

    func progressSnapshots() -> AsyncThrowingStream<[ProgressSnapshot], any Error> {
        AsyncThrowingStream { continuation in
            do {
                let subscription = try makeSubscription()
                let commandClient = GohCommandClient { request in
                    try subscription.sendSync(request)
                }
                let (requestID, reply): (UUID, SubscribeReply)
                do {
                    (requestID, reply) = try commandClient.sendWithRequestID(
                        .subscribe(request: SubscribeRequest(scope: .all)),
                        expecting: SubscribeReply.self)
                } catch {
                    subscription.cancel()
                    throw error
                }

                continuation.yield(reply.snapshot)
                let task = Task.detached { [subscription] in
                    Self.consumeProgressNotifications(
                        requestID: requestID,
                        subscription: subscription,
                        continuation: continuation)
                }

                continuation.onTermination = { _ in
                    task.cancel()
                    subscription.cancel()
                }
            } catch {
                continuation.finish(throwing: Self.map(error))
            }
        }
    }

    func add(_ request: AddRequest) async throws -> JobSummary {
        do {
            return try await Self.sendOneShot(
                .add(request: request),
                expecting: JobSummary.self,
                validationMode: validationMode)
        } catch {
            throw Self.map(error)
        }
    }

    func pause(jobID: UInt64) async throws {
        do {
            let _: JobSummary = try await Self.sendOneShot(
                .pause(jobID: jobID),
                expecting: JobSummary.self,
                validationMode: validationMode)
        } catch {
            throw Self.map(error)
        }
    }

    func resume(jobID: UInt64) async throws {
        do {
            let _: JobSummary = try await Self.sendOneShot(
                .resume(jobID: jobID),
                expecting: JobSummary.self,
                validationMode: validationMode)
        } catch {
            throw Self.map(error)
        }
    }

    func remove(jobID: UInt64, keepPartialFile: Bool) async throws {
        do {
            let _: RmReply = try await Self.sendOneShot(
                .rm(request: RmRequest(
                    jobID: jobID,
                    keepPartialFile: keepPartialFile)),
                expecting: RmReply.self,
                validationMode: validationMode)
        } catch {
            throw Self.map(error)
        }
    }

    private func makeSubscription() throws -> LiveProgressSubscription {
        let inbox = GohXPCNotificationInbox()
        let session = try makeSession(inbox: inbox)
        return LiveProgressSubscription(inbox: inbox, session: session)
    }

    private func makeSession(inbox: GohXPCNotificationInbox) throws -> GohProgressSubscriptionSession {
        let client = try GohXPCClient(
            machServiceName: GohXPCService.machServiceName,
            mode: validationMode,
            incomingMessageHandler: { message in
                inbox.handle(message)
            },
            cancellationHandler: { error in
                inbox.sessionInvalidated("\(error)")
            })

        return GohProgressSubscriptionSession(
            sendSync: { request in try client.sendSync(request) },
            receiveNotification: { try inbox.receive() },
            cancel: { client.cancel() })
    }

    private nonisolated static func sendOneShot<Reply: Codable & Sendable>(
        _ command: Command,
        expecting _: Reply.Type,
        validationMode: PeerValidationMode
    ) async throws -> Reply {
        try await Task.detached {
            let client = try GohXPCClient(
                machServiceName: GohXPCService.machServiceName,
                mode: validationMode)
            defer { client.cancel() }

            return try GohCommandClient { request in
                try client.sendSync(request)
            }
            .send(command, expecting: Reply.self)
        }.value
    }

    private nonisolated static func consumeProgressNotifications(
        requestID: UUID,
        subscription: LiveProgressSubscription,
        continuation: AsyncThrowingStream<[ProgressSnapshot], any Error>.Continuation
    ) {
        while !Task.isCancelled {
            do {
                let envelope = try subscription.receive()
                guard envelope.messageType == .notification else {
                    throw GohMenuError.malformedReply(
                        "daemon sent a non-notification progress message")
                }
                guard envelope.requestID == requestID else {
                    throw GohMenuError.malformedReply(
                        "daemon sent a progress notification for a different request")
                }
                continuation.yield(envelope.payload.snapshot)
            } catch GohXPCNotificationInboxError.interrupted {
                continuation.finish()
                return
            } catch GohXPCNotificationInboxError.sessionInvalidated(let reason) {
                continuation.finish(throwing: connectionError(reason))
                return
            } catch GohXPCNotificationInboxError.malformedProgressNotification(let message) {
                continuation.finish(throwing: GohMenuError.malformedReply(message))
                return
            } catch {
                continuation.finish(throwing: map(error))
                return
            }
        }
        continuation.finish()
    }

    private nonisolated static func map(_ error: any Error) -> GohMenuError {
        if let error = error as? GohMenuError {
            return error
        }

        if let error = error as? GohCommandClientError {
            switch error {
            case .daemon(let daemonError):
                if daemonError.code == .protocolVersionMismatch {
                    return .protocolMismatch(daemonError.message ?? daemonError.code.rawValue)
                }
                return .daemon(daemonError)
            case .malformedReply(let message):
                return .malformedReply(message)
            }
        }

        if let error = error as? GohXPCNotificationInboxError {
            switch error {
            case .interrupted:
                return .daemonUnavailable("progress subscription ended")
            case .malformedProgressNotification(let message):
                return .malformedReply(message)
            case .sessionInvalidated(let reason):
                return connectionError(reason)
            }
        }

        return connectionError("\(error)")
    }

    private nonisolated static func connectionError(_ text: String) -> GohMenuError {
        let lowercased = text.lowercased()
        if lowercased.contains("peer")
            || lowercased.contains("code sign")
            || lowercased.contains("codesign")
            || lowercased.contains("requirement")
            || lowercased.contains("forbidden")
        {
            return .peerValidation(text)
        }

        return .daemonUnavailable(text)
    }
}

nonisolated private final class LiveProgressSubscription: @unchecked Sendable {
    private let inbox: GohXPCNotificationInbox
    private let session: GohProgressSubscriptionSession

    init(
        inbox: GohXPCNotificationInbox,
        session: GohProgressSubscriptionSession
    ) {
        self.inbox = inbox
        self.session = session
    }

    func sendSync(_ request: XPCDictionary) throws -> XPCDictionary {
        try session.sendSync(request)
    }

    func receive() throws -> GohEnvelope<ProgressEvent> {
        try session.receiveNotification()
    }

    func cancel() {
        inbox.interrupt()
        session.cancel()
    }
}
