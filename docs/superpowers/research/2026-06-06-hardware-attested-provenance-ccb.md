---
date: 2026-06-06
feature: hardware-attested-provenance
type: codebase-context-brief
---

# Codebase Context Brief — Hardware-attested provenance (Secure Enclave signing)

## ⚡ Empirical feasibility result (run 2026-06-06 — resolves the CCB's #1 open question)
A 65-line spike compiled **ad-hoc** (`Signature=adhoc`, `TeamIdentifier=not set` — identical to
the dogfood lane) and run as the user:
```
SecureEnclave.isAvailable = true
✅ SE P-256 signing key created (key.dataRepresentation = 284-byte opaque, machine-bound handle)
✅ sign + verify round-trip = true   (publicKey.x963Representation = 65 bytes)
```
**On macOS, a non-sandboxed process creates/uses Secure Enclave keys with NO Developer ID, NO Team
ID, NO entitlement, ad-hoc signed.** The feature is buildable + testable NOW in the dogfood lane;
it does NOT depend on the Phase-3 Developer-ID gate. Primitives this hands the design:
- **Private key never leaves the enclave**; goh persists the **284-byte `dataRepresentation`** (an
  opaque handle encrypted to THIS Secure Enclave — useless on any other machine) to re-open the key.
- **`publicKey.x963Representation` (65 bytes) is exportable** → embed in the record/report so any
  recipient verifies the signature offline, on any machine, with no key of their own.
- Daemon (headless LaunchAgent, same user) can use a **non-biometric** SE key headlessly; a
  **Touch-ID-gated** key needs a foreground UI prompt → only viable in a foreground CLI verb, never
  the daemon.

## STACK
Swift 6 (6.2 floor / 6.3 toolchain), macOS 26.0+, Apple Silicon. **CryptoKit only** — `SHA256` in 3
places (`FileDigest`, `ChunkAssembler`, `ManifestCodec`); **zero** existing `P256`/`SecureEnclave`/
keychain/`LocalAuthentication` usage. Binary-plist provenance + TOML lockfile; JSON via
`CommandCoding.encoder` (`.iso8601`, `.sortedKeys`). Swift Testing; `-warnings-as-errors`. Atomic
write = temp→chmod 0600→fsync→rename→fsync(dir).

## EXISTING PATTERNS
- **Provenance store = daemon single-writer.** Daemon `load()` (recovers corrupt→`.corrupt-<ts>`
  sidecar, resets); CLI `loadReadOnly()` (zero side effects). `goh verify --all` reads the plist
  **directly** with a raw `PropertyListDecoder` (to split corrupt=exit6 from empty=exit0). All writes
  inside `Mutex<Inner>.withLock`. File: `~/Library/Application Support/dev.goh.daemon/provenance.plist`.
- **CLI trust reads are read-only + daemon-down-capable** (`which`, `verify`, `verify --all`).
- **Frozen-format + golden-fixture discipline.** Each format has a version constant + a fixture +
  an encode-equals/round-trip test: `provenance-v1.plist` (round-trip, not byte-exact — cross-SDK
  plist skew), `verify-all-report-v1.json` (BYTE-EXACT), `envelope-v{1..4}-*.json`. Version bumps
  (e.g. protocolVersion 3→4) add a new fixture + four-round design pass.
- **Signing/entitlements reality:** dogfood/debug = ad-hoc, `get-task-allow` only, no Team ID, no
  keychain-access-group, not sandboxed, no committed `.entitlements`. Release = Developer-ID via
  `Scripts/private-release-candidate.sh` (`codesign --options runtime --timestamp`). XPC peer
  validation uses `XPCPeerRequirement.isFromSameTeam()` (relaxed by `GOH_XPC_ALLOW_UNVALIDATED_PEERS=1`).
  **SE key creation needs none of this** (empirically confirmed above).

