---
date: 2026-06-05
feature: provenance-sync-skip-fold
type: pipeline-retrospective
---

# Pipeline Retrospective — provenance-sync-skip-fold

## Adversarial Review Categories That Fired

### Spec Review (2 rounds)
- **Round 1 — 4 BLOCKs:**
  - Cat 1 (Product Validity): `goh which` lock-branch short-circuit made `verifiedAt` dead
    output for exactly the files the feature records → M5 unreachable. Fixed: ledger-first
    precedence + explicit renderer rewrite.
  - Cat 4/7 (Consistency / silent-failure): hash double-prefix — the spec falsely claimed
    `FileDigest` returns raw hex; it returns the `"sha256:"`-prefixed form. Fixed: carry the
    prefixed value verbatim, daemon does not re-prefix.
  - Cat 3 (Completeness): missing `process()` → caller plumbing for the verified entry. Fixed:
    `EntryOutcome.verifiedEntry` carrier populated at the skip-return sites.
  - Cat 8 (Interface Contracts): `CommandOutcome.ack` added without specifying the exhaustive
    `CommandService.encodeReply` arm. Fixed: arm specified.
- **Round 2 — 1 BLOCK (the Cat-1 fix was incomplete):** ledger-first precedence silently
  inverted the existing `lockPrecedence` test and the renderer still didn't read `verifiedAt`.
  Fixed in-spec (post-cap, user-accepted at gate): explicit test rewrite + renderer rewrite.

### Plan Review (2 rounds)
- **Round 1 — 1 BLOCK:** the v4 golden fixture used a numeric date decoded with a plain
  `JSONDecoder`, but the real wire codec is `CommandCoding` with `.iso8601`; the golden file
  would have misrepresented the wire bytes. Fixed: ISO-8601 string + `CommandCoding.decoder` +
  a value assertion that genuinely exercises the codec.
- **Round 2 — APPROVED:** zero blocks; fix verified (wrapper shape + date), all six correctness
  invariants re-confirmed against code.

## Approach Selected

**Chosen:** The Courier (new XPC command; daemon stays sole writer) + additive `verifiedAt`.
**THE BET:** Keeping the daemon the sole writer is worth a protocolVersion bump; best-effort skip
recording (daemon may be down) is acceptable because the download path already treats provenance
as never-fatal. (Plus the provenance-wide O(n) bet, preserved via a single batch write.)
**Rejected approaches:**
- The Shared Ledger (CLI writes the plist directly + flock) — killed by a fatal landmine: the
  daemon's in-memory cache goes stale and silently overwrites CLI writes on the next download
  completion; flock can't fix it.
- The Read-Time Reconciler (no writes; `which`/`verify` read the lockfile as a fallback) —
  cheapest, but never unifies the ledger (the stated goal) and only helps files with a locatable
  lockfile.

## Design Validation Changes

Three gaps found and fixed before the spec: (1) `downloadedAt` was undefined for a
verified-not-downloaded file → hash-keyed merge rule; (2) one-write-per-file was O(n²) at scale →
batch command (one daemon read-modify-write); (3) a protocolVersion mismatch during a partial
upgrade could abort sync → best-effort recording made explicit.

## Open Risks Not Resolved

- **Deliberate behavior change accepted:** `goh which` now trusts the global ledger over a
  manifest's `gohfile.lock` when the same path is recorded in both with divergent hashes
  (ledger-first). Judged correct (the ledger is the unified, more-current source of truth) and
  documented; flagged to the user at the spec gate.
- **Round-2 spec BLOCK fixed past the 2-round cap** without a third review (user-accepted at the
  gate; the fix was mechanical and the per-task `swift test` + code-review gates in
  subagent-driven-development are the real check). Consistent with the prior provenance slice.
- `verifiedAt == downloadedAt` (to the encoded second) could in principle collide with a genuine
  same-instant download; vanishingly unlikely, not a blocker.
