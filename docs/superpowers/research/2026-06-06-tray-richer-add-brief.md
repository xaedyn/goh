---
date: 2026-06-06
feature: tray-richer-add
type: research-brief
---

# Research Brief — Richer Add in the Tray

Source tiers: [VERIFIED] authoritative Apple/primary URL; [SINGLE] one credible source;
[UNVERIFIED] first-principles.

## 1. Folder picking from an `.accessory` / `MenuBarExtra(.window)` app
- **`.fileImporter` is unreliable from a popover/menu overlay context** — fails silently when
  presented from within the transient `MenuBarExtra(.window)` surface (same root cause as the
  documented `Menu`-scope failure) [SINGLE].
- **`NSOpenPanel.begin(completionHandler:)` (non-modal) preceded by
  `NSApp.activate(ignoringOtherApps: true)`** is the working pattern for an accessory app (no key
  window otherwise → panel appears behind / unfocused) [VERIFIED: Apple Forums 650270]. Use
  `.begin`, NOT `.runModal()` (modal blocks the popover) [UNVERIFIED].
- **Do NOT toggle `setActivationPolicy(.regular)`** to show the panel — documented dock-flicker /
  menu-bar-stuck bug (FB7743313), no Apple fix [VERIFIED: Apple Forums 650270].

## 2. The popover dismisses when the panel opens — DESIGN-DRIVING
- `MenuBarExtra(.window)` popovers close on focus loss; presenting `NSOpenPanel` (or any panel that
  takes key focus) **dismisses the popover and loses the in-progress add form** [SINGLE: FB11984872].
  `MenuBarExtra` does not expose its underlying `NSPopover`, so the usual `.applicationDefined`
  behavior workaround isn't available.
- **Mitigation (the load-bearing conclusion):** do NOT host the richer-add form (anything that opens
  a folder picker) inside the transient popover. Use a **persistent window** the app controls
  (SwiftUI `Window` scene opened via `@Environment(\.openWindow)`, or an `NSWindow` kept alive). The
  folder picker works cleanly from a real window. The popover's job is to *launch* that window.

## 3. Security-scoped access — NOT needed (non-sandboxed)
- `startAccessingSecurityScopedResource()` is App-Sandbox-only; a no-op without the sandbox
  entitlement [UNVERIFIED, corroborated by Apple doc structure]. goh is non-sandboxed Developer-ID.
- The plain path string from `NSOpenPanel` is sufficient; the daemon (same-user LaunchAgent) writes
  to it under standard POSIX + TCC, and TCC consent is established by the user's own pick [UNVERIFIED].
  So: pass the chosen folder as a plain `String` in `AddRequest.destination` over XPC — no bookmark.

## 4. Connection-count control (1–16) with an "automatic/default" state
- Idiomatic: `Toggle("Automatic", isOn:)` + a `Stepper(value:in: 1...16)` disabled while automatic is
  on [UNVERIFIED, HIG convention]. "Automatic" ON → send `connectionCount: nil` (governor runs);
  OFF → send the pinned `UInt8`. A 17-option Picker is clunkier.

## 5. macOS 26 notes
- No `MenuBarExtra`/`.fileImporter`/accessory-panel behavior changes found in 26.0–26.5 notes
  [UNVERIFIED: absence]. `NSApp.activate(ignoringOtherApps:)` before window/panel presentation is
  still required as of macOS 26 [SINGLE: TahoeMenuDemo]. (Unrelated `openSettings` regression on 26
  noted — not used here.)

## Design implications
- **The richer-add form should live in a persistent window, not the popover** (because the folder
  picker would dismiss the popover). The popover gets a button that opens that window.
- Folder pick: `NSApp.activate(ignoringOtherApps:true)` + `NSOpenPanel.begin` (dirs only) from the
  window; pass the path string straight into `AddRequest.destination`; `nil` when not chosen.
- Connections: Toggle(Automatic)+Stepper(1...16); `nil` when automatic.
- This stays a **pure GUI change** — `AddRequest` already carries `destination`/`connectionCount`;
  no wire/protocol change.
