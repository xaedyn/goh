import Foundation
import Synchronization
import Testing
import XPC

import GohCore

@Suite("foreground download command")
struct GohForegroundDownloadTests {

    @Test("foreground download adds, subscribes, and renders until completion")
    func addsSubscribesAndRendersUntilCompletion() throws {
        let request = AddRequest(url: "https://example.com/file.zip")
        let active = Self.makeJob(
            id: 42,
            state: .active,
            progress: JobProgress(
                bytesCompleted: 512,
                bytesTotal: 1024,
                bytesPerSecond: 2048))
        let completed = Self.makeJob(
            id: 42,
            state: .completed,
            progress: JobProgress(
                bytesCompleted: 1024,
                bytesTotal: 1024,
                bytesPerSecond: 0))
        let sentCommands = Mutex<[Command]>([])
        let subscribeRequestID = Mutex<UUID?>(nil)
        let notificationDelivered = Mutex(false)
        let emittedOutput = Mutex("")
        let emittedError = Mutex("")

        let session = GohForegroundDownloadSession(
            sendSync: { message in
                try message.withUnsafeUnderlyingDictionary { object in
                    let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                    sentCommands.withLock { $0.append(envelope.payload) }
                    switch envelope.payload {
                    case .add:
                        return try Self.reply(to: envelope, payload: active)
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
                #expect(emittedOutput.withLock { output in
                    output.contains("Added job 42")
                        && output.contains("Job 42 active")
                })
                let shouldDeliver = notificationDelivered.withLock { delivered in
                    guard !delivered else { return false }
                    delivered = true
                    return true
                }
                let requestID = try #require(subscribeRequestID.withLock { $0 })
                guard shouldDeliver else {
                    throw GohError(code: .cancelled, message: "no more notifications")
                }
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

        let result = GohForegroundDownload(
            request: request,
            session: session,
            standardOutput: { chunk in emittedOutput.withLock { $0 += chunk } },
            standardError: { chunk in emittedError.withLock { $0 += chunk } }
        ).run()

        #expect(sentCommands.withLock { $0 } == [
            .add(request: request),
            .subscribe(request: SubscribeRequest(scope: .job, jobID: 42)),
        ])
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "")
        #expect(result.standardError == "")
        #expect(emittedOutput.withLock { $0.contains("Added job 42") })
        #expect(emittedOutput.withLock {
            $0.contains("Job 42 active: 512 B/1 KB (50%) at 2 KB/s")
        })
        #expect(emittedOutput.withLock {
            $0.contains("Job 42 completed: 1 KB/1 KB (100%) at 0 B/s")
        })
        #expect(emittedError.withLock { $0 } == "")
    }

    @Test("a stale notification carrying a previous subscription's requestID is skipped, not fatal")
    func staleNotificationRequestIDIsSkipped() throws {
        let request = AddRequest(url: "https://example.com/file.zip")
        let active = Self.makeJob(
            id: 42, state: .active,
            progress: JobProgress(bytesCompleted: 512, bytesTotal: 1024, bytesPerSecond: 2048))
        let completed = Self.makeJob(
            id: 42, state: .completed,
            progress: JobProgress(bytesCompleted: 1024, bytesTotal: 1024, bytesPerSecond: 0))
        let subscribeRequestID = Mutex<UUID?>(nil)
        let notificationCount = Mutex(0)
        let emittedError = Mutex("")

        let session = GohForegroundDownloadSession(
            sendSync: { message in
                try message.withUnsafeUnderlyingDictionary { object in
                    let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                    switch envelope.payload {
                    case .add:
                        return try Self.reply(to: envelope, payload: active)
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
                            to: envelope, payload: GohError(code: .invalidArgument),
                            messageType: .error)
                    }
                }
            },
            receiveNotification: {
                let n = notificationCount.withLock { $0 += 1; return $0 }
                let realID = try #require(subscribeRequestID.withLock { $0 })
                switch n {
                case 1:
                    // Stale: a notification from a previous subscription (wrong requestID),
                    // as can arrive in-flight just after a reconnect. Must be skipped.
                    return Self.notification(
                        requestID: UUID(),
                        event: ProgressEvent(
                            sequence: 1, revision: 2,
                            emittedAt: Date(timeIntervalSince1970: 1_800_000_000),
                            updateKind: .fullSnapshot,
                            snapshot: [ProgressSnapshot(job: active, lanes: [])]))
                case 2:
                    return Self.notification(
                        requestID: realID,
                        event: ProgressEvent(
                            sequence: 2, revision: 3,
                            emittedAt: Date(timeIntervalSince1970: 1_800_000_001),
                            updateKind: .fullSnapshot,
                            snapshot: [ProgressSnapshot(job: completed, lanes: [])]))
                default:
                    throw GohError(code: .cancelled, message: "no more notifications")
                }
            },
            cancel: {}
        )

        let result = GohForegroundDownload(
            request: request,
            session: session,
            standardError: { chunk in emittedError.withLock { $0 += chunk } }
        ).run()

        #expect(result.exitCode == 0)
        #expect(!emittedError.withLock { $0 }.contains("invalid reply"))
    }

    @Test("foreground interrupt detaches without cancelling the daemon job")
    func interruptDetachesWithoutCancellingJob() throws {
        let request = AddRequest(url: "https://example.com/file.zip")
        let active = Self.makeJob(
            id: 42,
            state: .active,
            progress: JobProgress(
                bytesCompleted: 512,
                bytesTotal: 1024,
                bytesPerSecond: 2048))
        let cancelCount = Mutex(0)
        let emittedOutput = Mutex("")
        let emittedError = Mutex("")

        let session = GohForegroundDownloadSession(
            sendSync: { message in
                try message.withUnsafeUnderlyingDictionary { object in
                    let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                    switch envelope.payload {
                    case .add:
                        return try Self.reply(to: envelope, payload: active)
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
                throw GohXPCNotificationInboxError.interrupted
            },
            cancel: { cancelCount.withLock { $0 += 1 } }
        )

        let result = GohForegroundDownload(
            request: request,
            session: session,
            standardOutput: { chunk in emittedOutput.withLock { $0 += chunk } },
            standardError: { chunk in emittedError.withLock { $0 += chunk } }
        ).run()

        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "")
        #expect(result.standardError == "")
        #expect(emittedOutput.withLock { $0.contains("Job 42 active") })
        #expect(emittedError.withLock {
            $0 == "^C - download continues in background as job 42. 'goh ls' to check, 'goh rm 42' to cancel.\n"
        })
        #expect(cancelCount.withLock { $0 } == 1)
    }

    @Test("foreground reconnect re-subscribes and resumes rendering")
    func reconnectResubscribesAndResumesRendering() throws {
        let request = AddRequest(url: "https://example.com/file.zip")
        let active = Self.makeJob(
            id: 42,
            state: .active,
            progress: JobProgress(
                bytesCompleted: 512,
                bytesTotal: 1024,
                bytesPerSecond: 2048))
        let completed = Self.makeJob(
            id: 42,
            state: .completed,
            progress: JobProgress(
                bytesCompleted: 1024,
                bytesTotal: 1024,
                bytesPerSecond: 0))
        let sentCommands = Mutex<[Command]>([])
        let reconnectCount = Mutex(0)
        let reconnectedSubscribeRequestID = Mutex<UUID?>(nil)
        let emittedOutput = Mutex("")
        let emittedError = Mutex("")

        let firstSession = GohForegroundDownloadSession(
            sendSync: { message in
                try message.withUnsafeUnderlyingDictionary { object in
                    let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                    sentCommands.withLock { $0.append(envelope.payload) }
                    switch envelope.payload {
                    case .add:
                        return try Self.reply(to: envelope, payload: active)
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

        let secondSession = GohForegroundDownloadSession(
            sendSync: { message in
                try message.withUnsafeUnderlyingDictionary { object in
                    let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                    sentCommands.withLock { $0.append(envelope.payload) }
                    switch envelope.payload {
                    case .subscribe:
                        reconnectedSubscribeRequestID.withLock { $0 = envelope.requestID }
                        return try Self.reply(
                            to: envelope,
                            payload: SubscribeReply(
                                revision: 2,
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
                let requestID = try #require(reconnectedSubscribeRequestID.withLock { $0 })
                return Self.notification(
                    requestID: requestID,
                    event: ProgressEvent(
                        sequence: 1,
                        revision: 3,
                        emittedAt: Date(timeIntervalSince1970: 1_800_000_001),
                        updateKind: .fullSnapshot,
                        snapshot: [ProgressSnapshot(job: completed, lanes: [])]))
            },
            cancel: {}
        )

        let result = GohForegroundDownload(
            request: request,
            session: firstSession,
            reconnect: {
                reconnectCount.withLock { $0 += 1 }
                return secondSession
            },
            reconnectWindow: .milliseconds(20),
            reconnectPollInterval: .milliseconds(1),
            standardOutput: { chunk in emittedOutput.withLock { $0 += chunk } },
            standardError: { chunk in emittedError.withLock { $0 += chunk } }
        ).run()

        #expect(result.exitCode == 0)
        #expect(sentCommands.withLock { $0 } == [
            .add(request: request),
            .subscribe(request: SubscribeRequest(scope: .job, jobID: 42)),
            .subscribe(request: SubscribeRequest(scope: .job, jobID: 42)),
        ])
        #expect(reconnectCount.withLock { $0 } == 1)
        #expect(emittedOutput.withLock {
            $0.contains("Job 42 completed: 1 KB/1 KB (100%) at 0 B/s")
        })
        #expect(emittedError.withLock {
            $0 == "gohd connection lost; reconnecting...\n"
        })
    }

    @Test("foreground reconnect gives up with background guidance")
    func reconnectGivesUpWithBackgroundGuidance() throws {
        let request = AddRequest(url: "https://example.com/file.zip")
        let active = Self.makeJob(
            id: 42,
            state: .active,
            progress: JobProgress(
                bytesCompleted: 512,
                bytesTotal: 1024,
                bytesPerSecond: 2048))
        let emittedOutput = Mutex("")
        let emittedError = Mutex("")

        let session = GohForegroundDownloadSession(
            sendSync: { message in
                try message.withUnsafeUnderlyingDictionary { object in
                    let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                    switch envelope.payload {
                    case .add:
                        return try Self.reply(to: envelope, payload: active)
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

        let result = GohForegroundDownload(
            request: request,
            session: session,
            reconnect: {
                throw GohXPCNotificationInboxError.sessionInvalidated(
                    "daemon still unavailable")
            },
            reconnectWindow: .milliseconds(5),
            reconnectPollInterval: .milliseconds(1),
            standardOutput: { chunk in emittedOutput.withLock { $0 += chunk } },
            standardError: { chunk in emittedError.withLock { $0 += chunk } }
        ).run()

        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "")
        #expect(result.standardError == "")
        #expect(emittedOutput.withLock { $0.contains("Job 42 active") })
        #expect(emittedError.withLock {
            $0.contains("gohd connection lost; reconnecting...\n")
                && $0.contains("download continues in background as job 42. 'goh ls' to check.\n")
        })
    }

    @Test("foreground reconnect reports daemon errors after reconnecting")
    func reconnectReportsDaemonErrorsAfterReconnect() throws {
        let request = AddRequest(url: "https://example.com/file.zip")
        let active = Self.makeJob(
            id: 42,
            state: .active,
            progress: JobProgress(
                bytesCompleted: 512,
                bytesTotal: 1024,
                bytesPerSecond: 2048))
        let reconnectCount = Mutex(0)
        let emittedOutput = Mutex("")
        let emittedError = Mutex("")

        let firstSession = GohForegroundDownloadSession(
            sendSync: { message in
                try message.withUnsafeUnderlyingDictionary { object in
                    let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                    switch envelope.payload {
                    case .add:
                        return try Self.reply(to: envelope, payload: active)
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

        let secondSession = GohForegroundDownloadSession(
            sendSync: { message in
                try message.withUnsafeUnderlyingDictionary { object in
                    let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                    reconnectCount.withLock { $0 += 1 }
                    return try Self.reply(
                        to: envelope,
                        payload: GohError(
                            code: .jobNotFound,
                            message: "job 42 is no longer tracked"),
                        messageType: .error)
                }
            },
            receiveNotification: {
                Issue.record("should not wait for notifications after daemon error")
                throw GohXPCNotificationInboxError.interrupted
            },
            cancel: {}
        )

        let result = GohForegroundDownload(
            request: request,
            session: firstSession,
            reconnect: { secondSession },
            reconnectWindow: .milliseconds(20),
            reconnectPollInterval: .milliseconds(1),
            standardOutput: { chunk in emittedOutput.withLock { $0 += chunk } },
            standardError: { chunk in emittedError.withLock { $0 += chunk } }
        ).run()

        #expect(result.exitCode == 1)
        #expect(reconnectCount.withLock { $0 } == 1)
        #expect(emittedOutput.withLock { $0.contains("Job 42 active") })
        #expect(emittedError.withLock {
            $0 == "gohd connection lost; reconnecting...\ngohd: job 42 is no longer tracked\n"
        })
    }

    @Test("foreground interrupt during reconnect detaches promptly")
    func interruptDuringReconnectDetachesPromptly() throws {
        let request = AddRequest(url: "https://example.com/file.zip")
        let active = Self.makeJob(
            id: 42,
            state: .active,
            progress: JobProgress(
                bytesCompleted: 512,
                bytesTotal: 1024,
                bytesPerSecond: 2048))
        let interrupted = Mutex(false)
        let reconnectCount = Mutex(0)
        let emittedOutput = Mutex("")
        let emittedError = Mutex("")

        let session = GohForegroundDownloadSession(
            sendSync: { message in
                try message.withUnsafeUnderlyingDictionary { object in
                    let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                    switch envelope.payload {
                    case .add:
                        return try Self.reply(to: envelope, payload: active)
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

        let result = GohForegroundDownload(
            request: request,
            session: session,
            reconnect: {
                reconnectCount.withLock { $0 += 1 }
                interrupted.withLock { $0 = true }
                throw GohXPCNotificationInboxError.sessionInvalidated(
                    "daemon still unavailable")
            },
            reconnectWindow: .seconds(1),
            reconnectPollInterval: .milliseconds(100),
            shouldInterrupt: { interrupted.withLock { $0 } },
            standardOutput: { chunk in emittedOutput.withLock { $0 += chunk } },
            standardError: { chunk in emittedError.withLock { $0 += chunk } }
        ).run()

        #expect(result.exitCode == 0)
        #expect(reconnectCount.withLock { $0 } == 1)
        #expect(emittedOutput.withLock { $0.contains("Job 42 active") })
        #expect(emittedError.withLock {
            $0 == "gohd connection lost; reconnecting...\n"
                + "^C - download continues in background as job 42. 'goh ls' to check, 'goh rm 42' to cancel.\n"
        })
    }

    private static func makeJob(
        id: UInt64,
        state: JobState,
        progress: JobProgress
    ) -> JobSummary {
        JobSummary(
            id: id,
            url: "https://example.com/file.zip",
            destination: "/tmp/file.zip",
            state: state,
            progress: progress,
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
