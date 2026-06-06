---
date: 2026-06-06
feature: hardware-attested-provenance
REQUIRED_SKILL: superpowers:subagent-driven-development
Goal: Add `goh attest` (sign a verify-all report with a Secure Enclave P-256 key) and `goh verify-attestation` (offline signature verification) — hardware-rooted, tamper-evident, cross-machine-verifiable, purely additive.
Architecture: The Signed Receipt (Approach A) — one SE key signs the whole verify-all report; verification uses only the embedded public key.
Tech Stack: Swift 6.2/6.3 (Swift 6 language mode, nonisolated-default on GohCore), macOS 26.0+ Apple Silicon; CryptoKit (SHA-256 existing; new: SecureEnclave.P256.Signing ECDSA + P256.Signing.PublicKey verify); Foundation; CommandCoding.encoder (.iso8601, .sortedKeys); Swift Testing; CI -warnings-as-errors on macos-26; local needs DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer.
---

# Implementation Plan — Hardware-attested provenance (`goh attest` / `goh verify-attestation`)

## Acceptance criteria map

| AC | Description | Owning task |
|----|-------------|-------------|
| AC1 | Sign→verify round-trip valid; tampered payload → INVALID (distinct exit/status from SHA-256 mismatch) | Task 3 (signer) + Task 7 (verify-attestation) |
| AC2 | Additive + never fatal; all existing verify/which paths unchanged; attest-with-no-key exits 5, ledger intact | Task 6 (attest) + Task 9 (integration) |
| AC3 | Recipient verifies offline using only embedded public key — no SE, no network | Task 3 (verify path) + Task 7 |
| AC4 | Hardware-rooted: SE P-256 key; private material persisted as opaque handle only | Task 3 (SE signer) |
| AC5 | Frozen-format integrity: existing golden fixtures pass; new schemas versioned + golden-fixtured | Task 2 (AttestTypes) + Task 5 (artifact fixture) + Task 7 (result fixture) |

## Bet check (Phase 1 rationale)

> "The highest-value attestation is the portable verify REPORT (a proof you share), not signing every
> ledger entry — report attestation alone delivers the headline with a fraction of the surface."
>
> This plan signs ONE VerifyAllReport per `goh attest` invocation. No per-entry signatures, no
> ProvenanceRecord changes, no daemon involvement. The SE key is CLI-local. Existing verify/which/which
> paths are untouched (AC2/AC5).

## CI note — Secure Enclave availability

The CI `macos-26` runner is a VM. **The Secure Enclave may not be available** (`SecureEnclave.isAvailable
== false` in a VM). The plan handles this in two ways:

1. **All VERIFY-path tests** (parsing, signature checking, result schema) use a **software
   `P256.Signing.PrivateKey`** — they never touch the SE and run everywhere, including CI.
2. **SIGN/attest tests** that require a real SE key are gated:
   ```swift
   guard SecureEnclave.isAvailable else { return }  // skip gracefully in CI VM
   ```
   The golden artifact fixture (`signed-verify-report-v1.json`) is signed with a **throwaway software
   P256 key** so the fixture-driven verify tests run in CI without SE. The fixture is committed to the
   repo; its embedded `pub` is the fixture key's public key. The SE availability guard only applies to
   tests that call `SecureEnclaveSigner.createOrOpen(at:)` directly.

## Phase structure

> 10 tasks → 3 phases segmented at deployment-independence boundaries.
> Phase artifacts: `docs/superpowers/progress/2026-06-06-hardware-attested-provenance-phase{1,2,3}.md`

- **Phase 1 (Tasks 1–3):** Crypto core — `AttestKeyLocation`, `AttestTypes` (envelope/PAE/result
  schemas + PAE builder), `SecureEnclaveSigner`. All unit-testable with a software P256 key. No CLI
  surface; no existing file modified.
- **Phase 2 (Tasks 4–6):** `goh attest` verb — encode seam factoring in
  `GohVerifyAllCommand`, golden artifact fixture, `GohAttestCommand`.
- **Phase 3 (Tasks 7–10):** `goh verify-attestation` verb + CLI parse/dispatch/usage wiring +
  integration test suite + full health check.

---

## Phase 1 — Crypto core

### Task 1 — CREATE `Sources/GohCore/CLI/AttestKeyLocation.swift`

**Files**
- CREATE `Sources/GohCore/CLI/AttestKeyLocation.swift`

**Pre-task reads**
- [x] `Sources/GohCore/Provenance/ProvenanceStoreLocation.swift` — mirror the `defaultURL(create:)`
  resolver pattern; note the `create: false` invariant for CLI read paths; `GohXPCService.machServiceName`
  usage for the support directory
- [x] `Sources/GohCore/Provenance/ProvenanceStore.swift` — the atomic write idiom
  (temp→chmod 0600→fsync→rename→fsync(dir)) to reuse for keys.json + handle writes

**Step 1 — Failing test**

File: `Tests/GohCoreTests/AttestKeyLocationTests.swift` (CREATE)

```swift
import Foundation
import Testing
@testable import GohCore

// AC5: AttestKeyLocation resolves to a path separate from the daemon's store.
@Suite("AttestKeyLocation")
struct AttestKeyLocationTests {

    // AC5: resolver returns a path under dev.goh.attest, distinct from dev.goh.daemon
    @Test("resolver returns ~/Library/Application Support/dev.goh.attest/ paths")
    func resolverReturnsAttestPaths() throws {
        let handleURL = try AttestKeyLocation.signingKeyHandleURL(create: false)
        let keysURL = try AttestKeyLocation.keysJSONURL(create: false)

        // Must be under the attest directory, not the daemon directory
        #expect(handleURL.path.contains("dev.goh.attest"))
        #expect(keysURL.path.contains("dev.goh.attest"))
        #expect(!handleURL.path.contains("dev.goh.daemon"))
        #expect(!keysURL.path.contains("dev.goh.daemon"))

        // File names
        #expect(handleURL.lastPathComponent == "signing-key.handle")
        #expect(keysURL.lastPathComponent == "keys.json")

        // Same parent directory
        #expect(handleURL.deletingLastPathComponent().path == keysURL.deletingLastPathComponent().path)
    }

    // AC5: create:false does NOT create the directory
    @Test("create:false does not create directory")
    func createFalseDoesNotCreateDirectory() throws {
        // Use a path in a temp location to confirm no directory creation
        let url = try AttestKeyLocation.signingKeyHandleURL(create: false)
        // We can only assert it returns a URL without throwing; actual directory
        // existence depends on whether the user has run `goh attest` before.
        // The key invariant: passing create:false must not throw even if the dir is absent.
        _ = url  // no assertion on existence — just that it doesn't throw
    }
}
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AttestKeyLocationTests 2>&1
```

Expected: compile error — `AttestKeyLocation` does not exist.

**Step 3 — Implementation**

CREATE `Sources/GohCore/CLI/AttestKeyLocation.swift`:

