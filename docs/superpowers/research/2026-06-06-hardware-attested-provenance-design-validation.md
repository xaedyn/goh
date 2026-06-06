---
date: 2026-06-06
feature: hardware-attested-provenance
type: design-validation
---

# Design Validation — Hardware-attested provenance (Approach A: The Signed Receipt)

## Acceptance Criteria (from Step 2.5)
- **AC1** sign+verify a record; tampering after signing breaks verification, distinctly from a SHA-256 mismatch.
- **AC2** additive + never fatal: all existing verify/which paths unchanged with/without a signature or key; attest-with-no-key fails cleanly (distinct exit), never corrupts.
- **AC3** recipient verifies offline on another machine using only the embedded public key.
- **AC4** hardware-rooted: SE P-256 key, private material non-exportable (persisted as the opaque handle).
- **AC5** frozen-format integrity: existing golden fixtures still pass; the new signed artifact is its own versioned shape + fixture (payload-pinned, never signature-byte-pinned).

## Dependency Enumeration
**No existing interface or frozen format is modified.** Approach A adds new verbs and a new artifact:
- New: `goh attest` (≈ `verify --all --sign`), `goh verify-attestation <file>`; a `SignedVerifyReport`
  envelope type; a CLI-owned attest key store (SE key handle + `keys.json`).
- Reuses (read-only, unchanged): `GohVerifyAllCommand`/`VerifyAllReport` (to produce the report bytes),
  `CommandCoding.encoder`, `GohCommandLine` parse/dispatch (new cases, mirrors `--json`).
- Untouched frozen formats: `ProvenanceRecord` (currentVersion 1), `VerifyAllReport` JSON
  (reportVersion 1, byte-exact fixture), `gohfile.lock` (lockfileVersion 1). No external consumers.

## Questions Asked & Answers

### Zero Silent Failures
- **Existing users/data on ship?** Nothing existing changes — new verbs + new artifact only. No
  migration. Unsigned `verify --all --json`, the ledger, the lock, and `which` are byte-for-byte
  unchanged; existing tests pass unmodified.
- **New write path?** Attest must create+persist an SE key **handle** + a `keys.json` (kid→pubkey).
  This is a **new CLI-owned store, separate from the daemon-owned provenance ledger** — it does NOT
  touch `provenance.plist` or violate its single-writer rule. Location: a dedicated CLI-owned subdir
  (e.g. `~/Library/Application Support/dev.goh.daemon/attest/`), files 0600, all writes atomic
  (temp→fsync→rename).
- **Step-1-ok / step-2-fails?** Attest order is: create-or-open key → **persist handle atomically &
  record kid in `keys.json` atomically** → run verify → sign report bytes → write artifact atomically.
  A crash after key creation but before handle-persist would orphan an unused enclave key (benign);
  persisting the handle as part of creation avoids losing a usable key. A failed artifact write leaves
  nothing corrupted (atomic rename; no partial file).

### Failure at Scale
- **10×?** One signature over the whole report regardless of entry count (sub-ms ECDSA). The report's
  own size is the only scale factor, identical to today's `verify --all`.
- **Concurrent ops?** Two concurrent first-`attest` runs could both create a key. Guard: create the
  handle file with **O_EXCL (create-if-absent)**; if it already exists, open it. `keys.json` is written
  atomically (temp→rename) and is append-merge (load, add kid if absent, write). Worst case: one
  orphaned enclave key; never a corrupt store.
- **Dependency (Secure Enclave) unavailable?** If `SecureEnclave.isAvailable == false` or key
  open/create fails, attest fails with a clear message + a distinct exit code; **every other path
  (verify, verify --all, which, byte-hash) is unaffected** (AC2). `verify-attestation` of an existing
  artifact still works — it needs only the embedded public key, not the enclave.

### Simplest Attack
- **Cheapest abuse — the "new key, new ledger" forge:** an attacker running **as the user** can create
  a fresh SE key and sign a forged report; it self-verifies. **This is the core honesty point.**
  `verify-attestation` must distinguish two outcomes: (1) *signature cryptographically valid &
  tamper-evident since signing* (always checkable from the embedded pubkey), vs (2) *signed by a key
  you trust* — only true if the kid matches a **pinned** key. Provide `--expect-key <kid>` (and/or a
  trusted-keys file); without pinning, output says "signed by <kid> — key identity UNVERIFIED unless
  you pinned it." Optional **Touch-ID-gated key** raises the forge bar (a biometric tap per signature;
  foreground-only, so CI uses an ungated key — a documented user choice).
- **Authz on a new endpoint?** None — local CLI, no network, no XPC, no daemon. The only "capability"
  is invoking the SE key, addressed above (pinning + optional Touch ID).
- **What an unprivileged/other process learns?** The artifact carries url/path/sha256 (already exposed
  by `verify --all`) + a public key (public by definition). The key **handle** file (0600) is opaque,
  machine-bound, and only usable by this Secure Enclave — reading it yields nothing usable and cannot
  extract the private key.

## Gaps Found
1. CLI-owned attest key store (handle + `keys.json`) — a new write surface needing a defined location, 0600, atomic writes.
2. Crash-safe key create→persist ordering (don't lose a usable key; orphaned enclave key on crash is acceptable).
3. Concurrent first-attest key-creation race.
4. The "new key, new ledger" identity gap — `verify-attestation` must separate "valid/tamper-evident" from "trusted key," with optional pinning + honest output.
5. SE unavailable / local key reset — clean degradation; old artifacts still verify from their embedded pubkey; `keys.json` retains historical pubkeys.

## Fixes Applied (folded into the spec)
1. Define a dedicated CLI-owned `attest/` store (handle + `keys.json`), 0600, atomic temp→rename writes; explicitly separate from the daemon-owned provenance ledger (no single-writer violation).
2. Create order: create-or-open key → persist handle + record kid atomically → sign → write artifact atomically; document the benign orphaned-key-on-crash case.
3. Create the handle file with O_EXCL; open-if-exists; atomic append-merge `keys.json`.
4. `verify-attestation` reports a three-state result — `valid & trusted` (kid pinned/matches), `valid but UNTRUSTED key` (no pin), `INVALID/tampered` — and supports `--expect-key`/trusted-keys; the spec states the threat model plainly (tamper-evidence + integrity, not identity-to-strangers without pinning). Optional Touch-ID-gated key as hardening.
5. SE-unavailable/key-missing → distinct non-fatal exit on attest; verify-attestation of existing artifacts unaffected (embedded pubkey); historical pubkeys retained in `keys.json`.

No unresolved gaps.
