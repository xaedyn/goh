---
date: 2026-06-05
feature: provenance-sync-skip-fold
type: approach-memos
---

# Approach Decision Memos — Record provenance for skipped/already-present `goh sync` files

Two decision axes. **Axis 1 — mechanism** (how the CLI gets a verified-skip entry into the
daemon-owned ledger). **Axis 2 — semantics** (what a "verified, not downloaded now" entry
records). The three memos below are Axis-1 architectures; the Axis-2 fork is called out
separately because it applies to whichever recording architecture is chosen.

---

## APPROACH 1 — The Courier  *(recommended)*

CORE IDEA
The CLI hands the verified entry to the daemon over a new XPC command; the daemon — the sole
writer — records it, exactly as it already does for downloads.

MECHANISM
Add `Command.recordProvenance(request: RecordProvenanceRequest)` carrying the entry fields.
`CommandService` routes it to `CommandDispatcher`, which is given the existing
`ProvenanceStore` (it and the dispatcher are already constructed together in `gohd/main.swift`)
and calls `provenanceStore.record(entry:)` inside the same do/catch+warn the completion
handler uses. `goh sync`'s `process()` fires the command after each skip `return`
(`upToDate`/`firstUse`/accepted `tofuChange`), best-effort. `protocolVersion` bumps 3→4 with
new `envelope-v4-*` golden fixtures; the v3 fixtures stay as compatibility history.

FIT ASSESSMENT
Scale fit: matches — personal-scale, one extra small XPC round-trip per already-present file.
Team fit: fits — reuses the established command/dispatcher/fixture pattern end to end.
Operational: none new; same store, same daemon.
Stack alignment: fits existing — no new dependency; idiomatic XPC + plist.

TRADEOFFS
Strong at: preserves the single-writer invariant and the daemon's in-memory cache coherence
(no lost-update, no stale-cache overwrite); honest, clean wire contract.
Sacrifices: touches the frozen XPC contract (protocolVersion bump → four-round on the wire
addition); needs the daemon up to record a skip (mitigated: best-effort, sync still exits 0).

WHAT WE'D BUILD
`RecordProvenanceRequest` payload; `Command.recordProvenance` case; `CommandOutcome.ack` +
`AckReply`; dispatcher store-injection + handler arm; the sync `process()` call sites;
`envelope-v4-*` fixtures + round-trip tests.

THE BET
Keeping the daemon the sole writer is worth a protocolVersion bump — and a best-effort skip
recording (daemon may be down) is acceptable because the download path already treats
provenance as never-fatal.

REVERSAL COST
Easy — the command and the call sites are additive; removing them restores prior behavior, and
v4 can coexist with v3 readers.

WHAT WE'RE NOT BUILDING
No CLI write path to the plist; no cross-process locking; no daemon cache redesign.

INDUSTRY PRECEDENT
Single-writer-through-a-service is the standard fix for multi-writer-to-a-file hazards
`[UNVERIFIED — first-principles]`; mirrors goh's own download completion recording.

---

## APPROACH 2 — The Shared Ledger  *(rejected — fatal landmine)*

CORE IDEA
Make `ProvenanceStore` cross-process safe and let the CLI write skipped entries directly to
`provenance.plist`, the way `goh which`/`verify --all` already *read* it directly.

MECHANISM
Add a `loadForWrite()` + a cross-process `flock` around `record()`'s read-modify-write, plumb a
writable store + resolved path into `GohSyncCommand`, and have the CLI append/update the entry.

FIT ASSESSMENT
Scale fit: matches volume but introduces a concurrency hazard.
Team fit: requires getting cross-process locking + cache invalidation exactly right.
Operational: none new, but a new correctness surface.
Stack alignment: avoids the wire change.

TRADEOFFS
Strong at: no XPC contract change; daemon-down capable.
Sacrifices: **correctness.** Per Agent B `[VERIFIED]`: even with perfect `flock`, the daemon
caches the ledger in memory, so a CLI write goes stale and the daemon's *next* completion
`record()` silently overwrites the CLI's entry. Fixing it forces the daemon to reload-on-every-
write (kills the cache) — a bigger, riskier change than Approach 1. Also contradicts the
documented + test-enforced SOLE-WRITER invariant and BLOCK-3.

THE BET
That cross-process write coordination can be made correct without redesigning the daemon's
cache — which the dependency analysis shows is false.

REVERSAL COST
Hard — undoing a relaxed single-writer invariant and any data loss it caused.

