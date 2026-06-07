---
date: 2026-06-06
feature: tray-app-distribution
type: codebase-context-brief
---

# Codebase Context Brief — Tray App Distribution

STACK
Swift 6.3.x toolchain, swift-tools-version 6.2 (`.defaultIsolation` floor). Platform floor: macOS 26.0 (hard requirement — XPCPeerRequirement and XPCRequirement.isFromSameTeam are macOS 26.0 API). SwiftUI used for the menu bar view (MenuBarExtra + `.menuBarExtraStyle(.window)`); AppKit used for NSApplication, NSPasteboard, NSWorkspace. `goh-menu` is an `.executableTarget` with `.defaultIsolation(MainActor.self)`; `GohMenuBar` is a `.target` with the same isolation. Both are built by `swift build` into flat binaries in `.build/debug/` or `.build/release/`; there is no `.app` bundle today — `dogfood-build.sh` copies the bare `goh-menu` binary alongside `goh` and `gohd`. Test framework: Swift Testing (not XCTest) with `@Test` and `#expect`.

EXISTING PATTERNS

XPC client shape: `LiveGohMenuClient` (Sources/goh-menu/main.swift) conforms to `GohMenuClient` (Sources/GohMenuBar/GohMenuViewModel.swift). It creates a `GohXPCClient` per call, passing `machServiceName: GohXPCService.machServiceName` (`"dev.goh.daemon"`) and a `PeerValidationMode` resolved from the environment via `GohXPCService.peerValidationMode(environment:)`. One-shot commands use `Task.detached`; progress subscription uses a long-lived session wrapped in `LiveProgressSubscription`. The client protocol is `@MainActor`-isolated.

Peer validation modes: `PeerValidationMode.enforced` passes `.isFromSameTeam()` as an `XPCPeerRequirement` to both `XPCListener` and `XPCSession`. `PeerValidationMode.relaxedForDevelopment` passes `nil` (no requirement). The relaxation branch is guarded by `#if DEBUG` with a `#if RELEASE #error(...)` tripwire — it is compiled out of release builds entirely (Sources/GohCore/IPC/XPCService.swift). The environment variable `GOH_XPC_ALLOW_UNVALIDATED_PEERS` triggers relaxation in debug builds only.

Error handling: Errors thrown from the XPC layer are caught and mapped through `GohMenuErrorMapper.map(_:)` (Sources/GohMenuBar/GohMenuProgressStream.swift) into the `GohMenuError` enum (Sources/GohMenuBar/GohMenuModels.swift). The ViewModel re-renders to a `health: .failed(...)` state and surfaces human-readable copy via `GohMenuPresenter`. No raw errors are re-thrown to the view layer.

Test pattern: `@Suite` / `@Test` structs injecting stub dependencies via initializer injection into `GohMenuViewModel` or calling presenter pure functions directly — no XPC, no process launches, no file I/O.

Daemon completion path: `DownloadEngine` (Sources/GohCore/Engine/DownloadEngine.swift, line 902) calls `completedDownloadHandler?(completed, transferDuration, isResume, sha256, governorOutcome)` when a job finishes. In `gohd/main.swift` (lines 139–185) this closure runs synchronously on the engine's internal worker: it (1) records a bandit observation if eligible, (2) calls `metadataTagger.tagCompletedDownload(...)` for Spotlight, and (3) writes a `ProvenanceEntry` to disk. The handler receives a fully-populated `JobSummary` with `.state == .completed`. There is no fan-out to any notification system at this point.

Spotlight tagging: `SpotlightMetadataTagger.tagCompletedDownload(destination:sourceURL:downloadedAt:)` in `Sources/GohCore/Platform/SpotlightMetadataTagger.swift` is called directly inside `completedDownloadHandler` in `gohd`. This is the closest existing analog to where a notification trigger would live — a synchronous side-effect fired by the engine's completion closure in the daemon.

UserDefaults / config usage: None found anywhere in `Sources/`. No `UserDefaults`, no preferences file, no settings store. `AttestKeyLocation.bundleID` (`"dev.goh.attest"`) is the only bundle-identifier-shaped string in the codebase, used for Application Support directory placement, not for the menu app.

RELEVANT FILES

- Sources/goh-menu/main.swift — entry point; `GohMenuApp` (`@main`), `GohMenuAppDelegate`, `LiveGohMenuClient`, `LiveProgressSubscription`. Wires SwiftUI `App` + `MenuBarExtra` scene to the live XPC client.
- Sources/GohMenuBar/GohMenuViewModel.swift — `GohMenuClient` protocol, `GohMenuViewModel`. The `@MainActor` observable that drives the UI.
- Sources/GohMenuBar/GohMenuModels.swift — `GohMenuHealth`, `GohMenuError`, `GohMenuState`, `GohMenuJobRow`, `GohMenuControl`, `GohMenuPrimaryAction`, `GohMenuRecoveryAction`.
- Sources/GohMenuBar/GohMenuPresenter.swift — pure `GohMenuPresenter`; state → view-model mapping. Would need a new method or a parallel presenter for notification content.
- Sources/GohMenuBar/GohMenuProgressStream.swift — `GohMenuProgressStream`, `GohMenuErrorMapper`, `GohMenuProgressSubscriptionCancellation`. The async stream that polls the XPC progress subscription.
- Sources/GohMenuBar/GohMenuView.swift — SwiftUI `GohMenuView` and `GohMenuJobRowView`. The window-style MenuBarExtra content.
- Sources/GohCore/IPC/XPCService.swift — `PeerValidationMode`, `GohXPCService` (machServiceName, env key, peerValidationMode). The security policy declaration.
- Sources/GohCore/IPC/XPCTransport.swift — `GohXPCListener`, `GohXPCClient`, `GohXPCServerSession`. The concrete XPC transport wrappers.
- Sources/gohd/main.swift — `completedDownloadHandler` closure (lines 139–185). The only place in the daemon where a job's completion is observed as a side-effect hook.
- Sources/GohCore/Platform/SpotlightMetadataTagger.swift — `SpotlightMetadataTagger`; the completion side-effect closest in structure to where a notification POST would live.
- Package.swift — SwiftPM manifest; target declarations, platform floor, dependency list.
- Scripts/dogfood-build.sh — builds debug binaries; copies bare `goh-menu` binary; no signing.
- Scripts/package-release.sh / package-pkg.sh — build release; produce tar.gz / .pkg; no signing or notarization.
- Scripts/private-release-candidate.sh — the only script that signs (`codesign --sign`) and notarizes (`xcrun notarytool`); signs `goh` and `gohd` only — `goh-menu` is not included.

