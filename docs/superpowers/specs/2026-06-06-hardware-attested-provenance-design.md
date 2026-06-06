---
date: 2026-06-06
feature: hardware-attested-provenance
type: spec
status: draft
approach: A — The Signed Receipt
---

# Spec — Hardware-attested provenance (`goh attest` / `goh verify-attestation`)

## 1. Problem

goh can already answer "is this still exactly what I downloaded?" against your own frozen record,
offline (`goh verify --all`). But the record — and any `verify --all --json` report — is just bytes a
process can rewrite, and a report you hand to a collaborator or attach to a release is trivially
forgeable. There is no way to (a) make a verify result **tamper-evident**, or (b) hand someone a
**portable proof** that a verification genuinely ran and produced a given result, checkable offline
with no account, server, or CA. Every Apple Silicon Mac has a Secure Enclave — a hardware key store
whose private keys physically cannot leave the chip — and goh already requires Apple Silicon. This
feature uses it to turn a verify report into a hardware-rooted, offline-verifiable attestation, making
goh's Apple-Silicon requirement *earned* rather than incidental.

## 2. Success metrics

Each maps to an AC; all observable via the CLI + Swift Testing.

- **M1 (AC1/AC4):** `goh attest` produces a signed artifact whose signature `goh verify-attestation`
  reports as **valid**; mutating any byte of the embedded payload makes `verify-attestation` report
  **INVALID** (a distinct status/exit from a SHA-256 mismatch). The signing key is a
  `SecureEnclave.P256.Signing` key (asserted by a unit test; private material persisted only as the
  opaque handle). Verified by sign→verify and tamper tests.
- **M2 (AC3):** A signed artifact verifies **offline using only the bytes in the file** — a test
  verifies it with a fresh `P256.Signing.PublicKey(x963Representation:)` from the embedded `pub`, with
  no Secure Enclave and no other state. (This is also what proves cross-machine verification.)
- **M3 (AC2 — non-fatal gate):** `goh verify`, `verify --all [--json]`, and `which` are byte-for-byte
  unchanged (existing tests pass unmodified). `goh attest` with no key / Secure Enclave unavailable
  exits with a **distinct non-zero code** and produces **no partial artifact**, leaving the ledger and
  all other paths intact. A release blocker if any existing verify/which output or exit code changes.
- **M4 (AC5):** Existing golden fixtures (`provenance-v1.plist`, `verify-all-report-v1.json`) pass
  unmodified. The new `SignedVerifyReport` carries `attestationVersion: 1` and has its own golden
  fixture + test that **verifies the signature** (never byte-compares signature values — ECDSA P-256
  is non-deterministic).
- **M5 (threat-model honesty, fail-closed):** `goh verify-attestation` distinguishes the trust states
  at the **exit-code layer**, defaulting to fail-closed: `0` valid&trusted (`--expect-key` matched or
  `--allow-untrusted-key`), `1` valid-but-identity-unverified (no pin, no opt-in — non-zero so CI fails
  closed), `2` INVALID, `3` `--expect-key` mismatch. Verified by a test per exit code.

## 3. The signed artifact — `SignedVerifyReport` (new frozen format, `attestationVersion = 1`)

A self-contained JSON envelope. **The payload is carried as opaque base64 bytes, never as a nested
re-serializable object** — so the verifier reconstructs the exact signed bytes with no re-encoding (the
canonicalization footgun is eliminated; per DSSE).

```jsonc
{
  "attestationVersion": 1,                                  // frozen; gates the envelope shape
  "payloadType": "application/vnd.goh.verify-report+json; v=1",
  "payload": "<base64(payload_bytes)>",   // see "payload_bytes" definition below — base64 std alphabet
  "sig": {
    "ns":  "dev.goh.verify-report.v1",   // namespace; prevents cross-context signature reuse (FROZEN)
    "alg": "ES256",                       // ECDSA P-256 + SHA-256 (FROZEN raw value)
    "kid": "<hex(SHA256(pub.x963)[0..3])>",        // 8 hex chars — key id
    "pub": "<base64url(publicKey.x963Representation, 65 bytes)>",   // embedded → offline verify
    "sig": "<base64url(signature.rawRepresentation, 64 bytes r‖s)>"
  }
}
```