```swift
import Foundation

/// Resolves paths for the CLI-owned attest key store.
///
/// The attest key store lives at `~/Library/Application Support/dev.goh.attest/`
/// — a SEPARATE top-level directory from the daemon-owned `dev.goh.daemon/`.
/// This separation is intentional: the CLI's `attest` verb is a legitimate writer
/// of its own store; the daemon's provenance store is untouched.
///
/// The `create: true` path is ONLY taken by `goh attest` (which creates the key).
/// All read paths — including `goh verify-attestation` — use `create: false` and
/// never touch this directory.
public enum AttestKeyLocation {

    /// The attest support directory bundle identifier.
    static let bundleID = "dev.goh.attest"

    /// `~/Library/Application Support/dev.goh.attest/signing-key.handle`
    ///
    /// - Parameter create: When `true`, creates the `dev.goh.attest` directory
    ///   (mode 0700) with `withIntermediateDirectories: true`. When `false`,
    ///   no directory is created; a missing directory is "no key" (caller handles).
    public static func signingKeyHandleURL(create: Bool) throws -> URL {
        try attestDirectoryURL(create: create).appending(path: "signing-key.handle")
    }

    /// `~/Library/Application Support/dev.goh.attest/keys.json`
    ///
    /// - Parameter create: Same semantics as `signingKeyHandleURL(create:)`.
    public static func keysJSONURL(create: Bool) throws -> URL {
        try attestDirectoryURL(create: create).appending(path: "keys.json")
    }

    // MARK: - Private

    static func attestDirectoryURL(create: Bool) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: create)
        let directory = support.appending(path: bundleID, directoryHint: .isDirectory)
        if create {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        return directory
    }
}
```

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AttestKeyLocationTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: both tests pass; build clean.

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/AttestKeyLocation.swift Tests/GohCoreTests/AttestKeyLocationTests.swift
git commit -m "feat(attest): add AttestKeyLocation resolver for CLI-owned attest key store"
```

---

### Task 2 — CREATE `Sources/GohCore/CLI/AttestTypes.swift`

**Files**
- CREATE `Sources/GohCore/CLI/AttestTypes.swift`

**Pre-task reads**
- [x] `Sources/GohCore/Model/CommandCoding.swift` — `CommandCoding.encoder` (`.iso8601`,
  `.sortedKeys`); this encoder is used for the envelope; `CommandCoding.decoder` for parsing
- [x] `Sources/GohCore/CLI/VerifyReportTypes.swift` — `VerifyAllReport`, `VerifySummary` fields
  used to derive the `verdict` in `VerifyAttestationResult`
- [x] `Tests/GohCoreTests/Fixtures/verify-all-report-v1.json` — confirmed 806 bytes, NO trailing
  newline (last byte `}` = 0x7d at offset 0x325); `payload_bytes` must equal these exact bytes

**Step 1 — Failing tests**

File: `Tests/GohCoreTests/AttestTypesTests.swift` (CREATE)

```swift
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
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AttestTypesTests 2>&1
```

Expected: compile errors — `SignedVerifyReport`, `VerifyAttestationResult`, `AttestVerdict` do not exist.

**Step 3 — Implementation**

CREATE `Sources/GohCore/CLI/AttestTypes.swift`:

```swift
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
```

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AttestTypesTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: all 7 tests pass; build clean.

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/AttestTypes.swift Tests/GohCoreTests/AttestTypesTests.swift
git commit -m "feat(attest): add SignedVerifyReport envelope, PAE builder, VerifyAttestationResult types (attestationVersion=1)"
```

---

### Task 3 — CREATE `Sources/GohCore/TrustCore/SecureEnclaveSigner.swift`

**Files**
- CREATE `Sources/GohCore/TrustCore/SecureEnclaveSigner.swift`

**Pre-task reads**
- [x] `Sources/GohCore/TrustCore/FileDigest.swift` — CryptoKit import pattern; the module is
  `nonisolated`-default; no actors
- [x] `Sources/GohCore/Provenance/ProvenanceStore.swift` — `writeAtomically` idiom
  (temp→chmod 0600→fsync→rename→fsync(dir)) lines 206–228; `fsync(path:)` helper lines 230–239
- [x] `Sources/GohCore/CLI/AttestTypes.swift` (just created) — `SignedVerifyReport.deriveKid(from:)`,
  `Data.base64URLEncodedString()`
- [x] `Sources/GohCore/CLI/AttestKeyLocation.swift` (just created) — `signingKeyHandleURL(create:)`,
  `keysJSONURL(create:)`

**Step 1 — Failing tests**

File: `Tests/GohCoreTests/SecureEnclaveSignerTests.swift` (CREATE)

```swift
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
    @Test("AC4: createOrOpen creates a handle file and persists only opaque bytes")
    func createOrOpenPersistsHandle() throws {
        // AC4: hardware-rooted — private material is only the opaque handle
        guard SecureEnclave.isAvailable else { return }  // skip in CI VM without SE

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
    @Test("AC1/AC4: SE signer sign→verify round-trip")
    func seSignerRoundTrip() throws {
        // AC1: tamper-evident; AC4: hardware-rooted
        guard SecureEnclave.isAvailable else { return }

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
    @Test("createOrOpen is idempotent: same kid on second open")
    func createOrOpenIsIdempotent() throws {
        guard SecureEnclave.isAvailable else { return }

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
    @Test("createOrOpen: handle already present → opens existing key, does not clobber")
    func createOrOpenDoesNotClobberExistingHandle() throws {
        guard SecureEnclave.isAvailable else { return }

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
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SecureEnclaveSignerTests 2>&1
```

Expected: compile errors — `SecureEnclaveSigner` does not exist.

**Step 3 — Implementation**

CREATE `Sources/GohCore/TrustCore/SecureEnclaveSigner.swift`:

```swift
import Darwin
import Foundation
import CryptoKit

/// Errors from SecureEnclaveSigner operations.
public enum SecureEnclaveSignerError: Error {
    /// Secure Enclave is not available on this machine (VM / no SE hardware).
    case secureEnclaveUnavailable
    /// Failed to create the SE key.
    case keyCreationFailed(underlying: Error)
    /// Failed to re-open an existing SE key handle.
    case keyOpenFailed(underlying: Error)
    /// Failed to sign the given data.
    case signingFailed(underlying: Error)
    /// Atomic write to the handle file failed.
    case handleWriteFailed(path: String, underlying: Error)
    /// O_EXCL create raced — the handle already exists, caller should re-open.
    case handleAlreadyExists
}

/// A create-or-open wrapper for a `SecureEnclave.P256.Signing.PrivateKey`.
///
/// Private material is persisted ONLY as the opaque `dataRepresentation` (~284B)
/// to a 0600 file (the "handle"). The public key's 65-byte `x963Representation`
/// is exportable and is embedded in every signed artifact.
///
/// **Concurrency:** the signer is `Sendable`; each method is safe to call from
/// any context. The SE key handle is immutable after `createOrOpen`.
///
/// **SE availability:** `SecureEnclave.isAvailable` must be checked before calling
/// `createOrOpen`. If the Secure Enclave is unavailable (e.g. in a CI VM),
/// `createOrOpen` throws `SecureEnclaveSignerError.secureEnclaveUnavailable`.
public struct SecureEnclaveSigner: Sendable {

    /// The 8-hex key identifier: `hex(SHA256(publicKey.x963Representation)[0..3])`.
    public let kid: String

    /// The 65-byte x963 public key, exportable for embedding in the signed artifact.
    public let publicKeyX963: Data

    private let privateKey: SecureEnclave.P256.Signing.PrivateKey

    // MARK: - Create or open

    /// Opens the SE key from `handleURL` if the file exists; otherwise creates a new
    /// `SecureEnclave.P256.Signing.PrivateKey`, persists the handle with `O_CREAT|O_EXCL`
    /// (exclusive create — if two concurrent first-run `attest` calls race, one wins and
    /// the loser opens the winner's handle), and returns the signer.
    ///
    /// **Handle file:** `handleURL` parent directory must already exist (caller's responsibility
    /// via `AttestKeyLocation.attestDirectoryURL(create: true)`).
    ///
    /// **Crash safety:** the handle is written via a full `write(2)` + `fsync` + `close`
    /// sequence on a file opened with `O_CREAT|O_EXCL|O_WRONLY`. A crash before the `write`
    /// completes leaves no file (clean retry); a crash after `fsync` + `close` leaves a valid,
    /// reusable handle. No key material is ever lost.
    ///
    /// - Throws: `SecureEnclaveSignerError.secureEnclaveUnavailable` if SE is absent.
    public static func createOrOpen(handleURL: URL) throws -> SecureEnclaveSigner {
        guard SecureEnclave.isAvailable else {
            throw SecureEnclaveSignerError.secureEnclaveUnavailable
        }

        if FileManager.default.fileExists(atPath: handleURL.path) {
            return try openExisting(handleURL: handleURL)
        } else {
            return try createNew(handleURL: handleURL)
        }
    }

    // MARK: - Sign

    /// Signs the given PAE bytes with the SE key.
    ///
    /// Returns the 64-byte raw representation (`r ‖ s`) of the ECDSA-P256-SHA256 signature.
    /// ECDSA is non-deterministic: signing the same data twice yields different bytes.
    ///
    /// - Parameter pae: The DSSE Pre-Authentication Encoding bytes to sign.
    /// - Returns: 64 bytes: `signature.rawRepresentation`.
    /// - Throws: `SecureEnclaveSignerError.signingFailed` if the SE rejects the operation.
    public func sign(pae: Data) throws -> Data {
        do {
            let sig = try privateKey.signature(for: pae)
            return sig.rawRepresentation
        } catch {
            throw SecureEnclaveSignerError.signingFailed(underlying: error)
        }
    }

    // MARK: - Private helpers

    private init(privateKey: SecureEnclave.P256.Signing.PrivateKey) {
        self.privateKey = privateKey
        let pub = privateKey.publicKey
        self.publicKeyX963 = pub.x963Representation
        self.kid = SignedVerifyReport.deriveKid(from: pub)
    }

    private static func createNew(handleURL: URL) throws -> SecureEnclaveSigner {
        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey()
        } catch {
            throw SecureEnclaveSignerError.keyCreationFailed(underlying: error)
        }

        // Persist handle with O_CREAT|O_EXCL — exclusive create-if-absent.
        // On EEXIST: another concurrent first-run `attest` won the race → open its handle.
        let handleData = key.dataRepresentation
        do {
            try writeExclusive(data: handleData, to: handleURL)
        } catch SecureEnclaveSignerError.handleAlreadyExists {
            // Race: another `attest` call created the handle first — open the winner's key.
            return try openExisting(handleURL: handleURL)
        }

        return SecureEnclaveSigner(privateKey: key)
    }

    private static func openExisting(handleURL: URL) throws -> SecureEnclaveSigner {
        guard let handleData = try? Data(contentsOf: handleURL) else {
            throw SecureEnclaveSignerError.keyOpenFailed(
                underlying: CocoaError(.fileReadNoSuchFile))
        }
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: handleData)
            return SecureEnclaveSigner(privateKey: key)
        } catch {
            throw SecureEnclaveSignerError.keyOpenFailed(underlying: error)
        }
    }

    /// Exclusive create-and-write: `open(O_CREAT|O_EXCL|O_WRONLY, 0o600)` → full write loop →
    /// `fsync` → `close` → `fsync(dir)`.
    ///
    /// This is the spec §4 "O_EXCL create-if-absent" guarantee. Unlike `rename(2)` (which
    /// atomically REPLACES its destination and never returns EEXIST), `O_CREAT|O_EXCL` fails
    /// with EEXIST when the file already exists — giving a true exclusive-create semantic.
    ///
    /// On EEXIST: throws `SecureEnclaveSignerError.handleAlreadyExists`; caller opens existing.
    /// On any other error: throws `SecureEnclaveSignerError.handleWriteFailed`.
    private static func writeExclusive(data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR) // 0o600
        if fd < 0 {
            let e = errno
            if e == EEXIST {
                throw SecureEnclaveSignerError.handleAlreadyExists
            }
            throw SecureEnclaveSignerError.handleWriteFailed(
                path: url.path,
                underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(e)))
        }
        defer { Darwin.close(fd) }

        // Full write loop (handles short writes on large data, though SE handles are ~284B)
        var written = 0
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            while written < data.count {
                let n = Darwin.write(fd, ptr.baseAddress!.advanced(by: written), data.count - written)
                if n < 0 {
                    let e = errno
                    throw SecureEnclaveSignerError.handleWriteFailed(
                        path: url.path,
                        underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(e)))
                }
                written += n
            }
        }

        guard Darwin.fsync(fd) == 0 else {
            throw SecureEnclaveSignerError.handleWriteFailed(
                path: url.path,
                underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        // fsync the parent directory to flush the new directory entry
        try fsyncFile(path: url.deletingLastPathComponent().path)
    }

    /// Fsync a file or directory at `path` for durability.
    ///
    /// Matches `ProvenanceStore.fsync(path:)` convention: throws on BOTH data-fd AND
    /// dir-fd fsync failures (the project treats both as durability-critical).
    /// `guard fd >= 0 else { return }` is retained for the directory-open case to mirror
    /// the ProvenanceStore pattern (a missing directory is not a crash-safety issue here —
    /// the handle itself was already fsynced above before this call).
    private static func fsyncFile(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard Darwin.fsync(fd) == 0 else {
            throw SecureEnclaveSignerError.handleWriteFailed(
                path: path,
                underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
    }
}
```

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SecureEnclaveSignerTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected:
- Software-key tests (`softwareKeySignVerifyRoundTrip`, `publicKeyX963RoundTrip`, `kidIsDeterministic`):
  PASS on CI and locally.
