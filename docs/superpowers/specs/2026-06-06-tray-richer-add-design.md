---
date: 2026-06-06
feature: tray-richer-add
type: spec
approach: A — Add Download window
status: draft
revision: 2 (post adversarial spec review round 1 — 4 block issues fixed)
---

# Spec — Richer Add in the Tray (Add Download window)

## 1. Problem

The tray app can only add a download with defaults — it sends `AddRequest(url:)` with `destination`
and `connectionCount` left `nil`. A user who wants to choose *where* a file saves or *how many*
connections to use must drop to the CLI. `AddRequest` already carries both fields and the daemon
already honors them, so the gap is purely the GUI. This spec adds a small **Add Download window**
(opened from the popover) with an editable URL, a folder picker, and an automatic/connections control.
It is a **pure GUI change** — no wire/protocol/daemon change.

## 2. Success metrics

Done = all five acceptance criteria
(`docs/superpowers/research/2026-06-06-tray-richer-add-acceptance-criteria.md`) hold, plus:
- `swift build -warnings-as-errors` clean; full existing suite green (currently 735) + new tests.
- From the popover, an "Add download…" entry opens a window; choosing a folder sets
  `AddRequest.destination`; pinning a count sets `AddRequest.connectionCount`; leaving folder unset →
  `nil`, leaving "Automatic" on → `nil`.
- The existing one-tap clipboard add is byte-unchanged (`AddRequest(url:)` only).
- No diff to `Sources/GohCore` wire/contract; `protocolVersion` unchanged.

Rollback trigger: any existing test regresses, or an add from the window sends a non-nil field the
user didn't choose.

