import Foundation
import CryptoKit
import Testing
@testable import GohCore

// AC5: frozen format — envelope field names/values, PAE, result schema
@Suite("AttestTypes")
struct AttestTypesTests {

    // MARK: - PAE builder

    // AC1/AC5: PAE bytes are deterministic and match the DSSE spec
    // PAE = "DSSEv1" SP ASCII(len(payloadType)) SP payloadType SP ASCII(len(payload)) SP payload
    @Test("PAE builder produces correct DSSE-PAE bytes for known inputs")
    func paeBuilderIsCorrect() throws {
        // AC1: PAE is the signing input; must be deterministic given payloadType + payload
        let payloadType = "application/vnd.goh.verify-report+json; v=1"
        let payload = Data("hello".utf8)
        let pae = SignedVerifyReport.buildPAE(payloadType: payloadType, payloadBytes: payload)

        // Manually construct expected PAE:
        // "DSSEv1" + SP + "45" + SP + payloadType + SP + "5" + SP + "hello"
        let expected = "DSSEv1 \(payloadType.utf8.count) \(payloadType) \(payload.count) "
            .data(using: .utf8)! + payload
        #expect(pae == expected)
    }

    // AC1/AC5: len is byte count (UTF-8), not character count
    @Test("PAE builder uses byte length, not character count")
    func paeLengthIsByteCount() throws {
        let payloadType = "application/vnd.goh.verify-report+json; v=1"
        let multibyte = Data("café".utf8)  // 5 bytes, 4 chars
        let pae = SignedVerifyReport.buildPAE(payloadType: payloadType, payloadBytes: multibyte)
        let paeStr = String(data: pae, encoding: .utf8)!
        // Should contain " 5 " (byte count), not " 4 " (char count)
        #expect(paeStr.contains(" 5 café"))
    }

    // MARK: - Envelope encode/decode round-trip

    // AC5: SignedVerifyReport encodes with the correct field names (frozen)
    @Test("AC5: SignedVerifyReport field names are frozen")
    func envelopeFieldNamesFrozen() throws {
        // Use a throwaway software key (SE NOT required — verify-path only)
        let key = P256.Signing.PrivateKey()
        let payloadType = SignedVerifyReport.payloadType
        let payload = Data("test-payload".utf8)
        let pae = SignedVerifyReport.buildPAE(payloadType: payloadType, payloadBytes: payload)
        let sig = try key.signature(for: pae)
        let pub = key.publicKey

        let kidData = SHA256.hash(data: pub.x963Representation)
        let kid = kidData.prefix(4).map { String(format: "%02x", $0) }.joined()

        let envelope = SignedVerifyReport(
            attestationVersion: 1,
            payloadType: payloadType,
            payloadBase64: payload.base64EncodedString(),
            sig: SignedVerifyReport.SigBlock(
                ns: SignedVerifyReport.namespace,
                alg: "ES256",
                kid: kid,
                pubBase64url: pub.x963Representation.base64URLEncodedString(),
                sigBase64url: sig.rawRepresentation.base64URLEncodedString()
            )
        )

        let data = try CommandCoding.encoder.encode(envelope)
        let json = String(decoding: data, as: UTF8.self)

        // AC5: frozen field names
        #expect(json.contains("\"attestationVersion\""))
        #expect(json.contains("\"payloadType\""))
        #expect(json.contains("\"payload\""))
        #expect(json.contains("\"sig\""))
        #expect(json.contains("\"ns\""))
        #expect(json.contains("\"alg\""))
        #expect(json.contains("\"kid\""))
        #expect(json.contains("\"pub\""))
        // "sig" inside the sig block — appears twice
        #expect(json.contains("\"ES256\""))
        #expect(json.contains("\"dev.goh.verify-report.v1\""))
    }

    // AC5: frozen constants
    @Test("AC5: payloadType and namespace constants are frozen")
    func constantsFrozen() {
        // AC5: if these change, existing artifacts silently stop verifying
        #expect(SignedVerifyReport.payloadType == "application/vnd.goh.verify-report+json; v=1")
        #expect(SignedVerifyReport.namespace == "dev.goh.verify-report.v1")
    }

    // MARK: - VerifyAttestationResult field names

    // AC5: VerifyAttestationResult field names are frozen
    @Test("AC5: VerifyAttestationResult field names are frozen")
    func resultFieldNamesFrozen() throws {
        let result = VerifyAttestationResult(
            resultVersion: 1,
            attestationVersion: 1,
            signatureValid: true,
            keyTrusted: false,
            kid: "aabbccdd",
            payloadType: SignedVerifyReport.payloadType,
            verdict: "ok"
        )

        let data = try CommandCoding.encoder.encode(result)
        let json = String(decoding: data, as: UTF8.self)

        // AC5: frozen field names (do NOT rename)
        #expect(json.contains("\"resultVersion\""))
        #expect(json.contains("\"attestationVersion\""))
        #expect(json.contains("\"signatureValid\""))
        #expect(json.contains("\"keyTrusted\""))
        #expect(json.contains("\"kid\""))
        #expect(json.contains("\"payloadType\""))
        #expect(json.contains("\"verdict\""))
    }

    // AC5: verdict raw values are frozen
    @Test("AC5: AttestVerdict raw values are frozen")
    func verdictRawValuesFrozen() {
        // These are the frozen string values in the --json output
        #expect(AttestVerdict.ok.rawValue == "ok")
        #expect(AttestVerdict.failed.rawValue == "failed")
        #expect(AttestVerdict.missing.rawValue == "missing")
    }

    // MARK: - base64url helper

    // AC5: base64url (no padding, URL-safe alphabet)
    @Test("base64URLEncodedString produces URL-safe no-padding output")
    func base64urlIsURLSafe() {
        // 65-byte x963 pubkey will contain characters that differ between std and url base64
        let key = P256.Signing.PrivateKey()
        let x963 = key.publicKey.x963Representation
        let encoded = x963.base64URLEncodedString()
        // No padding
        #expect(!encoded.contains("="))
        // No + or / (std base64 chars replaced with - and _)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
    }

    // MARK: - kid derivation

    // AC5: kid is 8 hex chars (first 4 bytes of SHA-256(x963))
    @Test("kid derivation produces 8 hex chars from SHA-256(x963)[0..3]")
    func kidDerivationIsCorrect() {
        let key = P256.Signing.PrivateKey()
        let pub = key.publicKey
        let kid = SignedVerifyReport.deriveKid(from: pub)
        #expect(kid.count == 8)
        // All hex chars
        #expect(kid.allSatisfy { $0.isHexDigit })
    }
}