- SE-gated tests (`createOrOpenPersistsHandle`, `seSignerRoundTrip`, `createOrOpenIsIdempotent`,
  `createOrOpenDoesNotClobberExistingHandle`): PASS locally (SE available); graceful skip in CI VM
  (`guard SecureEnclave.isAvailable else { return }`).
- Build: clean, zero warnings.

**Step 5 — Commit**

```
git add Sources/GohCore/TrustCore/SecureEnclaveSigner.swift Tests/GohCoreTests/SecureEnclaveSignerTests.swift
git commit -m "feat(attest): add SecureEnclaveSigner — create-or-open SE P-256 key, atomic handle persist, sign(pae:)"
```

---

## Phase 2 — `goh attest` verb

### Task 4 — Factor encode seam in `GohVerifyAllCommand`

**Files**
- MODIFY `Sources/GohCore/CLI/GohVerifyAllCommand.swift`

**Pre-task reads**
- [x] `Sources/GohCore/CLI/GohVerifyAllCommand.swift` — the WHOLE file.
  CRITICAL: the `jsonResult(exitCode:report:)` private helper at lines 202–210:
  ```swift
  private static func jsonResult(exitCode: Int32, report: VerifyAllReport) -> GohCommandLineResult {
      guard let data = try? CommandCoding.encoder.encode(report) else {
          return GohCommandLineResult(exitCode: exitCode, standardOutput: "")
      }
      return GohCommandLineResult(
          exitCode: exitCode,
          standardOutput: String(decoding: data, as: UTF8.self) + "\n")
  }
  ```
  The encode step is INLINE here. The plan factors out a PUBLIC `payloadBytes(for:) -> Data?` method
  that returns `CommandCoding.encoder.encode(report)` (NO newline). The `jsonResult` helper is then
  rewritten to call this seam. The stdout path continues to append `"\n"` (frozen, behavior unchanged).
- [x] `Tests/GohCoreTests/Fixtures/verify-all-report-v1.json` — 806 bytes, NO trailing newline.
  The new test pins `payloadBytes` == these exact 806 bytes.

**Step 1 — Failing test**

File: `Tests/GohCoreTests/GohVerifyAllPayloadBytesTests.swift` (CREATE)

```swift
import Foundation
import Testing
@testable import GohCore

// AC5 / crypto-critical: payload_bytes == fixture bytes (no newline)
// This is B1 from the spec: payload_bytes = CommandCoding.encoder.encode(report) with NO trailing newline.
@Suite("GohVerifyAllCommand — payloadBytes seam")
struct GohVerifyAllPayloadBytesTests {

    // AC5/B1: payloadBytes returns encoder output with NO trailing newline
    @Test("AC5/B1: payloadBytes(for:) == verify-all-report-v1.json fixture bytes (no trailing newline)")
    func payloadBytesMatchFixture() throws {
        // Construct the exact same report as the golden fixture
        let fixedDate = Date(timeIntervalSince1970: 1_714_262_400)
        let report = VerifyAllReport(
            reportVersion: 1,
            generatedAt: fixedDate,
            summary: VerifySummary(total: 3, ok: 1, failed: 1, missing: 1),
            entries: [
                VerifyEntryResult(
                    path: "/private/tmp/goh-fixture/ok.bin",
                    url: "https://example.com/ok.bin",
                    status: .ok,
                    expectedSha256: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    actualSha256: nil),
                VerifyEntryResult(
                    path: "/private/tmp/goh-fixture/failed.bin",
                    url: "https://example.com/failed.bin",
                    status: .failed,
                    expectedSha256: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    actualSha256: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
                VerifyEntryResult(
                    path: "/private/tmp/goh-fixture/missing.bin",
                    url: "https://example.com/missing.bin",
                    status: .missing,
                    expectedSha256: "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                    actualSha256: nil),
            ])

        // B1: payloadBytes must equal the fixture bytes (no trailing newline)
        let payload = try #require(GohVerifyAllCommand.payloadBytes(for: report),
            "payloadBytes returned nil — encoding a valid value type should never fail")

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/verify-all-report-v1.json")
        let fixtureData = try Data(contentsOf: fixtureURL)

        // Byte-exact equality: payload_bytes must == fixture bytes
        #expect(payload == fixtureData,
            "payload_bytes differ from fixture — check CommandCoding.encoder settings or newline leakage")

        // Confirm no trailing newline (last byte must be '}' = 0x7d)
        #expect(payload.last == 0x7D, "payload_bytes must not end with a newline")
    }

    // AC5/B1: --json stdout path still appends '\n' (frozen behavior, not changed)
    @Test("AC5/B1: --json stdout output ends with '\\n' (frozen stdout behavior)")
    func jsonStdoutEndsWithNewline() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-payload-seam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixedDate = Date(timeIntervalSince1970: 1_714_262_400)
        let result = GohVerifyAllCommand.run(
            provenanceStorePath: dir.appendingPathComponent("absent.plist").path,
            json: true,
            generatedAt: fixedDate)

        // stdout MUST end with '\n' (frozen; terminal display convention)
        #expect(result.standardOutput.hasSuffix("\n"),
            "--json stdout must end with \\n (frozen stdout behavior must not change)")
    }
}
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllPayloadBytesTests 2>&1
```

