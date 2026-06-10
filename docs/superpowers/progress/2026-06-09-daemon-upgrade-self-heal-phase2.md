---
date: 2026-06-09
feature: daemon-upgrade-self-heal
phase: 2
title: CLI Surfaces
status: not-started
---

# Phase 2 — CLI Surfaces

**Scope:** `DaemonRestarting` protocol + live `launchctl` impl; scoped auto-heal
in `verify --all`, `verify --quick`, and `doctor`; `goh daemon restart [--force]`
verb; doctor skew finding; reconcile end-to-end re-schedule assertion.
Depends on Phase 1 being merged.

## Tasks in this phase

- **Task 5** — `DaemonRestarting` protocol + `LaunchctlDaemonRestarter` (Create `Sources/GohCore/Model/DaemonRestarting.swift`)
- **Task 6** — `DaemonAutoHeal` helper (Create `Sources/GohCore/CLI/DaemonAutoHeal.swift`) — the shared polling loop used by verify --all, verify --quick, and doctor
- **Task 7** — Wire auto-heal into `GohVerifyAllCommand.run` and `GohVerifyQuickCommand.run` (Modify both)
- **Task 8** — `goh daemon restart [--force]` verb (Modify `Sources/GohCore/CLI/GohCommandLine.swift`)
- **Task 9** — Doctor skew finding (Modify `Sources/GohCore/CLI/GohDoctor.swift`)
- **Task 10** — Reconcile end-to-end re-schedule assertion (Modify `Tests/GohCoreTests/JobStoreStartupReconciliationTests.swift`)

## AC coverage

| AC  | Task |
|-----|------|
| AC3 | 8    |
| AC4 | 5, 6 |
| AC5 | 6, 7 |
| AC6 | 9    |
| AC7 | 6    |
| AC8 | 10   |

## Phase 2 deployment gate

`swift build -Xswiftc -warnings-as-errors` passes.
`swift test --filter DaemonRestartingTests` and
`swift test --filter DaemonAutoHealTests` and
`swift test --filter GohCommandLineTests` and
`swift test --filter GohDoctorTests` and
`swift test --filter GohVerifyAllCommandTests` and
`swift test --filter GohVerifyQuickCommandTests` and
`swift test --filter JobStoreStartupReconciliationTests` all green.
