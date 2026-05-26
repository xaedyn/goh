import Foundation
import Synchronization
import XPC

import GohCore

nonisolated public struct GohMenuProgressSubscription: Sendable {
    public var sendSync: @Sendable (XPCDictionary) throws -> XPCDictionary
    public var receiveNotification: @Sendable () throws -> GohEnvelope<ProgressEvent>
    public var cancel: @Sendable () -> Void

    public init(
        sendSync: @escaping @Sendable (XPCDictionary) throws -> XPCDictionary,
        receiveNotification: @escaping @Sendable () throws -> GohEnvelope<ProgressEvent>,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.sendSync = sendSync
        self.receiveNotification = receiveNotification
        self.cancel = cancel
    }
}

nonisolated public enum GohMenuProgressStream {
    public static func snapshots(
        makeSubscription: @escaping @Sendable () throws -> GohMenuProgressSubscription
    ) -> AsyncThrowingStream<[ProgressSnapshot], any Error> {
        AsyncThrowingStream { continuation in
            let cancellation = GohMenuProgressSubscriptionCancellation()
            let task = Task.detached {
                do {
                    let subscription = try makeSubscription()
                    cancellation.install(subscription)
                    defer { cancellation.cancel() }

                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }

                    let commandClient = GohCommandClient { request in
                        try subscription.sendSync(request)
                    }
                    let (requestID, reply): (UUID, SubscribeReply) = try commandClient
                        .sendWithRequestID(
                            .subscribe(request: SubscribeRequest(scope: .all)),
                            expecting: SubscribeReply.self)

                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }

                    continuation.yield(reply.snapshot)
                    consumeProgressNotifications(
                        requestID: requestID,
                        subscription: subscription,
                        continuation: continuation)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: GohMenuErrorMapper.map(error))
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
                cancellation.cancel()
            }
        }
    }

    private static func consumeProgressNotifications(
        requestID: UUID,
        subscription: GohMenuProgressSubscription,
        continuation: AsyncThrowingStream<[ProgressSnapshot], any Error>.Continuation
    ) {
        while !Task.isCancelled {
            do {
                let envelope = try subscription.receiveNotification()
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
                continuation.finish(throwing: GohMenuErrorMapper.connectionError(reason))
                return
            } catch GohXPCNotificationInboxError.malformedProgressNotification(let message) {
                continuation.finish(throwing: GohMenuError.malformedReply(message))
                return
            } catch {
                continuation.finish(throwing: GohMenuErrorMapper.map(error))
                return
            }
        }
        continuation.finish()
    }
}

nonisolated public enum GohMenuErrorMapper {
    public static func map(_ error: any Error) -> GohMenuError {
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

    static func connectionError(_ text: String) -> GohMenuError {
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

/// @unchecked Sendable invariant: this private coordinator protects mutable
/// subscription state with `Mutex`. Cancellation may intentionally race with
/// off-main setup/receive; the state machine resolves that race by canceling an
/// already-installed subscription or immediately canceling a later install.
nonisolated private final class GohMenuProgressSubscriptionCancellation: @unchecked Sendable {
    private let state = Mutex(State())

    func install(_ subscription: GohMenuProgressSubscription) {
        let shouldCancel = state.withLock { state in
            if state.cancelled {
                return true
            }
            state.subscription = subscription
            return false
        }

        if shouldCancel {
            subscription.cancel()
        }
    }

    func cancel() {
        let subscription = state.withLock { state in
            state.cancelled = true
            let subscription = state.subscription
            state.subscription = nil
            return subscription
        }
        subscription?.cancel()
    }

    private struct State {
        var subscription: GohMenuProgressSubscription?
        var cancelled = false
    }
}
