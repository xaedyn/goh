---
date: 2026-06-06
feature: tray-richer-add
phase: 2
title: UI / wiring layer
status: pending
---

# Phase 2 — UI / wiring layer

SwiftUI view + composition-root wiring. No new unit tests (AppKit layer); build verification
is the gate. Manual smoke required before declaring done.
Gate: `swift build -Xswiftc -warnings-as-errors` clean + full test suite green + smoke pass.

## Tasks

- [ ] **P2-1** CREATE `Sources/GohMenuBar/AddDownloadView.swift`
  - SwiftUI form: URL field, destination row (Choose folder…/path label/Use default), Toggle("Automatic")+Stepper(1...16), Add/Cancel, error text
  - `@Environment(\.dismiss)` for close-on-success and Cancel
  - Accessibility labels on all controls
  - Build-only verification (no unit test)

- [ ] **P2-2** MODIFY `Sources/goh-menu/main.swift`
  - ADD `NSOpenPanelFolderPicker` — live `FolderPicker` impl: `NSApp.activate(ignoringOtherApps:true)` + `NSOpenPanel.begin` (dirs only), returns `url.path(percentEncoded: false)` or nil on cancel
  - ADD `GohMenuViewModel.makeAddDownloadViewModel(folderPicker:)` factory in `GohMenuViewModel.swift` (passes `self.client` + `clipboardURL` initialURL)
  - ADD `Window(id: "add-download")` scene to `GohMenuApp.body`
  - Belt-and-suspenders front: `NSApp.activate(...)` + `openWindow(id:)` + optional `orderFrontRegardless` lookup; do NOT switch to `.regular` activation policy
  - Build-only verification (no unit test)

- [ ] **P2-3** MODIFY `Sources/GohMenuBar/GohMenuView.swift`
  - Add `@Environment(\.openWindow) private var openWindow` at top of struct
  - Add `addDownloadButton` computed property: `NSApp.activate(ignoringOtherApps:true)` + `openWindow(id:"add-download")`; `.bordered` style, `.large` controlSize, accessibility label
  - Insert `addDownloadButton` in body between `primaryAction` and first `Divider()`
  - Existing `primaryAction` and all other views unchanged
  - Build-only verification (no unit test)

## Phase 2 exit criteria

- [ ] `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors` clean
- [ ] `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` green (all existing + Phase 1 tests)
- [ ] `NSOpenPanelFolderPicker` declared only in `goh-menu` (not in GohMenuBar sources)
- [ ] `GohMenuApp.body` contains `Window(id: "add-download")` scene
- [ ] `GohMenuView` contains "Add download…" button; existing one-tap unchanged
- [ ] No new `#available` ladders; no diff to `Sources/GohCore`
- [ ] Manual smoke: window opens; folder pick works; Automatic toggle disables stepper; Add closes on success; Cancel closes without submitting; invalid URL keeps Add disabled; re-opening focuses existing window

## Notes

(filled in after completion)
