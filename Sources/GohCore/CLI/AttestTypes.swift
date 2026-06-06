import Foundation
import CryptoKit

// MARK: - SignedVerifyReport (frozen attestation envelope, attestationVersion = 1)
//
// Field names, alg, ns, and payloadType raw values are FROZEN.
// A change bumps attestationVersion (+ media-type v=) and requires a new golden fixture.
// Encoder: CommandCoding.encoder (.iso8601, .sortedKeys) for the outer envelope.

/// The signed attestation artifact produced by `goh attest`.
///
/// The `payload` field carries the canonical `VerifyAllReport` JSON bytes (no trailing newline)
/// as standard base64. The signature covers `buildPAE(payloadType:payloadBytes:)` — never the
/// outer envelope — so verification requires only the bytes in this file.
public struct SignedVerifyReport: Codable, Sendable {

    /// Frozen payload type string (inside the signed PAE).
    public static let payloadType = "application/vnd.goh.verify-report+json; v=1"

    /// Namespace: prevents cross-context signature reuse (FROZEN).
    public static let namespace = "dev.goh.verify-report.v1"

    /// Always 1 for v1 of this envelope shape. Governs outer envelope parsing.
    public var attestationVersion: Int          // do NOT rename
    /// FROZEN: "application/vnd.goh.verify-report+json; v=1"
    public var payloadType: String              // do NOT rename — key "payloadType"
    /// Standard base64 (NOT base64url) of the canonical payload bytes. Key: "payload".
    public var payloadBase64: String            // do NOT rename — key "payload"
    /// Cryptographic signature block.
    public var sig: SigBlock                    // do NOT rename

    public init(
        attestationVersion: Int = 1,
        payloadType: String,
        payloadBase64: String,
        sig: SigBlock
    ) {
        self.attestationVersion = attestationVersion
        self.payloadType = payloadType
        self.payloadBase64 = payloadBase64
        self.sig = sig
    }

    // MARK: - CodingKeys (wire key "payload", not "payloadBase64")

    enum CodingKeys: String, CodingKey {
        case attestationVersion
        case payloadType
        case payloadBase64 = "payload"   // wire name is "payload"
        case sig
    }

    // MARK: - SigBlock

    /// The cryptographic signature block. All field names are FROZEN.
    public struct SigBlock: Codable, Sendable {
        /// Namespace; prevents cross-context replay. FROZEN: "dev.goh.verify-report.v1"
        public var ns: String               // do NOT rename
        /// Algorithm. FROZEN: "ES256" (ECDSA P-256 + SHA-256)
        public var alg: String              // do NOT rename
        /// 8 hex chars: hex(SHA256(pub.x963Representation)[0..3])
        public var kid: String              // do NOT rename
        /// base64url(publicKey.x963Representation, 65 bytes) — NO padding. Key: "pub"
        public var pubBase64url: String     // do NOT rename — key "pub"
        /// base64url(signature.rawRepresentation, 64 bytes r‖s) — NO padding. Key: "sig"
        public var sigBase64url: String     // do NOT rename — key "sig"

        public init(ns: String, alg: String, kid: String, pubBase64url: String, sigBase64url: String) {
            self.ns = ns
            self.alg = alg
            self.kid = kid
            self.pubBase64url = pubBase64url
            self.sigBase64url = sigBase64url
        }

        enum CodingKeys: String, CodingKey {
            case ns
            case alg
            case kid
            case pubBase64url = "pub"    // wire name is "pub"
            case sigBase64url = "sig"    // wire name is "sig"
        }
    }

    // MARK: - PAE builder (FROZEN byte layout)

    /// Builds the DSSE Pre-Authentication Encoding signing input.
    ///
    /// `PAE = "DSSEv1" SP ASCII(len(payloadType)) SP payloadType SP ASCII(len(payload)) SP payload`
    ///
    /// Where SP = 0x20, lengths are ASCII-decimal byte counts (UTF-8 length of payloadType,
    /// byte count of payloadBytes). This is the ONLY value that is signed or verified;
    /// the outer envelope is never re-serialized on the verify path.
    public static func buildPAE(payloadType: String, payloadBytes: Data) -> Data {
        var pae = Data()
        let prefix = "DSSEv1 \(payloadType.utf8.count) \(payloadType) \(payloadBytes.count) "
        pae.append(contentsOf: prefix.utf8)
        pae.append(payloadBytes)
        return pae
    }

    // MARK: - kid derivation

    /// Derives the 8-hex-char key id from a P-256 public key.
    ///
    /// `kid = hex(SHA256(publicKey.x963Representation)[0..3])`
    public static func deriveKid(from publicKey: P256.Signing.PublicKey) -> String {
        let hash = SHA256.hash(data: publicKey.x963Representation)
        return hash.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - VerifyAttestationResult (frozen --json result, resultVersion = 1)
//
// Field names and verdict raw values are FROZEN — do NOT rename.
// The golden fixture Tests/GohCoreTests/Fixtures/verify-attestation-result-v1.json
// enforces this: any schema change will fail the encode-equals test.

/// The JSON result emitted by `goh verify-attestation --json`. Frozen at resultVersion 1.
public struct VerifyAttestationResult: Codable, Equatable, Sendable {
    /// Always 1 for v1; bump only if a field name/type or enum raw value changes.
    public var resultVersion: Int               // do NOT rename
    /// The `attestationVersion` from the parsed artifact.
    public var attestationVersion: Int          // do NOT rename
    /// True iff the ECDSA signature verified correctly against the embedded public key.
    public var signatureValid: Bool             // do NOT rename
    /// True iff `--expect-key` matched or `--allow-untrusted-key` was passed.
    public var keyTrusted: Bool                 // do NOT rename
    /// The 8-hex kid from the artifact's sig block.
    public var kid: String                      // do NOT rename
    /// The payloadType from the artifact.
    public var payloadType: String              // do NOT rename
    /// Inner VerifyAllReport verdict: "ok" | "failed" | "missing"; nil if signatureValid==false.
    public var verdict: String?                 // do NOT rename; nil → key absent in JSON

    public init(
        resultVersion: Int = 1,
        attestationVersion: Int,
        signatureValid: Bool,
        keyTrusted: Bool,
        kid: String,
        payloadType: String,
        verdict: String?
    ) {
        self.resultVersion = resultVersion
        self.attestationVersion = attestationVersion
        self.signatureValid = signatureValid
        self.keyTrusted = keyTrusted
        self.kid = kid
        self.payloadType = payloadType
        self.verdict = verdict
    }
}

/// The inner VerifyAllReport verdict derived from its summary.
/// FROZEN raw values — do NOT rename.
public enum AttestVerdict: String, Sendable {
    case ok       // summary.missing == 0 && summary.failed == 0 — do NOT rename
    case failed   // summary.failed > 0 && summary.missing == 0 — do NOT rename
    case missing  // summary.missing > 0 — do NOT rename (precedence over failed)
}

// MARK: - Data + base64url helper

extension Data {
    /// Standard base64url encoding: URL-safe alphabet (`-` and `_`), no padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode a base64url string (URL-safe alphabet, no padding).
    init?(base64URLEncoded string: String) {
        // Re-add padding
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder != 0 {
            s += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: s) else { return nil }
        self = data
    }
}