- **`payload_bytes` — EXACT byte definition (B1, crypto-critical, FROZEN):**
  `payload_bytes = CommandCoding.encoder.encode(theVerifyAllReport)` — the encoder output **with NO
  trailing newline**. This is byte-identical to the `verify-all-report-v1.json` golden fixture's bytes,
  and it is the SAME value the `--json` path encodes *before* it appends `"\n"` for terminal display.
  `attest` MUST sign this encoder output directly and MUST NOT use the stdout-rendering path
  (`GohVerifyAllCommand`'s `String + "\n"`) as the signing source — the trailing newline would change
  the length-prefixed PAE and silently break verification. A test pins `payload_bytes` == the fixture
  bytes (no `\n`).
- **Canonical signed input (DSSE-PAE, FROZEN):**
  `PAE = "DSSEv1" SP ASCII(len(payloadType)) SP payloadType SP ASCII(len(payload_bytes)) SP payload_bytes`
  where `payload_bytes` is the value defined above (pre-base64), lengths are ASCII-decimal byte counts,
  and SP is a single 0x20. The signature is `ECDSA-P256-SHA256(PAE)` over the SHA-256 of the PAE (the
  CryptoKit `signature(for:)` API hashes internally). Because `payloadType` is inside the length-prefixed
  PAE, a verify-report signature can never validate as some future ledger-attestation (different
  payloadType) — replay-proof and injective.
- **Only `payload_bytes` is signed — never the outer envelope.** Verification reconstructs the PAE from
  the artifact's own `payloadType` + base64-decoded `payload`, and checks `sig` against the embedded
  `pub`. No re-serialization of any JSON object occurs on the verify path.
- **base64 alphabets (frozen, deliberate):** `payload` uses standard base64; `pub` and `sig` use
  base64url. This mix is intentional and part of the frozen format — implementers must not normalize them.
- **Two version signals, frozen together:** the media-type `; v=1` (inside the signed PAE) and the
  envelope `attestationVersion: 1` are bumped together; `attestationVersion` governs envelope parsing,
  the media-type `v=` governs the signed-payload contract. A mismatch between them is a malformed artifact
  (verify-attestation exit 6).
- Field names + `alg`/`ns`/`payloadType` raw values are **frozen**; a change bumps `attestationVersion`
  (+ media-type `v=`) and adds a new golden fixture. Encoder: `CommandCoding.encoder` for the envelope.
- The embedded `payload` decodes to the exact canonical report bytes, so a recipient can ALSO run
  byte-verification logic on it independently — the signature is strictly additive over the existing report.

## 4. Key store (new, CLI-owned — in its OWN directory, not the daemon's)

To avoid violating the invariant that the **CLI never creates the daemon-owned support directory**
(`ProvenanceStoreLocation` read paths use `create:false`), the attest key material lives in a **separate
top-level CLI-owned directory**, NOT under `dev.goh.daemon/`:
`~/Library/Application Support/dev.goh.attest/` (dir 0700, created by the `attest` verb only via a new
`AttestKeyLocation` resolver — the `attest` verb is a legitimate writer; this directory is unrelated to
and never touched by the provenance store). Contents:
- `signing-key.handle` (0600) — the SE key's opaque `dataRepresentation` (~284 bytes), machine-bound,
  non-extractable.
- `keys.json` (0600) — `{ "keysVersion": 1, "keys": [ { "kid", "pub" (b64url x963), "createdAt" } ] }`,
  the history of public keys **this machine's signer** has used.

**`keys.json` is signer-side history ONLY — it is NEVER read on any verification path (B5).**
`goh verify-attestation` verifies against the **`pub` embedded in the artifact** and nothing else
(that is what makes it offline + cross-machine — a recipient has no `keys.json`). `keys.json` exists
so (a) `attest` re-opens/rotates its own key, and (b) a user can look up their own current `kid` to
share for `--expect-key` pinning. The `kid` in an artifact is an 8-hex **hint**; `pub` is authoritative.

Lifecycle:
- **Create-or-open:** open the SE key from `signing-key.handle` if present; else create
  `SecureEnclave.P256.Signing.PrivateKey()`, write the handle with **O_EXCL** (create-if-absent; lose
  the race → open the existing one), then append `{kid,pub,createdAt}` to `keys.json` (atomic
  temp→fsync→rename, append-merge). Ordering: handle persisted first, then `keys.json` appended; if the
  `keys.json` append fails after the handle is written, the key is still usable (the `pub` is embedded in
  every artifact regardless) — only the user's local `--expect-key` self-lookup would miss until the next
  successful append, which `attest` re-attempts idempotently. A crash never loses a usable key (worst
  case: a benign orphaned enclave key).
- **SE unavailable / open fails:** `attest` fails cleanly (distinct exit 5, no artifact); never affects
  other commands. Verification of existing artifacts is unaffected (it needs only the embedded `pub`).
- **Key reset / new machine:** a new SE key gets a new `kid` appended to `keys.json`; OLD artifacts still
  verify from their embedded `pub`; the embedded-`pub` design means verification never depends on the
  signer's local key state.

## 5. CLI surface

- **`goh attest [--output <file>]`** — runs the existing `verify --all` logic to produce the
  `VerifyAllReport`, signs its canonical bytes with the SE key, and writes the `SignedVerifyReport`
  envelope to `--output` (or stdout). Exit codes: **mirror the verify verdict so it drops into CI** —
  `0` all-ok, `2` a file changed, `9` a file missing (the artifact is still produced for 0/2/9 — it
  attests the true state, drift included); `6` ledger unreadable/corrupt → no artifact; `5`
  **attestation failed** (Secure Enclave unavailable / key error / write failure) → no artifact; `64`
  usage. (Touch-ID gating is out of scope for v1 — see §7.)
- **`goh verify-attestation <file> [--expect-key <kid|pubkey>] [--allow-untrusted-key] [--json]`** —
  reads a `SignedVerifyReport`, reconstructs the PAE from the embedded `payloadType`+`payload`, and
  verifies `sig` against the **embedded `pub`** (never `keys.json`). **Fails closed on unverified
  identity (B3):**
  - `0` — signature **valid AND key trusted**: either `--expect-key` was given and matches, OR
    `--allow-untrusted-key` was given (explicit opt-in to tamper-evidence-only).
  - `1` — signature **valid but key identity NOT verified** (no `--expect-key` and no
    `--allow-untrusted-key`). This is a *non-zero, fail-closed* default so `verify-attestation && deploy`
    in CI does NOT silently accept a self-signed forgery. The message tells the user to pass
    `--expect-key <kid>` (to pin) or `--allow-untrusted-key` (to accept tamper-evidence-only).
  - `2` — signature **INVALID** (payload tampered / bad signature / pub mismatch).
  - `3` — `--expect-key` **mismatch** (valid signature, but a different key than the one pinned).
  - `6` — malformed/unparseable artifact, or `attestationVersion` / media-type `v=` unknown or
    mismatched (loud rejection, never silent accept).
  - `64` — usage.
  Rationale for fail-closed: the headline use is "verify in CI / before trusting a release," whose idiom
  is `cmd && next`; the safe interpretation must be the default and reach `$?`. Tamper-evidence-only is a
  deliberate opt-in.
  - **`--expect-key` strength:** accepts either an 8-hex `kid` (convenient but only 32-bit — a *hint*) or
    a full base64url x963 public key (strong pinning). The spec recommends full-pubkey pinning for
    adversarial settings; `kid` matching is a convenience for honest-error detection. Documented in
    `--help`.
- **`verify-attestation --json` result is its own FROZEN, versioned, golden-fixtured schema (B4):**
  ```jsonc
  { "resultVersion": 1,              // frozen; its own golden fixture
    "attestationVersion": 1,         // from the artifact
    "signatureValid": true,          // crypto check result
    "keyTrusted": false,             // true iff --expect-key matched or --allow-untrusted-key given
    "kid": "<8 hex>",
    "payloadType": "application/vnd.goh.verify-report+json; v=1",
    "verdict": "ok" }                // the inner VerifyAllReport's overall verdict, derived from its
                                     // summary: "ok" | "failed" | "missing"; null if signatureValid==false
  ```
  Field names + `verdict` raw values frozen; a golden fixture + encode-equals test guard it.
- **`attest --output <file>`** writes the artifact via the project's atomic temp→fsync→rename idiom
  (so a crash never leaves a partial artifact); stdout mode streams directly.
- Parse grammar mirrors the existing `--json`/`--all` pattern; `ParsedCommand` gains additive cases;
  the frozen `verify` lockfile arm is untouched.

## 6. Threat model (stated plainly; the spec commits to honesty here)

A goh attestation proves: **the embedded payload was signed by the holder of the embedded public key's
private key and has not changed since** — tamper-evidence + integrity binding. It **stops**: silent
post-hoc edits to a verify report by anything that cannot invoke this machine's Secure Enclave; a forged
report handed to a collaborator (they detect the tamper). It does **NOT** prove identity to a stranger:
an attacker running **as you** can mint a fresh SE key and sign a forged report that is internally
valid. The defense is **out-of-band key pinning** — `verify-attestation --expect-key <kid>` (the
recipient learns your real `kid` once, through any trusted channel) turns "valid" into "valid & from the
key I trust." goh surfaces the distinction in every output and never implies identity it can't prove.
It is **not** a mirror (restores nothing) and **not** a replacement for the SHA-256 byte check (still
the primary integrity path).

## 7. Out of scope (v1)

- **Per-entry ledger signing** (continuous whole-ledger tamper-evidence) — Approach B, a future phase
  (would bump `ProvenanceRecord.currentVersion`; deliberately not in v1).
- **Signing `gohfile.lock`** — future.
- **Touch-ID-gated signing key** (`LocalAuthentication` + `SecAccessControl`) — future hardening; v1
  ships an ungated SE key (so `attest` works headless / in CI). Noted as the natural next hardening.
- **Identity/PKI beyond TOFU pinning** — no CA, no transparency log, no Sigstore bundle; `kid` pinning
  is the trust model.
- **Full DSSE/in-toto envelope interop** — goh uses DSSE-PAE as the *signing input* but a goh-specific
  envelope; emitting standard DSSE/Sigstore bundles for third-party tools is future.
- No change to `provenance.plist`, `verify --all --json`, `gohfile.lock`, `which`, or any exit codes of
  existing commands.

## 8. Security surface

New surface: two local CLI verbs, no network, no XPC, no daemon involvement, no new auth/authz endpoint.
The only capability is invoking the machine's Secure Enclave signing key — addressed by the threat model
(pinning; optional Touch ID later). New on-disk: the 0700 `attest/` dir with a 0600 opaque key handle
(machine-bound, non-extractable — useless if read) and a 0600 `keys.json` of public keys (public by
definition). The signed artifact exposes only what `verify --all` already exposes (url/path/sha256) plus
a public key. No PII class beyond the existing ledger's. Validation: `verify-attestation` strictly parses
the envelope (unknown `attestationVersion` → exit 6; malformed base64/sig → INVALID), never executes or
trusts artifact-supplied paths.

## 9. Rollout & backward compatibility

Purely additive: new verbs + a new artifact format + a new CLI-owned key store. **Rollback** = remove the
verbs/types/store; nothing existing changes, no migration, no daemon/protocol/on-disk-format version
touched. No rolling-deploy concern (CLI-local, no XPC). `attestationVersion: 1` is the forward signal;
`keys.json` retains historical public keys so artifacts remain verifiable across key resets forever.

## 10. Edge cases

- **No key yet / first run:** `attest` creates one (O_EXCL, persists handle + keys.json atomically) then signs.
- **Secure Enclave unavailable / key open fails:** `attest` exit `5`, no artifact; all other commands unaffected; existing artifacts still verify.
- **Ledger unreadable/corrupt:** `attest` exit `6`, no artifact (nothing meaningful to attest).
- **Drift present (changed/missing):** `attest` STILL produces the artifact (attests the true state) and exits `2`/`9` so CI sees both the signed proof and the drift.
- **Tampered artifact:** any byte change to `payload`/`sig`/`pub` → `verify-attestation` exit `2` INVALID (the signature covers the PAE of payloadType+payload; pub mismatch fails too).
- **Valid signature, no `--expect-key` / no `--allow-untrusted-key`:** exit `1` (fail-closed — identity unverified), with a message instructing how to pin or opt in. `--allow-untrusted-key` → exit `0` (tamper-evidence-only, explicit).
- **`--expect-key` mismatch:** exit `3` (valid signature, wrong key) — distinct from INVALID (`2`) and from unverified (`1`).
- **Unknown `attestationVersion` / media-type `v=` / malformed envelope:** `verify-attestation` exit `6` (loud rejection, never silent accept).
- **Key reset / different machine:** an artifact made by an old/other key still verifies from its embedded `pub`; `--expect-key` of the old kid still matches; a new local key gets a new kid appended to `keys.json` (signer-side only; never consulted on verify).
- **Concurrent first `attest`:** O_EXCL handle create + atomic append-merge `keys.json`; at worst one orphaned enclave key; never a corrupt store.
- **ECDSA non-determinism:** the same report signed twice yields different `sig` bytes; both verify. Tests/fixtures verify signatures, never byte-compare them.
