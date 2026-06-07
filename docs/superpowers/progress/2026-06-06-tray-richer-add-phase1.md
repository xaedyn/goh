---
date: 2026-06-06
feature: tray-richer-add
phase: 1
title: Value layer
status: pending
---

# Phase 1 — Value layer

All logic in `GohMenuBar` and its test target. No AppKit panels, no XPC, no file I/O.
Gate: `swift build -Xswiftc -warnings-as-errors` clean + full test suite green.

## Tasks

- [ ] **P1-1** MODIFY `Sources/GohMenuBar/GohMenuModels.swift`
  - Add `nonisolated public var userFacingMessage: String` to `GohMenuError`
  - Five cases: daemonUnavailable, peerValidation, protocolMismatch, daemon, malformedReply
  - No enum case names, no `String(describing:)` in returned strings
  - AC5 coverage (additive; no mapper change)

- [ ] **P1-2** CREATE `Sources/GohMenuBar/FolderPicker.swift`
  - `public protocol FolderPicker: Sendable` with `@MainActor func chooseFolder() async -> String?`
  - Protocol only — no concrete type (live impl in goh-menu; stub in tests)
  - Enables unit-testing AddDownloadViewModel without AppKit

- [ ] **P1-3** CREATE `Sources/GohMenuBar/AddDownloadViewModel.swift`
  - `@MainActor public final class AddDownloadViewModel: ObservableObject`
  - Fields: `urlText`, `chosenFolder`, `automaticConnections`, `connectionCount`, `errorText`
  - `canAdd` via `GohClipboardURLDetector().url(from: urlText) != nil`
  - `chooseFolder()` guards cancel (nil pick leaves chosenFolder unchanged)
  - `useDefaultFolder()` clears chosenFolder → nil
  - `submit()` normalizes URL, clamps count with `UInt8(min(16,max(1,count)))`, maps errors via `GohMenuErrorMapper.map(error).userFacingMessage`
  - AC1, AC2, AC3 coverage

- [ ] **P1-4** CREATE `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift`
  - `StubFolderPicker` (private, @MainActor, scripted result)
  - `FakeMenuClient` (private parallel to GohMenuViewModelTests.swift)
  - `GohMenuErrorUserFacingMessageTests` suite: 5 per-case tests
  - `AddDownloadViewModelTests` suite: folder-chosen, cancel-pick-unchanged, useDefaultFolder, automatic-nil, pinned-exact, clamp-0→1, clamp-99→16, normalized-URL, canAdd-false cases, submit-no-op, error-text-string-assert, AC4-regression

## Phase 1 exit criteria

- [ ] `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors` clean
- [ ] `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` green (all existing + new)
- [ ] `GohMenuError.userFacingMessage` returns plain sentences for all 5 cases
- [ ] No AppKit import in any GohMenuBar source file
- [ ] No `#available` ladders introduced
- [ ] No diff to `Sources/GohCore`

## Notes

(filled in after completion)
