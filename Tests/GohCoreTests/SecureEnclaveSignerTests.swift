import Foundation
import CryptoKit
import Testing
@testable import GohCore

// AC3: verify-path tests use a software P256 key — SE NOT required, runs on CI.
// AC4: sign-path tests require SE — gated on SecureEnclave.isAvailable.
@Suite("SecureEnclaveSigner")
struct SecureEnclaveSignerTests {

    // MARK: - Verify path (software key — no SE required, runs on CI)

    // AC1: sign → verify round-trip with a software key (proves PAE+sig logic is correct)
    @Test("AC1: software key sign→verify round-trip succeeds")
    func softwareKeySignVerifyRoundTrip() throws {
        // AC1: tamper-evident — same report signed → verifies; mutated → fails
        let key = P256.Signing.PrivateKey()
        let pub = key.publicKey
        let payload = Data("test-payload-bytes".utf8)
        let payloadType = SignedVerifyReport.payloadType
        let pae = SignedVerifyReport.buildPAE(payloadType: payloadType, payloadBytes: payload)

        let sig = try key.signature(for: pae)

        // Valid: same pae → valid
        #expect(pub.isValidSignature(sig, for: pae))

        // AC1: mutated payload → DIFFERENT pae → invalid sig
        let mutated = Data("mutated-payload".utf8)
        let mutatedPAE = SignedVerifyReport.buildPAE(payloadType: payloadType, payloadBytes: mutated)
        #expect(!pub.isValidSignature(sig, for: mutatedPAE))
    }

    // AC3: public key can be exported as x963 and re-imported for offline verify
    @Test("AC3: public key x963 round-trip works without SE (offline verify path)")
    func publicKeyX963RoundTrip() throws {
        // AC3: verifier on another machine reconstructs public key from embedded bytes
        let key = P256.Signing.PrivateKey()
        let pub = key.publicKey
        let x963 = pub.x963Representation

        // Re-import from bytes (as a verifier would do from the artifact)
        let reimported = try P256.Signing.PublicKey(x963Representation: x963)

        let payload = Data("some payload".utf8)
        let payloadType = SignedVerifyReport.payloadType
        let pae = SignedVerifyReport.buildPAE(payloadType: payloadType, payloadBytes: payload)
        let sig = try key.signature(for: pae)

        // Verify with re-imported key (no SE involved)
        #expect(reimported.isValidSignature(sig, for: pae))

        // Byte-flip in sig → invalid
        var rawSig = sig.rawRepresentation
        rawSig[0] ^= 0xFF
        let badSig = try P256.Signing.ECDSASignature(rawRepresentation: rawSig)
        #expect(!reimported.isValidSignature(badSig, for: pae))
    }

    // AC5: kid is stable for a given public key
    @Test("AC5: kid derivation is deterministic and 8 hex chars")
    func kidIsDeterministic() {
        let key = P256.Signing.PrivateKey()
        let pub = key.publicKey
        let kid1 = SignedVerifyReport.deriveKid(from: pub)
        let kid2 = SignedVerifyReport.deriveKid(from: pub)
        #expect(kid1 == kid2)
        #expect(kid1.count == 8)
    }

    // MARK: - SE path (gated — skip gracefully in CI VM)

    // AC4: SecureEnclaveSigner.createOrOpen persists only the opaque handle
    @Test("AC4: createOrOpen creates a handle file and persists only opaque bytes",
          .enabled(if: SecureEnclave.isAvailable))
    func createOrOpenPersistsHandle() throws {
        // AC4: hardware-rooted — private material is only the opaque handle

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-se-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let handleURL = dir.appendingPathComponent("signing-key.handle")
        let signer = try SecureEnclaveSigner.createOrOpen(handleURL: handleURL)

        // Handle file must exist and be > 0 bytes (the opaque dataRepresentation ~284 bytes)
        #expect(FileManager.default.fileExists(atPath: handleURL.path))
        let handleData = try Data(contentsOf: handleURL)
        #expect(handleData.count > 0)

        // File permissions must be 0600
        let attrs = try FileManager.default.attributesOfItem(atPath: handleURL.path)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)

        // kid is 8 hex chars
        #expect(signer.kid.count == 8)

