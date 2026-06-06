import Foundation
import CryptoKit

/// CLI runner for `goh verify-attestation <file> [--expect-key <kid|pubkey>] [--allow-untrusted-key] [--json]`.
///
/// Parses a `SignedVerifyReport` envelope, reconstructs the DSSE-PAE from the embedded
/// payloadType + payload, and verifies the signature against the **embedded public key**.
/// Never reads `keys.json` — verification is offline + cross-machine from artifact bytes alone.
///
/// Exit codes:
///   0  — signature VALID AND key TRUSTED (--expect-key matched or --allow-untrusted-key)
///   1  — signature VALID but key identity NOT verified (no --expect-key, no --allow-untrusted-key)
///         FAIL-CLOSED DEFAULT so `verify-attestation && deploy` is safe.
///   2  — signature INVALID (payload tampered / bad signature / pub mismatch)
///   3  — --expect-key mismatch (valid signature, wrong key)
///   6  — malformed/unparseable artifact or unknown attestationVersion / media-type v=
///   64 — usage error
public enum GohVerifyAttestationCommand {

    /// Runs `goh verify-attestation`.
    ///
    /// - Parameters:
    ///   - artifactPath: Path to the `SignedVerifyReport` JSON file.
    ///   - expectKey: Optional `--expect-key` value: 8-hex kid (hint) or full base64url x963 pubkey.
    ///   - allowUntrustedKey: `--allow-untrusted-key` opt-in: valid sig → exit 0 regardless of pin.
    ///   - json: `--json` flag: emit a `VerifyAttestationResult` JSON instead of human text.
    public static func run(
        artifactPath: String,
        expectKey: String?,
        allowUntrustedKey: Bool,
        json: Bool
    ) -> GohCommandLineResult {

        // ── Step 1: Read + parse envelope ─────────────────────────────────────
        guard let artifactData = try? Data(contentsOf: URL(fileURLWithPath: artifactPath)) else {
            let msg = "verify-attestation: cannot read artifact file: \(artifactPath)\n"
            return GohCommandLineResult(exitCode: 6, standardError: msg)
        }

        let envelope: SignedVerifyReport
        do {
            envelope = try CommandCoding.decoder.decode(SignedVerifyReport.self, from: artifactData)
        } catch {
            let msg = "verify-attestation: malformed artifact (JSON parse failed): \(error)\n"
            return GohCommandLineResult(exitCode: 6, standardError: msg)
        }

        // ── Step 2: Version gate ───────────────────────────────────────────────
        guard envelope.attestationVersion == 1 else {
            let msg = "verify-attestation: unknown attestationVersion \(envelope.attestationVersion) — "
                + "this version of goh does not support it\n"
            return GohCommandLineResult(exitCode: 6, standardError: msg)
        }
        // Media-type version must match (v=1 for attestationVersion 1)
        guard envelope.payloadType == SignedVerifyReport.payloadType else {
            let msg = "verify-attestation: unsupported payloadType '\(envelope.payloadType)'\n"
            return GohCommandLineResult(exitCode: 6, standardError: msg)
        }

        // ── Step 3: Decode payload + reconstruct PAE ──────────────────────────
        guard let payloadBytes = Data(base64Encoded: envelope.payloadBase64),
              !payloadBytes.isEmpty else {
            return GohCommandLineResult(exitCode: 6,
                standardError: "verify-attestation: malformed payload base64\n")
        }

        let pae = SignedVerifyReport.buildPAE(
            payloadType: envelope.payloadType,
            payloadBytes: payloadBytes)

        // ── Step 4: Decode sig + pub ───────────────────────────────────────────
        guard let pubX963 = Data(base64URLEncoded: envelope.sig.pubBase64url),
              let rawSig = Data(base64URLEncoded: envelope.sig.sigBase64url) else {
            return GohCommandLineResult(exitCode: 6,
                standardError: "verify-attestation: malformed pub or sig base64url\n")
        }

        let pub: P256.Signing.PublicKey
        do {
            pub = try P256.Signing.PublicKey(x963Representation: pubX963)
        } catch {
            return GohCommandLineResult(exitCode: 6,
                standardError: "verify-attestation: malformed public key: \(error)\n")
        }

        let sig: P256.Signing.ECDSASignature
        do {
            sig = try P256.Signing.ECDSASignature(rawRepresentation: rawSig)
        } catch {
            return GohCommandLineResult(exitCode: 6,
                standardError: "verify-attestation: malformed signature: \(error)\n")
        }

        // ── Step 5: Verify signature against embedded pub ─────────────────────
        let signatureValid = pub.isValidSignature(sig, for: pae)

        // ── Step 6: Derive verdict from payload (only when sig is valid) ───────
        var verdict: String? = nil
        if signatureValid,
           let report = try? CommandCoding.decoder.decode(VerifyAllReport.self, from: payloadBytes) {
            if report.summary.missing > 0 {
                verdict = AttestVerdict.missing.rawValue
            } else if report.summary.failed > 0 {
                verdict = AttestVerdict.failed.rawValue
            } else {
                verdict = AttestVerdict.ok.rawValue
            }
        }

        // ── Step 7: Key trust evaluation ──────────────────────────────────────
        let kid = envelope.sig.kid
        var keyTrusted = false
        var exitCode: Int32

        if !signatureValid {
            exitCode = 2
            // keyTrusted stays false; verdict stays nil
        } else if let expectKey {
            // --expect-key: match against kid (8-hex hint) or full pubkey (strong pin)
            let kidMatch = (expectKey == kid)
            let pubMatch = (expectKey == envelope.sig.pubBase64url)
            if kidMatch || pubMatch {
                keyTrusted = true
                exitCode = 0
            } else {
                keyTrusted = false
                exitCode = 3
            }
        } else if allowUntrustedKey {
            keyTrusted = true
            exitCode = 0
        } else {
            // Fail-closed default: valid but identity unverified
            keyTrusted = false
            exitCode = 1
        }

        // ── Step 8: Emit result ────────────────────────────────────────────────
        let result = VerifyAttestationResult(
            resultVersion: 1,
            attestationVersion: envelope.attestationVersion,
            signatureValid: signatureValid,
            keyTrusted: keyTrusted,
            kid: kid,
            payloadType: envelope.payloadType,
            verdict: verdict)

        if json {
            guard let data = try? CommandCoding.encoder.encode(result) else {
                return GohCommandLineResult(exitCode: exitCode, standardOutput: "")
            }
            return GohCommandLineResult(
                exitCode: exitCode,
                standardOutput: String(decoding: data, as: UTF8.self) + "\n")
        }

        // Human output
        let statusLine: String
        switch exitCode {
        case 0:
            statusLine = "VALID — signature OK, key trusted (kid: \(kid), verdict: \(verdict ?? "unknown"))\n"
        case 1:
            statusLine = "VALID — but key identity NOT verified (kid: \(kid))\n"
                + "  Pass --expect-key \(kid) to pin this key, or --allow-untrusted-key to accept tamper-evidence only.\n"
        case 2:
            statusLine = "INVALID — signature verification failed\n"
        case 3:
            statusLine = "MISMATCH — valid signature but --expect-key does not match (artifact kid: \(kid))\n"
        default:
            statusLine = "ERROR\n"
        }
        return GohCommandLineResult(exitCode: exitCode, standardOutput: statusLine)
    }
}
