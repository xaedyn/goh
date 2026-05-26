import Foundation
import Synchronization
import Testing
import XPC

import GohCore

@Suite("top command")
struct GohTopTests {

    @Test("top subscribes to all jobs and repaints snapshots until interrupted")
    func subscribesAndRepaintsUntilInterrupted() throws {
        let active = Self.job(id: 1, state: .active)
        let completed = Self.job(id: 1, state: .completed)
        let sentCommands = Mutex<[Command]>([])
        let subscribeRequestID = Mutex<UUID?>(nil)
        let notificationCount = Mutex(0)
        let emittedOutput = Mutex("")
        let emittedError = Mutex("")

        let session = GohProgressSubscriptionSession(
            sendSync: { message in
                try message.withUnsafeUnderlyingDictionary { object in
                    let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                    sentCommands.withLock { $0.append(envelope.payload) }
                    switch envelope.payload {
                    case .subscribe:
                        subscribeRequestID.withLock { $0 = envelope.requestID }
                        return try Self.reply(
                            to: envelope,
                            payload: SubscribeReply(
                                revision: 1,
                                snapshot: [ProgressSnapshot(job: active, lanes: [])]))
                    default:
                        Issue.record("unexpected command \(envelope.payload)")
                        return try Self.reply(
                            to: envelope,
                            payload: GohError(code: .invalidArgument),
                            messageType: .error)
                    }
                }
            },
            receiveNotification: {
                let count = notificationCount.withLock { count in
                    count += 1
                    return count
                }
                guard count == 1 else {
                    throw GohXPCNotificationInboxError.interrupted
                }
                let requestID = try #require(subscribeRequestID.withLock { $0 })
                return Self.notification(
                    requestID: requestID,
                    event: ProgressEvent(
                        sequence: 1,
                        revision: 2,
                        emittedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        updateKind: .fullSnapshot,
                        snapshot: [ProgressSnapshot(job: completed, lanes: [])]))
            },
            cancel: {}
        )

        let result = GohTop(
            session: session,
            render: { snapshots in
                "render \(snapshots.map { $0.job.state.rawValue }.joined(separator: ","))\n"
            },
            standardOutput: { chunk in emittedOutput.withLock { $0 += chunk } },
            standardError: { chunk in emittedError.withLock { $0 += chunk } }
        ).run()

        #expect(sentCommands.withLock { $0 } == [
            .subscribe(request: SubscribeRequest(scope: .all)),
        ])
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "")
        #expect(result.standardError == "")
        #expect(emittedOutput.withLock {
            $0 == "\u{1B}[?1049h"
                + "\u{1B}[Hrender active\n\u{1B}[J"
                + "\u{1B}[Hrender completed\n\u{1B}[J"
                + "\u{1B}[?1049l"
        })
        #expect(emittedError.withLock { $0 } == "")
    }

    @Test("top reconnect give-up exits as monitor failure")
    func reconnectGiveUpExitsAsMonitorFailure() throws {
        let active = Self.job(id: 1, state: .active)
        let emittedOutput = Mutex("")
        let emittedError = Mutex("")

        let session = GohProgressSubscriptionSession(
            sendSync: { message in
                try message.withUnsafeUnderlyingDictionary { object in
                    let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                    switch envelope.payload {
                    case .subscribe:
                        return try Self.reply(
                            to: envelope,
                            payload: SubscribeReply(
                                revision: 1,
                                snapshot: [ProgressSnapshot(job: active, lanes: [])]))
                    default:
                        Issue.record("unexpected command \(envelope.payload)")
                        return try Self.reply(
                            to: envelope,
                            payload: GohError(code: .invalidArgument),
                            messageType: .error)
                    }
                }
            },
            receiveNotification: {
                throw GohXPCNotificationInboxError.sessionInvalidated(
                    "daemon session ended")
            },
            cancel: {}
        )

        let result = GohTop(
            session: session,
            reconnect: {
                throw GohXPCNotificationInboxError.sessionInvalidated(
                    "daemon still unavailable")
            },
            reconnectWindow: .milliseconds(5),
            reconnectPollInterval: .milliseconds(1),
            render: { snapshots in "render \(snapshots.count)\n" },
            standardOutput: { chunk in emittedOutput.withLock { $0 += chunk } },
            standardError: { chunk in emittedError.withLock { $0 += chunk } }
        ).run()

        #expect(result.exitCode == 1)
        #expect(result.standardOutput == "")
        #expect(result.standardError == "")
        #expect(emittedOutput.withLock {
            $0 == "\u{1B}[?1049h"
                + "\u{1B}[Hrender 1\n\u{1B}[J"
                + "\u{1B}[?1049l"
        })
        #expect(emittedError.withLock {
            $0 == "gohd connection lost; reconnecting...\n"
                + "Could not reconnect to gohd.\nStart the daemon with: brew services start goh\n"
        })
    }

    private static func job(id: UInt64, state: JobState) -> JobSummary {
        JobSummary(
            id: id,
            url: "https://example.com/\(id)",
            destination: "/tmp/\(id)",
            state: state,
            progress: JobProgress(
                bytesCompleted: 0,
                bytesTotal: 1,
                bytesPerSecond: 0),
            createdAt: Date(timeIntervalSince1970: 0),
            lastProgressAt: nil,
            requestedConnectionCount: 8,
            actualConnectionCount: state == .active ? 4 : 0)
    }

    private static func reply<Payload: Codable & Sendable>(
        to envelope: GohEnvelope<Command>,
        payload: Payload,
        messageType: MessageType = .reply
    ) throws -> XPCDictionary {
        try XPCDictionary(GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: envelope.requestID,
            messageType: messageType,
            payload: payload)
            .xpcDictionary())
    }

    private static func notification(
        requestID: UUID,
        event: ProgressEvent
    ) -> GohEnvelope<ProgressEvent> {
        GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .notification,
            payload: event)
    }
}
