import Foundation
import CryptoKit
import Testing
@testable import GohCore

// ALL tests in this suite are SE-independent — they use the software-key golden fixture
// or construct software-key artifacts inline. Runs on CI without Secure Enclave.
@Suite("GohVerifyAttestationCommand")
struct GohVerifyAttestationCommandTests {

    // Helper: load the golden fixture artifact (software key)
    private func loadFixtureArtifactPath() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/signed-verify-report-v1.json")
        try #require(FileManager.default.fileExists(atPath: url.path),
            "signed-verify-report-v1.json fixture missing — run Task 5 script first")
        return url.path
    }

    private func loadResultFixturePath() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/verify-attestation-result-v1.json")
        try #require(FileManager.default.fileExists(atPath: url.path),
            "verify-attestation-result-v1.json fixture missing — run Task 5 script first")
        return url.path
    }

    // MARK: - AC1: sign→verify round-trip + tamper detection

    // AC1: golden fixture verifies as valid with --allow-untrusted-key
    @Test("AC1: golden fixture artifact verifies as valid (software key fixture, --allow-untrusted-key)")
    func goldenFixtureVerifies() throws {
        // AC1: the fixture is a once-generated valid artifact; this is the primary regression gate
        let path = try loadFixtureArtifactPath()
        let result = GohVerifyAttestationCommand.run(
            artifactPath: path,
            expectKey: nil,
            allowUntrustedKey: true,
            json: false)
        // signatureValid=true + --allow-untrusted-key → exit 0
        #expect(result.exitCode == 0)
    }

    // AC1: byte-flipped payload → exit 2 (INVALID)
    @Test("AC1: byte-flipped payload in artifact → exit 2 INVALID")
    func byteFlippedPayloadIsInvalid() throws {
        let path = try loadFixtureArtifactPath()
        let artifactData = try Data(contentsOf: URL(fileURLWithPath: path))
        var envelope = try CommandCoding.decoder.decode(SignedVerifyReport.self, from: artifactData)

        // Corrupt the base64-encoded payload (flip a byte before re-encoding)
        var payloadBytes = try #require(Data(base64Encoded: envelope.payloadBase64))
        payloadBytes[0] ^= 0xFF
        envelope = SignedVerifyReport(
            attestationVersion: envelope.attestationVersion,
            payloadType: envelope.payloadType,
            payloadBase64: payloadBytes.base64EncodedString(),
            sig: envelope.sig)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-tamper-\(UUID().uuidString).json")
        try CommandCoding.encoder.encode(envelope).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = GohVerifyAttestationCommand.run(
            artifactPath: tmp.path,
            expectKey: nil,
            allowUntrustedKey: true,
            json: false)
        // AC1: tampered → INVALID → exit 2
        #expect(result.exitCode == 2)
    }

    // MARK: - AC3: offline verify (embedded pub only)

    // AC3: verify using only embedded pub — no SE, no keys.json
    @Test("AC3: verify-attestation uses only the embedded public key (offline, no SE)")
    func verifyUsesOnlyEmbeddedPub() throws {
        // AC3: reconstruct pub from artifact's own embedded bytes — no external key state
        let path = try loadFixtureArtifactPath()
        let artifactData = try Data(contentsOf: URL(fileURLWithPath: path))
        let envelope = try CommandCoding.decoder.decode(SignedVerifyReport.self, from: artifactData)

        // Extract embedded pub
        let pubX963 = try #require(Data(base64URLEncoded: envelope.sig.pubBase64url))
        let pub = try P256.Signing.PublicKey(x963Representation: pubX963)

        // Rebuild PAE from artifact fields
        let payloadBytes = try #require(Data(base64Encoded: envelope.payloadBase64))
        let pae = SignedVerifyReport.buildPAE(
            payloadType: envelope.payloadType,
            payloadBytes: payloadBytes)

        let rawSig = try #require(Data(base64URLEncoded: envelope.sig.sigBase64url))
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: rawSig)

        // AC3: valid without any SE or external key store
        #expect(pub.isValidSignature(sig, for: pae))
    }

    // MARK: - AC5: cross-fixture binding (BLOCK-3 fix)

    // AC5/B1 (spec §3): base64-decoded artifact.payload must == verify-all-report-v1.json bytes.
    // This pins the cross-fixture binding: if the fixture generator ever re-synthesizes the
    // payload instead of reading verify-all-report-v1.json directly, this test catches it.
    @Test("AC5/B1: artifact.payload base64-decodes to exact verify-all-report-v1.json bytes")
    func payloadCrossFixtureBinding() throws {
        // Load the signed artifact fixture
        let artifactURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/signed-verify-report-v1.json")
        let artifactData = try Data(contentsOf: artifactURL)
        let envelope = try CommandCoding.decoder.decode(SignedVerifyReport.self, from: artifactData)

        // Decode the embedded payload bytes from the artifact
        let payloadBytes = try #require(Data(base64Encoded: envelope.payloadBase64),
            "artifact.payload is not valid standard base64")

        // Load the verify-all-report-v1.json fixture — the canonical source of truth
        let reportFixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/verify-all-report-v1.json")
        let reportFixtureBytes = try Data(contentsOf: reportFixtureURL)

        // AC5/B1: they must be byte-identical (spec §3 requirement — FROZEN)
        #expect(payloadBytes == reportFixtureBytes,
            "CROSS-FIXTURE BINDING BROKEN: artifact.payload does not match verify-all-report-v1.json — regenerate signed-verify-report-v1.json using the Task 5 script")
    }

    // MARK: - M5: fail-closed exit codes

    // M5/exit-1: valid sig, no --expect-key, no --allow-untrusted-key → exit 1 (fail-closed)
    @Test("M5: valid sig, no pin, no opt-in → exit 1 (fail-closed, identity unverified)")
    func validSigNoPinIsFailClosed() throws {
        // AC: default behavior must fail closed in CI pipelines
        let path = try loadFixtureArtifactPath()
        let result = GohVerifyAttestationCommand.run(
            artifactPath: path,
            expectKey: nil,
            allowUntrustedKey: false,
            json: false)
        #expect(result.exitCode == 1)
    }

    // M5/exit-0 (--allow-untrusted-key): valid sig + opt-in → exit 0
    @Test("M5: valid sig + --allow-untrusted-key → exit 0")
    func validSigAllowUntrustedKeyIsZero() throws {
        let path = try loadFixtureArtifactPath()
        let result = GohVerifyAttestationCommand.run(
            artifactPath: path,
            expectKey: nil,
            allowUntrustedKey: true,
            json: false)
        #expect(result.exitCode == 0)
    }

    // M5/exit-0 (--expect-key kid match): valid sig + matching kid → exit 0
    @Test("M5: valid sig + matching --expect-key kid → exit 0")
    func validSigMatchingKidIsZero() throws {
        let path = try loadFixtureArtifactPath()
        let artifactData = try Data(contentsOf: URL(fileURLWithPath: path))
        let envelope = try CommandCoding.decoder.decode(SignedVerifyReport.self, from: artifactData)
        let kid = envelope.sig.kid

        let result = GohVerifyAttestationCommand.run(
            artifactPath: path,
            expectKey: kid,
            allowUntrustedKey: false,
            json: false)
        #expect(result.exitCode == 0)
    }

    // M5/exit-0 (--expect-key full pubkey match): valid sig + matching full pubkey → exit 0
    @Test("M5: valid sig + matching --expect-key full pubkey → exit 0")
    func validSigMatchingFullPubkeyIsZero() throws {
        let path = try loadFixtureArtifactPath()
        let artifactData = try Data(contentsOf: URL(fileURLWithPath: path))
        let envelope = try CommandCoding.decoder.decode(SignedVerifyReport.self, from: artifactData)
        let fullPub = envelope.sig.pubBase64url  // full base64url x963

        let result = GohVerifyAttestationCommand.run(
            artifactPath: path,
            expectKey: fullPub,
            allowUntrustedKey: false,
            json: false)
        #expect(result.exitCode == 0)
    }

    // M5/exit-2: invalid signature → exit 2 (INVALID)
    @Test("M5: invalid signature → exit 2 INVALID")
    func invalidSignatureExits2() throws {
        // Already covered by byteFlippedPayloadIsInvalid but explicitly name the exit code
        let path = try loadFixtureArtifactPath()
        let artifactData = try Data(contentsOf: URL(fileURLWithPath: path))
        var envelope = try CommandCoding.decoder.decode(SignedVerifyReport.self, from: artifactData)

        // Corrupt the sig field directly
        var rawSig = try #require(Data(base64URLEncoded: envelope.sig.sigBase64url))
        rawSig[0] ^= 0xFF
        envelope = SignedVerifyReport(
            attestationVersion: envelope.attestationVersion,
            payloadType: envelope.payloadType,
            payloadBase64: envelope.payloadBase64,
            sig: SignedVerifyReport.SigBlock(
                ns: envelope.sig.ns,
                alg: envelope.sig.alg,
                kid: envelope.sig.kid,
                pubBase64url: envelope.sig.pubBase64url,
                sigBase64url: rawSig.base64URLEncodedString()))

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-badsig-\(UUID().uuidString).json")
        try CommandCoding.encoder.encode(envelope).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = GohVerifyAttestationCommand.run(
            artifactPath: tmp.path,
            expectKey: nil,
            allowUntrustedKey: true,
            json: false)
        #expect(result.exitCode == 2)
    }

    // M5/exit-3: valid sig, --expect-key mismatch → exit 3
    @Test("M5: valid sig + --expect-key mismatch → exit 3")
    func expectKeyMismatchExits3() throws {
        let path = try loadFixtureArtifactPath()
        let result = GohVerifyAttestationCommand.run(
            artifactPath: path,
            expectKey: "00000000",   // wrong kid
            allowUntrustedKey: false,
            json: false)
        #expect(result.exitCode == 3)
    }

    // M5/exit-6: unknown attestationVersion → exit 6
    @Test("M5: unknown attestationVersion → exit 6")
    func unknownVersionExits6() throws {
        // Build a structurally valid envelope with version 99
        let key = P256.Signing.PrivateKey()
        let payload = Data("test".utf8)
        let payloadType = SignedVerifyReport.payloadType
        let pae = SignedVerifyReport.buildPAE(payloadType: payloadType, payloadBytes: payload)
        let sig = try key.signature(for: pae)
        let pub = key.publicKey

        let envelope = SignedVerifyReport(
            attestationVersion: 99,  // unknown version
            payloadType: payloadType,
            payloadBase64: payload.base64EncodedString(),
            sig: SignedVerifyReport.SigBlock(
                ns: SignedVerifyReport.namespace,
                alg: "ES256",
                kid: SignedVerifyReport.deriveKid(from: pub),
                pubBase64url: pub.x963Representation.base64URLEncodedString(),
                sigBase64url: sig.rawRepresentation.base64URLEncodedString()))

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-badver-\(UUID().uuidString).json")
        try CommandCoding.encoder.encode(envelope).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = GohVerifyAttestationCommand.run(
            artifactPath: tmp.path,
            expectKey: nil,
            allowUntrustedKey: true,
            json: false)
        #expect(result.exitCode == 6)
    }

    // M5/exit-6: malformed JSON → exit 6
    @Test("M5: malformed JSON artifact → exit 6")
    func malformedJSONExits6() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-malformed-\(UUID().uuidString).json")
        try Data("not json at all".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = GohVerifyAttestationCommand.run(
            artifactPath: tmp.path,
            expectKey: nil,
            allowUntrustedKey: true,
            json: false)
        #expect(result.exitCode == 6)
    }

    // M5/exit-64: missing artifact path → exit 6
    @Test("M5: missing artifact file → exit 6 (cannot parse a nonexistent file)")
    func missingFileExits6() throws {
        let result = GohVerifyAttestationCommand.run(
            artifactPath: "/nonexistent/path/artifact.json",
            expectKey: nil,
            allowUntrustedKey: false,
            json: false)
        #expect(result.exitCode == 6)
    }

    // MARK: - --json result schema

    // AC5: --json result is valid JSON with frozen field names
    @Test("AC5: --json result has frozen field names and correct values for valid+trusted artifact")
    func jsonResultHasFrozenFields() throws {
        let path = try loadFixtureArtifactPath()
        let result = GohVerifyAttestationCommand.run(
            artifactPath: path,
            expectKey: nil,
            allowUntrustedKey: true,
            json: true)
        #expect(result.exitCode == 0)

        let data = Data(result.standardOutput.utf8)
        let parsed = try CommandCoding.decoder.decode(VerifyAttestationResult.self, from: data)
        #expect(parsed.resultVersion == 1)
        #expect(parsed.attestationVersion == 1)
        #expect(parsed.signatureValid == true)
        #expect(parsed.keyTrusted == true)
        #expect(parsed.kid.count == 8)
        #expect(parsed.payloadType == SignedVerifyReport.payloadType)
        // verdict is non-nil when signatureValid==true
        #expect(parsed.verdict != nil)
    }

    // AC5: --json result for INVALID sig has signatureValid=false, keyTrusted=false, verdict=nil
    @Test("AC5: --json result for INVALID sig has signatureValid=false, verdict=nil")
    func jsonResultForInvalidSig() throws {
        let path = try loadFixtureArtifactPath()
        let artifactData = try Data(contentsOf: URL(fileURLWithPath: path))
        var envelope = try CommandCoding.decoder.decode(SignedVerifyReport.self, from: artifactData)

        var rawSig = try #require(Data(base64URLEncoded: envelope.sig.sigBase64url))
        rawSig[0] ^= 0xFF
        envelope = SignedVerifyReport(
            attestationVersion: envelope.attestationVersion,
            payloadType: envelope.payloadType,
            payloadBase64: envelope.payloadBase64,
            sig: SignedVerifyReport.SigBlock(
                ns: envelope.sig.ns, alg: envelope.sig.alg, kid: envelope.sig.kid,
                pubBase64url: envelope.sig.pubBase64url,
                sigBase64url: rawSig.base64URLEncodedString()))

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-invalid-json-\(UUID().uuidString).json")
        try CommandCoding.encoder.encode(envelope).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = GohVerifyAttestationCommand.run(
            artifactPath: tmp.path,
            expectKey: nil,
            allowUntrustedKey: true,
            json: true)
        #expect(result.exitCode == 2)

        let data = Data(result.standardOutput.utf8)
        let parsed = try CommandCoding.decoder.decode(VerifyAttestationResult.self, from: data)
        #expect(parsed.signatureValid == false)
        #expect(parsed.keyTrusted == false)
        #expect(parsed.verdict == nil)
    }

    // AC5: --json result for exit-3 (--expect-key mismatch) has keyTrusted=false
    @Test("AC5: --json result for --expect-key mismatch has keyTrusted=false")
    func jsonResultForKeyMismatch() throws {
        let path = try loadFixtureArtifactPath()
        let result = GohVerifyAttestationCommand.run(
            artifactPath: path,
            expectKey: "00000000",
            allowUntrustedKey: false,
            json: true)
        #expect(result.exitCode == 3)

        let data = Data(result.standardOutput.utf8)
        let parsed = try CommandCoding.decoder.decode(VerifyAttestationResult.self, from: data)
        // AC5: golden fixture pins exit-3 --json shape
        #expect(parsed.signatureValid == true)
        #expect(parsed.keyTrusted == false)
    }

    // AC5: golden fixture encode-equals for result schema
    @Test("AC5: VerifyAttestationResult encodes to golden fixture byte-for-byte")
    func resultEncodeEqualsFixture() throws {
        let fixturePath = try loadResultFixturePath()
        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let fixtureResult = try CommandCoding.decoder.decode(VerifyAttestationResult.self, from: fixtureData)

        // Re-encode and compare (tests field order + encoder settings)
        let reEncoded = try CommandCoding.encoder.encode(fixtureResult)
        #expect(reEncoded == fixtureData,
            "VerifyAttestationResult re-encode differs from fixture — schema changed?")
    }
}
