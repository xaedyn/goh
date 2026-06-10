---
date: 2026-06-09
feature: daemon-upgrade-self-heal
phase: 3
title: Tray Skew Notice + Idle-Gated Restart Action
status: not-started
---

# Phase 3 — Tray Notice + Action

**Scope:** Surface daemon skew in the tray via a neutral notice and an
idle-gated "Restart background service" action. Reuses the `.ls` health read
already done by the tray's progress stream. Depends on Phase 1 (wire field)
and Phase 2 (DaemonRestarting protocol).

## Tasks in this phase

- **Task 11** — `GohMenuClient.ls() async throws -> LsReply` — expose a one-shot ls to the client protocol (Modify `Sources/GohMenuBar/GohMenuViewModel.swift` protocol + `Sources/goh-menu/main.swift` `LiveGohMenuClient`)
- **Task 12** — Skew check in `GohMenuViewModel` + skew notice in `GohMenuModels` / `GohMenuPresenter` (Modify `Sources/GohMenuBar/GohMenuViewModel.swift`, `Sources/GohMenuBar/GohMenuModels.swift`, `Sources/GohMenuBar/GohMenuPresenter.swift`)
- **Task 13** — Idle-gated restart action in `GohMenuViewModel` (Modify `Sources/GohMenuBar/GohMenuViewModel.swift`, `Sources/GohMenuBar/GohMenuView.swift`)

## AC coverage

No new ACs — tray is the spec §4.7 surface. These tasks implement it per spec.

## Phase 3 deployment gate

`swift build -Xswiftc -warnings-as-errors` passes.
`swift test --filter GohMenuViewModelTests` and
`swift test --filter GohMenuPresenterTests` green.
