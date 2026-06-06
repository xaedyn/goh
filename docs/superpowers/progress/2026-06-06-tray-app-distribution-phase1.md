---
date: 2026-06-06
feature: tray-app-distribution
phase: 1
title: Value layer
status: complete
---

# Phase 1 — Value layer

All logic in `GohMenuBar`; all unit-testable with no framework dependencies. No
changes to `goh-menu/main.swift`, no scripts, no `Info.plist`. CI gate: `swift
build -warnings-as-errors` clean + full test suite green.

## Tasks

- [x] **P1-1** CREATE `Sources/GohMenuBar/GohMenuPreferences.swift` + tests
  - `GohMenuPreferences` protocol + `UserDefaultsMenuPreferences` live impl
  - Tests: defaults false when absent; round-trip notificationsEnabled; round-trip launchAtLoginEnabled; write false after true
  - AC4 coverage

- [x] **P1-2** CREATE `Sources/GohMenuBar/GohMenuNotifications.swift` (types + pure detector) + tests
  - `GohNotificationAuthorization` enum, `GohNotificationContent` struct, `GohMenuNotificationService` protocol, `GohNotificationTransitionDetector` (pure, no framework)
  - Tests: seed suppression; active→completed fires once; active→failed fires once; already-terminal no-refire; disappearing job dropped; bulk N transitions → N notifications; terminal→same-terminal no-refire
  - AC2 coverage (pure detector)

- [x] **P1-3** CREATE `Sources/GohMenuBar/GohMenuLoginItem.swift` + tests
  - `GohLoginItemStatus` enum; `GohMenuLoginItem` protocol; `UnsupportedLoginItem`; `GohLoginItemError`
  - Tests: stub returns enabled; stub returns requiresApproval; unsupported returns .unsupported; unsupported register throws; stub records calls
  - AC3 coverage (protocol + enum)

## Phase 1 exit criteria

- [x] `swift build -warnings-as-errors` clean
- [x] `swift test` green (732 tests in 100 suites)
- [x] No `#available` ladders introduced
- [x] All new Sendable types/structs/enums marked `nonisolated` per convention
- [x] No XPC, no real framework calls, no file I/O in unit tests

## Notes

- P1-1: committed 8017038 — `UserDefaultsMenuPreferences` uses `nonisolated` on every member (not just the class).
- P1-2: committed 5667016 + 05f8ab8 — pure `GohNotificationTransitionDetector`; `isTerminal` extension marked `nonisolated`.
- P1-3: committed on 2026-06-06 — 5 new tests green; 732 total tests passing; build warning-free.
