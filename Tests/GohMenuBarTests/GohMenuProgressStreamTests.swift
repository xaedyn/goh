import Foundation
import Synchronization
import Testing
import XPC

import GohCore
@testable import GohMenuBar

@Suite("GohMenuProgressStream")
struct GohMenuProgressStreamTests {
    @Test func rejectsNonNotificationProgressEnvelope() async throws {
        let fake = FakeProgressSubscription(steps: [
            .envelope(messageType: .reply),
        ])
        var iterator = GohMenuProgressStream
            .snapshots(makeSubscription: { fake.subscription() })
            .makeAsyncIterator()

        let baseline = try await iterator.next()
        #expect(baseline == [])

        do {
            _ = try await iterator.next()
            Issue.record("expected malformed-reply error")
        } catch let error as GohMenuError {
            #expect(error == .malformedReply("daemon sent a non-notification progress message"))
        }
    }

    @Test func rejectsMismatchedProgressRequestID() async throws {
        let fake = FakeProgressSubscription(steps: [
            .mismatchedNotification,
        ])
        var iterator = GohMenuProgressStream
            .snapshots(makeSubscription: { fake.subscription() })
            .makeAsyncIterator()

        let baseline = try await iterator.next()
        #expect(baseline == [])

        do {
            _ = try await iterator.next()
            Issue.record("expected malformed-reply error")
        } catch let error as GohMenuError {
            #expect(error == .malformedReply("daemon sent a progress notification for a different request"))
        }
    }

    @Test func mapsPlainSessionInvalidationToDaemonUnavailable() async throws {
        let fake = FakeProgressSubscription(steps: [
            .sessionInvalidated("connection closed"),
        ])
        var iterator = GohMenuProgressStream
            .snapshots(makeSubscription: { fake.subscription() })
            .makeAsyncIterator()

        let baseline = try await iterator.next()
        #expect(baseline == [])

        do {
            _ = try await iterator.next()
            Issue.record("expected daemon-unavailable error")
        } catch let error as GohMenuError {
            #expect(error == .daemonUnavailable("connection closed"))
        }
    }

    @Test func mapsPeerSessionInvalidationToPeerValidation() async throws {
        let fake = FakeProgressSubscription(steps: [
            .sessionInvalidated("Peer forbidden (code signing)"),
        ])
        var iterator = GohMenuProgressStream
            .snapshots(makeSubscription: { fake.subscription() })
            .makeAsyncIterator()

        let baseline = try await iterator.next()
        #expect(baseline == [])

        do {
            _ = try await iterator.next()
            Issue.record("expected peer-validation error")
        } catch let error as GohMenuError {
            #expect(error == .peerValidation("Peer forbidden (code signing)"))
        }
    }

    @Test func interruptionEndsStreamCleanly() async throws {
        let fake = FakeProgressSubscription(steps: [
            .interrupted,
        ])
        var iterator = GohMenuProgressStream
            .snapshots(makeSubscription: { fake.subscription() })
            .makeAsyncIterator()

        let baseline = try await iterator.next()
        #expect(baseline == [])
        let ended = try await iterator.next()

        #expect(ended == nil)
        #expect(fake.cancelCount == 1)
    }

    /// Regression guard for the cooperative-pool blocking bug (MEMORY.md
    /// "Sync→async bridge pool deadlock"): `snapshots` does its blocking subscribe
    /// round-trip and `receiveNotification()` on a GCD thread, never the Swift
    /// cooperative pool. This is a starvation barrier — every stream's blocking
    /// `sendSync` parks until ALL `streamCount` of them have arrived. The GCD global
    /// queue spins up enough threads for all to arrive and release. If the work ran on
    /// the cooperative pool (bounded to roughly the core count), fewer than
    /// `streamCount` workers could park there at once, the barrier would never reach
    /// its count, and the parked workers — blocked, not suspended — would never yield,
    /// deadlocking until the time limit fails the test.
    ///
    /// `streamCount` is derived from the active core count rather than hard-coded:
    /// the cooperative pool's width scales with cores, so a fixed size could exceed
    /// the pool on a small runner (real starvation) yet fit within it on a high-core
    /// machine (false pass). Pinning it to 4× the core count keeps it comfortably
    /// wider than the pool everywhere while staying well under GCD's thread ceiling.
    @Test(.timeLimit(.minutes(1)))
    func blockingSubscribeRunsOffCooperativePool() async throws {
        let streamCount = max(16, ProcessInfo.processInfo.activeProcessorCount * 4)
        let barrier = StartupBarrier(count: streamCount)

        let baselines = try await withThrowingTaskGroup(of: [ProgressSnapshot].self) { group in
            for _ in 0..<streamCount {
                group.addTask {
                    let fake = BarrieredProgressSubscription(barrier: barrier)
                    var iterator = GohMenuProgressStream
                        .snapshots(makeSubscription: { fake.subscription() })
                        .makeAsyncIterator()
                    return try await iterator.next() ?? [ProgressSnapshot]()
                }
            }
            var collected: [[ProgressSnapshot]] = []
            for try await snapshot in group {
                collected.append(snapshot)
            }
            return collected
        }

        #expect(baselines.count == streamCount)
        #expect(baselines.allSatisfy { $0 == [] })
    }
}

