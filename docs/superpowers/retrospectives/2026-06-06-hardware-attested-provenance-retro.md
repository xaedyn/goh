---
date: 2026-06-06
feature: hardware-attested-provenance
type: pipeline-retrospective
---

# Pipeline Retrospective — Hardware-attested provenance

## Adversarial Review Categories That Fired

### Spec Review (2 rounds)
- **Round 1 — 5 BLOCKs:**
  - Product Validity / byte-exactness: the signed `payload_bytes` were ambiguous by a trailing newline
    (`verify --all --json` appends `\n`; the encoder/fixture don't) → length-prefixed PAE would silently
    reject genuine artifacts. Fixed: pin `payload_bytes = encode()` no-newline; forbid the stdout path
    as signing source.
  - Internal Consistency / Interface: the attest key store under the daemon-owned dir violated the
    "CLI never creates the daemon support dir" invariant. Fixed: separate top-level `dev.goh.attest/`.
  - Security: exit 0 for "valid but untrusted key" made CI silently accept the "new key, new ledger"
    forgery. Fixed: **fail-closed** — exit 1 unless `--expect-key` matches or `--allow-untrusted-key`.
  - Completeness: the `verify-attestation --json` result schema was unversioned/underspecified. Fixed:
    `resultVersion: 1` + every field + golden fixture.
  - Completeness: `keys.json` was wrongly described as a verify input. Fixed: verify uses the embedded
    `pub` ONLY; `keys.json` is signer-side history only.
- **Round 2 — APPROVED:** all 10 categories pass; no second-order defects; 3 advisories carried to the
  plan (encode-seam factoring, exit-3 `--json` shape, cross-verb exit-code docs).

### Plan Review (2 rounds, 5 blocks total)
- **Round 1 — 3 BLOCKs** (crypto core confirmed sound — PAE symmetry, fixture reproduction, no silent
  accept/reject): (1) attest parse tests would write to the real home dir + mint a real SE key
  (non-hermetic) → test-only signer-injection seam; (2) the "O_EXCL via `rename(2)`" race protection was
  dead code (`rename` replaces, never EEXIST) → real `O_CREAT|O_EXCL`; (3) the fixture generator matched
  the verify-all fixture only by coincidence → read its exact bytes + a committed cross-binding test.
- **Round 2 — 2 NEW mechanical BLOCKs from the round-1 fixes** (escalation, fixed past the cap,
  user-accepted at the gate): (A) the new `init` params placed after the trailing-closure `send` would
  break `main.swift` → placed before `send`; (B) three bare `Darwin.fsync(...)` → unused-result errors
  under `-warnings-as-errors` → check result + throw (matching `ProvenanceStore`).

## Approach Selected
**Chosen:** A — The Signed Receipt (sign the verify report into a portable, offline-verifiable artifact).
**THE BET:** the highest-value attestation is the portable verify REPORT (a proof you share), not signing
every ledger entry — report attestation alone delivers the headline with a fraction of the surface.
**Rejected:** B — The Sealed Ledger (per-entry daemon signing; continuous tamper-evidence but bumps the
frozen ledger format + daemon crypto — the natural Phase 2); C — The Detached Seal (sidecar signatures,
zero frozen-format change, but a looser two-file binding A's self-contained artifact beats for sharing).

## Design Validation Changes
Five gaps fixed pre-spec: CLI-owned attest key store (separate from the daemon ledger); crash-safe
create→persist ordering; concurrent-first-attest race; the "new key, new ledger" identity gap (→ pinning
+ honest three-state output); clean SE-unavailable degradation.

## Empirical de-risking
A Secure Enclave spike (this session) proved SE P-256 key create/sign/verify works on **ad-hoc/dogfood
builds with no Developer ID, no Team ID, no entitlement** — refuting the CCB's pessimistic assumption and
removing the feared dependency on the Phase-3 credential gate. The feature is buildable/testable now.

## Open Risks Not Resolved (accepted)
- **The "new key, new ledger" forge** (attacker running as you mints a fresh SE key) is unstoppable
  without out-of-band key pinning; mitigated by `--expect-key` + fail-closed default + honest output, but
  it is the documented residual.
- **CI Secure Enclave availability** on the macos-26 runner is unverifiable from the repo; mitigated by
  SE-independent verify-path tests + SE-gated sign tests (CI stays green regardless).
- **Touch-ID-gated signing key** deferred to a future hardening (out of scope v1).
- **TOCTOU** in attest (verify runs twice: exit-6 check + stable payload) accepted for v1.