Expected: compile error — `GohVerifyAllCommand.payloadBytes(for:)` does not exist.

**Step 3 — Implementation**

MODIFY `Sources/GohCore/CLI/GohVerifyAllCommand.swift` — add one public method and update `jsonResult`:

Add after the `private static func emptyReport(...)` helper (after line 199):

```swift
    /// Returns the canonical payload bytes for a `VerifyAllReport` — the encoder output
    /// with NO trailing newline.
    ///
    /// **Crypto-critical (B1):** this is `payload_bytes` for `goh attest`'s signing input.
    /// It is byte-identical to the golden `verify-all-report-v1.json` fixture.
    /// The `--json` stdout path appends `"\n"` AFTER this; never sign the stdout bytes.
    ///
    /// Returns `nil` only if `CommandCoding.encoder.encode` fails (a programming error —
    /// encoding a value type should never fail in practice).
    public static func payloadBytes(for report: VerifyAllReport) -> Data? {
        try? CommandCoding.encoder.encode(report)
    }
```

Update `jsonResult` to call the seam (replaces the inline encode):

```swift
    private static func jsonResult(exitCode: Int32, report: VerifyAllReport) -> GohCommandLineResult {
        guard let data = payloadBytes(for: report) else {
            // Defensive: encoding a value type should never fail.
            return GohCommandLineResult(exitCode: exitCode, standardOutput: "")
        }
        return GohCommandLineResult(
            exitCode: exitCode,
            standardOutput: String(decoding: data, as: UTF8.self) + "\n")
    }
```

No other changes. The `+ "\n"` on stdout is untouched (frozen behavior).

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllPayloadBytesTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllCommandJSONTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllCommandTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: all three suites pass (new + existing); build clean. The encode seam is now public for
`GohAttestCommand` to use directly.

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/GohVerifyAllCommand.swift Tests/GohCoreTests/GohVerifyAllPayloadBytesTests.swift
git commit -m "feat(attest): factor payloadBytes(for:) encode seam in GohVerifyAllCommand (no behavior change)"
```

---

### Task 5 — Commit golden artifact fixture `signed-verify-report-v1.json`

**Files**
- CREATE `Tests/GohCoreTests/Fixtures/signed-verify-report-v1.json`
- CREATE `Tests/GohCoreTests/Fixtures/verify-attestation-result-v1.json`

**Pre-task reads**
- [x] `Tests/GohCoreTests/Fixtures/verify-all-report-v1.json` — 806 bytes, the exact payload
  that will be embedded (base64-encoded) in the signed artifact fixture
- [x] `Sources/GohCore/CLI/AttestTypes.swift` — `SignedVerifyReport` field names/encoding;
  `CodingKeys` confirming wire keys ("payload", "pub", "sig"); `VerifyAttestationResult` fields

**Step 1 — No failing test yet**

The fixture-driven verify tests are in Task 7. This task creates the fixtures; Task 7 consumes them.

**Step 2 — Generate the fixtures**

The fixtures use a **throwaway software P256 key** (not SE) so they are:
- Reproducible: the key, report, and all other inputs are fixed
- CI-runnable: no SE required to verify the embedded signature

Run this one-time Swift snippet from the repo root to generate both fixtures:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift -e '
import Foundation
import CryptoKit

// ── Fixture key (throwaway — private key known only to test harness) ──────────
// The actual private key bytes are NOT committed; only the artifact (with embedded pub) is.
// To regenerate: run this script; the fixture key changes but the test still passes
// (it verifies the embedded pub, not a pinned key).
let key = P256.Signing.PrivateKey()
let pub = key.publicKey
let x963 = pub.x963Representation
let kid = SHA256.hash(data: x963).prefix(4).map { String(format: "%02x", $0) }.joined()

// ── Payload bytes — READ THE EXACT BYTES from the verify-all-report-v1.json fixture ──
// CRITICAL (BLOCK-3 fix / spec §3 B1): payload_bytes MUST be the exact bytes of the
// verify-all-report-v1.json fixture file. Do NOT re-synthesize the VerifyAllReport using
// a local struct + encoder — any difference in field order, date format, or whitespace
// produces different bytes and silently breaks the cross-fixture binding.
// The spec requires: base64-decode(artifact.payload) == verify-all-report-v1.json bytes.
let fixtureURL = URL(fileURLWithPath: "Tests/GohCoreTests/Fixtures/verify-all-report-v1.json")
let payloadBytes = try Data(contentsOf: fixtureURL)
precondition(payloadBytes.count == 806, "verify-all-report-v1.json must be 806 bytes; got \(payloadBytes.count) — was it edited?")
precondition(payloadBytes.last == 0x7D, "verify-all-report-v1.json must not end with a newline (last byte must be '}')")

let payloadType = "application/vnd.goh.verify-report+json; v=1"
let paePrefix = "DSSEv1 \(payloadType.utf8.count) \(payloadType) \(payloadBytes.count) "
var pae = Data()
pae.append(contentsOf: paePrefix.utf8)
pae.append(payloadBytes)

let sig = try key.signature(for: pae)
let rawSig = sig.rawRepresentation
precondition(rawSig.count == 64, "raw sig must be 64 bytes")

func b64url(_ d: Data) -> String {
    d.base64EncodedString()
     .replacingOccurrences(of: "+", with: "-")
     .replacingOccurrences(of: "/", with: "_")
     .replacingOccurrences(of: "=", with: "")
}

// ── signed-verify-report-v1.json ─────────────────────────────────────────────
struct SigBlock: Codable {
    var ns: String; var alg: String; var kid: String; var pub: String; var sig: String
}
struct SignedVerifyReport: Codable {
    var attestationVersion: Int; var payloadType: String; var payload: String
    var sig: SigBlock
}

let envelope = SignedVerifyReport(
    attestationVersion: 1,
    payloadType: payloadType,
    payload: payloadBytes.base64EncodedString(),
    sig: SigBlock(ns: "dev.goh.verify-report.v1", alg: "ES256", kid: kid,
                  pub: b64url(x963), sig: b64url(rawSig))
)
let envelopeEncoder = JSONEncoder()
envelopeEncoder.dateEncodingStrategy = .iso8601
envelopeEncoder.outputFormatting = [.sortedKeys]
let envelopeData = try envelopeEncoder.encode(envelope)
try envelopeData.write(to: URL(fileURLWithPath: "Tests/GohCoreTests/Fixtures/signed-verify-report-v1.json"))
print("signed-verify-report-v1.json: \(envelopeData.count) bytes")

// ── Cross-fixture binding assertion (BLOCK-3 fix) ─────────────────────────────
// Verify the round-trip: base64-decode(artifact.payload) must == verify-all-report-v1.json bytes.
// This pins the spec §3 requirement at generation time so any future regeneration
// that introduces a byte-level mismatch fails loudly here rather than silently at test time.
let writtenEnvelope = try JSONDecoder().decode(
    type(of: envelope), from: envelopeData)
let roundTrippedPayload = Data(base64Encoded: writtenEnvelope.payload)!
precondition(roundTrippedPayload == payloadBytes,
    "CROSS-FIXTURE BINDING BROKEN: base64-decoded artifact.payload != verify-all-report-v1.json bytes")
print("Cross-fixture binding OK: payload bytes round-trip verified (\(roundTrippedPayload.count) bytes)")

// ── verify-attestation-result-v1.json ────────────────────────────────────────
// Represents: signatureValid=true, keyTrusted=true (--allow-untrusted-key), verdict="missing"
// (the fixture report has 1 missing entry)
struct VerifyAttestationResult: Codable {
    var resultVersion: Int; var attestationVersion: Int
    var signatureValid: Bool; var keyTrusted: Bool; var kid: String
    var payloadType: String; var verdict: String?
}
let result = VerifyAttestationResult(
    resultVersion: 1, attestationVersion: 1,
    signatureValid: true, keyTrusted: true, kid: kid,
    payloadType: payloadType, verdict: "missing"
)
let resultEncoder = JSONEncoder()
resultEncoder.dateEncodingStrategy = .iso8601
resultEncoder.outputFormatting = [.sortedKeys]
let resultData = try resultEncoder.encode(result)
try resultData.write(to: URL(fileURLWithPath: "Tests/GohCoreTests/Fixtures/verify-attestation-result-v1.json"))
print("verify-attestation-result-v1.json: \(resultData.count) bytes")
print("kid: \(kid)")
print("Done.")
'
```

