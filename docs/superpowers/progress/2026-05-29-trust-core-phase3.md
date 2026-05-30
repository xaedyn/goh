---
date: 2026-05-30
feature: trust-core
phase: 3
status: executed (verified by passing tests)
---

# Phase 3 Progress — Daemon DownloadFile path-confinement hardening

## What was built

- `Sources/GohCore/Model/GohError.swift` — added `ErrorCode.symlinkComponentRefused`
  - Added to all exhaustive switches across the codebase (DownloadEngine.retryEligible, any CLI mapping)
- `Sources/GohCore/Engine/DownloadFile.swift` — hardened `init(path:expectedSize:truncate:)`
  - Added `O_NOFOLLOW` to the existing `O_RDWR | O_CREAT` flags (keeping `O_TRUNC` for fresh, none for resume; NO `O_EXCL`)
  - Added `Self.refuseSymlinkedComponents(in:)` — base-free `openat` descent of destination's own path components, each intermediate dir opened `O_NOFOLLOW | O_DIRECTORY`; throws `GohError(.symlinkComponentRefused)` if any component is a symlink or non-directory
  - `ELOOP` from `open(2)` also maps to `GohError(.symlinkComponentRefused)`
- `Tests/GohCoreTests/DownloadFileConfinementTests.swift`
  - Normal write succeeds (regression: O_NOFOLLOW must not break normal writes)
  - Resume (truncate:false) succeeds (regression)
  - Symlinked final component refused
  - Symlinked intermediate directory refused
  - TOCTOU: symlink planted after lexical check caught at write time

## Current state of modified files

- `GohError.swift`: one new `case symlinkComponentRefused` in `ErrorCode`
- `DownloadFile.swift`: `init` has two added behaviors; all other methods unchanged
- `DownloadEngine.swift` (or wherever `retryEligible` is): `.symlinkComponentRefused` → `false`

## Contracts established

- `ErrorCode.symlinkComponentRefused` is the discriminable error for daemon confinement refusal.
- The daemon's write-path hardening is base-free: it receives only `destination`, never `base`.
- `protocolVersion` stays 3; no frozen-contract change.
- All downloads (not just sync) are hardened.

## Open items

- CLI must map `GohError(.symlinkComponentRefused)` from daemon to exit code 5 (not 8).
  This mapping is implemented in `GohSyncCommand.downloadAndAccept` (Phase 6) where the
  `daemonError` branch checks `err.code == .symlinkComponentRefused`.

---

## ⚠️ Implementation traps — read before writing Phase 3 (hard-won, 6 review rounds)

This phase's `openat`/`O_NOFOLLOW` mechanism was mis-specified **three separate
times** during design+plan review. The plan prose is now correct, but these are
the specific wrong instincts that kept recurring — do not repeat them:

1. **Do NOT `open()` the destination by absolute path after proving the parent
   with `openat`.** The proof and the write must be the SAME fd chain: the final
   open is `openat(parentFd, finalComponent, …)` relative to the proven parent fd,
   never a second absolute `open(path, …)`. A separate absolute open re-resolves
   every component through the kernel again, re-opening the exact TOCTOU window
   the descent was meant to close. (Bug in review round 5.)
2. **Do NOT use `FileManager.createDirectory` for missing intermediates** — it
   follows symlinks. Create each missing dir with `mkdirat(parentFd, comp, …)`
   relative to the proven parent fd, then `openat` it `O_NOFOLLOW|O_DIRECTORY` to
   descend. (The first sketch abandoned the descent on the first `ENOENT` and fell
   back to FileManager — making confinement a NO-OP for every fresh download,
   which has no pre-existing parent dirs. Review round 4.)
3. **Do NOT add `O_EXCL`** to the download open. Resume reopens the same
   destination in place (`truncate: false`) to append; `O_EXCL` breaks every
   resume. Keep `O_RDWR | O_CREAT`, `O_TRUNC` fresh-only.
4. **The daemon has NO `base`.** `AddRequest`/`JobSummary` carry only the absolute
   `destination`. The descent is base-free — anchor at `/` (or the first existing
   real-directory ancestor) and walk the destination's own components. The lexical
   "stay inside base" check belongs to the CLI (`SyncPathConfinement`, Phase 6),
   the only side that has `base`. Do not try to give the daemon `base` — that
   forces an `AddRequest` field + protocolVersion bump, which is forbidden.
5. **Map BOTH `ELOOP` and `ENOTDIR`** from the final `openat` to
   `.symlinkComponentRefused` (→ exit 5), consistent with the descent; other
   errnos → `openFailed` (→ exit 8).

### How to verify this phase (running-code gate)

Correctness is established by **passing tests, not prose**:
1. Write the symlink-swap tests FIRST — three cases: (a) fresh-download
   intermediate symlink (parent dirs do NOT pre-exist), (b) **parent-directory-
   component** swap (proves the parent-fd-relative chain — a final-component-only
   test passes with mere `O_NOFOLLOW` and gives false confidence), (c)
   final-component symlink.
2. Run, SEE THEM FAIL.
3. Implement.
4. Run, SEE THEM PASS (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   swift test --filter DownloadFileConfinementTests`).
5. Review the COMPILED + TESTED code (Swift + green output), not the prose, before
   this phase merges.

### Scope reminder (do not re-escalate)

The TOCTOU symlink-race this closes is a same-machine attacker already running
code on the box — an ACCEPTED residual risk in goh's v0.1 threat model (cf. the
`SMAppService` deferral in ROADMAP.md). The **load-bearing** defense against the
real attack (a hostile shared `gohfile` with `../` or absolute `path`) is the
**lexical confinement** in Phase 6 (`SyncPathConfinement`). Implement this
hardening and make its tests pass — but if a genuinely hard POSIX edge surfaces,
it is acceptable to ship the tested lexical + `O_NOFOLLOW`-final-component defense
and file the deeper race as a documented limitation, rather than block v1. Do NOT
let review re-escalate this into an open-ended v1 blocker (that pattern cost ~6
rounds; see STATE.md process note).
