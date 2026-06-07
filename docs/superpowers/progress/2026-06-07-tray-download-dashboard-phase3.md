---
date: 2026-06-07
feature: tray-download-dashboard
phase: 3
status: not-started
tasks: [T5, T6, T7]
depends-on: phase2
---

# Phase 3 — UI + wiring

## Goal
Fix the popover collapse and add "Downloads…" button (T5); build the rich `DownloadsWindowView` (T6); wire `Window(id:"downloads")` in `main.swift` (T7). All three tasks are build-validated (`swift build -warnings-as-errors`) and confirmed by manual smoke.

## Gate
`swift build -Xswiftc -warnings-as-errors` clean + `swift test` green + manual smoke: one active download → popover shows row (non-zero height) → "Downloads…" opens window → row has determinate progress bar + secondary line with speed/ETA/elapsed/connections.

## Tasks

### T5 — MODIFY `Sources/GohMenuBar/GohMenuView.swift` — fix collapse + "Downloads…" button

**AC1 (no collapse) + AC5 (no regression)**

- [ ] Read lines 163–183 (`jobs` computed var) before changing
- [ ] Replace `ScrollView { LazyVStack ... }.frame(maxHeight: 260)` with a capped top-N `VStack`:
  - [ ] Show top 5 rows via `model.state.rows.prefix(5)` as a `VStack` (not `ScrollView`)
  - [ ] Add `.frame(minHeight: 32)` so SwiftUI never collapses to zero height in the popover
  - [ ] Show "N more — see Downloads" caption when `rows.count > 5`
- [ ] Add "Downloads…" `Button` below the jobs section (before the lower `Divider()`):
  - [ ] Action: `NSApp.activate(ignoringOtherApps: true); openWindow(id: "downloads")`
  - [ ] Label: `Label("Downloads…", systemImage: "arrow.down.circle")`
  - [ ] `.buttonStyle(.bordered)`, `.controlSize(.small)`
  - [ ] `.accessibilityLabel("Open Downloads window")`
  - [ ] `.help("Open the Downloads window to see all downloads")`
- [ ] Run `swift build -Xswiftc -warnings-as-errors` — clean
- [ ] Run `swift test` — full suite green
- [ ] Manual smoke note: popover with 1 active job shows the row with non-zero height; "Downloads…" button visible

### T6 — CREATE `Sources/GohMenuBar/DownloadsWindowView.swift`

**AC1 (rows in window) + AC3 (rich rows) + AC4 (completed/failed state)**

- [ ] Read `GohMenuModels.swift` fields (`progressFraction`, `sizeText`, `etaText`, `elapsedText`, `connectionText`, `verifyStatus`) before writing views
- [ ] Read existing `GohMenuView.swift` `orderedControls` private extension; if still private, move it to an `internal extension GohMenuJobRow` in `GohMenuModels.swift` (so `DownloadsWindowView.swift` can use it without duplication)
- [ ] CREATE `Sources/GohMenuBar/DownloadsWindowView.swift`:
  - [ ] `public struct DownloadsWindowView: View` — `@ObservedObject private var model: GohMenuViewModel`
  - [ ] Empty state: `Text("No downloads yet.")` centered, AC1 edge case
  - [ ] Non-empty: `ScrollView { LazyVStack { ForEach(model.state.rows) { DownloadRowView(...) } } }` — full list, not capped
  - [ ] `.frame(minWidth: 480, minHeight: 200)` — resizable window
  - [ ] `private struct DownloadRowView: View` with `@State private var isHovered = false`:
    - [ ] Primary line: `Image(systemName: fileTypeIcon(for: row.title))` + `Text(row.title).font(.headline).truncationMode(.middle)` + hover-only controls
    - [ ] Progress: `ProgressView(value: row.progressFraction)` when fraction non-nil; `ProgressView()` (indeterminate) when nil
    - [ ] Secondary line `.caption .secondary`: joins non-nil parts of `[sizeText, "ETA \(etaText)", elapsedText, connectionText, verifyStatus]` with ` · `; prepend "Paused" when stateText == "Paused"
    - [ ] Hover controls: `HStack` of buttons for `row.orderedControls` (same action/icon/a11y pattern as GohMenuJobRowView)
    - [ ] `.contentShape(Rectangle()).onHover { isHovered = $0 }`
  - [ ] `private func fileTypeIcon(for filename: String) -> String` — maps common extensions to SF Symbols; default "doc"
  - [ ] All `accessibilityLabel` on controls + `accessibilityHidden(true)` on decorative icon
- [ ] Run `swift build -Xswiftc -warnings-as-errors` — clean
- [ ] Manual smoke note: Downloads window opens; rows show determinate bar (or spinner when total nil); secondary line shows ETA/elapsed/connections for active; completed row shows verifyStatus when ledger entry present

### T7 — MODIFY `Sources/goh-menu/main.swift` — Window(id:"downloads") scene + root

**AC1 (window accessible from popover)**

- [ ] Read existing `AddDownloadWindowRoot` / `TrustWindowRoot` @StateObject pattern before writing
- [ ] ADD `struct DownloadsWindowRoot: View` (uses `@ObservedObject` not `@StateObject` — `GohMenuViewModel` is already owned by `GohMenuAppDelegate`):
  ```swift
  struct DownloadsWindowRoot: View {
      @ObservedObject private var model: GohMenuViewModel
      init(model: GohMenuViewModel) { self.model = model }
      var body: some View { DownloadsWindowView(model: model) }
  }
  ```
- [ ] ADD `Window("Downloads", id: "downloads")` scene in `GohMenuApp.body` (after the existing `Window("Trust", ...)` scene):
  - [ ] Content: `DownloadsWindowRoot(model: appDelegate.model)`
  - [ ] `.windowResizability(.contentMinSize)`
  - [ ] `.defaultSize(width: 600, height: 400)`
  - [ ] `.defaultPosition(.center)`
- [ ] Run `swift build -Xswiftc -warnings-as-errors` — clean
- [ ] Run `swift test` — full suite green
- [ ] Manual smoke checklist:
  - [ ] Launch tray app with ≥1 active download → popover shows row(s) with non-zero height (AC1)
  - [ ] Click "Downloads…" → Downloads window opens (AC1)
  - [ ] Active row: determinate progress bar visible; secondary line shows speed + ETA + elapsed + connections (AC3)
  - [ ] Active row with nil `bytesTotal`: indeterminate spinner; no ETA shown (AC3 edge case)
  - [ ] Completed row: final size + verify status when ledger entry present (AC4)
  - [ ] Failed row: error summary visible (AC4)
  - [ ] `goh ls` output: speed column shows rolling rate — run a download, observe the RATE column does not monotonically climb (AC2)

## Phase 3 completion criteria
- [ ] `swift build -Xswiftc -warnings-as-errors` clean
- [ ] `swift test` — all tests green (no new tests added; build + smoke validate P3)
- [ ] All 5 ACs manually confirmed via the smoke checklist above
- [ ] No `#available` guards, no `explicit-any`, no AI attribution in commits
