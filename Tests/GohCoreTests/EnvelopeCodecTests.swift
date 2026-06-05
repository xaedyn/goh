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

    /// Loads a committed golden fixture by name.
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

    @Test("decodes the protocolVersion=2 auth import request fixture")
    func decodesV2AuthImportRequestFixture() throws {
        let envelope = try JSONDecoder().decode(
            GohEnvelope<Command>.self,
            from: fixtureData("envelope-v2-auth-import-safari-request"))

        #expect(envelope.protocolVersion == 2)
        #expect(envelope.requestID == UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        #expect(envelope.messageType == .request)
        #expect(envelope.payload == .authImportSafari(request: AuthImportSafariRequest()))
    }

    @Test("decodes the protocolVersion=2 auth import reply fixture")
    func decodesV2AuthImportReplyFixture() throws {
        let envelope = try JSONDecoder().decode(
            GohEnvelope<AuthImportSafariReply>.self,
            from: fixtureData("envelope-v2-auth-import-safari-reply"))

        #expect(envelope.protocolVersion == 2)
        #expect(envelope.messageType == .reply)
        #expect(envelope.payload == AuthImportSafariReply(importedCookieCount: 42))
    }

    @Test("decodes the protocolVersion=3 subscribe request fixture")
    func decodesV3SubscribeRequestFixture() throws {
        let envelope = try JSONDecoder().decode(
            GohEnvelope<Command>.self,
            from: fixtureData("envelope-v3-subscribe-request"))

        #expect(envelope.protocolVersion == 3)
        #expect(envelope.requestID == UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        #expect(envelope.messageType == .request)
        #expect(envelope.payload == .subscribe(request: SubscribeRequest(scope: .job, jobID: 42)))
    }

    @Test("decodes the protocolVersion=3 subscribe reply fixture")
    func decodesV3SubscribeReplyFixture() throws {
        let envelope = try JSONDecoder().decode(
            GohEnvelope<SubscribeReply>.self,
            from: fixtureData("envelope-v3-subscribe-reply"))

        #expect(envelope.protocolVersion == 3)
        #expect(envelope.messageType == .reply)
        #expect(envelope.payload == SubscribeReply(revision: 7, snapshot: []))
    }

    @Test("decodes the protocolVersion=3 progress notification fixture")
    func decodesV3ProgressNotificationFixture() throws {
        let envelope = try CommandCoding.decoder.decode(
            GohEnvelope<ProgressEvent>.self,
            from: fixtureData("envelope-v3-progress-notification"))

        #expect(envelope.protocolVersion == 3)
        #expect(envelope.messageType == .notification)
        #expect(envelope.payload == ProgressEvent(
            sequence: 1,
            revision: 8,
            emittedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updateKind: .fullSnapshot,
            snapshot: []))
    }

    @Test("decodes the protocolVersion=4 recordVerifiedProvenance request fixture")
    func decodesV4RecordVerifiedProvenanceRequestFixture() throws {
        let envelope = try CommandCoding.decoder.decode(
            GohEnvelope<Command>.self,
            from: fixtureData("envelope-v4-record-verified-provenance-request"))
        #expect(envelope.protocolVersion == 4)
        #expect(envelope.requestID == UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        #expect(envelope.messageType == .request)
        if case .recordVerifiedProvenance(let req) = envelope.payload {
            #expect(req.entries.count == 1)
            #expect(req.entries[0].url == "https://example.com/f.bin")
            #expect(req.entries[0].sha256 == "sha256:" + String(repeating: "a", count: 64))
            #expect(req.entries[0].size == 1024)
            #expect(req.entries[0].destinationPath == "/Users/testuser/Downloads/f.bin")
            #expect(req.entries[0].verifiedAt == Date(timeIntervalSince1970: 1_714_262_400))
        } else {
            Issue.record("expected .recordVerifiedProvenance payload")
        }
    }

    @Test("decodes the protocolVersion=4 recordVerifiedProvenance reply fixture")
    func decodesV4RecordVerifiedProvenanceReplyFixture() throws {
        let envelope = try CommandCoding.decoder.decode(
            GohEnvelope<AckReply>.self,
            from: fixtureData("envelope-v4-record-verified-provenance-reply"))
        #expect(envelope.protocolVersion == 4)
        #expect(envelope.messageType == .reply)
        #expect(envelope.payload == AckReply())
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
