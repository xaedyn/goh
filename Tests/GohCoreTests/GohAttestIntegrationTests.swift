import Foundation
import CryptoKit
import Testing
@testable import GohCore

// Integration tests for the full attest→verify-attestation pipeline.
//
// SE-dependent tests (round-trip sign with real SE) are gated on SecureEnclave.isAvailable.
// All verify-path tests use the software-key golden fixture — run on CI without SE.
@Suite("GohAttest integration")
struct GohAttestIntegrationTests {

    // MARK: - AC2: additivity regression gate

    // AC2: all existing verify-all tests still pass after adding attest verb
    // (verified by running the full suite in Task 10 — this test is a smoke check)
    @Test("AC2: verify --all exit codes unchanged after adding attest")
    func verifyAllExitCodesUnchanged() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-int-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Empty ledger → exit 0 (unchanged)
        let r = GohCommandLine(
            arguments: ["verify", "--all"],
            provenanceStorePathResolver: { dir.appendingPathComponent("absent.plist").path },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 0)
        #expect(!r.standardOutput.contains("{"))  // human output, not JSON
    }

    // MARK: - Full pipeline (software key — no SE, runs on CI)

    // AC1/AC3: attest with software signer → verify-attestation validates offline
    @Test("AC1/AC3: full pipeline with software signer — attest produces artifact that verify-attestation accepts")
    func fullPipelineSoftwareSigner() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-int-sw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Set up ledger with one OK file
        let filePath = dir.appendingPathComponent("model.bin").path
        let content = Data("model-content".utf8)
        try content.write(to: URL(fileURLWithPath: filePath))
        let (sha256, _) = try FileDigest.sha256WithSize(path: filePath)
        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        try store.record(entry: ProvenanceEntry(
            url: "https://example.com/model.bin",
            sha256: sha256, size: content.count,
            downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
            destinationPath: URL(fileURLWithPath: filePath).standardizedFileURL.path))

        let outputPath = dir.appendingPathComponent("attestation.json").path

        // Use software signer (SE-independent)
        let key = P256.Signing.PrivateKey()
        let signer = GohAttestCommand.SignerOverride(
            kid: SignedVerifyReport.deriveKid(from: key.publicKey),
            publicKeyX963: key.publicKey.x963Representation,
            sign: { pae in try key.signature(for: pae).rawRepresentation })

        let attestResult = GohAttestCommand.run(
            provenanceStorePath: storeURL.path,
            outputPath: outputPath,
            attestKeyHandleURL: dir.appendingPathComponent("handle"),
            attestKeysJSONURL: dir.appendingPathComponent("keys.json"),
            signerOverride: signer)

        // AC1: exit 0 (all OK)
        #expect(attestResult.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: outputPath))

        // AC3: verify-attestation succeeds offline (no SE, no keys.json) with --allow-untrusted-key
        let verifyResult = GohVerifyAttestationCommand.run(
            artifactPath: outputPath,
            expectKey: nil,
            allowUntrustedKey: true,
            json: false)
        #expect(verifyResult.exitCode == 0)

        // AC3: verify with correct --expect-key full pubkey → exit 0
        let correctPub = key.publicKey.x963Representation.base64URLEncodedString()
        let verifyResult2 = GohVerifyAttestationCommand.run(
            artifactPath: outputPath,
            expectKey: correctPub,
            allowUntrustedKey: false,
            json: false)
        #expect(verifyResult2.exitCode == 0)

        // AC3: verify with wrong --expect-key full pubkey → exit 3 (mismatch)
        let wrongKey = P256.Signing.PrivateKey()
        let wrongPub = wrongKey.publicKey.x963Representation.base64URLEncodedString()
        let verifyResult3 = GohVerifyAttestationCommand.run(
            artifactPath: outputPath,
            expectKey: wrongPub,
            allowUntrustedKey: false,
            json: false)
        #expect(verifyResult3.exitCode == 3)

        // AC1: tamper the artifact → exit 2 (INVALID)
        let artifactData = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        let envelope = try CommandCoding.decoder.decode(SignedVerifyReport.self, from: artifactData)
        var payloadBytes = try #require(Data(base64Encoded: envelope.payloadBase64))
        payloadBytes[0] ^= 0xFF
        let tamperedEnvelope = SignedVerifyReport(
            attestationVersion: envelope.attestationVersion,
            payloadType: envelope.payloadType,
            payloadBase64: payloadBytes.base64EncodedString(),
            sig: envelope.sig)
        let tamperedPath = dir.appendingPathComponent("tampered.json").path
        try CommandCoding.encoder.encode(tamperedEnvelope).write(
            to: URL(fileURLWithPath: tamperedPath))

        let tamperResult = GohVerifyAttestationCommand.run(
            artifactPath: tamperedPath,
            expectKey: nil,
            allowUntrustedKey: true,
            json: false)
        #expect(tamperResult.exitCode == 2)
    }

    // AC5: golden artifact fixture still verifies after all changes
    @Test("AC5: golden fixture signed-verify-report-v1.json still verifies (regression gate)")
    func goldenFixtureRegression() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/signed-verify-report-v1.json")
        try #require(FileManager.default.fileExists(atPath: fixtureURL.path),
            "signed-verify-report-v1.json missing")

        let result = GohVerifyAttestationCommand.run(
            artifactPath: fixtureURL.path,
            expectKey: nil,
            allowUntrustedKey: true,
            json: false)
        #expect(result.exitCode == 0)
    }

    // MARK: - Full SE pipeline (gated)

    // AC1/AC4: full SE pipeline — attest with real SE key, verify offline
    @Test("AC1/AC4: SE pipeline — attest + verify-attestation end-to-end")
    func sePipeline() throws {
        guard SecureEnclave.isAvailable else { return }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-int-se-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Minimal ledger
        let storeURL = dir.appendingPathComponent("provenance.plist")
        let emptyRecord = ProvenanceRecord(version: ProvenanceRecord.currentVersion, entries: [])
        let plistData = try PropertyListEncoder().encode(emptyRecord)
        try plistData.write(to: storeURL)

        let outputPath = dir.appendingPathComponent("attestation.json").path
        let handleURL = dir.appendingPathComponent("signing-key.handle")
        let keysURL = dir.appendingPathComponent("keys.json")

        let attestResult = GohAttestCommand.run(
            provenanceStorePath: storeURL.path,
            outputPath: outputPath,
            attestKeyHandleURL: handleURL,
            attestKeysJSONURL: keysURL,
            signerOverride: nil)  // real SE key

        #expect(attestResult.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: outputPath))
        // AC4: handle file created
        #expect(FileManager.default.fileExists(atPath: handleURL.path))
        // AC4: handle file is 0600
        let attrs = try FileManager.default.attributesOfItem(atPath: handleURL.path)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)

        // Verify offline (no SE needed for verify)
        let verifyResult = GohVerifyAttestationCommand.run(
            artifactPath: outputPath,
            expectKey: nil,
            allowUntrustedKey: true,
            json: false)
        #expect(verifyResult.exitCode == 0)
    }

    // MARK: - Helpers
    private struct TestTransportError: Error {}
}
