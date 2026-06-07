---
date: 2026-06-06
feature: tray-app-distribution
type: spec
approach: B — All-in-One PKG
status: draft
revision: 2 (post adversarial spec review round 1 — 5 block issues fixed)
---

# Spec — Tray App Distribution

## 1. Problem

`goh` has a working menu-bar companion (`goh-menu`), but it is built as a bare
SwiftPM executable: no `.app` bundle, no bundle identifier, no notifications, no
launch-at-login, no preferences, and it is not part of any installer. To put goh
in testers' hands we need it to (a) install in one low-friction step, (b) behave
like a real macOS menu-bar app (always-there icon, completion notifications,
settings), and (c) preserve goh's signed-peer XPC trust model. This spec covers
turning `goh-menu` into a distributable, properly-bundled tray app delivered by a
single installer. It does **not** change the download engine, the daemon, or any
wire/on-disk contract.

## 2. Success metrics

Definition of done = all five acceptance criteria
(`docs/superpowers/research/2026-06-06-tray-app-distribution-acceptance-criteria.md`)
hold, plus:

- **Build:** `swift build -warnings-as-errors` clean; full existing test suite green
  (716 tests at HEAD); no new `#available` ladder.
- **Bundle:** `Scripts/package-app.sh <version>` emits `goh.app` with a valid
  `Info.plist` (`CFBundleIdentifier`, `LSUIElement=true`, and
  `LSMinimumSystemVersion` equal to the PKG `requirements.plist` `os` value —
  currently `26.5` — single-sourced; see §6 and the OS-floor note below);
  `defaults read <app>/Contents/Info CFBundleIdentifier` returns the identifier.
- **Installer:** `Scripts/package-pkg.sh <version>` emits a single `.pkg` whose
  payload installs the existing `goh`/`gohd` to their current location **and**
  `goh.app` to `/Applications`.
- **Notifications:** with permission granted and the app running, a tracked download
  reaching completed/failed produces exactly **one** notification per terminal
  *transition* (no progress notifications; no re-notification of jobs already
  terminal when the app started); with permission denied/undetermined, zero
  notifications and no crash.
- **Always-on subscription:** the progress subscription that feeds notifications is
  owned by the app composition root and runs from app launch until app termination,
  independent of whether the menu popover is open (see §4).
- **Login item:** toggling on yields `SMAppService.mainApp.status ∈ {.enabled,
  .requiresApproval}`; toggling off yields `.notRegistered`; the daemon LaunchAgent
  is byte-unchanged. Login-item registration is exercisable only from the bundled
  `.app` (see §6).
- **Preferences:** toggles persist across an app relaunch and govern AC2/AC3.
- **Trust model unchanged:** the `#if RELEASE #error(...)` peer-relaxation tripwire
  in `XPCService.peerValidationMode` is present and unmodified; release builds still
  pass `.isFromSameTeam()`; `protocolVersion` and the XPC envelope are unchanged.

Rollback trigger: any existing test regresses, or the trust-model invariants above
fail.

**OS-floor note (pre-existing, out of scope to resolve here):** `Package.swift`
declares `.macOS("26.0")` while both packaging scripts pin `requirements.plist`
`os` to `26.5`. This feature does **not** relitigate that gap; it only requires the
app's `LSMinimumSystemVersion` to equal the value the installer enforces (the
effective tester floor), so the app and its installer never advertise different
floors. If the PKG pin changes, the Info.plist value changes with it.

## 3. Out of scope

- **Daemon registration migration** (`SMAppService` for `gohd`) — explicitly deferred
  (ROADMAP §SMAppService migration / DESIGN §3.2). Daemon stays on `brew services`.
- **App Store / sandboxing** — tester distribution only; no App Sandbox entitlement.
- **Notification coalescing / summary** for bulk completion — v1 posts one per
  terminal transition; coalescing is a documented future enhancement.
- **Progress / start notifications** — terminal transitions only (completed, failed).
- **Bundling `goh`/`gohd` inside `goh.app`** — the app payload is `goh-menu` only;
  the CLI/daemon are PKG-installed to their existing path (no duplicate binaries,
  no version skew).
- **Standalone app-only DMG channel** — reversible future addition; not built now.
- **Rich preferences** (download folder, connection count, theme) — v1 ships exactly
  two toggles (notifications, launch-at-login). More only if testers ask.
