---
date: 2026-06-05
feature: provenance-sync-skip-fold
type: design-validation
---

# Design Validation — Record provenance for skipped/already-present `goh sync` files

Chosen approach: **The Courier** (new XPC command, daemon is sole writer) + **`verifiedAt`**
(additive-optional field on `ProvenanceEntry`; no on-disk version bump).

## Acceptance Criteria (from Step 2.5)

- **AC1** — `upToDate` skip → entry in `provenance.plist`; `goh which` shows it (not "(not recorded)").
- **AC2** — `firstUse` / accepted `tofuChange` skip → in plist; `goh verify --all` reports OK next run.
- **AC3** — canonical destination-path form identical to the download path; updates, never duplicates.
- **AC4** — recording is non-fatal; an all-present `goh sync` with the daemon stopped still exits 0.
- **AC5** — on-disk `ProvenanceRecord` format unchanged (additive-optional `verifiedAt` keeps the
  `provenance-v1.plist` golden fixture decodable; no `currentVersion` bump).

## Dependency Enumeration

Modified interfaces and their consumers (from Agent B, `[VERIFIED]`):

- **XPC `Command` wire contract** (`protocolVersion = 3 → 4`). Consumers: `GohCommandClient`
  (stamps version symbolically — auto-updates), `CommandService` (exact-equality reject —
  constant bump only), `CommandDispatcher` (exhaustive switch — compile-enforced new arm),
  `CommandTests.commandRoundTrip` (exhaustive case array — compile-enforced), `envelope-v3-*`
  golden fixtures (retained immutable; add `envelope-v4-*`). New `CommandOutcome.ack` +
  `AckReply`.
- **On-disk `ProvenanceEntry`** gains `verifiedAt: Date?` (additive-optional). Consumers:
  `ProvenanceStore` (encode/decode + new merge method), `provenance-v1.plist` golden round-trip,
  `goh which` (render), `goh verify --all` (tolerate; verifies sha256 as before).
- **`GohSyncCommand`** gains a verified-entry collector + one batch send. No interface it exports
  changes.

## Questions Asked & Answers

### Zero Silent Failures
- **What happens to existing users/data on ship?** Existing provenance entries are preserved —
  the merge keeps each entry's `downloadedAt` when the on-disk SHA-256 still matches; only
  `verifiedAt` is added. New sync-verified files appear as new entries. No reader breaks: old
  records decode with `verifiedAt = nil`; the v1 golden fixture still decodes.
- **What happens during a rolling/partial upgrade (new CLI, old daemon)?** The
  `recordVerifiedProvenance` call carries `protocolVersion 4`; an old daemon rejects it with a
  clean `protocolVersionMismatch`. Because recording is **best-effort**, sync catches it, warns
  ("provenance not recorded — restart the daemon"), and completes with its normal exit code.
- **Second-step-fails partial state?** Recording is one batch *after* the per-file work; if the
  daemon dies mid-sync, some files are recorded and some are not — each write is atomic
  (`rename(2)`), so no corruption, and the next sync re-verifies and records the rest. Safe and
  recoverable.

### Failure at Scale
- **10× volume — what breaks first?** A manifest of thousands of already-present files. **Gap
  found:** one command + one full-plist rewrite per file is O(n²). **Fix:** a single
  **batch** request (`recordVerifiedProvenance(entries: [...])`) applied in one daemon-side
  read-modify-write → O(n) total, one XPC round-trip. (If a batch is ever too large, it may be
  chunked, but personal-scale manifests do not require it.)
- **Concurrent operations?** Concurrent syncs, or a sync's batch racing a download completion,
  all funnel through the daemon's single `ProvenanceStore` writer; the merge runs inside one
  `Mutex.withLock`, so writes serialize with no lost-update and no corruption. (This is exactly
  the hazard the rejected direct-write approach could not avoid.)
- **Daemon unavailable?** The daemon *is* the only dependency. Down → batch fails → best-effort
  warn → sync exits per pre-feature semantics (AC4).

### Simplest Attack
- **Cheapest abuse?** The command rides the existing same-team peer-validated XPC channel — no
  new network surface; only a same-team local process can call it. A same-user process could
  already write the 0600 user-owned plist directly, so this adds no privilege. Ledger poisoning
  is bounded to what the user can already do to their own file. (Noted, accepted.)
- **Missing/misconfigured authz on the new command?** It reuses `CommandService`'s existing peer
  requirement; there is no per-command authz to misconfigure. The daemon canonicalizes the
  request path the same way the download path does (single source of truth) and never opens the
  path during recording (it trusts the CLI's freshly-computed hash — consistent with the trust
  model: the user's own CLI verified the user's own file).
- **Crafted request crashing the daemon?** Payload is strings/ints/date only; recording is a
  pure in-memory merge + atomic write. No path-traversal vector (path is a logical key, not used
  to open files during record).

## Gaps Found

1. **`downloadedAt` undefined for a verified-not-downloaded file** (surfaced by the `verifiedAt`
   choice + AC3 update-not-duplicate).
2. **O(n²) full-plist rewrites** for a large all-present sync (violates provenance's O(n) bet).
3. **protocolVersion mismatch during partial upgrade** could abort sync if recording were fatal.
4. **Additive `verifiedAt` vs the v1 golden round-trip** — must confirm the field is truly
   additive (nil omitted; fixture still decodes byte-stable).
5. **`goh which` / `verify --all` must render/tolerate `verifiedAt`** (and `which` should
   distinguish downloaded vs verified-present).

## Fixes Applied

1. **Hash-keyed merge** (daemon-side, atomic under the store Mutex): `existing && existing.sha256
   == request.sha256` → preserve `downloadedAt`, set `verifiedAt`, refresh `url/size`; else →
   new entry with `downloadedAt = verifiedAt` and `verifiedAt` set. The request carries the ALREADY-`"sha256:"`-prefixed digest (from `FileDigest.sha256WithSize`); the daemon stores it verbatim without re-prefixing. The daemon canonicalizes the request path identically to the download path.
2. **Batch command** `recordVerifiedProvenance(entries: [VerifiedProvenanceEntry])` → one
   daemon read-modify-write. Add `ProvenanceStore.recordVerified(entries:)` doing the merge for
   all entries inside one `withLock`.
3. **Best-effort recording**: sync wraps the batch send in do/catch+warn; recording can never
   change sync's per-entry exit contribution or overall exit code (AC4). An all-present,
   daemon-down sync still exits 0.
4. **Additive-optional `verifiedAt: Date?`**: implementation must verify the `provenance-v1.plist`
   round-trip stays green (nil optional omitted in binary plist). If synthesized Codable does not
   round-trip byte-stable, this becomes a spec/implementation note — but no `currentVersion` bump
   and no new v2 on-disk format is authorized by this slice.
5. **Reader updates in scope**: `goh which` renders "downloaded <date>" vs "verified <date>" (or
   both) based on `verifiedAt`; `goh verify --all` is unchanged in its hash check and simply
   includes the new entries.