/// A reusable N-way barrier: the first `count - 1` arrivals park; the `count`th
/// releases all of them. Backed by a `DispatchSemaphore` so a waiter blocks its OS
/// thread (the property under test), never a cooperative suspension point.
private final class StartupBarrier: @unchecked Sendable {
    private let arrived = Mutex(0)
    private let gate = DispatchSemaphore(value: 0)
    private let count: Int

    init(count: Int) {
        self.count = count
    }

    func arriveAndWait() {
        let n = arrived.withLock { value in
            value += 1
            return value
        }
        if n == count {
            for _ in 0..<count { gate.signal() }
        }
        gate.wait()
    }
}

/// A subscription whose `sendSync` (the subscribe round-trip) blocks on a shared
/// startup barrier before replying, then ends the stream cleanly on first receive.
private final class BarrieredProgressSubscription: @unchecked Sendable {
    private let state = Mutex(State())
    private let barrier: StartupBarrier

    init(barrier: StartupBarrier) {
        self.barrier = barrier
    }

    func subscription() -> GohMenuProgressSubscription {
        GohMenuProgressSubscription(
            sendSync: { [self] message in
                barrier.arriveAndWait()
                return try message.withUnsafeUnderlyingDictionary { object in
                    let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                    state.withLock { $0.requestID = envelope.requestID }
                    return try XPCDictionary(GohEnvelope(
                        protocolVersion: CommandService.protocolVersion,
                        requestID: envelope.requestID,
                        messageType: .reply,
                        payload: SubscribeReply(revision: 1, snapshot: []))
                        .xpcDictionary())
                }
            },
            receiveNotification: {
                throw GohXPCNotificationInboxError.interrupted
            },
            cancel: {})
    }

    private struct State {
        var requestID: UUID?
    }
}

private final class FakeProgressSubscription: @unchecked Sendable {
    private let state: Mutex<State>

    init(steps: [ReceiveStep]) {
        state = Mutex(State(steps: steps))
    }

    var cancelCount: Int {
        state.withLock { $0.cancelCount }
    }

    func subscription() -> GohMenuProgressSubscription {
        GohMenuProgressSubscription(
            sendSync: { [self] message in
                try message.withUnsafeUnderlyingDictionary { object in
                    let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                    guard case .subscribe = envelope.payload else {
                        throw TestSubscriptionError.unexpectedCommand
                    }
                    state.withLock { $0.requestID = envelope.requestID }
                    return try Self.reply(
                        to: envelope,
                        payload: SubscribeReply(revision: 1, snapshot: []))
                }
            },
            receiveNotification: { [self] in
                let step = try state.withLock { state -> ReceiveStep in
                    guard !state.steps.isEmpty else {
                        throw TestSubscriptionError.missingReceiveStep
                    }
                    return state.steps.removeFirst()
                }
                let requestID = try state.withLock { state -> UUID in
                    guard let requestID = state.requestID else {
                        throw TestSubscriptionError.missingRequestID
                    }
                    return requestID
                }

                switch step {
                case .envelope(let messageType):
                    return Self.envelope(requestID: requestID, messageType: messageType)
                case .mismatchedNotification:
                    return Self.envelope(requestID: UUID(), messageType: .notification)
                case .sessionInvalidated(let reason):
                    throw GohXPCNotificationInboxError.sessionInvalidated(reason)
                case .interrupted:
                    throw GohXPCNotificationInboxError.interrupted
                }
            },
            cancel: { [self] in
                state.withLock { $0.cancelCount += 1 }
            })
    }

    private static func reply<Payload: Codable & Sendable>(
        to envelope: GohEnvelope<Command>,
        payload: Payload
    ) throws -> XPCDictionary {
        try XPCDictionary(GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: envelope.requestID,
            messageType: .reply,
            payload: payload)
            .xpcDictionary())
    }

    private static func envelope(
        requestID: UUID,
        messageType: MessageType
    ) -> GohEnvelope<ProgressEvent> {
        GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: messageType,
            payload: ProgressEvent(
                sequence: 1,
                revision: 2,
                emittedAt: Date(timeIntervalSince1970: 1_800_000_000),
                updateKind: .fullSnapshot,
                snapshot: []))
    }

    private struct State {
        var requestID: UUID?
        var steps: [ReceiveStep]
        var cancelCount = 0
    }
}

private enum ReceiveStep {
    case envelope(messageType: MessageType)
    case mismatchedNotification
    case sessionInvalidated(String)
    case interrupted
}

private enum TestSubscriptionError: Error {
    case unexpectedCommand
    case missingRequestID
    case missingReceiveStep
}