WHAT WE'RE NOT BUILDING
n/a — not recommended.

INDUSTRY PRECEDENT
None that endorses multi-writer to a cache-backed file without reload-on-write.

---

## APPROACH 3 — The Read-Time Reconciler  *(cheapest; doesn't truly unify the ledger)*

CORE IDEA
Write nothing new during sync. Teach `goh which` / `goh verify --all` to fall back to the sync
`gohfile.lock` when a path isn't in `provenance.plist`.

MECHANISM
`which`/`verify --all` already read provenance directly; add a secondary lookup into the
lockfile for paths absent from the ledger, surfacing the lock entry's `{url, sha256, size,
downloadedAt}`.

FIT ASSESSMENT
Scale fit: matches.
Team fit: fits — pure CLI read-side change, no daemon, no wire, no on-disk format change.
Operational: none.
Stack alignment: fits.

TRADEOFFS
Strong at: zero contract changes, daemon-down capable, smallest diff.
Sacrifices: doesn't put sync-verified files in the unified ledger (the stated goal) — it only
*reads* two sources. Only helps files that have a lockfile and whose lockfile the command can
locate (no general "which any file on disk" answer); `verify --all` would need a lockfile to
enumerate. Diverges from the user's chosen "record into provenance.plist."

THE BET
That a read-time union of two files is as good as one ledger — which fails the "unify" goal.

REVERSAL COST
Easy.

WHAT WE'RE NOT BUILDING
No recording at all.

INDUSTRY PRECEDENT
Lockfile-as-source-of-truth is normal; merging two provenance sources at read time is ad hoc.

---

## AXIS 2 — Semantics of a verified-not-downloaded entry (applies to Approach 1 or 3)

**2A — Format-frozen:** keep `ProvenanceRecord.currentVersion = 1`; record `downloadedAt = now`,
understood as "last confirmed present at this hash." Simplest; no on-disk format change; honors
AC5 as written. Conflates "downloaded" with "verified-present" — `goh which` can't tell a user
whether goh actually fetched the bytes or merely re-verified them.

**2B — Verify-stamped:** add `verifiedAt: Date?` (and/or a source marker) to `ProvenanceEntry`.
Matches the SLSA-VSA precedent and is semantically honest. Costs: touches the *second* frozen
contract (on-disk record). If `verifiedAt` is an additive-optional that leaves the
`provenance-v1.plist` golden fixture decodable, it may avoid a `currentVersion` bump; if not, it
is a true v2 (four-round on the on-disk format). `goh which`/`verify --all` output must render it.

---

## Comparison matrix

| Criterion | A1 Courier | A2 Shared Ledger | A3 Read-Time Reconciler |
|---|---|---|---|
| AC1 (upToDate → in plist, `which` shows it) | STRONG — recorded in the ledger | STRONG (if correct) | WEAK — not in ledger; read-time union only |
| AC2 (firstUse/tofu → `verify --all` OK next run) | STRONG | STRONG (if correct) | PARTIAL — needs lockfile present to enumerate |
| AC3 (canonical path, update-not-duplicate) | STRONG — same daemon `record()` keyed by path | PARTIAL — must replicate canonicalization CLI-side | PARTIAL — two sources can disagree |
| AC4 (non-fatal; daemon-down sync still exits 0) | STRONG — best-effort do/catch | STRONG — daemon-down capable | STRONG — no write |
| AC5 (on-disk format unchanged) | STRONG with 2A / PARTIAL with 2B | STRONG with 2A | STRONG |
| Scale fit | STRONG | PARTIAL — concurrency hazard | STRONG |
| Team fit | STRONG — established pattern | WEAK — lock+cache correctness | STRONG |
| Operational burden | STRONG — none new | PARTIAL — new correctness surface | STRONG — none |
| Stack alignment | PARTIAL — protocolVersion bump (four-round) | STRONG — no wire change | STRONG — no contract change |

**Recommendation:** **Approach 1 (The Courier)** on the mechanism axis — it is the only option
that records into the unified ledger without the data-loss landmine, and the protocolVersion
bump is a known, bounded cost the project has paid before. Semantics axis is the real user call;
my lean is **2B-additive-optional** (honest `verifiedAt`, kept additive so the v1 golden fixture
still decodes and no on-disk version bump is forced) — but **2A** is defensible if you want the
absolute minimum surface and accept the downloaded/verified conflation.