- **Actual signing/notarization execution** — gated on the pending Apple Developer ID.
  This spec makes the build *signing-ready* (script seam + documented inside-out order);
  running it is the post-credential wrapping step.
- **Resolving the Package.swift(26.0)-vs-PKG(26.5) floor difference** — pre-existing;
  see §2 OS-floor note.

## 4. Subscription lifecycle & notification flow (load-bearing)

This section exists because round-1 review found that the progress subscription
today is popover-scoped, which would make notifications dead in the common case.

- **Today:** `GohMenuView.body` calls `model.start()` in `.task` and `model.stop()`
  in `.onDisappear` (GohMenuView.swift:27–32). The subscription therefore lives only
  while the popover is open.
- **Required change:** ownership of the long-lived `GohMenuViewModel` (and its
  progress subscription) moves to the **app composition root** (`GohMenuAppDelegate`
  in `goh-menu/main.swift`). `start()` is called once at
  `applicationDidFinishLaunching`; `stop()` is called at app termination. The popover
  view **observes** the already-running model and no longer owns start/stop. Opening/
  closing the menu must not start or stop the subscription. Clipboard refresh on
  popover appear is retained (it is cheap and view-scoped).
- **Concurrency:** the model is `@MainActor` (unchanged); the single owned
  subscription `Task` is created once and cancelled once. No new actor or shared
  mutable state beyond the existing model.
- **Notification trigger:** the notification coordinator observes the same
  `[ProgressSnapshot]` updates the model already applies (`applyProgressSnapshots`,
  GohMenuViewModel.swift:166) and emits notifications per the transition contract in
  §7. It honors `GohMenuPreferences.notificationsEnabled` and the authorization
  status (no-op when disabled/denied).

## 5. Security surface

- **No new IPC.** Notifications are posted by the tray app from the `ProgressSnapshot`
  stream it already subscribes to. No new XPC `Command`, no wire-format change, no new
  daemon endpoint → no new IPC attack surface.
- **Trust model preserved.** All new code paths that resolve peer validation continue
  through `GohXPCService.peerValidationMode`; the `#error` tripwire forbidding
  relaxation in release builds is untouched. The `.app` and bundled CLI/daemon must be
  Developer-ID-signed with the **same team** so `.isFromSameTeam()` passes (the signing
  step, post-credential).
- **Local-only inputs.** `UserDefaults` (per-user) and `SMAppService` (per-user login
  item) introduce no network or cross-user input. Notification content derives from the
  daemon's own job data (file name, outcome) — no new untrusted external string path.
- **PII:** a notification body shows the destination file name and, where a URL/host
  is included, it MUST be passed through the existing `URLDisplay.sanitized` (control-
  char strip + query-credential redaction) before display — same rule the UI already
  applies. No raw URL with credentials is ever shown.

## 6. Edge cases

- **Notification permission undetermined:** request authorization once (first launch);
  never re-prompt. A pending request must not block the subscription.
- **Notification permission denied:** the live service checks `authorizationStatus`
  before every schedule; denied/undetermined → silent no-op, no crash, no error
  surfaced (best-effort, mirroring `SpotlightMetadataTagger`).
- **Seed snapshot suppression:** the first `[ProgressSnapshot]` observed after
  `start()` (the `subscribe` reply seed, GohMenuProgressStream.swift:53, which may
  contain jobs already `.completed`/`.failed` from before app launch) seeds the
  coordinator's prior-state map **without** emitting any notification. Only
  transitions observed *after* the seed fire notifications. This prevents re-notifying
  history on every relaunch.
- **Transition dedup:** notifications fire only on an edge from a non-terminal state
  to a terminal state (`.completed` or a failed state), keyed by `job.id`. Once a job
  is recorded terminal, subsequent identical snapshots do not re-fire.
- **Job disappears from snapshot set:** its entry is dropped from the prior-state map;
  disappearance never emits a notification.
- **Bulk completion:** N concurrent terminal transitions → one notification each in
  v1 (acceptable at tester scale; coalescing deferred). No progress notifications.
- **Login item `.requiresApproval`:** the preferences UI renders this honestly as
  "Enabled — approve in System Settings → Login Items," not a silent failure or a
  toggle that snaps back. Re-reading `status()` reflects later approval.
