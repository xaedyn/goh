---
date: 2026-06-06
feature: tray-app-distribution
type: acceptance-criteria
---

# Acceptance Criteria — Tray App Distribution

Scope (confirmed with user 2026-06-06):
- Extend the existing `goh-menu` companion into a distributable `.app` bundle.
- Add: app-bundle packaging, completion/failure notifications, launch-at-login
  (tray app ONLY — daemon stays on `brew services`), and a preferences UI.
- Tester distribution target: easy install, NOT App Store. Signing + notarization
  is a final wrapping step gated on the pending Apple Developer ID (external
  dependency — not verifiable this session).

## Acceptance Criteria

**AC1 (app bundle).** Running the packaging script produces `goh.app` whose
`Contents/Info.plist` declares a `CFBundleIdentifier` and `LSUIElement=true`
(menu-bar accessory, no Dock icon). Double-clicking the bundle launches the
menu-bar app and its status-bar icon appears.
Signal: `goh.app` exists; `defaults read <path>/Contents/Info CFBundleIdentifier`
returns the identifier; the status item renders.

**AC2 (notifications).** When a tracked download transitions to `.completed` or
to a failed state while the tray app is running, a native macOS notification is
delivered showing the file name and the outcome — after the user has granted
notification permission on first run. A user who denies permission sees no
notifications and no crash.
Signal: `UNUserNotificationCenter` delivers a request observable in Notification
Center; denial path is handled (authorization status checked before scheduling).

**AC3 (launch-at-login, tray app only).** Toggling "Launch at login" ON in the
tray app registers it as a login item (`SMAppService.mainApp.status == .enabled`)
so it starts at next login; toggling OFF unregisters it
(`status == .notRegistered`). The daemon's `brew services` registration is
unchanged. Default is OFF.
Signal: `SMAppService.mainApp.status` reflects the toggle; the app appears/
disappears under System Settings → General → Login Items; daemon plist untouched.

**AC4 (preferences).** The tray app exposes a preferences surface that lets the
user toggle notifications and launch-at-login, and the settings persist across
app restarts and drive the corresponding behavior.
Signal: toggles read/write a persistent store (e.g. `UserDefaults`); values
survive relaunch; AC2/AC3 behavior follows the stored values.

**AC5 (no security/behavior regression).** The `.app` build path does not weaken
the XPC trust model: release builds still enforce `.isFromSameTeam()`, the
`#if RELEASE #error(...)` peer-relaxation tripwire is intact, the frozen wire
contract (`protocolVersion`, envelope shape) is unchanged, and the full existing
test suite plus `swift build -warnings-as-errors` pass.
Signal: tripwire grep unchanged; `swift build -warnings-as-errors` clean; all
existing tests green; no new `#available` ladder introduced.

## External dependency (not an AC this session)

Gatekeeper-clean, double-click tester install requires the `.app` (and the
bundled `goh`/`gohd`) to be Developer-ID-signed and notarized. That is gated on
the pending Apple Developer Program enrollment. The work is structured so signing
+ notarization is the final wrapping step; until the cert lands, the artifact is
testable only via the local debug/dogfood path.
