import Foundation
import Testing
import XPC

import GohCore

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
            protocolVersion: 1, requestID: requestID, messageType: .request, payload: command)
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

    @Test("a request with an incompatible protocol version replies with protocolVersionMismatch")
    func protocolVersionMismatchRepliesWithError() throws {
        let (listener, client) = try makeChannel()
        defer { listener.cancel(); client.cancel() }

        let requestID = UUID()
        let request = GohEnvelope(
            protocolVersion: 2,
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
    func protocolVersionMismatchIsCheckedBeforePayloadDecode() throws {
        let (listener, client) = try makeChannel()
        defer { listener.cancel(); client.cancel() }

        let requestID = UUID()
        let request = makeEnvelopeDictionary(
            protocolVersion: 2,
            requestID: requestID,
            messageType: "request",
            payload: Data(#"{"futureCommand":{"shape":"unknown-to-v1"}}"#.utf8))
        let replyDictionary = try client.sendSync(XPCDictionary(request))
        let reply = try replyDictionary.withUnsafeUnderlyingDictionary { object in
            try GohEnvelope<GohError>(xpcDictionary: object)
        }

        #expect(reply.requestID == requestID)
        #expect(reply.messageType == .error)
        #expect(reply.payload.code == .protocolVersionMismatch)
    }

    @Test("a non-request envelope replies with invalidArgument")
    func nonRequestEnvelopeRepliesWithError() throws {
        let (listener, client) = try makeChannel()
        defer { listener.cancel(); client.cancel() }

        let requestID = UUID()
        let request = GohEnvelope(
            protocolVersion: 1,
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
