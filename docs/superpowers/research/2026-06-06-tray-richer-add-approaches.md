---
date: 2026-06-06
feature: tray-richer-add
type: approach-decision-memos
---

# Approach Decision Memos — Richer Add in the Tray

The implementation pieces are mostly determined by research: `AddRequest` already carries
`destination`/`connectionCount` (pure GUI change, no wire bump); folder-picking must use
`NSOpenPanel.begin` + `NSApp.activate` from a **persistent window** (the transient popover would
dismiss); connections = Toggle(Automatic)+Stepper(1...16); `nil` = default (governor/`~/Downloads`).

**The real fork: where the richer add lives — a per-download Add window, or set-once defaults.**

---

## APPROACH A — "Add Download window"

CORE IDEA
A button in the popover opens a small persistent window with the full add form (URL prefilled from
the clipboard, a folder picker, an automatic/connections control, and an Add button).

MECHANISM
The popover gains an "Add download…" button that calls `@Environment(\.openWindow)` (a SwiftUI
`Window` scene) and dismisses. In that window: a text field (prefilled with the detected clipboard
URL, editable), a "Choose folder…" button that runs `NSApp.activate(ignoringOtherApps:true)` +
`NSOpenPanel.begin` (directories only) and shows the chosen path (or "Downloads (default)"), and a
`Toggle("Automatic")` + `Stepper(1...16)`. Add sends `AddRequest(url:, destination: chosenOrNil,
connectionCount: pinnedOrNil)` through the existing `GohMenuClient.add`. The popover's existing
one-tap clipboard add stays as-is for the fast path.

FIT ASSESSMENT
Scale fit: matches — single user, one add at a time.
Team fit: fits — SwiftUI `Window` + `openWindow` is standard; no new dep.
Operational: a second window scene in the menu-bar app; no runtime burden.
Stack alignment: fits — SwiftUI, MainActor; folder picker from a real window is the researched-safe path.

TRADEOFFS
Strong at: full per-download control; robust folder picking (no popover-dismiss problem); the fast
one-tap add still exists for users who don't care.
Sacrifices: adds a window to manage; two add paths (quick vs detailed).

WHAT WE'D BUILD
A `Window` scene + an `AddDownloadView`, a small folder-picker helper (`NSOpenPanel` wrapper), a
view-model add method taking destination + connectionCount, a popover "Add download…" entry.

THE BET
A dedicated add window is acceptable UX for the "I want to choose where/how" case (the fast path
stays in the popover for everyone else).

REVERSAL COST
Easy — additive; the window can be removed and the popover quick-add remains.

WHAT WE'RE NOT BUILDING
No inline folder picker inside the popover (research shows it dismisses the popover); no per-add
priority/cookies controls (out of scope).

INDUSTRY PRECEDENT
Menu-bar apps commonly open a real window for multi-field actions while keeping the popover for
glanceable status [UNVERIFIED, common pattern].

---

## APPROACH B — "Set-once defaults in Settings"

CORE IDEA
No per-add form: add a "default download folder" and "default connection count" to a real Settings
window; every tray add uses those, so one-tap add gets richer without a per-download dialog.

MECHANISM
Promote the current Preferences (a sheet on the popover — which has the same picker-dismiss problem)
into a real `Window`/Settings scene, add a "Choose folder…" (same `NSOpenPanel` approach) and an
automatic/connections control, persist both in the existing `GohMenuPreferences` store. The popover's
one-tap add reads those prefs and sends them in `AddRequest`.

FIT ASSESSMENT
Scale fit: matches.
Team fit: fits — extends the preferences store + view we just built.
Operational: none new beyond moving Preferences to a window.
Stack alignment: fits.

TRADEOFFS
Strong at: simplest add UX (one tap, no dialog); reuses the preferences store; one place to manage.
Sacrifices: no per-download choice (every add goes to the same folder with the same count until you
change settings); requires reworking the just-shipped Preferences sheet into a window for safe
folder-picking.

WHAT WE'D BUILD
A Settings `Window`, two new preference keys + controls, the same folder-picker helper, popover add
reading prefs.

THE BET
Users mostly want one consistent destination/speed, not per-download control.

REVERSAL COST
Easy — additive prefs.

WHAT WE'RE NOT BUILDING
No per-download override.

INDUSTRY PRECEDENT
"Default download location" is the browser/download-manager norm [UNVERIFIED, common pattern].

---

## Comparison matrix

| Criterion | A — Add window | B — Set-once defaults |
|---|---|---|
| AC1 destination (per-download) | STRONG — choose per add | PARTIAL — one default for all adds |
| AC2 connection count | STRONG — per add | PARTIAL — one default |
| AC3 range safety (1–16) | STRONG | STRONG |
| AC4 no default-path regression | STRONG — nil when unset | STRONG |
| AC5 no contract change | STRONG | STRONG |
| Folder-pick robustness | STRONG — real window | STRONG — real window (needs Prefs→window rework) |
| Matches "choose folder when adding" ask | STRONG | WEAK — set once, not per add |
| Simplicity / surface | PARTIAL — adds a window + 2nd add path | PARTIAL — reworks shipped Prefs sheet |

## Recommendation
**Approach A — "Add Download window."** It's what you actually asked for ("choose folder *when
adding*"), it's robust against the popover-dismiss problem by using a real window, and it leaves the
existing one-tap clipboard add untouched for the fast path. B is a fine *future* addition (a default
folder is a nice convenience) but it doesn't deliver per-download choice and it would force reworking
the Preferences sheet we just shipped. We can add B's "default folder" later as a convenience on top
of A.
