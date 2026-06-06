import Foundation
import CryptoKit
import Testing
import XPC
@testable import GohCore

@Suite("GohCommandLine — attest + verify-attestation parse boundary")
struct GohAttestParseTests {

    private struct TestTransportError: Error {}

    // BLOCK-1 fix: software-key SignerOverride for hermetic parse/dispatch tests.
    // Injected via attestSignerResolver so NO real SE key is created and NO writes
    // go to ~/Library/Application Support/dev.goh.attest/ during tests.
    // IMPORTANT: this override is test-injection only; it is never a production fallback.
    private func makeSoftwareSignerResolver() -> GohCommandLine.AttestSignerResolver {
        let key = P256.Signing.PrivateKey()
        let override = GohAttestCommand.SignerOverride(
            kid: SignedVerifyReport.deriveKid(from: key.publicKey),
            publicKeyX963: key.publicKey.x963Representation,
            sign: { pae in try key.signature(for: pae).rawRepresentation }
        )
        return { override }
    }

    // AC5/parse: `attest` routes correctly — hermetic (software signer + temp key location)
    @Test("AC5/parse: 'attest' routes to GohAttestCommand (hermetic — no SE, no home dir writes)")
    func attestRoutes() throws {
        // BLOCK-1 fix: inject (a) temp dir as attest key location and (b) software signer.
        // Without these, this test falls through to the real SE + ~/Library/…/dev.goh.attest/.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-attest-parse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let handleURL = dir.appendingPathComponent("signing-key.handle")
        let keysURL = dir.appendingPathComponent("keys.json")

        let r = GohCommandLine(
            arguments: ["attest"],
            provenanceStorePathResolver: { dir.appendingPathComponent("absent.plist").path },
            attestKeyLocationResolver: { (handleURL: handleURL, keysJSONURL: keysURL) },
            attestSignerResolver: makeSoftwareSignerResolver(),
            send: { _ in throw TestTransportError() }
        ).run()
        // absent ledger → verify-all returns exit 0; attest with software signer exits 0.
        // The key parse invariant: exit is NOT 64 (parse error).
        #expect(r.exitCode != 64)
    }

    // AC5/parse: `attest --output <file>` parses correctly — hermetic (software signer + temp key location)
    @Test("AC5/parse: 'attest --output <file>' parses and routes correctly (hermetic — no SE, no home dir writes)")
    func attestOutputRoutes() throws {
        // BLOCK-1 fix: inject (a) temp dir as attest key location and (b) software signer.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-attest-out-parse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let handleURL = dir.appendingPathComponent("signing-key.handle")
        let keysURL = dir.appendingPathComponent("keys.json")
        let outputPath = dir.appendingPathComponent("out.json").path

        let r = GohCommandLine(
            arguments: ["attest", "--output", outputPath],
            provenanceStorePathResolver: { dir.appendingPathComponent("absent.plist").path },
            attestKeyLocationResolver: { (handleURL: handleURL, keysJSONURL: keysURL) },
            attestSignerResolver: makeSoftwareSignerResolver(),
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode != 64)
    }

    // AC5/parse: `attest --unknown` → exit 64
    @Test("AC5/parse: 'attest --unknown-flag' → exit 64")
    func attestUnknownFlagExits64() {
        let r = GohCommandLine(
            arguments: ["attest", "--unknown-flag"],
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
    }

    // AC5/parse: `verify-attestation <file>` routes correctly
    @Test("AC5/parse: 'verify-attestation <file>' routes (file absent → exit 6, not 64)")
    func verifyAttestationRoutes() {
        let r = GohCommandLine(
            arguments: ["verify-attestation", "/nonexistent/artifact.json"],
            send: { _ in throw TestTransportError() }
        ).run()
        // File absent → exit 6 from GohVerifyAttestationCommand, not 64
        #expect(r.exitCode == 6)
    }

    // AC5/parse: `verify-attestation` with no file → exit 64
    @Test("AC5/parse: 'verify-attestation' with no file → exit 64")
    func verifyAttestationNoFileExits64() {
        let r = GohCommandLine(
            arguments: ["verify-attestation"],
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
    }

    // AC5/parse: `verify-attestation <file> --allow-untrusted-key` parses correctly
    @Test("AC5/parse: 'verify-attestation <file> --allow-untrusted-key' parses")
    func verifyAttestationAllowUntrustedKey() {
        let r = GohCommandLine(
            arguments: ["verify-attestation", "/nonexistent.json", "--allow-untrusted-key"],
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 6)  // file absent, not parse error
    }

    // AC5/parse: `verify-attestation <file> --expect-key <kid>` parses correctly
    @Test("AC5/parse: 'verify-attestation <file> --expect-key <kid>' parses")
    func verifyAttestationExpectKey() {
        let r = GohCommandLine(
            arguments: ["verify-attestation", "/nonexistent.json", "--expect-key", "aabbccdd"],
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 6)  // file absent, not parse error
    }

    // AC5/parse: `verify-attestation <file> --json` parses correctly
    @Test("AC5/parse: 'verify-attestation <file> --json' parses")
    func verifyAttestationJson() {
        let r = GohCommandLine(
            arguments: ["verify-attestation", "/nonexistent.json", "--json"],
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 6)  // file absent, not parse error
    }

    // Usage text includes attest and verify-attestation
    @Test("usage text includes 'attest' and 'verify-attestation'")
    func usageIncludesNewVerbs() {
        let r = GohCommandLine(
            arguments: ["--help"],
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.standardOutput.contains("attest"))
        #expect(r.standardOutput.contains("verify-attestation"))
    }
}