> IMPORTANT: Both files must have NO trailing newline. The `Data.write(to:)` API does not add
> newlines; do not open/re-save in an editor. Commit the raw bytes.
>
> After generation, confirm with `xxd`:
> ```
> xxd Tests/GohCoreTests/Fixtures/signed-verify-report-v1.json | tail -3
> xxd Tests/GohCoreTests/Fixtures/verify-attestation-result-v1.json | tail -3
> ```
> Last byte of each must be `7d` (`}`).

**Step 3 — Confirm fixtures exist, are valid JSON, and cross-fixture binding holds**

```
python3 -c "import json,sys; json.load(open('Tests/GohCoreTests/Fixtures/signed-verify-report-v1.json'))" && echo OK
python3 -c "import json,sys; json.load(open('Tests/GohCoreTests/Fixtures/verify-attestation-result-v1.json'))" && echo OK
```

Both must print `OK`.

Also verify the cross-fixture binding (spec §3 B1) at the shell:

```
python3 -c "
import json, base64, sys
art = json.load(open('Tests/GohCoreTests/Fixtures/signed-verify-report-v1.json'))
payload_bytes = base64.b64decode(art['payload'])
fixture_bytes = open('Tests/GohCoreTests/Fixtures/verify-all-report-v1.json', 'rb').read()
assert payload_bytes == fixture_bytes, f'MISMATCH: artifact.payload ({len(payload_bytes)}B) != verify-all-report-v1.json ({len(fixture_bytes)}B)'
print(f'Cross-fixture binding OK: {len(payload_bytes)} bytes')
"
```

Must print `Cross-fixture binding OK: 806 bytes`.

> **Committed test (BLOCK-3 fix):** The cross-fixture binding test in
> `GohVerifyAttestationCommandTests` (Task 7) contains a `payloadCrossFixtureBinding` test that
> asserts `Data(base64Encoded: artifact.payload) == Data(contentsOf: verify-all-report-v1.json)`.
> This must be added in Task 7's test file. See Task 7 Step 1 for the test addition note.

**Step 4 — Commit**

```
git add Tests/GohCoreTests/Fixtures/signed-verify-report-v1.json
git add Tests/GohCoreTests/Fixtures/verify-attestation-result-v1.json
git commit -m "test(attest): add golden fixtures signed-verify-report-v1.json and verify-attestation-result-v1.json"
```

---

### Task 6 — CREATE `Sources/GohCore/CLI/GohAttestCommand.swift`

**Files**
- CREATE `Sources/GohCore/CLI/GohAttestCommand.swift`

**Bet check:** This is the core of "The Signed Receipt" bet — one SE key signs one whole
VerifyAllReport. The signing covers `payloadBytes(for:)` (no newline), not stdout. The artifact is
produced for exit 0/2/9 (attests drift too); only exit 5 (SE/key failure) and exit 6 (ledger error)
produce no artifact.

**Pre-task reads**
- [x] `Sources/GohCore/CLI/GohVerifyAllCommand.swift` — `run(provenanceStorePath:json:generatedAt:)`
  signature; the full return type `GohCommandLineResult`; `payloadBytes(for:)` seam (just added)
- [x] `Sources/GohCore/CLI/AttestTypes.swift` — `SignedVerifyReport`, `SignedVerifyReport.SigBlock`,
  `SignedVerifyReport.payloadType`, `SignedVerifyReport.namespace`, `SignedVerifyReport.buildPAE`,
  `SignedVerifyReport.deriveKid(from:)`, `Data.base64URLEncodedString()`
- [x] `Sources/GohCore/TrustCore/SecureEnclaveSigner.swift` — `createOrOpen(handleURL:)`,
  `sign(pae:)`, `kid`, `publicKeyX963`, `SecureEnclaveSignerError`
- [x] `Sources/GohCore/CLI/AttestKeyLocation.swift` — `signingKeyHandleURL(create:)`,
  `keysJSONURL(create:)`
- [x] `Sources/GohCore/Provenance/ProvenanceStore.swift` — `writeAtomically` pattern lines 206–228
  to reuse for `--output` atomic write and `keys.json` append-merge

**Step 1 — Failing tests**

File: `Tests/GohCoreTests/GohAttestCommandTests.swift` (CREATE)

```swift
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
    }

    // MARK: - SE path (gated)

    // AC4: attest with real SE key produces a valid artifact
    @Test("AC4: attest with real SE key produces artifact with SE-signed sig")
    func seSignedAttest() throws {
        guard SecureEnclave.isAvailable else { return }

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
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohAttestCommandTests 2>&1
```

Expected: compile errors — `GohAttestCommand` does not exist.

**Step 3 — Implementation**

CREATE `Sources/GohCore/CLI/GohAttestCommand.swift`:

```swift
import Darwin
import Foundation
import CryptoKit

/// CLI runner for `goh attest [--output <file>]`.
///
/// Runs the existing `verify --all` logic, signs the canonical report bytes with the
/// Secure Enclave P-256 key, and writes a `SignedVerifyReport` artifact.
///
/// Exit codes:
///   0  — all entries OK; artifact produced.
///   2  — at least one hash MISMATCH (FAILED); artifact produced (attests drift).
///   9  — at least one file MISSING; artifact produced (attests drift).
///   6  — ledger unreadable/corrupt; NO artifact produced.
///   5  — attestation failed (SE unavailable / key error / write failure); NO artifact produced.
///   64 — usage error.
///
/// Additivity: no change to ProvenanceRecord, VerifyAllReport JSON, gohfile.lock, which,
/// or any existing exit code.
public enum GohAttestCommand {

    /// Injectable signer for testing without SE.
    public struct SignerOverride: Sendable {
        public var kid: String
        public var publicKeyX963: Data
        public var sign: @Sendable (Data) throws -> Data

        public init(kid: String, publicKeyX963: Data, sign: @Sendable @escaping (Data) throws -> Data) {
            self.kid = kid
            self.publicKeyX963 = publicKeyX963
            self.sign = sign
        }
    }

    /// Runs `goh attest`.
    ///
    /// - Parameters:
    ///   - provenanceStorePath: Path to `provenance.plist` (resolved by caller).
    ///   - outputPath: Path to write the artifact (nil → stdout).
    ///   - attestKeyHandleURL: URL of the SE key handle file.
    ///   - attestKeysJSONURL: URL of the `keys.json` history file.
    ///   - signerOverride: Inject a software signer for tests; nil uses the real SE key.
    public static func run(
        provenanceStorePath: String,
        outputPath: String?,
        attestKeyHandleURL: URL,
        attestKeysJSONURL: URL,
        signerOverride: SignerOverride? = nil
    ) -> GohCommandLineResult {

        // ── Step 1: Run verify-all to get the report ──────────────────────────
        let verifyResult = GohVerifyAllCommand.run(
            provenanceStorePath: provenanceStorePath,
            json: true)

        // Exit 6 from verify-all → ledger error, no artifact
        if verifyResult.exitCode == 6 {
            return GohCommandLineResult(
                exitCode: 6,
                standardError: "attest: ledger unreadable or corrupt\n")
        }

        // We need the actual VerifyAllReport to sign its payload bytes.
        // Re-call with a fixed timestamp so payload_bytes are stable for signing.
        // (The human-facing report reuses verifyResult.exitCode.)
        let reportDate = Date()
        let reportResult = GohVerifyAllCommand.run(
            provenanceStorePath: provenanceStorePath,
            json: true,
            generatedAt: reportDate)

        // Parse the report to get payload_bytes via the seam
        guard let reportData = reportResult.standardOutput
            .data(using: .utf8)?
            .dropLast()  // strip the trailing '\n' that --json appends
            .nonEmpty,
              let report = try? CommandCoding.decoder.decode(VerifyAllReport.self, from: reportData),
              let payloadBytes = GohVerifyAllCommand.payloadBytes(for: report)
        else {
            return GohCommandLineResult(
                exitCode: 5,
                standardError: "attest: failed to encode report for signing\n")
        }

        // ── Step 2: Create-or-open the signing key ────────────────────────────
        let kid: String
        let publicKeyX963: Data
        let signFn: (Data) throws -> Data

        if let override = signerOverride {
            kid = override.kid
            publicKeyX963 = override.publicKeyX963
            signFn = override.sign
            // Ensure the attest directory exists when using the real path
        } else {
            // Real SE path
            do {
                // Create the attest directory (create:true — attest is a legitimate writer)
                let _ = try AttestKeyLocation.signingKeyHandleURL(create: true)
                let signer = try SecureEnclaveSigner.createOrOpen(handleURL: attestKeyHandleURL)
                kid = signer.kid
                publicKeyX963 = signer.publicKeyX963
                signFn = { pae in try signer.sign(pae: pae) }
                // Append to keys.json (signer-side history; never consulted on verify)
                try appendToKeysJSON(url: attestKeysJSONURL, kid: kid, pubX963: publicKeyX963)
            } catch {
                return GohCommandLineResult(
                    exitCode: 5,
                    standardError: "attest: Secure Enclave key error: \(error)\n")
            }
        }

        // ── Step 3: Build PAE and sign ────────────────────────────────────────
        let pae = SignedVerifyReport.buildPAE(
            payloadType: SignedVerifyReport.payloadType,
            payloadBytes: payloadBytes)

        let rawSig: Data
        do {
            rawSig = try signFn(pae)
        } catch {
            return GohCommandLineResult(
                exitCode: 5,
                standardError: "attest: signing failed: \(error)\n")
        }

        // ── Step 4: Build envelope ────────────────────────────────────────────
        let envelope = SignedVerifyReport(
            attestationVersion: 1,
            payloadType: SignedVerifyReport.payloadType,
            payloadBase64: payloadBytes.base64EncodedString(),
            sig: SignedVerifyReport.SigBlock(
                ns: SignedVerifyReport.namespace,
                alg: "ES256",
                kid: kid,
                pubBase64url: publicKeyX963.base64URLEncodedString(),
                sigBase64url: rawSig.base64URLEncodedString()
            )
        )

        guard let envelopeData = try? CommandCoding.encoder.encode(envelope) else {
            return GohCommandLineResult(
                exitCode: 5,
                standardError: "attest: failed to encode artifact\n")
        }

        // ── Step 5: Write artifact (atomic) or emit to stdout ─────────────────
        if let outputPath {
            do {
                try writeArtifactAtomically(data: envelopeData, to: outputPath)
            } catch {
                return GohCommandLineResult(
                    exitCode: 5,
                    standardError: "attest: failed to write artifact: \(error)\n")
            }
        }

        // Exit code mirrors the verify verdict so `attest` drops into CI pipelines.
        let stdout = outputPath == nil
            ? String(decoding: envelopeData, as: UTF8.self) + "\n"
            : ""
        return GohCommandLineResult(
            exitCode: reportResult.exitCode,
            standardOutput: stdout)
    }

    // MARK: - Private helpers

    /// Append-merge {kid, pub, createdAt} to keys.json (signer-side history ONLY).
    ///
    /// keys.json is NEVER read on any verification path — it exists for the signer's
    /// own reference (e.g. to look up their current kid for `--expect-key` pinning).
    private static func appendToKeysJSON(url: URL, kid: String, pubX963: Data) throws {
        struct KeysFile: Codable {
            var keysVersion: Int = 1
            var keys: [KeyEntry]
        }
        struct KeyEntry: Codable {
            var kid: String
            var pub: String       // base64url x963
            var createdAt: String // ISO-8601
        }

        var keysFile: KeysFile
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let existing = try? CommandCoding.decoder.decode(KeysFile.self, from: data) {
            keysFile = existing
        } else {
            keysFile = KeysFile(keysVersion: 1, keys: [])
        }

        // Idempotent: append only if kid not already present
        if !keysFile.keys.contains(where: { $0.kid == kid }) {
            let formatter = ISO8601DateFormatter()
            keysFile.keys.append(KeyEntry(
                kid: kid,
                pub: pubX963.base64URLEncodedString(),
                createdAt: formatter.string(from: Date())
            ))
        }

        guard let data = try? CommandCoding.encoder.encode(keysFile) else { return }
        try writeAtomically(data: data, to: url, permissions: 0o600)
    }

    /// Atomic write: temp → chmod → fsync → rename → fsync(dir).
    private static func writeArtifactAtomically(data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try writeAtomically(data: data, to: url, permissions: 0o644)
    }

    private static func writeAtomically(data: Data, to url: URL, permissions: Int) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp)
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: tmp.path)
            let fd = open(tmp.path, O_RDONLY)
            if fd >= 0 {
                defer { close(fd) }
                guard Darwin.fsync(fd) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            guard rename(tmp.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            let dfd = open(dir.path, O_RDONLY)
            if dfd >= 0 {
                defer { close(dfd) }
                guard Darwin.fsync(dfd) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

extension Data {
    /// Returns self if non-empty, else nil.
    var nonEmpty: Data? { isEmpty ? nil : self }
}
```

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohAttestCommandTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected:
- Software-key tests: PASS everywhere.
- SE-gated test (`seSignedAttest`): PASS locally; graceful skip in CI VM.
- Build: clean.

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/GohAttestCommand.swift Tests/GohCoreTests/GohAttestCommandTests.swift
git commit -m "feat(attest): add GohAttestCommand — SE-signed verify-all artifact (exit 0/2/9/5/6)"
```

---

## Phase 3 — `goh verify-attestation` verb + CLI wiring + integration

### Task 7 — CREATE `Sources/GohCore/CLI/GohVerifyAttestationCommand.swift`

**Files**
- CREATE `Sources/GohCore/CLI/GohVerifyAttestationCommand.swift`

**Pre-task reads**
- [x] `Sources/GohCore/CLI/AttestTypes.swift` — `SignedVerifyReport`, `VerifyAttestationResult`,
  `AttestVerdict`, `Data.init?(base64URLEncoded:)`, `SignedVerifyReport.buildPAE`,
  `SignedVerifyReport.deriveKid(from:)` — all symbols used on the verify path
- [x] `Sources/GohCore/Model/CommandCoding.swift` — `CommandCoding.decoder` for parsing the
  envelope; `CommandCoding.encoder` for `--json` output
- [x] `Tests/GohCoreTests/Fixtures/signed-verify-report-v1.json` — the golden fixture; its embedded
  `pub` is a throwaway software key; tests verify this file and a byte-corrupted copy
- [x] `Tests/GohCoreTests/Fixtures/verify-attestation-result-v1.json` — the result schema fixture

**Step 1 — Failing tests**

File: `Tests/GohCoreTests/GohVerifyAttestationCommandTests.swift` (CREATE)

```swift
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
            "CROSS-FIXTURE BINDING BROKEN: artifact.payload (\(payloadBytes.count)B) != "
            + "verify-all-report-v1.json (\(reportFixtureBytes.count)B). "
            + "Regenerate signed-verify-report-v1.json using the Task 5 script (which reads "
            + "verify-all-report-v1.json directly — never re-synthesizes the report).")
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

    // M5/exit-64: missing artifact path → exit 64
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
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAttestationCommandTests 2>&1
```

Expected: compile errors — `GohVerifyAttestationCommand` does not exist.

**Step 3 — Implementation**

CREATE `Sources/GohCore/CLI/GohVerifyAttestationCommand.swift`:

```swift
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
```

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAttestationCommandTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: all tests pass (all SE-independent); build clean.

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/GohVerifyAttestationCommand.swift Tests/GohCoreTests/GohVerifyAttestationCommandTests.swift
git commit -m "feat(attest): add GohVerifyAttestationCommand — offline sig verify, fail-closed exit codes (0/1/2/3/6)"
```

---

### Task 8 — Wire `attest` + `verify-attestation` into `GohCommandLine`

**Files**
- MODIFY `Sources/GohCore/CLI/GohCommandLine.swift`

**Pre-task reads**
- [x] `Sources/GohCore/CLI/GohCommandLine.swift` — WHOLE file.
  - `ParsedCommand` enum (lines 219–235): add two cases
  - `GohCommandLine.init` (lines 33–53): add `attestKeyLocationResolver` closure
  - `parse(_:)` (lines 252–357): add `attest` and `verify-attestation` branches
  - `run()` dispatch switch (lines 55–184): add two cases
  - `usage()` (lines 557–583): add two lines to usage text
- [x] `Sources/GohCore/CLI/GohAttestCommand.swift` — `run(provenanceStorePath:outputPath:attestKeyHandleURL:attestKeysJSONURL:signerOverride:)` signature
- [x] `Sources/GohCore/CLI/GohVerifyAttestationCommand.swift` — `run(artifactPath:expectKey:allowUntrustedKey:json:)` signature
- [x] `Sources/GohCore/CLI/AttestKeyLocation.swift` — `signingKeyHandleURL(create:)`,
  `keysJSONURL(create:)` for the resolver injection

