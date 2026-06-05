---
date: 2026-06-04
feature: provenance-everywhere
type: design-validation
---

# Design Validation — Provenance-everywhere (Approach A: Native Ledger)

## Acceptance Criteria (from Step 2.5)

- **AC1** — Every successful download (manifest or ad-hoc, incl. resume) records
  `{url, sha256, size, downloadedAt, destinationPath}` from the streamed digest.
- **AC2** — `goh which <file>` answers from the record for ad-hoc downloads,
  offline (no `sha256: (not recorded)` fallback).
- **AC3** — Verify-everything re-hashes recorded files offline against their
  stored hash → OK/FAILED/MISSING, mirroring existing verify exit codes.
- **AC4** — Purely additive; new store has its own version field + golden
  round-trip; no frozen contract touched (protocolVersion 3, JobCatalog v1,
  JobSummary wire shape, gohfile.lock v1 all unchanged).
- **AC5** — Re-download updates in place (no dup corruption); corrupt store
  degrades gracefully and never blocks a download.

## Dependency Enumeration

Interface modified: `completedDownloadHandler` (daemon-internal closure) gains a
`sha256: String?` parameter. External consumers enumerated (Agent B):
- **Production:** `Sources/gohd/main.swift` L144–175 — the one closure that
  assigns the handler. Adds a named/`_` 5th param.
- **Tests:** `Tests/GohCoreTests/DownloadEngineTests.swift` closures at L74,
  L107, L1110, L1129 — each adds a wildcard `_`.
- **No other file** sets `completedDownloadHandler`. No XPC wire type, no
  `JobSummary`, no on-disk format consumes this signature. The change is
  daemon-internal and source-only.

`DownloadEngine.complete(...)` gains a `sha256: String?` arg; 3 call sites
(`fetchSingle`, `fetchRanged`, resume) all in `DownloadEngine.swift`.

## Questions Asked & Answers

### Zero Silent Failures
- **Existing users on upgrade?** The daemon creates `provenance.plist` empty on
  first run; no action required. **Pre-feature downloads are NOT retroactively
  recorded** — `goh which` on an older ad-hoc file still shows the xattr
  fallback. The record accrues from upgrade forward. (Boundary, not a defect.)
- **Existing data?** No existing store/format changes. `provenance.plist` is
  net-new and orthogonal to `gohfile.lock`. Existing golden fixtures unchanged.
- **Existing integrations/callers?** Handler widening is daemon-internal; XPC
  wire and `JobSummary` untouched. `goh which`/`verify` keep their current
  behavior (lockfile-first / existing exit codes); new branches are additive.
- **First step succeeds, second fails?** Within a download: the file is finished
  and moved to destination *before* the provenance write. If `record(entry:)`
  fails (disk full / corrupt store), the **download must still report success.**
  → **GAP 1 (fixed below): provenance recording is best-effort/non-fatal**,
  exactly like `SpotlightMetadataTagger` today.

### Failure at Scale
- **10x volume?** Record size is bounded by *download count* (~200 B/entry →
  <100 MB at hundreds of thousands). Full-plist rewrite per completion stays
  sub-perceptible, and it runs **off the download's critical path** (after
  `file.finish()`, best-effort). The documented escape hatch (append-log behind
  the same `record`/`verifyAll` interface) is reachable in one file if ever
  needed.
- **Concurrent operations?** Daemon is the **sole writer**, serialized through
  the store's `Mutex` (copying `HostProfileStore`). Multiple concurrent download
  completions serialize their `record` calls. The **CLI is a read-only
  consumer**; the atomic `rename(2)` guarantees the CLI reads either the old or
  new complete file, never a torn write.
  → **DECISION (GAP 3): the CLI reads `provenance.plist` directly (read-only,
  same-user 0600), NOT via a new XPC command.** This avoids adding XPC wire
  surface (no protocolVersion pressure) and means `goh which`/`verify --all`
  **work even when the daemon is not running** (true offline verify).
- **External dependency unavailable?** None added (no SQLite, no network). If
  Application Support is unwritable, the write fails → best-effort, logged,
  download still succeeds (GAP 1).

### Simplest Attack
- **Cheapest abuse?** No network surface and no new XPC endpoint are added (CLI
  reads the file directly), so the remote/abuse surface is unchanged.
- **Misconfigured auth on a new endpoint?** N/A — no new endpoint. This is an
  affirmative reason to prefer the direct-read design over an XPC query.
- **Unprivileged user?** `provenance.plist` is `0600`, readable only by the
  owning user — same as the other daemon stores. No cross-user leak. An attacker
  who could rewrite the 0600 store to point an entry at a sensitive file is
  already the same user, which is **out of goh's threat model** (DESIGN §3.2:
  same-user attacker already has many options). Verify-everything must still use
  the project's existing hardened at-rest read (`FileDigest`) and must not follow
  surprising symlinks beyond what `goh verify` already accepts.

## Gaps Found

1. **Provenance write could fail the download.** If `record(entry:)` threw and
   propagated, a transient store error would mark a perfectly good download as
   failed — violating AC5.
2. **Resume-path completions would be skipped.** The resume path's `verifyHash`
   discards the digest like the other two sites; without threading it, resumed
   downloads would never be recorded — violating AC1's "every successful
   download."
3. **Cross-process read pattern unstated.** Whether the CLI reads the daemon
   store directly or via XPC was undecided; an XPC route would add frozen-wire
   surface and a daemon-up dependency.

## Fixes Applied (folded into the design before spec writing)

1. **Best-effort recording.** The daemon's `completedDownloadHandler` wraps
   `provenanceStore.record(entry:)` in do/catch, logging on failure and never
   propagating — identical to the existing Spotlight-tagging best-effort
   contract. The download success path is independent of provenance persistence.
   (Spec: §Edge cases + §Rollout.)
2. **Record on all three completion paths incl. resume.** The digest is threaded
   from `ChunkAssembler.hashToCompletion()` through `complete(...)` and the
   handler in `fetchSingle`, `fetchRanged`, **and** the resume path. `verifyHash`
   is changed to return the digest instead of discarding it. (Spec: §Mechanism.)
3. **Direct read, no new XPC.** `goh which` and `goh verify --all` read
   `provenance.plist` directly (read-only, 0600, same-user). No XPC command, no
   protocolVersion change; verify works with the daemon down. (Spec: §Security
   surface + §Mechanism.)

**Accepted boundaries (stated, not fixed — verify-only by user decision):**
- Pre-feature downloads are not back-filled.
- The record is **path-keyed**: moving a recorded file makes `goh which
  <newpath>` miss and verify-everything report the old path MISSING (correct
  "it moved/vanished" behavior for a verify-only tool). Content-key
  cross-reference is a future enhancement, explicitly out of scope.
