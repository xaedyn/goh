---
date: 2026-06-06
feature: tray-app-distribution
type: research-brief
---

# Research Brief — Tray App Distribution

Synthesis of Apple-platform research (2026-06-06). Source tiers: [VERIFIED] =
authoritative Apple URL confirmed; [SINGLE] = one credible source; [UNVERIFIED]
= first-principles, flagged.

## 1. SwiftPM executable → .app bundle
SwiftPM does not emit `.app` bundles [UNVERIFIED — community consensus]. The
accepted path is to hand-assemble the tree and copy the `swift build` output in
[VERIFIED — Apple CFBundles Bundle Types]:

```
goh.app/Contents/
  Info.plist
  MacOS/goh-menu        (CFBundleExecutable)
  Resources/            (icon, may hold bundled helpers)
```

Minimum Info.plist keys [VERIFIED]: `CFBundleName`, `CFBundleIdentifier`
(reverse-DNS), `CFBundleExecutable`, `CFBundleVersion`, `CFBundlePackageType=APPL`,
`LSMinimumSystemVersion=26.0`. **`LSUIElement=true`** gives menu-bar-only, no Dock
icon (NOT `LSBackgroundOnly`, which is faceless/no-UI) [VERIFIED — Apple LSUIElement
doc].

## 2. UserNotifications — DECISIVE for the design
`UNUserNotificationCenter.current()` from an **unbundled** process throws
`bundleProxyForCurrentProcess is nil` — no workaround [VERIFIED — Apple Forums
679326]. **Therefore the daemon (`gohd`, no bundle) cannot post; the bundled tray
app must.** Ad-hoc signing suffices to *deliver* local notifications in dev;
Developer-ID is for Gatekeeper, not delivery [UNVERIFIED — inferred]. No special
entitlement for a non-sandboxed Developer-ID app; routing is by bundle ID. Flow:
`requestAuthorization(options:)` at first launch; stable since 10.14, no macOS 26
change [SINGLE — Apple UNUserNotificationCenter doc]. Denial path must be handled
(check authorization status before scheduling).

## 3. SMAppService login item (app-only)
`SMAppService.mainApp.register()/unregister()/status` registers the **containing
.app** as a login item; macOS 13+ so fine at the 26.0 floor [VERIFIED — Apple
SMAppService.mainApp doc]. Requires a proper `.app` bundle with a valid
`CFBundleIdentifier`; does **not** require `/Applications` [SINGLE — nilcoalescing].
First `register()` typically yields `.requiresApproval`; the user confirms in
System Settings → General → Login Items — cannot be bypassed [VERIFIED — Apple
requiresApproval doc]. Status enum: `.enabled / .requiresApproval / .notRegistered
/ .notFound`.

## 4. Developer-ID signing + notarization with bundled helpers
Sign inside-out, **no `--deep`** [VERIFIED — Apple Forums 128166 + Customizing the
Notarization Workflow]: sign inner Mach-O binaries (`goh`, `gohd`) individually
first, each with `--timestamp -o runtime` (hardened runtime), then sign the `.app`
last. Notarize the whole artifact (`xcrun notarytool submit … --wait`), then
`xcrun stapler staple`. `--options runtime` + `--timestamp` are both required for
notarization [VERIFIED — Apple Developer-ID page]. dylibs/frameworks don't need
hardened-runtime.

## 5. Tester distribution artifact
**DMG** is the low-friction choice [VERIFIED — Apple Notarizing macOS Software]:
notarize the DMG directly and staple the ticket (covers contents); testers
drag-install offline-verifiable. ZIP can't be stapled directly (each item stapled
separately = friction). **PKG** suits scripted installs (e.g. placing a LaunchAgent
plist) — more complex, but the repo already has `Scripts/package-pkg.sh` producing
a CLI/daemon PKG.

## 6. Preferences storage
`UserDefaults.standard` (auto-keyed by bundle ID) is idiomatic for ~3 boolean
toggles; `@AppStorage` binds SwiftUI controls with no boilerplate [VERIFIED — Apple
UserDefaults doc; @AppStorage name to be confirmed against current docs before
first use]. No reason for a plist/SQLite/SwiftData store at this size.

## Design implications
- Notifications: **tray app posts** from the `ProgressEvent` stream
  (`GohMenuProgressStream`) on transitions to completed/failed. Limitation:
  fires only while the app runs — acceptable because launch-at-login keeps it
  running. No new IPC / wire surface.
- App bundle: a new `Scripts/package-app.sh` + a checked-in `Info.plist` template;
  stays SwiftPM-first (CI keeps using `swift build`).
- Signing: extend the existing signing script to cover `goh-menu` and the `.app`,
  inside-out; this is the post-credential wrapping step.
- All four features touch only the menu-bar app + packaging — no `GohCore` /
  daemon / wire-contract changes.
