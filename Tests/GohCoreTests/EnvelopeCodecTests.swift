import Foundation
import Testing

import GohCore

@Suite("XPC envelope codec")
struct EnvelopeCodecTests {

    /// A minimal stand-in payload. Per-command payload shapes are a later slice;
    /// `GohEnvelope` is generic over any `Codable` payload, so a representative
    /// type is enough to exercise and freeze the envelope's own four-key shape.
    struct TestPayload: Codable, Sendable, Equatable {
        let note: String
    }

    /// Loads a committed `protocolVersion = 1` golden fixture by name.
    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing golden fixture: Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    @Test("decodes the protocolVersion=1 request fixture into the four envelope keys")
    func decodesRequestFixture() throws {
        let envelope = try JSONDecoder().decode(
            GohEnvelope<TestPayload>.self, from: fixtureData("envelope-v1-request"))

        #expect(envelope.protocolVersion == 1)
        #expect(envelope.requestID == UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        #expect(envelope.messageType == .request)
        #expect(envelope.payload == TestPayload(note: "golden fixture payload"))
    }

    @Test("decodes the protocolVersion=1 reply fixture")
    func decodesReplyFixture() throws {
        let envelope = try JSONDecoder().decode(
            GohEnvelope<TestPayload>.self, from: fixtureData("envelope-v1-reply"))

        #expect(envelope.messageType == .reply)
    }

    @Test("an envelope round-trips through encode then decode unchanged")
    func roundTripsUnchanged() throws {
        let original = try JSONDecoder().decode(
            GohEnvelope<TestPayload>.self, from: fixtureData("envelope-v1-request"))

        let reEncoded = try JSONEncoder().encode(original)
        let reDecoded = try JSONDecoder().decode(GohEnvelope<TestPayload>.self, from: reEncoded)

        #expect(reDecoded == original)
    }

    @Test("an unrecognised messageType is rejected with an error, never crashed")
    func unknownMessageTypeIsRejected() {
        let json = Data("""
            {
              "protocolVersion": 1,
              "requestID": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
              "messageType": "telepathy",
              "payload": { "note": "x" }
            }
            """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GohEnvelope<TestPayload>.self, from: json)
        }
    }
}
