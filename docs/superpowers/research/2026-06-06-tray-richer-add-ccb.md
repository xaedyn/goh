---
date: 2026-06-06
feature: tray-richer-add
type: codebase-context-brief
---

# CCB — Richer Add in the Tray

STACK
Swift 6.2, SwiftPM, macOS 26.0+. `GohMenuBar` is MainActor-default isolation; SwiftUI for all
views; the popover is `MenuBarExtra(.window)` (fixed 380pt width). The app runs `.accessory`
activation policy (no Dock icon). Swift Testing (`@Suite`/`@Test`/`#expect`); CI
`-warnings-as-errors`; no `#available` ladders.

EXISTING PATTERNS
- **Add today:** `GohMenuViewModel.performPrimaryAction()` (GohMenuViewModel.swift:109), `.addClipboardURL(url)`
  case calls `client.add(AddRequest(url: url.absoluteString))` — destination + connectionCount left nil
  (frozen-default path). Daemon resolves nil destination → `~/Downloads/<filename>` and nil
  connectionCount → bandit/governor or `defaultConnectionCount = 8`.
- **Client:** `func add(_ request: AddRequest) async throws -> JobSummary`, `@MainActor` protocol
  (GohMenuViewModel.swift:6-11); error mapped to `GohMenuHealth.failed`.
- **CLI parity:** `--output/-o <path>` → `AddRequest.destination`; `--connections <1-16>` →
  `AddRequest.connectionCount` (UInt8, validated 1...16 at parse, GohCommandLine.swift:508-515).
  Omitting `--output` → nil → daemon's `~/Downloads` default.
- **Test pattern:** `FakeMenuClient` (`@MainActor final class`, GohMenuViewModelTests.swift:320) records
  `addedRequests: [AddRequest]`; tests assert equality on the captured `AddRequest`. No existing test
  exercises non-nil destination/connectionCount from the menu path.
- **NSOpenPanel / connection-count validation in GohMenuBar:** NONE today.

RELEVANT FILES
- `Sources/GohMenuBar/GohMenuViewModel.swift` — view model, `GohMenuClient`, `performPrimaryAction`.
- `Sources/GohMenuBar/GohMenuView.swift` — popover body, primary-action button (lines 90-101), 380pt width.
- `Sources/GohMenuBar/GohMenuModels.swift` — `GohMenuPrimaryAction`, `GohMenuState`.
- `Sources/GohMenuBar/GohMenuPreferences.swift` — `UserDefaultsMenuPreferences` (model for persisting per-user defaults).
- `Sources/GohCore/Model/Command.swift` — `AddRequest` (source of truth).
- `Sources/GohCore/Model/CommandDispatcher.swift` — `defaultConnectionCount=8`, `maximumConnectionCount=16`,
  `defaultDestination(forURL:)`, rejects connectionCount==0.
- `Sources/goh-menu/main.swift` — app entry, `.accessory` policy, MenuBarExtra scene.
- `Tests/GohMenuBarTests/GohMenuViewModelTests.swift` — FakeMenuClient + add-path test pattern.

CONSTRAINTS
- **`AddRequest` EXACT shape (Command.swift:22-42):** `url: String` (required); `destination: String?`;
  `connectionCount: UInt8?`; `useImportedCookies: Bool?`; `priority: Priority?`. **destination and
  connectionCount ALREADY exist → this is a PURE GUI change. No wire-format change, NO protocolVersion
  bump.** The daemon already honors both (CommandDispatcher 80-171).
- **Connection range:** 1...16 (UInt8). CLI enforces 1...16 at parse; daemon caps `min(requested, 16)` and
  rejects 0. Canonical sources: `CommandDispatcher.maximumConnectionCount` / `.defaultConnectionCount` (public).
- **Default preservation:** when the user does NOT pick a folder / does NOT pin a count, the GUI must send
  `destination: nil` / `connectionCount: nil` (NOT a reconstructed `~/Downloads` path or `8`), so the daemon's
  own default + bandit/governor logic runs unchanged.
- MainActor-default + `nonisolated`-Sendable convention; Swift Testing; `-warnings-as-errors`; no `#available`;
  NSOpenPanel is AppKit/MainActor.

OPEN QUESTIONS
1. Wire shape — NOT a concern (both fields exist; GUI-only).
2. **Folder picker from an `.accessory` app:** no key window / no Dock icon. `NSOpenPanel` needs the app to
   activate/become key, or to attach as a sheet to the popover window. No existing panel usage to copy —
   the mechanism (sheet vs `begin` vs `runModal` + `NSApp.activate`) needs design + verification.
3. **Persistence:** should last-used folder + connection count be remembered (via the existing
   `GohMenuPreferences` store) or transient `@State`? Design choice.
4. **"Default vs pinned" semantics:** the count control must express "use default (nil)" distinctly from
   "pin N" — not a stepper defaulted to 8 (which would always send 8 and disable the governor).
5. **Form placement:** the 380pt popover currently has a single full-width primary button; a richer form must
   fit (inline vs disclosure vs sheet) and probably only when `primaryAction == .addClipboardURL`.
6. **Validation/empty state:** controls have no purpose when there's no valid URL to add.
