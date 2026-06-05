---
date: 2026-06-04
feature: provenance-everywhere
type: research-brief
---

# Research Brief — Provenance-everywhere (verify-only)

Synthesis of Agent A (industry patterns) + Agent B (codebase dependency map).
≤1000 words.

## The shape of the change (from the codebase)

goh **already computes** the SHA-256 it needs (`ChunkAssembler.hashToCompletion()
-> .digest(String)`, lowercase hex) but **discards it at three sites** in
`DownloadEngine.swift`: `fetchSingle` (~L518), `fetchRanged` (~L840), and the
resume path's `verifyHash` (L451–456). In all three the digest is in scope
immediately before the existing
`complete(jobID:in:transferDuration:isResume:governorOutcome:)` call. So
"capture the digest" is a thread-through, not new computation. `[VERIFIED — code]`

Two ways to carry it out of the engine:
- **Widen `completedDownloadHandler`** (currently
  `(@Sendable (JobSummary, Duration, Bool, GovernorOutcome) -> Void)?`) with a
  `sha256: String?` 5th arg. **Blast radius: tiny** — one production closure
  (`gohd/main.swift` L144–175) + 4 test closures in `DownloadEngineTests.swift`.
  Daemon-internal; no wire/on-disk contract touched. `[VERIFIED — code]`
- **Store the hash on `JobSummary`** via `JobStore.complete(id:)`. Rejected:
  `JobSummary` is a **frozen wire type** — a new field forces a `protocolVersion`
  bump (3→4) and touches every completed-state test. `[VERIFIED — code]`

The natural home for the record is a **daemon-owned store** in
`~/Library/Application Support/dev.goh.daemon/` — because `goh add` flows
through the daemon and the **CLI has no direct digest access**. `HostProfileStore`
is the skeleton to mirror: a `Sendable` class over `Mutex<Inner>`, a versioned
Codable root (`{ static currentVersion = 1; version; entries }`), atomic write
(`.tmp-<UUID>` → `chmod 0600` → `fsync(tmp)` → `rename` → `fsync(dir)`), and
corrupt→sidecar recovery (`<name>.corrupt-<unixtime>`, reset to empty).
`[VERIFIED — code]`

`goh which` gets a new lookup branch between its xattr fallback (which currently
prints `sha256: (not recorded)`) and its exit-4. `goh verify`'s exit-code
contract (`0` OK, `2` FAILED, `6` lock bad, `7` busy, `9` MISSING, `10`
untracked; precedence 9>2>10) is the vocabulary a verify-everything path should
mirror. `[VERIFIED — code]`

## Substrate: flat-file vs SQLite (the load-bearing fork)

- **Flat atomic-rewrite (plist/TOML)** — Cargo.lock, pylock.toml (PEP 751,
  accepted Mar 2025), dpkg `status`. Full file rewritten per change; safe via
  `rename(2)`. Matches goh's existing store idiom exactly; **no new dependency**.
  Cost: O(n) rewrite + reparse per download. `[VERIFIED — pylock.toml spec;
  Cargo docs]`
- **SQLite WAL** — Nix store `db.sqlite` (`ValidPaths(path, hash, narSize,
  registrationTime)`), Chrome `downloads` table. Single-writer/multi-reader
  without "database is locked"; automatic crash recovery via WAL replay; scales
  to millions of rows. Cost: a **new dependency/FFI surface** (libsqlite3),
  against goh's "Apple-frameworks-first, deps need justification" rule.
  `[VERIFIED — sqlite.org/wal.html; Nix store docs]`
- **Append-only log + compaction** — crash-safe O(1) appends, periodic fold/dedup.
  Middle ground; extra machinery (compaction, log-fold reader). `[UNVERIFIED —
  first-principles]`

**Scale reality:** a verify-only record is bounded by *download count*, not file
size — ~200 B/entry → ~200 MB at 1M downloads. At realistic personal volumes
(thousands–tens-of-thousands), an atomic-rewrite plist is comfortably adequate;
SQLite's scaling advantage is unneeded headroom that costs a dependency.
`[UNVERIFIED — size estimate first-principles]`

## Keying (stable identity)

- **Content-key (SHA-256)** is the only identifier stable across a file *move*;
  path-keys go stale, URL-keys diverge on redirect/CDN change. `[VERIFIED — Nix
  content-addressing; Chrome path columns diverge on move]`
- For goh's two queries, a **compound record** fits: `goh which <path>` needs a
  path→entry lookup; verify-everything re-hashes each recorded path against its
  stored hash. So an entry carries `{url, sha256, size, downloadedAt,
  path-at-download-time}`. Re-download of the same destination should **update
  in place** (one entry per logical destination) to avoid duplicate-entry
  growth. `[UNVERIFIED — compound key is first-principles; no single prior tool
  uses this exact shape]`

## Verify report + growth

- Adopt **`OK / FAILED / MISSING`** (+ optional `UNTRACKED`) from
  rpm `-V` / debsums / git-annex `fsck`; mirror goh's existing verify exit codes
  (2 mismatch, 9 missing) so behavior is consistent across both verify paths.
  `[VERIFIED — debsums.1; git-annex-fsck]`
- **No auto-pruning at v1** — bounded by count, deleting an entry only "forgets
  provenance" (no data loss). An explicit housekeeping verb can come later.
  `[SINGLE — Chrome downloads table has no TTL]`

## Portability decision (surfaces at approach selection)

`gohfile.lock` is deliberately **portable** (git-clone + verify reproduces on
any machine). The auto-record is more naturally **machine-local** ("what *this*
machine pulled") — it is daemon-owned and not something you commit. Keeping it
machine-local and **orthogonal to `gohfile.lock`** avoids muddying the lock's
"your declared manifest's frozen record" semantics. `[UNVERIFIED — design
judgment]`

## Implications for the approaches

1. Substrate is the primary axis: **plist daemon-store (idiom match, no dep)**
   vs **reuse the `gohfile.lock` format as a global auto-lock (max reuse, but
   couples to a frozen contract + TOML-rewrite cost + muddied semantics)** vs
   **append-log (scale bet, likely YAGNI)**.
2. Digest capture should **widen the daemon-internal completion handler**, never
   `JobSummary` (frozen wire).
3. Key by destination path for lookup, store the hash for identity; **update in
   place** per destination.
4. Mirror the existing verify exit-code vocabulary; no pruning at v1.
5. Keep the record **machine-local and orthogonal to `gohfile.lock`.**
