import Foundation
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

    @Test("a session-aware listener handles requests through the accepted session")
    func sessionAwareListenerHandlesRequests() throws {
        let listener = GohXPCListener(anonymousSessionHandler: { session, request in
            _ = session
            return request
        })
        defer { listener.cancel() }

        let client = try GohXPCClient(endpoint: listener.endpoint)
        defer { client.cancel() }

        let sent = try sampleEnvelope()
        let reply = try client.sendSync(XPCDictionary(sent.xpcDictionary()))
        let receivedReply = try reply.withUnsafeUnderlyingDictionary { object in
            try GohEnvelope<TestPayload>(xpcDictionary: object)
        }

        #expect(receivedReply == sent)
    }

    @Test("a same-team peer requirement rejects the unsigned test process")
    func sameTeamRequirementRejectsUnsignedPeer() throws {
        // Reject-direction coverage for the daemon-side per-message peer check
        // (`XPCReceivedMessage.senderSatisfies`): an unsigned binary like this
        // test process must report that it does not satisfy
        // `isFromSameTeam()`.
        //
        // What this test does NOT cover: the production session-accept path,
        // where `XPCListener(service:requirement:)` lets the OS reject an
        // unsatisfying peer before the handler ever runs (`DESIGN.md` §3.1).
        // That path requires a signed binary registered with launchd and is
        // exercised in the signed-build smoke gate
        // (`Scripts/private-release-candidate.sh`), not in CI.
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

    @Test("peerRequirement(for: .enforced) returns the requirement the production listener uses")
    func peerRequirementForEnforcedModeIsSet() {
        // The production daemon wires `XPCListener(service:requirement:)` to
        // `GohXPCService.peerRequirement(for: validationMode)`. If the mapping
        // function silently returns `nil` for `.enforced`, the production
        // listener would silently disable peer validation. This test catches
        // exactly that regression in CI.
        #expect(GohXPCService.peerRequirement(for: .enforced) != nil)
    }

    @Test("peerRequirement(for: .relaxedForDevelopment) returns nil so the dev escape hatch stays open")
    func peerRequirementForDevelopmentModeIsNil() {
        // The dogfood lane builds unsigned binaries that can't satisfy
        // `isFromSameTeam()`; the `.relaxedForDevelopment` mode is the
        // documented escape hatch (`DESIGN.md` §3.1). If the mapping function
        // silently returns a requirement for this mode, dogfood would be
        // unable to connect.
        #expect(GohXPCService.peerRequirement(for: .relaxedForDevelopment) == nil)
    }

    @Test("the requirement returned by peerRequirement(for: .enforced) rejects unsigned binaries")
    func enforcedRequirementRejectsUnsignedPeer() throws {
        // Closes the gap one step further than `sameTeamRequirementRejectsUnsignedPeer`:
        // proves that the requirement *value* the production listener wires
        // up (via the `peerRequirement(for:)` factory) is the same requirement
        // that demonstrably rejects unsigned binaries via `senderSatisfies`.
        //
        // We still cannot test the session-accept path itself in CI (see the
        // top-level comment on `sameTeamRequirementRejectsUnsignedPeer`).
        let requirement = try #require(
            GohXPCService.peerRequirement(for: .enforced))
        let listener = XPCListener(incomingSessionHandler: { request in
            request.accept(incomingMessageHandler: {
                (message: XPCReceivedMessage) -> (any Encodable)? in
                message.senderSatisfies(requirement)
            })
        })
        defer { listener.cancel() }

        let session = try XPCSession(endpoint: listener.endpoint)
        defer { session.cancel(reason: "test finished") }

        let satisfied: Bool = try session.sendSync(ProbeRequest())
        #expect(satisfied == false)
    }
}