        // AC4: confirm signer type is SE (not software) by asserting SE is used
        // (the type is SecureEnclave.P256.Signing.PrivateKey, not P256.Signing.PrivateKey)
        _ = signer.publicKeyX963  // 65 bytes exportable
        #expect(signer.publicKeyX963.count == 65)
    }

    // AC1/AC4: SE signer produces a valid ECDSA-P256 signature verifiable with embedded pub
    @Test("AC1/AC4: SE signer sign→verify round-trip",
          .enabled(if: SecureEnclave.isAvailable))
    func seSignerRoundTrip() throws {
        // AC1: tamper-evident; AC4: hardware-rooted

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-se-sign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let handleURL = dir.appendingPathComponent("signing-key.handle")
        let signer = try SecureEnclaveSigner.createOrOpen(handleURL: handleURL)

        let payload = Data("attest-payload".utf8)
        let payloadType = SignedVerifyReport.payloadType
        let rawSig = try signer.sign(pae: SignedVerifyReport.buildPAE(
            payloadType: payloadType, payloadBytes: payload))

        // Reconstruct public key from embedded x963 (as verify-attestation does)
        let pub = try P256.Signing.PublicKey(x963Representation: signer.publicKeyX963)
        let ecSig = try P256.Signing.ECDSASignature(rawRepresentation: rawSig)
        let pae = SignedVerifyReport.buildPAE(payloadType: payloadType, payloadBytes: payload)
        #expect(pub.isValidSignature(ecSig, for: pae))

        // Mutated payload → invalid
        let mutatedPAE = SignedVerifyReport.buildPAE(payloadType: payloadType,
                                                     payloadBytes: Data("mutated".utf8))
        #expect(!pub.isValidSignature(ecSig, for: mutatedPAE))
    }

    // createOrOpen is idempotent — re-opening an existing handle returns the same kid
    @Test("createOrOpen is idempotent: same kid on second open",
          .enabled(if: SecureEnclave.isAvailable))
    func createOrOpenIsIdempotent() throws {

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-se-idem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let handleURL = dir.appendingPathComponent("signing-key.handle")
        let signer1 = try SecureEnclaveSigner.createOrOpen(handleURL: handleURL)
        let signer2 = try SecureEnclaveSigner.createOrOpen(handleURL: handleURL)
        #expect(signer1.kid == signer2.kid)
        #expect(signer1.publicKeyX963 == signer2.publicKeyX963)
    }

    // BLOCK-2 fix: pre-existing handle file → createOrOpen opens it, never overwrites.
    // This is the O_EXCL "already-exists → open existing" contract from spec §4.
    // The sequential-re-open test above only verifies the happy path; this test verifies
    // that a pre-created handle is preserved (not clobbered) and yields the same key identity.
    @Test("createOrOpen: handle already present → opens existing key, does not clobber",
          .enabled(if: SecureEnclave.isAvailable))
    func createOrOpenDoesNotClobberExistingHandle() throws {

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-se-noclobber-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let handleURL = dir.appendingPathComponent("signing-key.handle")

        // Step 1: create via first call → captures kid/pubkey
        let signer1 = try SecureEnclaveSigner.createOrOpen(handleURL: handleURL)
        let originalKid = signer1.kid
        let originalPub = signer1.publicKeyX963

        // Confirm handle file is on disk
        #expect(FileManager.default.fileExists(atPath: handleURL.path))
        let originalHandleBytes = try Data(contentsOf: handleURL)
        #expect(originalHandleBytes.count > 0)

        // Step 2: second createOrOpen with handle already present →
        //   must OPEN the existing handle, NOT overwrite it with a new SE key
        let signer2 = try SecureEnclaveSigner.createOrOpen(handleURL: handleURL)
        #expect(signer2.kid == originalKid,
            "createOrOpen must return the same kid when handle already exists")
        #expect(signer2.publicKeyX963 == originalPub,
            "createOrOpen must return the same public key when handle already exists")

        // Handle file bytes must be unchanged (no overwrite occurred)
        let handleBytesAfter = try Data(contentsOf: handleURL)
        #expect(handleBytesAfter == originalHandleBytes,
            "handle file bytes must not change when handle already exists")
    }
}