CONSTRAINTS

- Frozen wire contract: `protocolVersion`, `requestID`, `messageType`, `payload` keys in the XPC envelope must not change. `protocolVersion` equality is checked on every connection; a mismatch causes a daemon error reply that must be decodable by both sides (DESIGN.md §4).
- The `#if DEBUG / #if RELEASE #error(...)` tripwire in `XPCService.peerValidationMode` must remain intact. Any new code that calls `peerValidationMode` inherits the same rule: the relaxation must never compile into a release build.
- `isFromSameTeam()` requires all XPC peers to carry a valid Apple Developer team signature and belong to the same team. In enforced mode (all release builds, and debug builds without `GOH_XPC_ALLOW_UNVALIDATED_PEERS`), an unsigned `goh-menu` binary cannot connect to a signed `gohd` and vice versa. The menu app must be signed with the same Developer ID team as `gohd` for production peer validation to pass.
- The packaging scripts (`package-release.sh`, `package-pkg.sh`) do not sign or notarize. Only `private-release-candidate.sh` signs, and it currently signs only `goh` and `gohd` — not `goh-menu`. A tester `.app` distribution requires adding `goh-menu` to the signing loop in that script (or a new script).
- SMAppService is in the ROADMAP.md v0.2 backlog explicitly as hardening deferred until distribution moves outside Homebrew (ROADMAP.md line 219–225, DESIGN.md §3.2). The current daemon install path is a user-writable LaunchAgent via `brew services`. The platform floor for `SMAppService` availability cannot be determined from the code; given the macOS 26.0 hard floor the availability question is whether it was introduced before or at 26.0 (SMAppService is macOS 13+, so it is available).
- No `#available` ladders are permitted (DESIGN.md §Platform support). Any new API used must be available at macOS 26.0 or the floor must rise in the same PR.

OPEN QUESTIONS

1. **Who POSTs notifications — daemon or menu app?** The daemon's `completedDownloadHandler` is the canonical completion event, but `gohd` is a background daemon with no bundle identifier and no user session entitlement. `UserNotifications.framework` on macOS requires a bundle identifier for permission grants and delivery. The menu app has a user session and (once bundled) a bundle identifier, but it only learns about completion indirectly via the `ProgressEvent` stream — the snapshot transition from `.active` to `.completed`. Either (a) the menu app watches for state transitions in its existing stream and posts `UNUserNotificationCenter` requests, or (b) the daemon sends a new IPC message type to the menu app at completion. Option (b) is an IPC surface addition; option (a) requires no new wire format but misses completions when the menu app is not running. This is the primary design decision for the notifications slice.

2. **Bundle identifier for `goh-menu`:** No `Info.plist`, no `CFBundleIdentifier`, and no `.entitlements` file exists for `goh-menu` anywhere in the repository. `UNUserNotificationCenter` and `SMAppService` both require a bundle identifier. SwiftUI's `App` protocol running as a plain executable (no `.app` wrapper) does not inject one. Building a real `.app` bundle requires an `Info.plist` with `CFBundleIdentifier` — this has never been set up for this target.

3. **Does `.app` packaging break the `brew services` install model?** Currently `goh-menu` is a sibling binary under `bin/`. An `.app` bundle lives at a path like `/Applications/goh.app/Contents/MacOS/goh-menu`. The menu app uses `CommandLine.arguments[0]` to locate itself for terminal handoff (`GohTerminalCommandBuilder`). An `.app` bundle changes that path. The install story (does it go in `/Applications`? does Homebrew's `cask` model apply?) needs design.

4. **`SMAppService` and the existing `brew services` LaunchAgent:** `SMAppService` registers a daemon or login-item plist from inside the `.app` bundle's `Contents/Library/LaunchDaemons` or `Contents/Library/LoginItems`. The existing `dev.goh.daemon.plist` is installed by `brew services` into `~/Library/LaunchAgents/`. Using `SMAppService` for the daemon requires the plist to move into the `.app` bundle and the `brew services` install path to be retired or coexist. These two registration mechanisms are mutually exclusive for the same Mach service name.

5. **UserNotifications entitlement and sandbox:** The `goh-menu` app is currently unsigned and unsandboxed. `UNUserNotificationCenter` works from unsandboxed apps on macOS but still requires user permission grant, which persists by bundle ID. If `goh-menu` later acquires a sandbox entitlement (common for App Store), additional entitlements would be needed. The tester distribution implied by this feature does not require App Store, so sandboxing is not forced — but this should be an explicit decision recorded in DESIGN.md before implementation.
