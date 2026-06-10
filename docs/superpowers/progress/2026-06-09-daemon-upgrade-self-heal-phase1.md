---
date: 2026-06-09
feature: daemon-upgrade-self-heal
phase: 1
title: GohCore + Wire + Daemon Report
status: not-started
---

# Phase 1 — GohCore + Wire + Daemon Report

**Scope:** Pure GohCore additions plus the wire additive-optional field.
No CLI surfaces, no tray changes. Fully unit-testable without running a daemon.

## Tasks in this phase

- **Task 1** — `GohFeatureLevel` (Create `Sources/GohCore/Model/GohFeatureLevel.swift`)
- **Task 2** — `DaemonSkew` + `DaemonSkewCheck.evaluate` (Create `Sources/GohCore/Model/DaemonSkewCheck.swift`)
- **Task 3** — `LsReply.featureLevel: Int?` additive-optional (Modify `Sources/GohCore/Model/CommandReply.swift`)
- **Task 4** — Daemon sets `featureLevel` in `.ls` reply (Modify `Sources/GohCore/Model/CommandDispatcher.swift`)

## AC coverage

| AC  | Task |
|-----|------|
| AC1 | 3, 4 |
| AC2 | 2    |
| AC9 | 3    |

## Phase 1 deployment gate

`swift build -Xswiftc -warnings-as-errors` passes.
`swift test --filter DaemonSkewCheckTests` and
`swift test --filter DaemonFeatureLevelTests` and
`swift test --filter LsReplyFeatureLevelTests` all green.