## 3. Out of scope
- **Persisting** the chosen folder/count as a default (that's Approach B / a future convenience).
- Per-add **priority** or **cookie** toggles (existing defaults apply).
- **gohfile sync**, **verify/which**, **auth import** (separate slices).
- Reworking the existing Preferences sheet.
- Any change to the daemon, the engine, `AddRequest`, or the wire format.

## 4. Behavior & flow
- The popover gains an **"Add download…"** button (alongside the existing one-tap quick-add, which
  stays). Tapping it calls `NSApp.activate(ignoringOtherApps: true)` then `openWindow(id:)` for a
  SwiftUI `Window` scene, and dismisses the popover.
- The **Add Download window** contains:
  - A **URL field**, prefilled with the detected clipboard URL if present, editable. Validation reuses
    the SHIPPED `GohClipboardURLDetector.url(from:)` (http/https-only, authority/port/percent checks) —
    NOT a hand-rolled `URL(string:)` — for parity with the one-tap path. The **Add** button is disabled
    unless `GohClipboardURLDetector().url(from: urlText) != nil`, and the request submits the detector's
    **normalized** `url.absoluteString` (not the raw text).
  - A **destination row**: a "Choose folder…" button + a label showing the chosen path or
    "Downloads (default)". Choosing runs `NSApp.activate(ignoringOtherApps: true)` then
    `NSOpenPanel.begin(completionHandler:)` with `canChooseDirectories = true`,
    `canChooseFiles = false`, `allowsMultipleSelection = false`. A "Use default" affordance clears it.
  - A **connections row**: `Toggle("Automatic")` (default ON) + a `Stepper(value:in: 1...16)` that is
    disabled while Automatic is on.
  - An **Add** button → builds `AddRequest` and calls the view model's `submit()`; on success the
    window **closes** (decided: close-on-success, not "clear for another"); on failure it shows a
    plain-English message and stays open for retry.
- **Field mapping (load-bearing):**
  - `url` = the detector's normalized `absoluteString` (canAdd guarantees it is non-nil).
  - `destination` = the chosen folder path, or `nil` if none chosen (never a reconstructed `~/Downloads`).
  - `connectionCount` = `nil` when Automatic is ON; when OFF, the count **clamped** to the valid range:
    `UInt8(min(16, max(1, connectionCount)))` (never literal `8`, never a trapping conversion).

## 5. Security surface
- **No new IPC** — reuses the existing `.add` XPC command and its peer validation. No wire change.
- The destination is a folder the user picked via `NSOpenPanel`, passed as a plain path `String`
  (non-sandboxed → no security-scoped bookmark needed). The daemon's existing path handling
  (`openConfined`, `..` rejection) is unchanged and still applies.
- The connection count is a `UInt8` clamped to 1–16 client-side; the daemon also caps/validates. No
  untrusted external input is introduced.

## 6. Edge cases
- **Empty/invalid URL:** Add disabled; an inline hint explains why. Never send a malformed `AddRequest`.
- **No folder chosen:** `destination: nil` → daemon's `~/Downloads` default (unchanged).
- **Automatic ON:** `connectionCount: nil` → governor/bandit runs (not forced to 8).
- **Stepper bounds:** cannot go below 1 or above 16.
- **Daemon unreachable / add throws:** map to `GohMenuError`, show plain-English text in the window,
  keep the window open for retry; never surface a raw error.
- **Reopening "Add download…":** focuses the single existing window (fixed `Window` id), does not spawn
  multiple windows.
- **Accessory-app focus:** the window and the `NSOpenPanel` are brought front via
  `NSApp.activate(ignoringOtherApps: true)`; activation policy is NOT switched to `.regular`.
- **Folder picker cancelled:** no change to the current selection.
- **Clipboard has no URL:** the URL field opens empty; the user types one; Add stays disabled until valid.

## 7. Interface contracts

All new types in `GohMenuBar` (testable) with the live AppKit folder-pick injected at the `goh-menu`
composition root. `nonisolated`-first on any Sendable decl per convention.

### 7.1 Folder picker (injectable so the view model / tests don't touch AppKit)
```
public protocol FolderPicker: Sendable {
    /// Presents a directory chooser; returns the chosen folder path, or nil if cancelled.
    @MainActor func chooseFolder() async -> String?
}
```
- Live impl `NSOpenPanelFolderPicker` lives in **`goh-menu`** (the composition root) so `GohMenuBar`
  stays AppKit-panel-free and unit-testable: `NSApp.activate(...)` + `NSOpenPanel.begin`, dirs-only,
  returns `url.path` or nil. Not unit-tested (real AppKit).
- Test impl: a stub returning a scripted path or nil.

### 7.2 Add-form view model
```
@MainActor public final class AddDownloadViewModel: ObservableObject {
    @Published public var urlText: String
    @Published public var chosenFolder: String?      // nil = default (~/Downloads)
    @Published public var automaticConnections: Bool // true = nil connectionCount
    @Published public var connectionCount: Int       // 1...16, used only when !automatic
    @Published public private(set) var errorText: String?

    /// True iff GohClipboardURLDetector().url(from: urlText) != nil (the SHIPPED validator).
    public var canAdd: Bool

    public init(initialURL: String?, client: any GohMenuClient, folderPicker: any FolderPicker)
    public func chooseFolder() async         // see guard below
    public func useDefaultFolder()           // clears chosenFolder → nil
    public func submit() async -> Bool       // builds AddRequest, calls client.add; true on success
}
```
- **`canAdd`** = `GohClipboardURLDetector().url(from: urlText) != nil` — the only gate on the Add button.
  Garbage (`"foo"`, `"file://x"`, whitespace-only, empty) → `false`.
- **`chooseFolder()`** must guard against cancel: `if let path = await folderPicker.chooseFolder() {
  chosenFolder = path }` — a cancelled pick leaves `chosenFolder` unchanged (never clears it).
- **`submit()`** — let `url = GohClipboardURLDetector().url(from: urlText)`; guard non-nil (else no-op,
  return false). Build:
  `AddRequest(url: url.absoluteString, destination: chosenFolder,
  connectionCount: automaticConnections ? nil : UInt8(min(16, max(1, connectionCount))))`. On thrown
  error: `errorText = GohMenuErrorMapper.map(error).userFacingMessage` (the reusable accessor in §7.4 —
  NEVER a raw `String(describing:)`); return false. On success: clear `errorText`, return true.

### 7.3 Reusable plain-English error text
Add a `nonisolated public var userFacingMessage: String` accessor to the existing `GohMenuError`
(`GohMenuModels.swift`) returning a single plain-English sentence per case (e.g. daemon-unavailable →
"goh's background service isn't reachable — run goh doctor."; peer-validation / protocol-mismatch /
malformed-reply / daemon(error) each get a calibrated sentence). This is the single source the add
window uses for `errorText`; it never emits an enum case name or `String(describing:)`. (The existing
`GohMenuPresenter` tuple copy is unchanged; this is an additive accessor.)

### 7.4 View + scene
- `AddDownloadView` (SwiftUI): URL field, destination row (Choose folder…/path label/Use default),
  `Toggle("Automatic")` + `Stepper(1...16)`, Add/Cancel, error text. Accessibility labels on controls.
- A `Window(id: "add-download")` scene in `goh-menu/main.swift`; the popover's "Add download…" button
  uses `@Environment(\.openWindow)` after `NSApp.activate(...)`.

## 8. Components to build
- `GohMenuBar/FolderPicker.swift` — `FolderPicker` protocol + a test-friendly seam.
- `GohMenuBar/AddDownloadViewModel.swift` — the form view model (unit-tested).
- `GohMenuBar/AddDownloadView.swift` — the SwiftUI form.
- `GohMenuBar/GohMenuModels.swift` — add `nonisolated public var userFacingMessage: String` to
  `GohMenuError` (§7.4).
- `goh-menu/main.swift` — `NSOpenPanelFolderPicker` live impl (`NSApp.activate(ignoringOtherApps:true)`
  + `NSOpenPanel.begin`, dirs-only), the `Window(id: "add-download")` scene, the popover entry that
  `NSApp.activate(...)` + `openWindow(id:)`. If `openWindow` does not front-order reliably in the
  `.accessory` app, fall back to `NSApp.activate` + the window's `makeKeyAndOrderFront`/
  `orderFrontRegardless` (do NOT switch activation policy to `.regular`).
- `GohMenuBar/GohMenuView.swift` — add the "Add download…" button to the popover.
- Tests in `Tests/GohMenuBarTests/` (`AddDownloadViewModel`, via the existing `FakeMenuClient` +
  a stub `FolderPicker`):
  - folder chosen → `AddRequest.destination` == chosen path; not chosen → `nil`.
  - automatic ON → `connectionCount` `nil`; pinned OFF → exact `UInt8`.
  - **out-of-range `connectionCount` (e.g. 0, 99) does NOT trap and is clamped to 1...16** in `submit()`.
  - submitted `url` equals the detector's **normalized** `absoluteString` (not raw text).
  - `canAdd == false` for `""`, `" "`, `"foo"`, `"file://x"`; and a `submit()` while invalid is a no-op
    (no `add` call recorded).
  - add failure (FakeMenuClient throws a known `GohMenuError`/client error) → `errorText` equals the
    **specific plain-English** `userFacingMessage` (assert the string, not just non-nil); no raw text.
  - `chooseFolder()` after a stubbed cancel (picker returns nil) leaves `chosenFolder` unchanged.
  - a direct unit test of `GohMenuError.userFacingMessage` for each case (plain sentence, no enum name).
  - regression: the existing popover one-tap add still sends `AddRequest(url:)` only (unchanged).

## 9. Rollout & migration
- Additive; new files + a popover button + a window scene. The only change to existing behavior is a
  new button in the popover footer/primary area. The one-tap quick-add path is unchanged.
- Rollback = revert the PR; no persisted state.

## 10. Unverified research claims relied upon
- `.fileImporter` is unreliable from the popover; `NSOpenPanel.begin` + `NSApp.activate` from a real
  window is the safe path [SINGLE]. If the live picker misbehaves, the protocol seam lets us swap the
  impl without touching the view model/tests.
- Non-sandboxed apps need no security-scoped bookmark [UNVERIFIED] — if false, only the live picker
  impl changes (return a bookmark-resolved path); the contract (a path String) is unaffected.
