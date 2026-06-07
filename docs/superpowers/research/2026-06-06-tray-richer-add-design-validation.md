---
date: 2026-06-06
feature: tray-richer-add
type: design-validation
---

# Design Validation — Richer Add (Approach A: Add Download window)

## Acceptance Criteria (from Step 2.5)
- AC1 destination: chosen folder → `AddRequest.destination`; not chosen → `nil` (default preserved).
- AC2 connection count: pinned → `connectionCount` UInt8; "automatic" → `nil` (governor runs).
- AC3 range safety: control can't emit outside 1–16.
- AC4 no regression: existing default add still sends `AddRequest(url:)` with nils; existing tests pass.
- AC5 no contract change: `protocolVersion`/`AddRequest` shape unchanged; build + tests green.

## Dependency Enumeration
No existing interfaces modified. `AddRequest` (Command.swift) already has `destination: String?` and
`connectionCount: UInt8?`; `GohMenuClient.add(_:)` signature is unchanged. The feature adds a SwiftUI
`Window` scene + an add view + a folder-picker helper + a view-model add method, all in
`goh-menu`/`GohMenuBar`. No `GohCore`/daemon/wire change. No new XPC command (reuses `.add`).

## Questions Asked & Answers

### Zero Silent Failures
- **Existing users on ship?** Additive — the popover's one-tap clipboard add is untouched; a new
  "Add download…" button opens a new window. No migration.
- **Existing data?** None. Folder/connections are per-add and transient in the window (no persistence
  in v1). No `UserDefaults`/format change.
- **Existing integrations?** `GohMenuClient.add` signature unchanged (already carries the two fields).
  No wire change.
- **Partial failure?** If the daemon is down, `add` throws → the window surfaces a plain-English
  `GohMenuError` (never raw) and stays open so the user can retry. Safe/recoverable.

### Failure at Scale
- **10x?** Single user, one add at a time. The add window is one-at-a-time.
- **Concurrent?** Reopening "Add download…" must FOCUS the single existing window (one window id), not
  spawn N windows.
- **External dep unavailable?** Daemon down → `add` throws → error shown in-window; no crash.

### Simplest Attack
- **Cheapest abuse?** None new — single-user, local. The destination is a folder the user themselves
  picked via `NSOpenPanel`; the connection count is a clamped `UInt8`. No external/untrusted input.
- **Auth/authz on a new endpoint?** No new endpoint — reuses the existing `.add` XPC command (same
  peer validation). No new IPC surface.
- **Unprivileged user / path safety?** The destination is passed as a plain path string; the daemon's
  existing `openConfined`/path handling already rejects unsafe components. A non-sandboxed app needs no
  security-scoped bookmark; the user's own pick suffices (POSIX + TCC).

## Gaps Found
1. **URL validation** — the editable URL field could be empty/invalid; sending garbage is a silent
   failure.
2. **"Automatic" semantics** — must send `connectionCount: nil` when automatic, pinned `UInt8`
   otherwise; stepper clamped 1–16.
3. **Multiple add windows** — reopening should focus one window, not spawn many.
4. **Accessory-app window/panel focus** — opening the window and the folder panel needs
   `NSApp.activate(ignoringOtherApps: true)` for an `.accessory` app to bring them front (research).
5. **Error surfacing** — add failure → plain-English `GohMenuError` in the window; window stays open.
6. **Default preservation** — unset folder → `destination: nil`; automatic → `connectionCount: nil`
   (never a reconstructed `~/Downloads` string or literal `8`).

## Fixes Applied (folded into the spec)
1. Add button disabled until the URL field is a non-empty, parseable URL; invalid → inline message.
2. Spec pins the Automatic(nil)/pinned(UInt8) mapping; Stepper range `1...16`.
3. Single `Window(id:)`; reopen focuses it (SwiftUI `openWindow` with a fixed id is idempotent).
4. Spec mandates `NSApp.activate(ignoringOtherApps: true)` when opening the window and before the
   `NSOpenPanel.begin`.
5. Add failures map through the existing `GohMenuError` path; the window shows the message and stays open.
6. Spec mandates nil-when-unset for both fields; AC4 regression test pins the default-add shape.

No gap required a user decision; all resolved at design time.
