---
date: 2026-06-05
feature: provenance-sync-skip-fold
type: research-brief
---

# Research Brief — Record provenance for skipped/already-present `goh sync` files

## The problem in one line

`goh sync` records provenance only for files it *downloads*; files it finds already
present and hash-matching are skipped and land only in `gohfile.lock`, so `goh which` /
`goh verify --all` are blind to them. We want them in the daemon-owned `provenance.plist`
too. The CLI is the actor; the store is daemon-owned and single-writer.

## Finding 1 — Mechanism: the CLI must NOT write the plist directly (a fatal landmine)

Dependency deep-dive (Agent B, all `[VERIFIED]` against source):

- **`ProvenanceStore.record()` is a whole-file read-modify-write** funnelled through one
  function; `rename(2)` makes each write atomic (no torn file), so the only multi-writer
  risk is **lost-update**, not corruption.
- **The killer:** the daemon keeps the ledger in an in-memory `Mutex<ProvenanceRecord>`.
  A CLI write to disk leaves that cache stale; the daemon's **next** download-completion
  `record()` writes its stale in-memory array back, **silently overwriting the CLI's
  entry**. A cross-process `flock` does NOT fix this — flock serializes writes but cannot
  refresh the daemon's cache. The only fix is making the daemon reload-from-disk on every
  record (negating the cache) — a larger, riskier change than the alternative.
- The single-writer invariant is **documented and test-enforced** (`ProvenanceStore.swift:27`
  "SOLE WRITER"; BLOCK-3 comment at L80; `ProvenanceStoreTests` BLOCK-3 test). Direct CLI
  writes contradict all three.

**Conclusion:** record through the daemon. The clean path is a **new XPC command**
(`recordProvenance(entry)`): daemon stays sole writer, in-memory cache stays coherent.
Cost (Agent B): ~7 source files + a new `.ack` `CommandOutcome` + 2 `envelope-v4-*`
golden fixtures + a `protocolVersion` 3→4 bump (a frozen-wire-contract change → four-round
discipline). The `Command` enum's `Codable` is synthesized; a new case needs only a
`RecordProvenanceRequest` payload, and the dispatcher must be handed the `ProvenanceStore`
(both it and the store are already in scope together in `gohd/main.swift`). Compile-time
exhaustiveness on the dispatch switch + the `commandRoundTrip` array is a safety net.

## Finding 2 — Semantics: do NOT fabricate `downloadedAt`; the verified case is distinct

Industry survey (Agent A):

- **Hash-only lockfiles dominate** — Cargo.lock, npm/pnpm, `go.sum`, Nix `flake.lock`,
  restic blobs carry **no timestamp at all** `[VERIFIED]`. If the hash matches, "when" is
  irrelevant to correctness. Strongest signal in the data.
- Where a timestamp exists (Go module-cache `.info`, restic snapshot, OCI image config) it
  is the **origin event** (tag/build/backup time) and is **never re-stamped on a cache
  hit** `[VERIFIED]`.
- **SLSA VSA** is the one tool that models verified-present as its own event: a separate
  `timeVerified` field on a separate attestation type `[VERIFIED]`. The recognized
  vocabulary for "confirmed present at T without re-fetching" is **`verifiedAt`/`timeVerified`**.
- Using `file.mtime` as a `downloadedAt` proxy is the worst option — unreliable across
  copies, not a provenance event `[VERIFIED reasoning]`.

**Conclusion (recommendation, not yet decided):** the semantically honest model records the
verification event distinctly. But that means a NEW field on `ProvenanceEntry`, which
touches the **on-disk** frozen format (`ProvenanceRecord.currentVersion = 1`) and would
conflict with AC5 as currently written. The competing pragmatic option keeps the format
frozen and writes `downloadedAt = now` with the understood meaning "last confirmed present
at this hash." This is the load-bearing user-facing decision for the approach gate.

## Dependency enumeration (interfaces this feature may modify)

- **XPC `Command` wire contract** (`protocolVersion = 3`): a new case + bump → consumers are
  `GohCommandClient` (stamps version, symbolic), `CommandService` (exact-equality reject),
  `CommandDispatcher` (exhaustive switch), `commandRoundTrip` test, `envelope-v3-*` fixtures
  (kept; add `v4-*`). In-lock-step CLI/daemon build, so a bump only yields a clean "restart
  daemon" error during a partial upgrade.
- **On-disk `ProvenanceRecord` format** (`currentVersion = 1`): touched ONLY if we add a
  `verifiedAt` field (golden `provenance-v1.plist` round-trip + version constant).
- **`GohSyncCommand`**: no provenance handle today; `dest` is local to `process()` (not in
  the skip helpers) — recording call belongs in `process()` after each skip `return`.

## Risks to carry into design validation

- Daemon-down sync of an all-present manifest must keep exiting 0 → recording on skips is
  **best-effort / non-fatal** (mirror the download completion handler's do/catch+warn).
- A protocolVersion bump is exact-equality; document the in-flight-upgrade behavior.
- If `verifiedAt` is added: decide whether it's an additive-optional field that leaves the
  v1 golden fixture decodable (no version bump) or a true v2 (four-round on the on-disk format).
