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
}
