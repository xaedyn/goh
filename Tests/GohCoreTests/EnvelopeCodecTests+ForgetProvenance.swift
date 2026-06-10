import Foundation
import Testing
@testable import GohCore

@Suite("XPC envelope codec — forgetProvenance golden fixtures")
struct EnvelopeCodecForgetProvenanceTests {

    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing golden fixture: Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    @Test("decodes the protocolVersion=4 forgetProvenance request fixture")
    func decodesV4ForgetProvenanceRequestFixture() throws {
        let data = try fixtureData("envelope-v4-forget-provenance-request")
        let envelope = try CommandCoding.decoder.decode(GohEnvelope<Command>.self, from: data)
        #expect(envelope.protocolVersion == 4)
        #expect(envelope.requestID == UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        #expect(envelope.messageType == .request)
        if case .forgetProvenance(let req) = envelope.payload {
            #expect(req.paths.count == 2)
            #expect(req.paths[0] == "/Users/testuser/Downloads/gone.bin")
            #expect(req.paths[1] == "/Volumes/Archive/old.iso")
        } else {
            Issue.record("expected .forgetProvenance payload, got \(envelope.payload)")
        }
    }

    @Test("decodes the protocolVersion=4 forgetProvenance reply fixture")
    func decodesV4ForgetProvenanceReplyFixture() throws {
        let data = try fixtureData("envelope-v4-forget-provenance-reply")
        let envelope = try CommandCoding.decoder.decode(
            GohEnvelope<ForgetProvenanceReply>.self, from: data)
        #expect(envelope.protocolVersion == 4)
        #expect(envelope.messageType == .reply)
        #expect(envelope.payload == ForgetProvenanceReply(forgotCount: 2))
    }

    @Test("forgetProvenance request fixture round-trips through encode→decode byte-equal")
    func forgetProvenanceRequestRoundTrips() throws {
        let data = try fixtureData("envelope-v4-forget-provenance-request")
        let envelope = try CommandCoding.decoder.decode(GohEnvelope<Command>.self, from: data)
        let reEncoded = try CommandCoding.encoder.encode(envelope)
        #expect(reEncoded == data, "re-encoded forgetProvenance request must be byte-equal to the committed fixture")
    }

    @Test("forgetProvenance reply fixture round-trips through encode→decode byte-equal")
    func forgetProvenanceReplyRoundTrips() throws {
        let data = try fixtureData("envelope-v4-forget-provenance-reply")
        let envelope = try CommandCoding.decoder.decode(
            GohEnvelope<ForgetProvenanceReply>.self, from: data)
        let reEncoded = try CommandCoding.encoder.encode(envelope)
        #expect(reEncoded == data, "re-encoded forgetProvenance reply must be byte-equal to the committed fixture")
    }
}