## RELEVANT FILES
| File | Purpose | Key facts |
|---|---|---|
| `Sources/GohCore/Provenance/ProvenanceRecord.swift` | frozen ledger format | `ProvenanceRecord{version, entries}`; `ProvenanceEntry{url, sha256, size, downloadedAt, destinationPath, verifiedAt?}`; `currentVersion = 1` (:11) |
| `Sources/GohCore/Provenance/ProvenanceStore.swift` | daemon writer / CLI reader | `load()`, `loadReadOnly()` (:92), `record(entry:)`, `recordVerified(entries:)`, `writeAtomically` (:206) |
| `Sources/GohCore/Provenance/ProvenanceStoreLocation.swift` | path resolver | `defaultURL(create:)` (:16) |
| `Sources/GohCore/CLI/VerifyReportTypes.swift` | frozen `--json` report | `VerifyAllReport{reportVersion, generatedAt, summary, entries}` (:11); `VerifyEntryResult`; `VerifyStatus`; `VerifyErrorReport` |
| `Sources/GohCore/CLI/GohVerifyAllCommand.swift` | `verify --all [--json]` | `run(provenanceStorePath:json:generatedAt:)` (:34); exit 0/2/9/6/64 |
| `Sources/GohCore/CLI/GohVerifyCommand.swift` / `GohWhichCommand.swift` | lockfile verify / provenance lookup | read-only, daemon-down |
| `Sources/GohCore/CLI/GohCommandLine.swift` | parse/dispatch | `ParsedCommand.verifyAll(json:Bool)` (:229); `--json` flag pattern to mirror |
| `Sources/GohCore/Model/CommandCoding.swift` | canonical encoder | `.iso8601`, `.sortedKeys` (:10) |
| `Sources/GohCore/TrustCore/LockfileCodec.swift` | `gohfile.lock` | `Lockfile{lockfileVersion=1, manifestHash, entries}`; `LockEntry{url, path, sha256, size, downloadedAt}` |
| `Sources/GohCore/TrustCore/FileDigest.swift` | SHA-256 | `sha256WithSize(path:) -> (String, Int)` returns `"sha256:<hex>"` |
| `Tests/GohCoreTests/Fixtures/{provenance-v1.plist, verify-all-report-v1.json}` | golden fixtures | guarded by round-trip / byte-exact encode-equals tests |

## CONSTRAINTS
1. **Frozen formats stay additive + versioned, four-round.** `ProvenanceRecord.currentVersion 1`;
   `VerifyAllReport.reportVersion 1` (BYTE-EXACT fixture — any field add/rename breaks it →
   reportVersion 2 + new fixture); `lockfileVersion 1`. Signatures must be additive so unsigned/older
   records still verify.
2. **Portability invariant:** SHA-256 re-hash stays the PRIMARY verification path — works with no key,
   on any machine. SE signature is an ADDITIVE attestation; absence is non-fatal.
3. **Daemon single-writer; CLI read-only, zero side effects.** Any signing-at-record-time lives in the
   daemon; CLI must not gain write/sidecar side effects on a read path.
4. **No `#available` ladders; floor moves as a whole** if any SE/LA API needs >26.0 (none do).

## OPEN QUESTIONS (for clarity check / approach gate / design validation)
1. **What gets signed** (different value + frozen-format impact each): (a) per-entry signature in
   `ProvenanceEntry` (ledger, currentVersion); (b) the `VerifyAllReport` JSON (reportVersion 2 + new
   byte-exact fixture); (c) a separate `.sig` sidecar next to `provenance.plist` (no frozen format
   touched, cleanest separation, but a new file lifecycle); (d) the `gohfile.lock`.
2. **Canonical signed message** — the verifier must reconstruct the exact signed bytes without the
   original encoding context (deterministic canonicalization of the record/report; e.g. the sorted-key
   JSON, or the entry's `{path|sha256|...}` canonical string, or a Merkle root over entries).
3. **Granularity** — per-entry signatures vs. one signature over a Merkle root / whole-record digest.
4. **Public-key distribution** — embed `publicKey` (65-byte x963 / PEM) in the report/ledger so a
   recipient verifies offline; trust model is TOFU/"this is the key that signed it" unless separately
   bound to an identity (be honest: not non-repudiation-to-strangers).
5. **Key lifecycle** — persist the 284-byte `dataRepresentation` handle (daemon-owned, 0600); on SE
   reset / logic-board swap / migration the handle is dead → old signatures unverifiable BY THAT KEY,
   but byte-verify still works and the persisted public key still checks old signatures. Need
   rotation / multi-key / graceful "signature unverifiable, bytes OK" degradation — never a hard fail.
6. **Sign at record-time (daemon, headless, non-biometric) vs. attest-time (foreground CLI verb,
   optional Touch-ID gate via `LocalAuthentication` + `SecAccessControl`).** Daemon can't show a Touch
   ID prompt.
7. **Surface** — new flag `goh verify --all --signed` / `--attest` (mirrors the `--json` pattern at
   GohCommandLine:229) vs. a new `goh attest` verb. New output shape ⇒ four-round + golden fixture.

## File:line index
`ProvenanceRecord.currentVersion=1` :11 · `ProvenanceEntry.verifiedAt:Date?` :56 ·
`ProvenanceStore.loadReadOnly()` :92 · `writeAtomically` :206 · `ProvenanceStoreLocation.defaultURL` :16 ·
`VerifyAllReport` VerifyReportTypes:11–32 · `GohVerifyAllCommand.run(...)` :34 ·
`CommandCoding.encoder` :10 · `LockfileCodec.Lockfile/LockEntry` :15–40 · `FileDigest.sha256WithSize` :24 ·
`ParsedCommand.verifyAll(json:)` GohCommandLine:229 · `CommandService.protocolVersion=4` :14 ·
golden encode-equals `VerifyReportTypesTests` :51–94 · provenance round-trip `ProvenanceRecordTests` :13–52.
