---
date: 2026-06-06
feature: tray-app-distribution
type: design-validation
---

# Design Validation — Tray App Distribution (Approach B: All-in-One PKG)

## Acceptance Criteria (from Step 2.5)

- **AC1 (app bundle).** Packaging produces `goh.app` with a `CFBundleIdentifier`
  and `LSUIElement=true`; double-click launches the tray app, status item appears.
- **AC2 (notifications).** Terminal download transitions (completed/failed) while
  the app runs deliver a native notification with file name + outcome, after a
  granted permission; denial is a graceful no-op.
- **AC3 (launch-at-login, app only).** Toggle registers/unregisters the app via
  `SMAppService.mainApp`; daemon's `brew services` registration unchanged; default OFF.
- **AC4 (preferences).** A preferences surface toggles notifications + launch-at-login;
  settings persist across restarts and drive behavior.
- **AC5 (no regression).** Release builds still enforce `.isFromSameTeam()`; the
  `#error` relaxation tripwire intact; wire contract unchanged; tests + build green.

## Dependency Enumeration

No existing interfaces modified. The feature adds: a new packaging script + Info.plist
template; new code inside `GohMenuBar`/`goh-menu` only (notification service, login-item
service, preferences store, preferences view); an extension to `Scripts/package-pkg.sh`.
**No `GohCore` types, no XPC `Command`/wire shapes, no daemon code, no on-disk frozen
formats are touched.** Notifications are posted locally by the tray app from the
`ProgressEvent` stream it already consumes — no new IPC surface.

## Questions Asked & Answers

### Zero Silent Failures
- **Existing users on ship?** Additive. brew CLI/daemon users are unaffected (the app
  is new and optional). The PKG now also carries `goh.app`; the daemon install
  *mechanism* (LaunchAgent) is unchanged. No migration required.
- **Existing data?** No schema/format change. `UserDefaults` (app-local, per-user) is
  new; `provenance.plist`, `gohfile.lock`, catalog, checkpoints all untouched.
- **Existing integrations?** `protocolVersion` and the XPC envelope are unchanged;
  CLI/daemon callers unaffected. Notifications add no `Command` case.
- **Partial-deploy failure?** PKG installs engine but app copy fails → working CLI,
  no app; re-run installer (recoverable). App installed but daemon not yet running →
  app renders the existing `health: .failed` "daemon unreachable" state (already
  handled), not a crash. Safe and recoverable in both directions.

### Failure at Scale
- **10x?** Single-user tool; "scale" = many concurrent downloads finishing at once.
  Risk: N simultaneous completions → N notifications (notification spam). Mitigation
  (folded into design): notify only on **terminal** events (completed/failed), never
  on progress; document coalescing/summary as a future enhancement, acceptable at
  tester volume.
- **Concurrent operations?** The progress stream is serialized through the
  `@MainActor` view model — no race posting notifications. `SMAppService` register/
  unregister is idempotent; the preferences toggle guards against redundant calls.
- **External dependency unavailable?** Daemon down → existing handled health state.
  `UNUserNotificationCenter` denied/unavailable → authorization status is checked
  before scheduling; no-op, no crash.

### Simplest Attack
- **Cheapest abuse?** Notifications are local, fed by the daemon's own job stream;
  no external/untrusted input path is introduced.
- **Auth/authz on a new endpoint?** None — there is **no new XPC endpoint**. The
  menu-app-posts decision means zero new IPC attack surface. This is a deliberate
  safety property of the chosen design.
- **Unprivileged user?** `UserDefaults` and the login item are per-user. Proper
  Developer-ID signing *strengthens* the existing `.isFromSameTeam()` posture rather
  than weakening it. No new privilege boundary.

## Gaps Found

1. **Notification spam** on bulk concurrent completion.
2. **Authorization denial / not-yet-requested** must be handled without crash or
   silent loss.
3. **First-run permission prompt timing** must not be annoying.
4. **`SMAppService` `.requiresApproval`** state must be surfaced honestly in the UI
   (the toggle can't silently "fail" — the user may need to approve in System Settings).
5. **Binary duplication risk:** the `.app` must NOT bundle its own copies of
   `goh`/`gohd` (version skew). The PKG installs those once to their normal location;
   `goh.app` contains only `goh-menu`.

## Fixes Applied

1. Scope notifications to terminal events only (completed/failed), no progress
   notifications; note future coalescing. (Into spec §Edge cases + §Out of scope.)
2. Always query `authorizationStatus` before scheduling; treat denied/undetermined as
   no-op. (Into spec §Edge cases.)
3. Request authorization on first launch (or first terminal event), once; never
   re-prompt. (Into spec.)
4. Preferences UI reads `SMAppService.mainApp.status` and renders `.requiresApproval`
   as an explicit "Approve in System Settings → Login Items" affordance, not a silent
   on/off. (Into spec §Edge cases + AC3.)
5. Spec states the `.app` payload is `goh-menu` only; CLI/daemon stay PKG-installed
   to their existing path; no bundled duplicates. (Into spec §Out of scope + Rollout.)

No gap required a user decision; all resolved at design time.
