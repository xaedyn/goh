---
date: 2026-06-06
feature: hardware-attested-provenance
type: research-brief
---

# Research Brief — Hardware-attested provenance

## Feasibility (settled empirically)
A Secure Enclave P-256 signing key can be **created and used on the current ad-hoc/dogfood builds**
(no Developer ID, no Team ID, no entitlement) — confirmed by a spike (`SecureEnclave.isAvailable =
true`, key created, sign+verify round-trip true). The private key never leaves the enclave; goh
persists the **284-byte opaque `dataRepresentation` handle** (machine-bound) to re-open it, and the
**65-byte `publicKey.x963Representation`** is exportable for offline verification. Not blocked on the
Phase-3 credential gate.

## Cryptographic design (high-confidence, from sourced research)

1. **Sign raw stored bytes; never re-serialize on verify (the DSSE pattern)** `[VERIFIED]`. The
   JSON-canonicalization footgun (key order, number/date/Unicode formatting drifting across
   SDK/Swift versions) is avoided entirely by signing the exact bytes written to disk and verifying
   those same bytes — no re-encode on the verifier side. Adopt the **DSSE pre-authentication encoding
   (PAE)** as the signing-input convention: `"DSSEv1" SP LEN(type) SP type SP LEN(body) SP body`,
   where `body` is the stored canonical bytes and `type` is a goh-specific payload type. (RFC 8785
   JCS is the interop alternative if a non-goh verifier must canonicalize; not needed for
   self-verification.)
2. **Envelope = SSH-sig semantics: embed the public key + a namespace** `[VERIFIED]`. The artifact is
   self-contained — a recipient verifies offline with only what's in the file, no key database, no
   CA. Minimal envelope:
   ```json
   "sig": { "ns": "dev.goh.<context>.v1", "alg": "ES256",
            "kid": "<hex(SHA-256(x963 pubkey)[0..3])>",
            "pub": "<base64url(x963, 65B)>", "sig": "<base64url(raw r||s, 64B)>" }
   ```
   The **namespace** prevents a ledger signature being replayed as a report signature (cross-context
   replay). Strongest precedent: **SSH signatures (sshsig)** — embeds the full pubkey + namespace,
   CA-free offline verify. minisign is the runner-up (clean 8-byte key-id + embedded-pubkey model).
3. **ECDSA P-256 is NON-deterministic** `[VERIFIED — swift-crypto source]`: a random nonce means the
   same payload signed twice yields **different** signatures. **Testing implication (load-bearing):**
   golden fixtures pin the **signed payload bytes + the public key**, and the test **re-signs and
   verifies** (`publicKey.isValidSignature(sig, for: payload) == true`) — it must NEVER byte-compare
   signature values. Use `rawRepresentation` (fixed 64B `r||s`) on the wire, not DER.
4. **Granularity** `[reasoned from VERIFIED perf]`: P-256 sign/verify is sub-millisecond, so cost is
   not a constraint. **Per-entry** signatures suit the append-mostly daemon-written ledger (sign each
   new entry once at record-time; no re-sign on append; each entry independently verifiable). **One
   whole-report** signature suits the verify-report (a one-shot snapshot export, signed once over its
   full bytes).
5. **Key identity + rotation** `[VERIFIED model from minisign/sshsig]`: `kid = hex(SHA-256(x963)[0..3])`
   (deterministic, no RNG state). Embed `pub`+`kid` in every signature so each is self-contained. A
   `keys.json` sidecar lists historical `{kid, pub, activeFrom, retiredAt}` so a Secure-Enclave reset
   (new key, new `kid`) does NOT invalidate verification of OLD signatures — the verifier routes by
   `kid` and keeps the old pubkey. Never assume one "current" key verifies all entries.

## Threat model (state honestly in the spec)
A self-signed record with an embedded pubkey proves: **the bytes were signed by the holder of THIS
pubkey's private key and have not changed since** — tamper-evidence + integrity binding. It **stops**
silent post-hoc edits to the ledger/report by anything that cannot invoke the Secure Enclave (malware,
another file tool, another user account) and forged verify reports. It does **NOT** prove
identity/non-repudiation to a stranger: an attacker running **as you** who creates a NEW SE key and
re-signs a forged record is undetectable **unless the initial `kid` is pinned out-of-band**. Mitigation
to offer: record the initial `kid` in an append-only/external location at first use (and surface
"signed by an UNKNOWN key" vs "signed by your pinned key"). It is NOT a mirror (doesn't restore bytes)
and NOT a substitute for the SHA-256 byte check (which remains the primary verification path).

## Portability + additivity invariants (must hold)
- **Byte-verification works with no key, on any machine** — the SHA-256 re-hash path is unchanged and
  primary; the signature is additive and its absence is non-fatal.
- Existing `goh verify` / `verify --all [--json]` / `which` outputs and exit codes are unchanged for
  unsigned records; any signed shape is **versioned + golden-fixtured** (four-round) and old/unsigned
  records remain fully usable.

## Dependency note
Formats potentially touched and their in-repo consumers (no external consumers): `ProvenanceRecord`
(ProvenanceStore reader/writer, `which`, `verify --all`, golden round-trip), `VerifyAllReport`
(`verify --all --json`, byte-exact golden fixture), `gohfile.lock` (`GohVerifyCommand`). Which are
touched depends on the chosen approach; a detached-sidecar approach touches none.

## Open design forks → approach gate
WHAT to attest (verify-report / ledger / both), and WHERE signatures live (embedded-in-a-versioned-
format vs detached sidecar that changes no frozen format), and WHERE signing happens (foreground CLI
verb — Touch-ID-gateable — vs daemon record-time, headless non-biometric). These are the approach memos.
