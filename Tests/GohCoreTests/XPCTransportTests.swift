import Foundation
import Synchronization
import Testing
import XPC

import GohCore

@Suite("XPC transport")
struct XPCTransportTests {

    struct TestPayload: Codable, Sendable, Equatable {
        let note: String
    }

    /// A trivial request body for the peer-validation probe.
    struct ProbeRequest: Codable, Sendable {
        var probe = true
    }

    private func sampleEnvelope() throws -> GohEnvelope<TestPayload> {
        let requestID = try #require(UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        return GohEnvelope(
            protocolVersion: 1,
            requestID: requestID,
            messageType: .request,
            payload: TestPayload(note: "transport round-trip"))
    }

    @Test("a GohEnvelope round-trips over the validated XPC transport channel")
    func envelopeRoundTripsOverChannel() throws {
        // Echo listener: reply with the dictionary it received.
        let listener = GohXPCListener(anonymousHandler: { $0 })
        defer { listener.cancel() }

        let client = try GohXPCClient(endpoint: listener.endpoint)
        defer { client.cancel() }

        let sent = try sampleEnvelope()
        let reply = try client.sendSync(XPCDictionary(sent.xpcDictionary()))
        let received = try reply.withUnsafeUnderlyingDictionary { object in
            try GohEnvelope<TestPayload>(xpcDictionary: object)
        }

        #expect(received == sent)
    }

    @Test("a listener can send a daemon-initiated message over the accepted session")
    func listenerCanPushMessageOverAcceptedSession() throws {
        let pushed = GohEnvelope(
            protocolVersion: 1,
            requestID: UUID(),
            messageType: .notification,
            payload: TestPayload(note: "server push"))
        let receivedPushes = Mutex<[GohEnvelope<TestPayload>]>([])
        let pushArrived = DispatchSemaphore(value: 0)

        let listener = GohXPCListener(anonymousSessionHandler: { session, request in
            try? session.send(XPCDictionary(pushed.xpcDictionary()))
            return request
        })
        defer { listener.cancel() }

        let client = try GohXPCClient(
            endpoint: listener.endpoint,
            incomingMessageHandler: { message in
                if let envelope = try? message.withUnsafeUnderlyingDictionary({
                    try GohEnvelope<TestPayload>(xpcDictionary: $0)
                }) {
                    receivedPushes.withLock { $0.append(envelope) }
                    pushArrived.signal()
                }
                return nil
            })
        defer { client.cancel() }

        let sent = try sampleEnvelope()
        let reply = try client.sendSync(XPCDictionary(sent.xpcDictionary()))
        let receivedReply = try reply.withUnsafeUnderlyingDictionary { object in
            try GohEnvelope<TestPayload>(xpcDictionary: object)
        }

        #expect(receivedReply == sent)
        #expect(pushArrived.wait(timeout: .now() + 30) == .success)
        #expect(receivedPushes.withLock { $0 } == [pushed])
    }

    @Test("a same-team peer requirement rejects the unsigned test process")
    func sameTeamRequirementRejectsUnsignedPeer() throws {
        // Reject-direction coverage: the daemon-side per-message peer check
        // (`XPCReceivedMessage.senderSatisfies`) must report that this unsigned
        // test binary does not satisfy `isFromSameTeam()`. The accept direction
        // needs a signed binary and is exercised in signed-build smoke testing.
        let listener = XPCListener(incomingSessionHandler: { request in
            request.accept(incomingMessageHandler: {
                (message: XPCReceivedMessage) -> (any Encodable)? in
                message.senderSatisfies(.isFromSameTeam())
            })
        })
        defer { listener.cancel() }

        let session = try XPCSession(endpoint: listener.endpoint)
        defer { session.cancel(reason: "test finished") }

        let satisfied: Bool = try session.sendSync(ProbeRequest())
        #expect(satisfied == false)
    }
}
