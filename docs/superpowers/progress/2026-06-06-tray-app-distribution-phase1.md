---
date: 2026-06-06
feature: tray-app-distribution
phase: 1
title: Value layer
status: not-started
---

# Phase 1 — Value layer

All logic in `GohMenuBar`; all unit-testable with no framework dependencies. No
changes to `goh-menu/main.swift`, no scripts, no `Info.plist`. CI gate: `swift
build -warnings-as-errors` clean + full test suite green.

## Tasks

- [ ] **P1-1** CREATE `Sources/GohMenuBar/GohMenuPreferences.swift` + tests
  - `GohMenuPreferences` protocol + `UserDefaultsMenuPreferences` live impl
  - Tests: defaults false when absent; round-trip notificationsEnabled; round-trip launchAtLoginEnabled; write false after true
  - AC4 coverage

- [ ] **P1-2** CREATE `Sources/GohMenuBar/GohMenuNotifications.swift` (types + pure detector) + tests
  - `GohNotificationAuthorization` enum, `GohNotificationContent` struct, `GohMenuNotificationService` protocol, `GohNotificationTransitionDetector` (pure, no framework)
  - Tests: seed suppression; active→completed fires once; active→failed fires once; already-terminal no-refire; disappearing job dropped; bulk N transitions → N notifications; terminal→same-terminal no-refire
  - AC2 coverage (pure detector)

- [ ] **P1-3** CREATE `Sources/GohMenuBar/GohMenuLoginItem.swift` + tests
  - `GohLoginItemStatus` enum; `GohMenuLoginItem` protocol; `UnsupportedLoginItem`; `GohLoginItemError`
  - Tests: stub returns enabled; stub returns requiresApproval; unsupported returns .unsupported; unsupported register throws; stub records calls
  - AC3 coverage (protocol + enum)

## Phase 1 exit criteria

- [ ] `swift build -warnings-as-errors` clean
- [ ] `swift test` green (all existing tests + 10+ new Phase 1 tests)
- [ ] No `#available` ladders introduced
- [ ] All new Sendable types/structs/enums marked `nonisolated` per convention
- [ ] No XPC, no real framework calls, no file I/O in unit tests

## Notes

_Filled in during execution._
