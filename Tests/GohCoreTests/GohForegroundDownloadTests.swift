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

        let result = GohForegroundDownload(request: request, session: session).run()

        #expect(sentCommands.withLock { $0 } == [
            .add(request: request),
            .subscribe(request: SubscribeRequest(scope: .job, jobID: 42)),
        ])
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("Added job 42"))
        #expect(result.standardOutput.contains("Job 42 active: 512 B/1 KB (50%) at 2 KB/s"))
        #expect(result.standardOutput.contains("Job 42 completed: 1 KB/1 KB (100%) at 0 B/s"))
        #expect(result.standardError == "")
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