- **Login item register/unregister failure:** surface a plain-English message in the
  preferences surface; leave the stored preference consistent with actual `status()`.
- **Login item on the debug bare binary:** `SMAppService.mainApp` requires a real
  `.app` bundle + identifier. AC3 is exercisable **only** from the bundled `.app`;
  on the debug bare-binary dogfood path the login-item control is disabled/unsupported
  (`GohLoginItemStatus.unsupported`), not an unhandled error. Unit tests stub the
  service and never call the real framework.
- **Daemon unreachable while app runs:** existing handled `health: .failed` state;
  notifications simply have nothing to fire on.
- **App launched before engine installed (PKG component edge):** app shows daemon-
  unreachable health; resolves once the daemon is running. No crash.
- **`UserDefaults` empty on first run:** both toggles default OFF; absence reads as OFF
  (the store returns non-optional `Bool`, defaulting false — see §7).
- **Bundle missing identifier (build error):** `package-app.sh` must `exit` non-zero
  with a clear message if the Info.plist template lacks `CFBundleIdentifier`
  (notifications + login item both hard-depend on it).

## 7. Interface contracts

All new types live in `GohMenuBar` (testable) with live impls wired in `goh-menu`.
All are protocol-fronted for initializer injection per the existing test pattern.

### 7.1 Preferences
```
public protocol GohMenuPreferences: AnyObject, Sendable {
    var notificationsEnabled: Bool { get set }   // default false when absent
    var launchAtLoginEnabled: Bool { get set }   // default false when absent
}
```
- Live impl: `UserDefaultsMenuPreferences` over `UserDefaults` (standard suite,
  keyed by bundle ID). Reads return non-optional `Bool`; an absent key reads `false`.
- `@AppStorage` (if used) is confined to the SwiftUI view layer only; the injectable
  store uses `UserDefaults` directly so unit tests touch no framework (advisory B).
- Test impl: in-memory dictionary, or a uniquely-named `UserDefaults(suiteName:)`.

### 7.2 Notification service + pure mapper
```
public enum GohNotificationAuthorization: Sendable { case authorized, denied, undetermined }

public struct GohNotificationContent: Sendable, Equatable {
    public let title: String   // e.g. "Download complete" / "Download failed"
    public let body: String    // sanitized file name + outcome (URLDisplay.sanitized for any host)
}

public protocol GohMenuNotificationService: Sendable {
    func authorizationStatus() async -> GohNotificationAuthorization
    func requestAuthorization() async                 // idempotent; never throws to caller
    func post(_ content: GohNotificationContent) async // best-effort; swallows errors
}
```
- **Pure transition mapper** (no framework; fully unit-tested), the heart of the
  dedup/seed contract:
```
public struct GohNotificationTransitionDetector {
    // prior: last-seen terminal-or-not state per job id; nil means "not yet seeded"
    public func evaluate(
        previous: [JobID: JobState]?,    // nil on the seed snapshot
        snapshots: [ProgressSnapshot]
    ) -> (toPost: [GohNotificationContent], next: [JobID: JobState])
}
```
  - If `previous == nil` (seed): return `toPost == []` and `next` = current per-job
    states (suppress history).
  - Else: emit one `GohNotificationContent` for each `job.id` whose state went
    non-terminal → terminal; `next` updates the map; ids absent from `snapshots` are
    dropped from `next`.
  - `JobID` is `JobSummary.id`'s type (`UInt64`); `JobState` is the existing enum.
- Live impl wraps `UNUserNotificationCenter.current()`. The coordinator that calls
  the detector + service lives in `goh-menu` (or `GohMenuBar` with the live service
  injected), runs on `@MainActor`, and gates on `GohMenuPreferences.notificationsEnabled`
  and `authorizationStatus() == .authorized`. All service errors are swallowed
  (view never sees raw errors — codebase rule).

### 7.3 Login item
```
public enum GohLoginItemStatus: Sendable {
    case enabled, requiresApproval, notRegistered, notFound, unsupported
}

public protocol GohMenuLoginItem: Sendable {
    func status() -> GohLoginItemStatus
    func register() throws
    func unregister() throws
}
```
- Live impl maps `SMAppService.mainApp` (`.enabled/.requiresApproval/.notRegistered/
  .notFound`); `.unsupported` is returned when running without a bundle (debug bare
  binary). `register()/unregister()` propagate `SMAppService` errors for the UI to map
  to a plain-English message.
