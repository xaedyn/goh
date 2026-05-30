---
date: 2026-05-30
feature: trust-core
phase: 3
status: template (fill after execution)
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
