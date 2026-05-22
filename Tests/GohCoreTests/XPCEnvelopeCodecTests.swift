import Foundation
import Testing
import XPC

import GohCore

@Suite("Envelope ⇄ XPC dictionary codec")
struct XPCEnvelopeCodecTests {

    /// A minimal stand-in payload — see `EnvelopeCodecTests.TestPayload`.
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

    /// Builds an envelope XPC dictionary field by field, independently of the
    /// production encoder. A `nil` argument omits that key.
    private func makeEnvelopeDictionary(
        protocolVersion: UInt64? = 1,
        requestID: String? = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
        messageType: String? = "request",
        payload: [String: Any]? = ["note": "golden fixture payload"]
    ) throws -> xpc_object_t {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        if let protocolVersion {
            xpc_dictionary_set_uint64(dictionary, "protocolVersion", protocolVersion)
        }
        if let requestID {
            xpc_dictionary_set_string(dictionary, "requestID", requestID)
        }
        if let messageType {
            xpc_dictionary_set_string(dictionary, "messageType", messageType)
        }
        if let payload {
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            // Unwrap to a non-optional pointer — `xpc_dictionary_set_data`'s
            // parameter is non-optional under some SDKs (see cross-SDK skew).
            bytes.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    xpc_dictionary_set_data(dictionary, "payload", base, raw.count)
                }
            }
        }
        return dictionary
    }

    @Test("the v1 request fixture decodes identically through the JSON and XPC codecs")
    func decodesIdenticallyThroughBothCodecs() throws {
        let fixture = try fixtureData("envelope-v1-request")

        let viaJSON = try JSONDecoder().decode(GohEnvelope<TestPayload>.self, from: fixture)

        let parsed = try #require(try JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        let dictionary = try makeEnvelopeDictionary(
            protocolVersion: UInt64(try #require(parsed["protocolVersion"] as? Int)),
            requestID: try #require(parsed["requestID"] as? String),
            messageType: try #require(parsed["messageType"] as? String),
            payload: try #require(parsed["payload"] as? [String: Any]))
        let viaXPC = try GohEnvelope<TestPayload>(xpcDictionary: dictionary)

        #expect(viaJSON == viaXPC)
    }

    @Test("an envelope round-trips through the XPC dictionary codec unchanged")
    func roundTripsThroughXPCCodec() throws {
        let original = try JSONDecoder().decode(
            GohEnvelope<TestPayload>.self, from: fixtureData("envelope-v1-request"))

        let restored = try GohEnvelope<TestPayload>(xpcDictionary: original.xpcDictionary())

        #expect(restored == original)
    }

    @Test("a sibling entry beside the four keys is isolated, not folded into payload")
    func siblingEntryIsIsolatedFromPayload() throws {
        let original = try JSONDecoder().decode(
            GohEnvelope<TestPayload>.self, from: fixtureData("envelope-v1-request"))
        let dictionary = try original.xpcDictionary()

        // A synthetic stand-in for a file-descriptor sibling (§5.2): an XPC
        // int64 value in place of xpc_fd, beside the four canonical keys.
        xpc_dictionary_set_int64(dictionary, "fd0", 7)

        let restored = try GohEnvelope<TestPayload>(xpcDictionary: dictionary)
        #expect(restored == original)
        #expect(XPCEnvelope.siblingKeys(in: dictionary) == ["fd0"])
    }

    @Test("an unrecognised messageType is rejected, not crashed")
    func rejectsUnknownMessageType() throws {
        let dictionary = try makeEnvelopeDictionary(messageType: "telepathy")

        #expect(throws: XPCEnvelopeError.self) {
            try GohEnvelope<TestPayload>(xpcDictionary: dictionary)
        }
    }

    @Test("a missing envelope key is rejected, not crashed")
    func rejectsMissingKey() throws {
        let dictionary = try makeEnvelopeDictionary(requestID: nil)

        #expect(throws: XPCEnvelopeError.self) {
            try GohEnvelope<TestPayload>(xpcDictionary: dictionary)
        }
    }

    @Test("the invalidArgument error code round-trips at protocolVersion 1")
    func invalidArgumentErrorCodeRoundTrips() throws {
        let fixture = try fixtureData("envelope-v1-error-invalid-argument")
        let decoded = try JSONDecoder().decode(GohEnvelope<GohError>.self, from: fixture)
        #expect(decoded.protocolVersion == 1)
        #expect(decoded.messageType == .error)
        #expect(decoded.payload.code == .invalidArgument)

        // Round-trip the decoded envelope through the XPC codec.
        let restored = try GohEnvelope<GohError>(xpcDictionary: decoded.xpcDictionary())
        #expect(restored == decoded)
        #expect(restored.payload.code == .invalidArgument)
    }

    @Test("a Date-bearing payload encodes its dates as ISO-8601 strings (§4)")
    func payloadDatesAreISO8601() throws {
        let summary = JobSummary(
            id: 1,
            url: "https://example.com/f",
            destination: "/tmp/f",
            state: .queued,
            progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastProgressAt: nil,
            requestedConnectionCount: 8,
            actualConnectionCount: 0)
        let envelope = GohEnvelope(
            protocolVersion: 1,
            requestID: try #require(UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")),
            messageType: .reply,
            payload: summary)

        let dictionary = try envelope.xpcDictionary()
        var length = 0
        let bytes = try #require(xpc_dictionary_get_data(dictionary, "payload", &length))
        let payloadJSON = String(decoding: Data(bytes: bytes, count: length), as: UTF8.self)

        // createdAt must be a quoted ISO-8601 string, not the numeric default.
        #expect(payloadJSON.contains("\"createdAt\":\"2023-11-14T"))
    }
}