**Step 1 — Failing tests**

File: `Tests/GohCoreTests/GohAttestParseTests.swift` (CREATE)

```swift
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
            send: { _ in throw TestTransportError() },
            // (a) temp attest key location — no writes to ~/Library/…/dev.goh.attest/
            attestKeyLocationResolver: { (handleURL: handleURL, keysJSONURL: keysURL) },
            // (b) software signer — no real SE key created
            attestSignerResolver: makeSoftwareSignerResolver()
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
            send: { _ in throw TestTransportError() },
            // (a) temp attest key location — no writes to ~/Library/…/dev.goh.attest/
            attestKeyLocationResolver: { (handleURL: handleURL, keysJSONURL: keysURL) },
            // (b) software signer — no real SE key created
            attestSignerResolver: makeSoftwareSignerResolver()
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
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohAttestParseTests 2>&1
```

Expected: compile errors — `attest` and `verify-attestation` parse branches do not exist.

**Step 3 — Implementation**

Four changes to `Sources/GohCore/CLI/GohCommandLine.swift`:

**Change A — `ParsedCommand`**: Add two new cases (after `verifyAll`):
```swift
    case attest(outputPath: String?)
    case verifyAttestation(
        artifactPath: String,
        expectKey: String?,
        allowUntrustedKey: Bool,
        json: Bool)
```

**Change B — `GohCommandLine.init`**: Add two injectable seams — `attestKeyLocationResolver`
(allows injecting a temp attest dir) and `attestSignerResolver` (allows injecting a software
signer so tests never touch the real Secure Enclave or `~/Library/Application Support/dev.goh.attest/`).

> **BLOCK-1 fix — test-only seam:** `attestSignerResolver` is a test-injection seam ONLY.
> Its production default is `nil` (no override → real SE signer via `SecureEnclaveSigner.createOrOpen`).
> It must NEVER be used as a production software-key fallback — that would defeat the hardware
> guarantee. The override is wired only when a non-nil value is injected (test path); the
> production path ignores it entirely.
>
> **Source compatibility (TRAILING-CLOSURE CONSTRAINT):** `Sources/goh/main.swift` constructs
> `GohCommandLine` using `send` as a trailing closure (the `} { request in ... }` at the bottom
> of the `GohCommandLine(...)` call). Swift binds a trailing closure to the LAST parameter of the
> initializer. Therefore `send` MUST remain the last parameter, and both new parameters —
> `attestKeyLocationResolver` and `attestSignerResolver` — MUST be inserted BEFORE `send`. Both
> are labeled and defaulted, so all existing callers that pass `send` positionally as a trailing
> closure remain source-compatible. Confirm the `send:` position against `Sources/goh/main.swift`
> before implementing.

```swift
public typealias AttestKeyLocationResolver = () -> (handleURL: URL, keysJSONURL: URL)?

/// Test-only injection seam for the attest signer. PRODUCTION DEFAULT IS NIL.
/// When nil, the real SE signer is used. Must NEVER be a production software fallback.
public typealias AttestSignerResolver = () -> GohAttestCommand.SignerOverride?

private let attestKeyLocationResolver: AttestKeyLocationResolver
private let attestSignerResolver: AttestSignerResolver

// In init: insert BEFORE the `send:` parameter (send must stay last — trailing-closure compat):
attestKeyLocationResolver: @escaping AttestKeyLocationResolver = {
    guard let handleURL = try? AttestKeyLocation.signingKeyHandleURL(create: false),
          let keysURL = try? AttestKeyLocation.keysJSONURL(create: false) else { return nil }
    return (handleURL, keysURL)
},
attestSignerResolver: @escaping AttestSignerResolver = { nil },
// send: remains the LAST parameter so main.swift's trailing closure compiles:
send: @escaping (XPCDictionary) throws -> XPCDictionary,
```

**Change C — `parse(_:)`**: Add two branches before the final `throw ParseError(...)`:
```swift
        // attest [--output <file>]
        if arguments.first == "attest" {
            var outputPath: String?
            var index = 1
            while index < arguments.count {
                let arg = arguments[index]
                switch arg {
                case "--output", "-o":
                    outputPath = try value(after: arg, in: arguments, at: &index)
                default:
                    guard !arg.hasPrefix("-") else {
                        throw ParseError(message: "unknown attest option \(arg)")
                    }
                    throw ParseError(message: "attest: unexpected argument \(arg)")
                }
            }
            return .attest(outputPath: outputPath)
        }

        // verify-attestation <file> [--expect-key <kid|pubkey>] [--allow-untrusted-key] [--json]
        if arguments.first == "verify-attestation" {
            let rest = Array(arguments.dropFirst())
            guard !rest.isEmpty, let artifactPath = rest.first, !artifactPath.hasPrefix("-") else {
                throw ParseError(message: "verify-attestation requires an artifact file path")
            }
            var expectKey: String?
            var allowUntrustedKey = false
            var json = false
            var index = 1
            while index < rest.count {
                let arg = rest[index]
                switch arg {
                case "--expect-key":
                    expectKey = try value(after: arg, in: rest, at: &index)
                case "--allow-untrusted-key":
                    allowUntrustedKey = true
                    index += 1
                case "--json":
                    json = true
                    index += 1
                default:
                    guard !arg.hasPrefix("-") else {
                        throw ParseError(message: "unknown verify-attestation option \(arg)")
                    }
                    throw ParseError(message: "verify-attestation: unexpected argument \(arg)")
                }
            }
            return .verifyAttestation(
                artifactPath: artifactPath,
                expectKey: expectKey,
                allowUntrustedKey: allowUntrustedKey,
                json: json)
        }
```

**Change D — `run()` dispatch**: Add two cases to the switch (before the `catch` clauses).
Note: the `.attest` case threads BOTH `attestKeyLocationResolver` AND `attestSignerResolver`
into `GohAttestCommand.run` (BLOCK-1 fix):
```swift
            case .attest(let outputPath):
                let storePathOrEmpty = provenanceStorePathResolver() ?? ""
                let locations = attestKeyLocationResolver()
                // attestKeyLocationResolver uses create:false (read path default).
                // GohAttestCommand.run calls create:true internally for the SE key.
                let handleURL = locations?.handleURL
                    ?? (try? AttestKeyLocation.signingKeyHandleURL(create: false))
                    ?? URL(fileURLWithPath: "")
                let keysURL = locations?.keysJSONURL
                    ?? (try? AttestKeyLocation.keysJSONURL(create: false))
                    ?? URL(fileURLWithPath: "")
                // Thread the injected signer override (test-only; nil in production).
                let signerOverride = attestSignerResolver()
                return GohAttestCommand.run(
                    provenanceStorePath: storePathOrEmpty,
                    outputPath: outputPath,
                    attestKeyHandleURL: handleURL,
                    attestKeysJSONURL: keysURL,
                    signerOverride: signerOverride)

            case .verifyAttestation(let artifactPath, let expectKey, let allowUntrustedKey, let json):
                return GohVerifyAttestationCommand.run(
                    artifactPath: artifactPath,
                    expectKey: expectKey,
                    allowUntrustedKey: allowUntrustedKey,
                    json: json)
```

**Change E — `usage()`**: Add two lines to the usage text:
```swift
          goh attest [--output <file>]   (exit: 0 ok · 2 changed · 9 missing · 5 attest-failed · 6 ledger-error)
          goh verify-attestation <file> [--expect-key <kid|pubkey>] [--allow-untrusted-key] [--json]
```

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohAttestParseTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllParseTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllCommandTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

