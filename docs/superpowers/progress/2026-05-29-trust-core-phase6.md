---
date: 2026-05-30
feature: trust-core
phase: 6
status: executed (verified by passing tests)
---

# Phase 6 Progress — `goh sync`

## What was built

- `Sources/GohCore/TrustCore/SyncPathConfinement.swift`
  - `SyncPathConfinement.resolve(entryPath:base:)` → confined absolute path or `ConfinementError`
  - Rule 1: absolute path → error; Rule 2: lexical `..` escape → error
  - Entry `path` is literal (no `~`/`$` expansion); base has `~` pre-expanded by caller
- `Sources/GohCore/CLI/GohSyncCommand.swift`
  - `GohSyncCommand.run(manifestPath:base:acceptChanged:send:)` → `GohCommandLineResult`
  - flock(LOCK_EX | LOCK_NB) on gohfile.lock → exit 7 if busy
  - Per-entry loop: confine → re-hash if present → skip / AC5 / download
  - Completion detection: `pollUntilTerminal(jobID:send:)` polling `ls` by job id; 120 s no-progress watchdog
  - Pinned acceptance (AC3): digest != pin → quarantine `.corrupt-<unix>`, exit contribution 2
  - TOFU first use (AC3): log "recorded sha256:… (first use, unverified)"
  - AC5: unpinned hash changed → exit 3 without `--accept-changed`; updates lock with `--accept-changed`
  - Daemon `symlinkComponentRefused` → exit contribution 5 (not 8)
  - Atomic lock write: `.tmp` → fsync → `rename(2)` → fsync dir
  - Exit precedence among failures: 5 > 2 > 3 > 8
- `Sources/GohCore/CLI/GohCommandLine.swift` — wired `sync`/`verify`/`which` parse + dispatch + usage
- `Tests/GohCoreTests/SyncPathConfinementTests.swift` — absolute, `..`, valid, `~` literal in path
- `Tests/GohCoreTests/GohSyncCommandTests.swift` — empty sync, idempotency (AC1), pinned (AC3), TOFU (AC3/AC5)

## Contracts established

- `goh sync` is CLI-local: loops existing `add` + polls `ls`; no new XPC command.
- `protocolVersion` stays 3 throughout; no catalog migration.
- Completion detection: terminal states = {completed, failed}; disappeared job → exit 8; 120 s no-progress → exit 8.
- SHA-256 obtained only by CLI re-hash (FileDigest), never from daemon.
- Lock written atomically; only the accepted, hash-verified entries are written.
- AC5 is loud and non-silent; --accept-changed is the explicit opt-in.

## Open items

- `goh sync --base` with `~` expansion: covered by `resolveBase` in implementation.
- Interactive TTY confirm for AC5 (not required in v1 — `--accept-changed` is the opt-in).
- `subscribe`-based completion detection (alternative to poll) — not needed in v1; poll is simpler and correct.