- Test impl: a stub returning a scripted `GohLoginItemStatus` and recording calls.

### 7.4 Preferences view
- `GohMenuPreferencesView` (SwiftUI): two toggles bound to the store; the
  launch-at-login toggle reflects `GohMenuLoginItem.status()` and renders the
  `.requiresApproval` affordance and any register error. Reachable from the existing
  menu footer.

### 7.5 Script contracts
- `Scripts/package-app.sh <version> [output-dir]` — assembles `goh.app` from the
  `swift build --release` `goh-menu` binary + the checked-in `Info.plist` template.
  Exit `0` success; `64` usage (bad/missing version); non-zero with a clear message
  if the template lacks `CFBundleIdentifier`. Output path is consumed identically by
  both `package-pkg.sh` and the signing script (no drift).
- `Scripts/package-pkg.sh <version> [output-dir]` — unchanged contract, extended to
  stage `goh.app` into the payload installing to `/Applications`. The payload-staging
  block is shared with `private-release-candidate.sh` via a small extracted helper, or
  — at minimum — both scripts are edited in lockstep and a comment in each names the
  other (advisory E: a single-edit miss would silently ship an app-less release).

## 8. Components to build

- `GohMenuBar/GohMenuPreferences.swift` — protocol + `UserDefaultsMenuPreferences`.
- `GohMenuBar/GohMenuNotifications.swift` — `GohNotificationAuthorization`,
  `GohNotificationContent`, `GohMenuNotificationService` protocol,
  `GohNotificationTransitionDetector` (pure), and the live `UNUserNotificationCenter`
  impl.
- `GohMenuBar/GohMenuLoginItem.swift` — `GohLoginItemStatus`, protocol, live
  `SMAppService` impl.
- `GohMenuBar/GohMenuPreferencesView.swift` — the settings surface.
- `goh-menu/main.swift` wiring — own the long-lived `GohMenuViewModel` + notification
  coordinator at the composition root (§4); inject live preferences/notification/
  login-item impls; request authorization once at first launch.
- `Resources/Info.plist` (template) + `Scripts/package-app.sh`.
- `Scripts/package-pkg.sh` extension (+ shared staging helper) and the signing-script
  seam (documented; run post-credential).
- Tests in `Tests/GohMenuBarTests/`: preferences round-trip (in-memory/temp suite);
  **transition detector** — seed suppression, non-terminal→terminal fires once, no
  re-fire on repeat, job-disappearance drop, both completed and failed edges;
  authorization-denied no-op; login-item status mapping incl. `.unsupported` and
  `.requiresApproval` (stubbed service). Initializer-injection pattern; no XPC, no
  real framework, no file I/O.

## 9. Rollout & migration

- **Additive.** New files in `GohMenuBar`/`goh-menu`, a new `Scripts/package-app.sh`,
  an `Info.plist` template, an extension to `Scripts/package-pkg.sh`, and the
  composition-root lifecycle change in `goh-menu/main.swift`. The only existing
  behavior that changes is internal to the menu app (subscription ownership moves
  from the popover to the app delegate — no user-visible regression; the popover still
  shows the same live state).
- **Backward compatibility:** brew users unaffected (app is new/optional). The debug
  dogfood lane keeps working; login-item is simply `.unsupported` there.
- **Partial-failure safety:** PKG components install independently; app-component
  failure still installs CLI/daemon (re-run to retry). App-without-running-daemon
  shows the existing handled health state.
- **Rollback:** revert the PR; no persisted migration to reverse (`UserDefaults` is
  app-local and harmless if left behind).
- **Signing seam:** the signing script gains `goh-menu` + `.app` + artifact, signed
  inside-out (inner Mach-O first with `--timestamp -o runtime`, `.app` last), then
  notarize + staple. Exercised only when the cert exists.

## 10. Unverified research claims relied upon

- Ad-hoc signing suffices to *deliver* local notifications in dev [UNVERIFIED] — does
  not affect production (Developer-ID signed). If false, notifications are testable
  only after signing — acceptable; unit tests cover the pure detector regardless.
- `@AppStorage` property-wrapper name [UNVERIFIED] — confirm against current docs
  before first use; the injectable store uses `UserDefaults` directly regardless, so a
  miss here cannot affect the testable contract.
