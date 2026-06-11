import Foundation
import CryptoKit
import Testing
@testable import GohCore

// AC2: verify-path (parse envelope, verify sig) tests use software key — no SE, runs on CI.
// AC1/AC4: sign path tests gated on SecureEnclave.isAvailable.
@Suite("GohAttestCommand")
struct GohAttestCommandTests {

    // MARK: - Software-key path (no SE — runs on CI)

    // AC2: no artifact produced on ledger error (exit 6)
    @Test("AC2: ledger unreadable → exit 6, no artifact")
    func ledgerUnreadableExits6NoArtifact() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-attest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        try Data("not a plist".utf8).write(to: storeURL)
        let outputURL = dir.appendingPathComponent("attestation.json")

        let result = GohAttestCommand.run(
            provenanceStorePath: storeURL.path,
            outputPath: outputURL.path,
            attestKeyHandleURL: dir.appendingPathComponent("signing-key.handle"),
            attestKeysJSONURL: dir.appendingPathComponent("keys.json"),
            // Inject software signer so test doesn't require SE
            signerOverride: makeSoftwareSigner())

        // AC2: exit 6, no artifact written
        #expect(result.exitCode == 6)
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }

    // AC1/AC5: produced artifact is valid JSON and verifiable with embedded pub (software key)
    @Test("AC1/AC5: artifact produced with software signer is valid JSON with verifiable signature")
    func softwareSignerProducesVerifiableArtifact() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-attest-sw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (storeURL, _) = try makeOKStore(in: dir)
        let outputURL = dir.appendingPathComponent("attestation.json")

        let signer = makeSoftwareSigner()
        let result = GohAttestCommand.run(
            provenanceStorePath: storeURL.path,
            outputPath: outputURL.path,
            attestKeyHandleURL: dir.appendingPathComponent("signing-key.handle"),
            attestKeysJSONURL: dir.appendingPathComponent("keys.json"),
            signerOverride: signer)

        // AC1: exit 0 for all-OK ledger
        #expect(result.exitCode == 0)
        // Artifact written
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        // AC1: artifact is valid JSON and signature verifies
        let artifactData = try Data(contentsOf: outputURL)
        let envelope = try CommandCoding.decoder.decode(SignedVerifyReport.self, from: artifactData)
        #expect(envelope.attestationVersion == 1)

        // Reconstruct PAE and verify
        let payloadBytes = try #require(Data(base64Encoded: envelope.payloadBase64))
        let pae = SignedVerifyReport.buildPAE(payloadType: envelope.payloadType,
                                              payloadBytes: payloadBytes)
        let pubX963 = try #require(Data(base64URLEncoded: envelope.sig.pubBase64url))
        let pub = try P256.Signing.PublicKey(x963Representation: pubX963)
        let rawSig = try #require(Data(base64URLEncoded: envelope.sig.sigBase64url))
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: rawSig)
        #expect(pub.isValidSignature(sig, for: pae))

        // AC1: byte-flip the payload → verify fails
        var mutatedPayload = payloadBytes
        mutatedPayload[0] ^= 0xFF
        let mutatedPAE = SignedVerifyReport.buildPAE(payloadType: envelope.payloadType,
                                                     payloadBytes: mutatedPayload)
        #expect(!pub.isValidSignature(sig, for: mutatedPAE))
    }

    // AC2: drift present → artifact produced, exit 2/9 (attests true state)
    @Test("AC2: drift present → artifact produced, exit matches verify verdict")
    func driftPresentProducesArtifact() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-attest-drift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let filePath = dir.appendingPathComponent("file.bin").path
        let (storeURL, _) = try makeOKStore(in: dir, filePath: filePath)
        // Delete the file to cause MISSING → exit 9
        try FileManager.default.removeItem(atPath: filePath)
        let outputURL = dir.appendingPathComponent("attestation.json")

        let result = GohAttestCommand.run(
            provenanceStorePath: storeURL.path,
            outputPath: outputURL.path,
            attestKeyHandleURL: dir.appendingPathComponent("signing-key.handle"),
            attestKeysJSONURL: dir.appendingPathComponent("keys.json"),
            signerOverride: makeSoftwareSigner())

        // AC2: artifact produced even for drift; exit mirrors verify verdict
        #expect(result.exitCode == 9)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        // Single-scan consistency: the verdict carried in the SIGNED payload must
        // agree with the returned exit code. Both are derived from one ledger scan,
        // so a missing-file run (exit 9) must produce a signed report whose summary
        // also reports the file missing — they can never disagree.
        let artifactData = try Data(contentsOf: outputURL)
        let envelope = try CommandCoding.decoder.decode(SignedVerifyReport.self, from: artifactData)
        let signedPayload = try #require(Data(base64Encoded: envelope.payloadBase64))
        let signedReport = try CommandCoding.decoder.decode(VerifyAllReport.self, from: signedPayload)
        #expect(signedReport.summary.missing == 1)
        #expect(signedReport.summary.ok == 0)
        #expect(signedReport.entries.allSatisfy { $0.status == .missing })
    }

    // MARK: - SE path (gated)

    // AC4: attest with real SE key produces a valid artifact
    @Test("AC4: attest with real SE key produces artifact with SE-signed sig",
          .enabled(if: SecureEnclave.isAvailable))
    func seSignedAttest() throws {

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-attest-se-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (storeURL, _) = try makeOKStore(in: dir)
        let outputURL = dir.appendingPathComponent("attestation.json")

        let result = GohAttestCommand.run(
            provenanceStorePath: storeURL.path,
            outputPath: outputURL.path,
            attestKeyHandleURL: dir.appendingPathComponent("signing-key.handle"),
            attestKeysJSONURL: dir.appendingPathComponent("keys.json"),
            signerOverride: nil)  // use real SE key

        #expect(result.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        // Handle file must exist
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("signing-key.handle").path))
    }

    // MARK: - Helpers

    private func makeSoftwareSigner() -> GohAttestCommand.SignerOverride {
        let key = P256.Signing.PrivateKey()
        return GohAttestCommand.SignerOverride(
            kid: SignedVerifyReport.deriveKid(from: key.publicKey),
            publicKeyX963: key.publicKey.x963Representation,
            sign: { pae in try key.signature(for: pae).rawRepresentation }
        )
    }

    private func makeOKStore(
        in dir: URL,
        filePath: String? = nil
    ) throws -> (storeURL: URL, sha256: String) {
        let path = filePath ?? dir.appendingPathComponent("file.bin").path
        let content = Data("hello-world".utf8)
        try content.write(to: URL(fileURLWithPath: path))
        let (sha256, _) = try FileDigest.sha256WithSize(path: path)

        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        try store.record(entry: ProvenanceEntry(
            url: "https://example.com/file.bin",
            sha256: sha256,
            size: content.count,
            downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
            destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path))
        return (storeURL, sha256)
    }
}
