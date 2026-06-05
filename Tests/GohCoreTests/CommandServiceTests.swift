import Darwin
import Foundation
import Synchronization
import Testing
import XPC

@testable import GohCore

@Suite("Command service over XPC")
struct CommandServiceTests {

    /// An anonymous-listener channel whose handler is a fresh `CommandService`.
    private func makeChannel() throws -> (GohXPCListener, GohXPCClient) {
        let service = CommandService(dispatcher: CommandDispatcher(store: JobStore()))
        let listener = GohXPCListener(anonymousHandler: { service.handle($0) })
        let client = try GohXPCClient(endpoint: listener.endpoint)
        return (listener, client)
    }

    /// Sends `command` over `client` and returns the decoded reply envelope,
    /// asserting the reply is correlated to the request by `requestID`.
    private func send<Reply: Codable & Sendable>(
        _ command: Command, expecting replyType: Reply.Type, over client: GohXPCClient
    ) throws -> GohEnvelope<Reply> {
        let requestID = UUID()
        let request = GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .request,
            payload: command)
        let replyDictionary = try client.sendSync(XPCDictionary(request.xpcDictionary()))
        let reply = try replyDictionary.withUnsafeUnderlyingDictionary { object in
            try GohEnvelope<Reply>(xpcDictionary: object)
        }
        #expect(reply.requestID == requestID, "reply must echo the request id")
        return reply
    }

    /// Builds a raw XPC envelope so tests can exercise compatibility handling
    /// independently of the current `Command` payload codec.
    private func makeEnvelopeDictionary(
        protocolVersion: UInt64,
        requestID: UUID,
        messageType: String,
        payload: Data
    ) -> xpc_object_t {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(dictionary, "protocolVersion", protocolVersion)
        xpc_dictionary_set_string(dictionary, "requestID", requestID.uuidString)
        xpc_dictionary_set_string(dictionary, "messageType", messageType)
        payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                xpc_dictionary_set_data(dictionary, "payload", base, raw.count)
            }
        }
        return dictionary
    }

    private func makeAuthImportSafariRequest(
        requestID: UUID,
        fileDescriptor: Int32? = nil
    ) throws -> xpc_object_t {
        let request = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .request,
            payload: Command.authImportSafari(request: AuthImportSafariRequest())
        ).xpcDictionary()
        if let fileDescriptor {
            XPCEnvelope.setFileDescriptor(
                fileDescriptor,
                forKey: XPCEnvelope.authSafariCookieFileKey,
                in: request)
        }
        return request
    }

    @Test("an add command round-trips to a queued JobSummary reply")
    func addRoundTrips() throws {
        let (listener, client) = try makeChannel()
        defer { listener.cancel(); client.cancel() }

        let reply = try send(
            .add(request: AddRequest(url: "https://example.com/f.iso")),
            expecting: JobSummary.self, over: client)
        #expect(reply.messageType == .reply)
        #expect(reply.payload.state == .queued)
        #expect(reply.payload.url == "https://example.com/f.iso")
        #expect(reply.payload.id == 1)
    }

    @Test("a pause of an unknown job round-trips to a jobNotFound error reply")
    func unknownPauseRoundTripsToError() throws {
        let (listener, client) = try makeChannel()
        defer { listener.cancel(); client.cancel() }

        let reply = try send(.pause(jobID: 999), expecting: GohError.self, over: client)
        #expect(reply.messageType == .error)
        #expect(reply.payload.code == .jobNotFound)
    }

    @Test("add then ls round-trips the created job back in the list")
    func addThenList() throws {
        let (listener, client) = try makeChannel()
        defer { listener.cancel(); client.cancel() }

        _ = try send(
            .add(request: AddRequest(url: "https://example.com/a")),
            expecting: JobSummary.self, over: client)
        let reply = try send(.ls, expecting: LsReply.self, over: client)
        #expect(reply.messageType == .reply)
        #expect(reply.payload.jobs.count == 1)
        #expect(reply.payload.jobs.first?.url == "https://example.com/a")
    }

    @Test("subscribe returns the progress broker's baseline reply")
    func subscribeReturnsBaselineReply() throws {
        let store = JobStore()
        let created = store.create(
            url: "https://example.com/big.zip",
            destination: "/tmp/big.zip",
            requestedConnectionCount: 8)
        let job = JobSummary(
            id: created.id,
            url: created.url,
            destination: created.destination,
            state: created.state,
            progress: created.progress,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastProgressAt: nil,
            requestedConnectionCount: created.requestedConnectionCount,
            actualConnectionCount: created.actualConnectionCount)
        let snapshot = ProgressSnapshot(job: job, lanes: [])
        let progress = ProgressBrokerHub(initialSnapshots: [snapshot])
        let service = CommandService(
            dispatcher: CommandDispatcher(store: store),
            progress: progress)
        let listener = GohXPCListener(anonymousSessionHandler: { session, request in
            service.handle(request, session: session)
        })
        let client = try GohXPCClient(endpoint: listener.endpoint)
        defer { listener.cancel(); client.cancel() }

        let reply = try send(
            .subscribe(request: SubscribeRequest(scope: .job, jobID: job.id)),
            expecting: SubscribeReply.self,
            over: client)

        #expect(reply.messageType == .reply)
        #expect(reply.payload == SubscribeReply(revision: 0, snapshot: [snapshot]))
    }

    @Test("subscribe pushes progress notifications over the same session")
    func subscribePushesProgressNotifications() throws {
        let store = JobStore()
        let created = store.create(
            url: "https://example.com/big.zip",
            destination: "/tmp/big.zip",
            requestedConnectionCount: 8)
        let job = JobSummary(
            id: created.id,
            url: created.url,
            destination: created.destination,
            state: created.state,
            progress: created.progress,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastProgressAt: nil,
            requestedConnectionCount: created.requestedConnectionCount,
            actualConnectionCount: created.actualConnectionCount)
        let progress = ProgressBrokerHub(
            cadence: 0.100,
            initialSnapshots: [ProgressSnapshot(job: job, lanes: [])])
        let service = CommandService(
            dispatcher: CommandDispatcher(store: store),
            progress: progress)
        let notifications = Mutex<[GohEnvelope<ProgressEvent>]>([])
        let session = GohXPCServerSession(send: { message in
            if let envelope = try? message.withUnsafeUnderlyingDictionary({
                try GohEnvelope<ProgressEvent>(xpcDictionary: $0)
            }) {
                notifications.withLock { $0.append(envelope) }
            }
        })

        let requestID = UUID()
        let request = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .request,
            payload: Command.subscribe(request: SubscribeRequest(scope: .job, jobID: job.id))
        ).xpcDictionary()
        let replyDictionary = try #require(service.handle(XPCDictionary(request), session: session))
        let reply = try replyDictionary.withUnsafeUnderlyingDictionary { object in
            try GohEnvelope<SubscribeReply>(xpcDictionary: object)
        }
        #expect(reply.messageType == .reply)

        var updatedJob = job
        updatedJob.state = .active
        updatedJob.progress = JobProgress(
            bytesCompleted: 256,
            bytesTotal: 1_024,
            bytesPerSecond: 512)
        updatedJob.lastProgressAt = Date(timeIntervalSince1970: 1_800_000_001)
        let updatedSnapshot = ProgressSnapshot(job: updatedJob, lanes: [])

        progress.publish(updatedSnapshot, at: Date(timeIntervalSince1970: 1_800_000_002))

        let received = try #require(notifications.withLock { $0.first })
        #expect(received.requestID == requestID)
        #expect(received.messageType == .notification)
        #expect(received.payload.sequence == 1)
        #expect(received.payload.revision == 1)
        #expect(received.payload.updateKind == .fullSnapshot)
        #expect(received.payload.snapshot == [updatedSnapshot])
    }

    @Test("session cancellation unsubscribes progress notifications")
    func sessionCancellationUnsubscribesProgressNotifications() throws {
        let store = JobStore()
        let created = store.create(
            url: "https://example.com/big.zip",
            destination: "/tmp/big.zip",
            requestedConnectionCount: 8)
        let job = JobSummary(
            id: created.id,
            url: created.url,
            destination: created.destination,
            state: created.state,
            progress: created.progress,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastProgressAt: nil,
            requestedConnectionCount: created.requestedConnectionCount,
            actualConnectionCount: created.actualConnectionCount)
        let progress = ProgressBrokerHub(
            cadence: 0,
            initialSnapshots: [ProgressSnapshot(job: job, lanes: [])])
        let service = CommandService(
            dispatcher: CommandDispatcher(store: store),
            progress: progress)
        let notifications = Mutex<[GohEnvelope<ProgressEvent>]>([])
        let cancellationHandlers = Mutex<[(@Sendable () -> Void)]>([])
        let session = GohXPCServerSession(
            send: { message in
                if let envelope = try? message.withUnsafeUnderlyingDictionary({
                    try GohEnvelope<ProgressEvent>(xpcDictionary: $0)
                }) {
                    notifications.withLock { $0.append(envelope) }
                }
            },
            registerCancellationHandler: { handler in
                cancellationHandlers.withLock { $0.append(handler) }
            })

        let request = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: UUID(),
            messageType: .request,
            payload: Command.subscribe(request: SubscribeRequest(scope: .job, jobID: job.id))
        ).xpcDictionary()
        #expect(service.handle(XPCDictionary(request), session: session) != nil)

        for handler in cancellationHandlers.withLock({ $0 }) {
            handler()
        }

        var updatedJob = job
        updatedJob.state = .active
        updatedJob.progress = JobProgress(
            bytesCompleted: 256,
            bytesTotal: 1_024,
            bytesPerSecond: 512)
        progress.publish(
            ProgressSnapshot(job: updatedJob, lanes: []),
            at: Date(timeIntervalSince1970: 1_800_000_002))

        #expect(notifications.withLock { $0 }.isEmpty)
    }

    @Test("auth import without the Safari cookie fd replies with invalidArgument")
    func authImportWithoutFileDescriptorRepliesWithInvalidArgument() throws {
        let service = CommandService(
            dispatcher: CommandDispatcher(store: JobStore()),
            authImportSafari: { _ in
                Issue.record("handler should not be called without the fd sibling")
                return .authImported(AuthImportSafariReply(importedCookieCount: 0))
            })
        let listener = GohXPCListener(anonymousHandler: { service.handle($0) })
        let client = try GohXPCClient(endpoint: listener.endpoint)
        defer { listener.cancel(); client.cancel() }

        let requestID = UUID()
        let replyDictionary = try client.sendSync(XPCDictionary(
            makeAuthImportSafariRequest(requestID: requestID)))
        let reply = try replyDictionary.withUnsafeUnderlyingDictionary { object in
            try GohEnvelope<GohError>(xpcDictionary: object)
        }

        #expect(reply.requestID == requestID)
        #expect(reply.messageType == .error)
        #expect(reply.payload.code == .invalidArgument)
    }

    @Test("auth import with a wrong-typed Safari cookie sibling replies with invalidArgument")
    func authImportWithWrongTypedFileDescriptorRepliesWithInvalidArgument() throws {
        let service = CommandService(
            dispatcher: CommandDispatcher(store: JobStore()),
            authImportSafari: { _ in
                Issue.record("handler should not be called without an fd sibling")
                return .authImported(AuthImportSafariReply(importedCookieCount: 0))
            })
        let listener = GohXPCListener(anonymousHandler: { service.handle($0) })
        let client = try GohXPCClient(endpoint: listener.endpoint)
        defer { listener.cancel(); client.cancel() }

        let requestID = UUID()
        let request = try makeAuthImportSafariRequest(requestID: requestID)
        xpc_dictionary_set_int64(request, XPCEnvelope.authSafariCookieFileKey, 7)

        let replyDictionary = try client.sendSync(XPCDictionary(request))
        let reply = try replyDictionary.withUnsafeUnderlyingDictionary { object in
            try GohEnvelope<GohError>(xpcDictionary: object)
        }

        #expect(reply.requestID == requestID)
        #expect(reply.messageType == .error)
        #expect(reply.payload.code == .invalidArgument)
    }

    @Test("auth import passes a duplicated Safari cookie fd to the handler")
    func authImportPassesDuplicatedFileDescriptorToHandler() throws {
        let payload = Array("cookie-bytes".utf8)
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "goh-auth-import-fd-\(UUID().uuidString)")
        try Data(payload).write(to: fileURL)
        let fd = open(fileURL.path, O_RDONLY)
        #expect(fd >= 0)
        defer {
            close(fd)
            try? FileManager.default.removeItem(at: fileURL)
        }

        let service = CommandService(
            dispatcher: CommandDispatcher(store: JobStore()),
            authImportSafari: { duplicatedFD in
                var buffer = [UInt8](repeating: 0, count: payload.count)
                let bytesRead = read(duplicatedFD, &buffer, buffer.count)
                guard bytesRead == payload.count, buffer == payload else {
                    return .failure(GohError(
                        code: .invalidArgument,
                        message: "did not receive the expected fd contents"))
                }
                return .authImported(AuthImportSafariReply(importedCookieCount: 42))
            })
        let listener = GohXPCListener(anonymousHandler: { service.handle($0) })
        let client = try GohXPCClient(endpoint: listener.endpoint)
        defer { listener.cancel(); client.cancel() }

        let requestID = UUID()
        let replyDictionary = try client.sendSync(XPCDictionary(
            makeAuthImportSafariRequest(requestID: requestID, fileDescriptor: fd)))
        let reply = try replyDictionary.withUnsafeUnderlyingDictionary { object in
            try GohEnvelope<AuthImportSafariReply>(xpcDictionary: object)
        }

        #expect(reply.requestID == requestID)
        #expect(reply.messageType == .reply)
        #expect(reply.payload.importedCookieCount == 42)
    }

    @Test("an old-version request replies with protocolVersionMismatch")
    func oldProtocolVersionMismatchRepliesWithError() throws {
        let (listener, client) = try makeChannel()
        defer { listener.cancel(); client.cancel() }

        let requestID = UUID()
        let request = GohEnvelope(
            protocolVersion: 1,
            requestID: requestID,
            messageType: .request,
            payload: Command.ls)
        let replyDictionary = try client.sendSync(XPCDictionary(request.xpcDictionary()))
        let reply = try replyDictionary.withUnsafeUnderlyingDictionary { object in
            try GohEnvelope<GohError>(xpcDictionary: object)
        }

        #expect(reply.requestID == requestID)
        #expect(reply.messageType == .error)
        #expect(reply.payload.code == .protocolVersionMismatch)
    }

    @Test("a future-version request with an unknown payload still replies with protocolVersionMismatch")
    func futureProtocolVersionMismatchIsCheckedBeforePayloadDecode() throws {
        let (listener, client) = try makeChannel()
        defer { listener.cancel(); client.cancel() }

        let requestID = UUID()
        let request = makeEnvelopeDictionary(
            protocolVersion: UInt64(CommandService.protocolVersion + 1),
            requestID: requestID,
            messageType: "request",
            payload: Data(#"{"futureCommand":{"shape":"unknown-to-v3"}}"#.utf8))
        let replyDictionary = try client.sendSync(XPCDictionary(request))
        let reply = try replyDictionary.withUnsafeUnderlyingDictionary { object in
            try GohEnvelope<GohError>(xpcDictionary: object)
        }

        #expect(reply.requestID == requestID)
        #expect(reply.messageType == .error)
        #expect(reply.payload.code == .protocolVersionMismatch)
    }

    @Test("recordVerifiedProvenance returns AckReply over real XPC and records to the store")
    func recordVerifiedProvenanceReturnsAck() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-dispatcher-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pStore = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
        _ = pStore.load()

        let service = CommandService(
            dispatcher: CommandDispatcher(store: JobStore(), provenanceStore: pStore))
        let listener = GohXPCListener(anonymousHandler: { service.handle($0) })
        let client = try GohXPCClient(endpoint: listener.endpoint)
        defer { listener.cancel(); client.cancel() }

        let t = Date(timeIntervalSince1970: 1_750_000_000)
        let entry = VerifiedProvenanceEntry(
            url: "https://example.com/f.bin",
            sha256: "sha256:" + String(repeating: "d", count: 64),
            size: 256, destinationPath: "/tmp/test-dispatcher-f.bin", verifiedAt: t)
        let command = Command.recordVerifiedProvenance(
            request: RecordVerifiedProvenanceRequest(entries: [entry]))

        let reply = try send(command, expecting: AckReply.self, over: client)
        #expect(reply.messageType == .reply)
        #expect(reply.payload == AckReply())

        let canonical = URL(fileURLWithPath: "/tmp/test-dispatcher-f.bin").standardizedFileURL.path
        let found = pStore.lookup(destinationPath: canonical)
        #expect(found != nil)
        #expect(found?.verifiedAt == t)
    }

    @Test("a non-request envelope replies with invalidArgument")
    func nonRequestEnvelopeRepliesWithError() throws {
        let (listener, client) = try makeChannel()
        defer { listener.cancel(); client.cancel() }

        let requestID = UUID()
        let request = GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .notification,
            payload: Command.ls)
        let replyDictionary = try client.sendSync(XPCDictionary(request.xpcDictionary()))
        let reply = try replyDictionary.withUnsafeUnderlyingDictionary { object in
            try GohEnvelope<GohError>(xpcDictionary: object)
        }

        #expect(reply.requestID == requestID)
        #expect(reply.messageType == .error)
        #expect(reply.payload.code == .invalidArgument)
    }
}