All four checks must pass; `-warnings-as-errors` build must be clean.

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/GohCommandLine.swift Tests/GohCoreTests/GohAttestParseTests.swift
git commit -m "feat(attest): wire attest + verify-attestation into GohCommandLine parse/dispatch/usage; add attestSignerResolver seam for hermetic parse tests"
```

---

### Task 9 — Integration test suite `GohAttestIntegrationTests`

**Files**
- CREATE `Tests/GohCoreTests/GohAttestIntegrationTests.swift`

**Pre-task reads**
- [x] All new source files (Tasks 1–8) — end-to-end flow from `GohCommandLine.run()` through
  `GohAttestCommand` → `SecureEnclaveSigner` → `GohVerifyAttestationCommand`
- [x] `Tests/GohCoreTests/Fixtures/signed-verify-report-v1.json` — for AC5 golden-fixture round-trip

**Step 1 — Failing tests (complete file)**

```swift
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

        // AC3: verify with correct --expect-key kid → exit 0
        let verifyResult2 = GohVerifyAttestationCommand.run(
            artifactPath: outputPath,
            expectKey: signer.kid,
            allowUntrustedKey: false,
            json: false)
        #expect(verifyResult2.exitCode == 0)

        // AC3: verify with wrong --expect-key → exit 3 (mismatch)
        let verifyResult3 = GohVerifyAttestationCommand.run(
            artifactPath: outputPath,
            expectKey: "00000000",
            allowUntrustedKey: false,
            json: false)
        #expect(verifyResult3.exitCode == 3)

        // AC1: tamper the artifact → exit 2 (INVALID)
        var artifactData = try Data(contentsOf: URL(fileURLWithPath: outputPath))
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
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohAttestIntegrationTests 2>&1
```

Expected: compile error (or test failures if any prior task missed something). After Tasks 1–8 are done, this should compile and tests should fail only if implementation has a defect.

**Step 3 — Implementation**

No new source files. Fix any defects found by these tests.

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohAttestIntegrationTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected:
- SE-independent tests: PASS everywhere.
- `sePipeline`: PASS locally; graceful skip in CI VM.
- Build: clean.

**Step 5 — Commit**

```
git add Tests/GohCoreTests/GohAttestIntegrationTests.swift
git commit -m "test(attest): add GohAttestIntegrationTests — full attest→verify-attestation pipeline"
```

---

### Task 10 — Full test run + final health check

**Files**
- No source changes. Run all existing + new tests; confirm zero regressions.

**Pre-task reads** — none (no edits)

**Step 1 — Full test suite**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1
```

Expected: all tests pass. Zero failures.
- **AC2 verification:** `GohVerifyAllCommandTests`, `GohVerifyAllCommandJSONTests`,
  `GohVerifyAllParseTests`, `GohVerifyAllParseJSONTests`, `GohWhichCommandTests`,
  `GohWhichLedgerTests`, `GohVerifyCommandTests` — all pass UNMODIFIED.
- **AC5 verification:** `VerifyReportTypesTests.encodeEqualsGoldenFixture`,
  `GohVerifyAllPayloadBytesTests.payloadBytesMatchFixture`, `AttestTypesTests.*`,
  `GohVerifyAttestationCommandTests.resultEncodeEqualsFixture` — all pass.

**Step 2 — Build with -warnings-as-errors**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: zero warnings, zero errors.

**Step 3 — Spot-check CLI**

```
# Verify existing commands are unchanged:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run goh --help 2>&1 | grep -E "attest|verify-attestation"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run goh verify --all --json 2>&1 | python3 -m json.tool

# Spot-check attest (exits 5 if SE unavailable, 0 if available + empty ledger):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run goh attest --output /tmp/test-attestation.json 2>&1; echo "exit: $?"
```

**Step 4 — Commit any fixups**

If fixups were needed from Task 10: commit with `fix(attest): <description>`.

If clean: no commit needed.

---

## File map summary

| Action | Path |
|--------|------|
| CREATE | `Sources/GohCore/CLI/AttestKeyLocation.swift` |
| CREATE | `Sources/GohCore/CLI/AttestTypes.swift` |
| CREATE | `Sources/GohCore/TrustCore/SecureEnclaveSigner.swift` |
| MODIFY | `Sources/GohCore/CLI/GohVerifyAllCommand.swift` |
| CREATE | `Sources/GohCore/CLI/GohAttestCommand.swift` |
| CREATE | `Sources/GohCore/CLI/GohVerifyAttestationCommand.swift` |
| MODIFY | `Sources/GohCore/CLI/GohCommandLine.swift` |
| CREATE | `Tests/GohCoreTests/AttestKeyLocationTests.swift` |
| CREATE | `Tests/GohCoreTests/AttestTypesTests.swift` |
| CREATE | `Tests/GohCoreTests/SecureEnclaveSignerTests.swift` |
| CREATE | `Tests/GohCoreTests/GohVerifyAllPayloadBytesTests.swift` |
| CREATE | `Tests/GohCoreTests/GohAttestCommandTests.swift` |
| CREATE | `Tests/GohCoreTests/GohVerifyAttestationCommandTests.swift` |
| CREATE | `Tests/GohCoreTests/GohAttestParseTests.swift` |
| CREATE | `Tests/GohCoreTests/GohAttestIntegrationTests.swift` |
| CREATE | `Tests/GohCoreTests/Fixtures/signed-verify-report-v1.json` |
| CREATE | `Tests/GohCoreTests/Fixtures/verify-attestation-result-v1.json` |

## Dependency order

```
Task 1 (AttestKeyLocation)
  └→ Task 2 (AttestTypes) ← Task 3 depends on deriveKid/base64url from here
       └→ Task 3 (SecureEnclaveSigner)
            └→ Task 4 (encode seam) ← no type deps, but must precede Task 6
                 └→ Task 5 (golden fixtures) ← consumed by Task 7 tests
                      └→ Task 6 (GohAttestCommand)
                           └→ Task 7 (GohVerifyAttestationCommand)
                                └→ Task 8 (GohCommandLine wiring)
                                     └→ Task 9 (integration tests)
                                          └→ Task 10 (health check)
```

Tasks 1, 2, 3 can be done in strict order (3 depends on types from 2).
Task 4 depends only on existing `GohVerifyAllCommand` (no new type deps).
Task 5 depends on Task 2 (needs the `CommandCoding.encoder` settings for fixture generation).
Task 6 depends on Tasks 3 + 4 + 5.
Task 7 depends on Tasks 2 + 5.
Task 8 depends on Tasks 6 + 7.
Tasks 9 and 10 depend on Task 8.

## Spec-vs-code discrepancies found during pre-write reads

### 1. Encode seam location (CRITICAL — directly addressed)

The spec states `payload_bytes = CommandCoding.encoder.encode(VerifyAllReport)` with NO trailing
newline and that `attest` must sign this directly. The current code has this encode call INLINE in
the private `jsonResult(exitCode:report:)` helper (lines 202–210 of `GohVerifyAllCommand.swift`):

```swift
guard let data = try? CommandCoding.encoder.encode(report) else { ... }
return GohCommandLineResult(exitCode: exitCode, standardOutput: String(decoding: data, as: UTF8.self) + "\n")
```

Task 4 factors this into a public `payloadBytes(for:) -> Data?` seam. The `+ "\n"` for stdout is
**not changed** — only the encode step is exposed. The new test `payloadBytesMatchFixture` pins
`payloadBytes(for:)` == the 806-byte golden fixture (no newline). This is the key correctness pin.

### 2. `GohAttestCommand` must re-call `GohVerifyAllCommand.run(json: true)` with a fixed date

The attest flow calls `GohVerifyAllCommand.run` twice: once to get the exit code (which reflects
real drift), and once with a fixed `generatedAt` to get stable payload bytes for signing. This is
necessary because `Date()` changes between calls. The implementation uses a single `reportDate =
Date()` captured before the second call to ensure the timestamp in the signed payload is stable.

### 3. CI Secure Enclave availability — unverifiable from codebase

The `macos-26` runner is confirmed to exist in `ci.yml` (based on CLAUDE.md note about the runner
name), but whether it exposes a hardware Secure Enclave is not verifiable from the codebase. The
plan handles this with blanket `guard SecureEnclave.isAvailable else { return }` guards on all
SE-requiring tests and a software-key golden fixture for all verify-path tests. If the CI runner
does expose SE (possible on Apple Silicon–backed VMs), the SE-gated tests will also exercise the
real path, which is a bonus — they are designed to pass in either scenario.

### 4. `Data.nonEmpty` extension conflict risk

`GohAttestCommand` uses a `Data.nonEmpty` extension. Verify at implementation time that this
extension name doesn't conflict with any existing extension in the codebase. If it does, rename it
to `Data.nilIfEmpty` or inline the guard.

### 5. `GohCommandLine.init` trailing-closure constraint (AttestKeyLocationResolver + AttestSignerResolver)

Adding `attestKeyLocationResolver` and `attestSignerResolver` to `GohCommandLine.init` changes
its public API. Default values alone are NOT sufficient for source compatibility here.
`Sources/goh/main.swift` passes `send` as a **trailing closure** — Swift binds a trailing closure
to the LAST parameter. Therefore defaulted parameters are source-compatible ONLY if inserted
BEFORE the trailing-closure `send` parameter. Both new parameters are therefore placed before
`send:`, which stays last. The main.swift trailing-closure call site (`} { request in ... }`)
remains valid without modification. The agent must confirm `send` is still the last parameter in
the final init signature before merging.
