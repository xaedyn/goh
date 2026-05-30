---
date: 2026-05-30
feature: trust-core
phase: 5
status: template (fill after execution)
---

# Phase 5 Progress — `goh verify`

## What was built

- `Sources/GohCore/CLI/GohVerifyCommand.swift`
  - `GohVerifyCommand.run(lockPath:strictUntracked:)` → `GohCommandLineResult`
  - Loads lock; maps `unsupported lockfileVersion` → exit 1, corrupt → quarantine + exit 6
  - Acquires `flock(LOCK_SH | LOCK_NB)` → exit 7 if busy
  - Re-computes `manifestHash` from alongside `gohfile.toml`; mismatch → exit 6 "lock is stale"
  - Per-entry: `OK` / `FAILED expected … actual …` (exit 2) / `MISSING` (exit 9)
  - Exit precedence: 9 > 2 > 10 (strict-untracked)
- `Sources/GohCore/CLI/GohCommandLine.swift` — added `.verify(lockPath:strictUntracked:)` + parse + dispatch
- `Tests/GohCoreTests/GohVerifyCommandTests.swift`
  - All-match exit 0 (AC2 all-match case)
  - Content mismatch exit 2, FAILED line (AC2)
  - Missing file exit 9, MISSING line (§6 / distinct from FAILED)
  - MISSING > FAILED precedence
  - Missing lock exit 6
  - Unknown lockfileVersion exit 1
  - --strict-untracked exit 10
  - Stale manifestHash exit 6
  - Concurrent verify (flock busy) exit 7

## Contracts established

- `goh verify` is read-only; never downloads.
- MISSING (exit 9) is observable-distinct from FAILED (exit 2).
- Exit code precedence: 9 > 2 > 10 (no MISSING or FAILED → only 10 for untracked).
- Stale lock → exit 6 (not a hard error; run sync to repair).

## Open items

- None. Phase 6 can proceed.
