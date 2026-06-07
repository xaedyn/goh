---
date: 2026-06-06
feature: tray-app-distribution
REQUIRED_SKILL: superpowers:subagent-driven-development
Goal: Turn goh-menu into a distributable bundled tray app with notifications, launch-at-login, preferences, and an all-in-one PKG installer.
Architecture: Approach B — All-in-One PKG. THE BET: "Versioning the engine and tray app together is acceptable for the tester phase."
Tech Stack: Swift 6.2 (swift-tools-version), Swift 6.3.x toolchain, SwiftPM, macOS 26.0 platform floor (PKG installer pins 26.5), SwiftUI + AppKit MenuBarExtra (LSUIElement), UserNotifications, SMAppService, modern Swift XPC (unchanged), Swift Testing.
---

# Implementation Plan — Tray App Distribution

## Acceptance criteria map

| AC | Description | Owning task(s) |
|----|-------------|----------------|
| AC1 | `Scripts/package-app.sh` emits `goh.app` with valid `CFBundleIdentifier` + `LSUIElement=true`; `defaults read` returns the identifier | Task P3-1 (Info.plist template) + Task P3-2 (package-app.sh) |
| AC2 | Tracked download reaching `.completed` or failed state while app is running delivers exactly one notification per terminal transition; denied permission = zero notifications + no crash | Task P1-2 (transition detector) + Task P2-3 (live UNUserNotificationCenter impl + coordinator) |
| AC3 | Toggling launch-at-login ON registers `SMAppService.mainApp`; toggling OFF unregisters; daemon LaunchAgent unchanged; unsupported on bare binary | Task P1-3 (login-item protocol + enum) + Task P2-4 (live SMAppService impl) |
| AC4 | Preferences UI has two toggles; values persist across relaunches; drive AC2/AC3 behavior | Task P1-1 (preferences store) + Task P2-5 (preferences view) |
| AC5 | `#if RELEASE #error` tripwire intact; `swift build -warnings-as-errors` clean; all existing tests green; no new `#available` ladder | Verified at end of every phase health check |

## THE BET — packaging phase load-bearing note

> Approach B bet: "Versioning the engine and tray app together is acceptable for the tester phase."
>
> This is load-bearing in Task P3-3 (extending `package-pkg.sh`): the PKG packages
> `goh` + `gohd` + `goh.app` together. A version bump requires re-cutting the whole PKG — cannot
> ship the app update alone. Acceptable at tester scale; the reversal path (Approach A companion
> DMG) is additive from the same assembled `.app`. The bet is recorded here, not relitigated.

## Phase structure

> 11 tasks → 3 phases segmented at deployment-independence boundaries.
> Phase artifacts: `docs/superpowers/progress/2026-06-06-tray-app-distribution-phase{1,2,3}.md`

- **Phase 1 (Tasks P1-1 – P1-3): Value layer.** Preferences store, pure `GohNotificationTransitionDetector`, login-item protocol + enum. All in `GohMenuBar`; all unit-testable with no framework. No changes to `goh-menu/main.swift`, no scripts, no `Info.plist`.
- **Phase 2 (Tasks P2-1 – P2-5): Wiring layer.** Composition-root lifecycle move; live `UNUserNotificationCenter` impl + coordinator (injected); live `SMAppService` impl; preferences view; view footer entry. Introduces no packaging — `swift build` is the CI gate.
- **Phase 3 (Tasks P3-1 – P3-3): Packaging layer.** `Info.plist` template; `Scripts/package-app.sh`; `package-pkg.sh` extension + shared staging helper; signing-script seam; `DESIGN.md` menu-bar-distribution subsection. CI gate: `swift build -warnings-as-errors` + `swift test` still green; packaging is validated manually (`Scripts/package-app.sh 0.0.1-test`, `defaults read`).

---

## Phase 1 — Value layer

### Task P1-1 — CREATE `Sources/GohMenuBar/GohMenuPreferences.swift`

**Responsibility:** `GohMenuPreferences` protocol + `UserDefaultsMenuPreferences` live impl. No `@AppStorage`. No framework beyond Foundation.

**Files**
- CREATE `Sources/GohMenuBar/GohMenuPreferences.swift`
- CREATE `Tests/GohMenuBarTests/GohMenuPreferencesTests.swift`

**Pre-task reads**
- [x] `Sources/GohMenuBar/GohMenuPresenter.swift` — confirm `nonisolated public struct` + `Sendable` pattern
- [x] `Tests/GohMenuBarTests/GohMenuPresenterTests.swift` — confirm `@Suite`/`@Test`/`#expect` pattern

**Step 1 — Failing test**

File: `Tests/GohMenuBarTests/GohMenuPreferencesTests.swift` (CREATE)

```swift
import Foundation
import Testing
@testable import GohMenuBar

// AC4: preferences persist across relaunches and read back correctly.
@Suite("GohMenuPreferences")
struct GohMenuPreferencesTests {

    // AC4: absent key reads as false (default OFF for both toggles)
    @Test func defaultsFalseWhenAbsent() {
        let suite = "dev.goh.test.prefs.\(UUID().uuidString)"
        let store = UserDefaultsMenuPreferences(suiteName: suite)
        #expect(store.notificationsEnabled == false)
        #expect(store.launchAtLoginEnabled == false)
    }

    // AC4: values survive a round-trip through the store
    @Test func roundTripsNotificationsEnabled() {
        let suite = "dev.goh.test.prefs.\(UUID().uuidString)"
        let store = UserDefaultsMenuPreferences(suiteName: suite)
        store.notificationsEnabled = true
        let fresh = UserDefaultsMenuPreferences(suiteName: suite)
        #expect(fresh.notificationsEnabled == true)
    }

    @Test func roundTripsLaunchAtLoginEnabled() {
        let suite = "dev.goh.test.prefs.\(UUID().uuidString)"
        let store = UserDefaultsMenuPreferences(suiteName: suite)
        store.launchAtLoginEnabled = true
        let fresh = UserDefaultsMenuPreferences(suiteName: suite)
        #expect(fresh.launchAtLoginEnabled == true)
    }

    @Test func readAfterWriteFalse() {
        let suite = "dev.goh.test.prefs.\(UUID().uuidString)"
        let store = UserDefaultsMenuPreferences(suiteName: suite)
        store.notificationsEnabled = true
        store.notificationsEnabled = false
        #expect(store.notificationsEnabled == false)
    }
}
```

Run: `swift test --filter GohMenuPreferencesTests` — expect failure (type not found).

**Step 2 — Minimal implementation**

File: `Sources/GohMenuBar/GohMenuPreferences.swift` (CREATE)

```swift
import Foundation

/// Protocol-fronted preferences store for goh-menu.
/// Conforms to Sendable (nonisolated) per the GohMenuBar convention.
/// The injectable interface uses UserDefaults directly; @AppStorage is confined
/// to the SwiftUI view layer (spec §7.1).
public protocol GohMenuPreferences: AnyObject, Sendable {
    /// Whether completion/failure notifications are enabled. Defaults to false when absent.
    var notificationsEnabled: Bool { get set }
    /// Whether the tray app registers as a login item. Defaults to false when absent.
    var launchAtLoginEnabled: Bool { get set }
}

/// Live implementation backed by UserDefaults.
/// Keys are prefixed with the bundle identifier at runtime; tests may pass a
/// uniquely-named suite to isolate state.
public final class UserDefaultsMenuPreferences: GohMenuPreferences, @unchecked Sendable {
    private let defaults: UserDefaults
    private enum Key {
        static let notificationsEnabled = "GohMenuNotificationsEnabled"
        static let launchAtLoginEnabled = "GohMenuLaunchAtLoginEnabled"
    }

    /// Production initializer: uses standard UserDefaults (keyed by bundle ID).
    public convenience init() {
        self.init(defaults: .standard)
    }

    /// Test initializer: uses a named suite so tests are isolated and removable.
    public convenience init(suiteName: String) {
        self.init(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
    }

    private init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var notificationsEnabled: Bool {
        get { defaults.bool(forKey: Key.notificationsEnabled) }
        set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    public var launchAtLoginEnabled: Bool {
        get { defaults.bool(forKey: Key.launchAtLoginEnabled) }
        set { defaults.set(newValue, forKey: Key.launchAtLoginEnabled) }
    }
}
```

**Step 3 — Run test, expect green**
```
swift test --filter GohMenuPreferencesTests
```

**Step 4 — Health check**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -warnings-as-errors 2>&1 | tail -5
```
Must be clean.

**Step 5 — Commit**
```
feat(menu): add GohMenuPreferences protocol + UserDefaultsMenuPreferences
```

---

### Task P1-2 — CREATE `Sources/GohMenuBar/GohMenuNotifications.swift` (types + pure detector)

**Responsibility:** `GohNotificationAuthorization` enum, `GohNotificationContent` struct, `GohMenuNotificationService` protocol, and the pure `GohNotificationTransitionDetector`. No `UNUserNotificationCenter` in this file — that is the live impl in Task P2-3.

**Files**
- CREATE `Sources/GohMenuBar/GohMenuNotifications.swift`
- CREATE `Tests/GohMenuBarTests/GohNotificationTransitionDetectorTests.swift`

**Pre-task reads**
- [x] `Sources/GohCore/Model/JobState.swift` — `JobState` cases: `.queued`, `.active`, `.paused`, `.completed`, `.failed` (only two are terminal: `.completed` and `.failed`)
- [x] `Sources/GohCore/Model/JobSummary.swift` — `JobSummary.id: UInt64`
- [x] `Sources/GohCore/Model/ProgressSubscription.swift` — `ProgressSnapshot.job: JobSummary`
- [x] `Sources/GohMenuBar/GohMenuPresenter.swift` — `nonisolated public struct` Sendable pattern

**Step 1 — Failing tests**

File: `Tests/GohMenuBarTests/GohNotificationTransitionDetectorTests.swift` (CREATE)

```swift
import Foundation
import Testing
import GohCore
@testable import GohMenuBar

// AC2: pure transition detector — seed suppression, dedup, both terminal variants.
@Suite("GohNotificationTransitionDetector")
struct GohNotificationTransitionDetectorTests {

    // AC2: seed snapshot (previous == nil) must not fire any notifications,
    // even if jobs are already completed/failed.
    @Test func seedSnapshotSuppressesAllNotifications() {
        let snapshots = [
            snapshot(id: 1, state: .completed),
            snapshot(id: 2, state: .failed),
            snapshot(id: 3, state: .active),
        ]
        let detector = GohNotificationTransitionDetector()
        let (toPost, next) = detector.evaluate(previous: nil, snapshots: snapshots)

        #expect(toPost.isEmpty)
        // Seeds the prior-state map with current states.
        #expect(next[1] == .completed)
        #expect(next[2] == .failed)
        #expect(next[3] == .active)
    }

    // AC2: non-terminal → completed fires exactly one notification.
    @Test func activeToCompletedFiresOneNotification() {
        let detector = GohNotificationTransitionDetector()
        let prior: [UInt64: JobState] = [1: .active]
        let (toPost, next) = detector.evaluate(
            previous: prior,
            snapshots: [snapshot(id: 1, state: .completed)])

        #expect(toPost.count == 1)
        #expect(toPost[0].title.lowercased().contains("complete"))
        #expect(next[1] == .completed)
    }

    // AC2: non-terminal → failed fires exactly one notification.
    @Test func activeToFailedFiresOneNotification() {
        let detector = GohNotificationTransitionDetector()
        let prior: [UInt64: JobState] = [1: .active]
        let (toPost, next) = detector.evaluate(
            previous: prior,
            snapshots: [snapshot(id: 1, state: .failed)])

        #expect(toPost.count == 1)
        #expect(toPost[0].title.lowercased().contains("fail"))
        #expect(next[1] == .failed)
    }

    // AC2: repeat snapshot of an already-terminal job must not re-fire.
    @Test func alreadyTerminalDoesNotRefire() {
        let detector = GohNotificationTransitionDetector()
        let prior: [UInt64: JobState] = [1: .completed]
        let (toPost, _) = detector.evaluate(
            previous: prior,
            snapshots: [snapshot(id: 1, state: .completed)])

        #expect(toPost.isEmpty)
    }

    // AC2: job disappears from snapshot set — no notification, removed from next map.
    @Test func disappearingJobDroppedFromMap() {
        let detector = GohNotificationTransitionDetector()
        let prior: [UInt64: JobState] = [1: .active, 2: .active]
        // Job 1 disappears; job 2 remains active.
        let (toPost, next) = detector.evaluate(
            previous: prior,
            snapshots: [snapshot(id: 2, state: .active)])

        #expect(toPost.isEmpty)
        #expect(next[1] == nil)
        #expect(next[2] == .active)
    }

    // AC2: bulk — N concurrent terminal transitions → one notification each.
    @Test func bulkCompletionFiresOnePerJob() {
        let detector = GohNotificationTransitionDetector()
        let prior: [UInt64: JobState] = [1: .active, 2: .active, 3: .paused]
        let (toPost, _) = detector.evaluate(
            previous: prior,
            snapshots: [
                snapshot(id: 1, state: .completed),
                snapshot(id: 2, state: .failed),
                snapshot(id: 3, state: .completed),
            ])

        #expect(toPost.count == 3)
    }

    // AC2: terminal → terminal (e.g. completed → completed) should not re-fire.
    @Test func terminalToSameTerminalDoesNotRefire() {
        let detector = GohNotificationTransitionDetector()
        let prior: [UInt64: JobState] = [1: .failed]
        let (toPost, _) = detector.evaluate(
            previous: prior,
            snapshots: [snapshot(id: 1, state: .failed)])

        #expect(toPost.isEmpty)
    }

    // Helper
    private func snapshot(id: UInt64, state: JobState) -> ProgressSnapshot {
        ProgressSnapshot(
            job: JobSummary(
                id: id,
                url: "https://example.com/\(id).bin",
                destination: "/tmp/\(id).bin",
                state: state,
                progress: JobProgress(bytesCompleted: 0, bytesTotal: 0, bytesPerSecond: 0),
                createdAt: Date(timeIntervalSince1970: 0),
                lastProgressAt: nil,
                requestedConnectionCount: 1,
                actualConnectionCount: 0),
            lanes: [])
    }
}
```

Run: `swift test --filter GohNotificationTransitionDetectorTests` — expect failure.

**Step 2 — Minimal implementation**

File: `Sources/GohMenuBar/GohMenuNotifications.swift` (CREATE)

```swift
import Foundation
import GohCore

// MARK: - Shared enums / value types (nonisolated Sendable per GohMenuBar convention)

public enum GohNotificationAuthorization: Sendable {
    case authorized
    case denied
    case undetermined
}

public struct GohNotificationContent: Sendable, Equatable {
    /// Short title, e.g. "Download complete" or "Download failed".
    public let title: String
    /// Sanitized body: file name + outcome. Any host/URL component must pass
    /// through URLDisplay.sanitized before inclusion (spec §5 PII rule).
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

// MARK: - Service protocol (implemented by live UNUserNotificationCenter in goh-menu; stubbed in tests)

public protocol GohMenuNotificationService: Sendable {
    /// Returns the current authorization status without prompting.
    func authorizationStatus() async -> GohNotificationAuthorization
    /// Requests authorization once. Idempotent; errors are swallowed (best-effort).
    func requestAuthorization() async
    /// Posts a notification. Best-effort: errors are swallowed; view never sees raw errors.
    func post(_ content: GohNotificationContent) async
}

// MARK: - Pure transition detector (no framework, fully unit-tested)

/// Stateless mapper: given the previous per-job state map and the current snapshot batch,
/// returns the notifications to post and the updated state map.
///
/// Contract (spec §7.2):
/// - previous == nil (seed): suppress all notifications; return current states as `next`.
/// - previous != nil: emit one GohNotificationContent for each job whose state went
///   non-terminal → terminal. Jobs absent from snapshots are dropped from `next`.
nonisolated public struct GohNotificationTransitionDetector: Sendable {
    public init() {}

    public func evaluate(
        previous: [UInt64: JobState]?,
        snapshots: [ProgressSnapshot]
    ) -> (toPost: [GohNotificationContent], next: [UInt64: JobState]) {
        // Build the current map from the snapshot batch.
        var next: [UInt64: JobState] = [:]
        for snapshot in snapshots {
            next[snapshot.job.id] = snapshot.job.state
        }

        // Seed path: suppress all notifications; just seed the map.
        guard let previous else {
            return (toPost: [], next: next)
        }

        // Transition path: emit one notification per non-terminal → terminal edge.
        var toPost: [GohNotificationContent] = []
        for snapshot in snapshots {
            let job = snapshot.job
            let currentState = job.state
            guard currentState.isTerminal else { continue }

            let previousState = previous[job.id]
            // Only fire on the transition edge: was not terminal (or absent = new job appearing terminal).
            // A new job appearing directly terminal in the first post-seed update should fire.
            // A job already recorded terminal should not re-fire.
            if let prev = previousState, prev.isTerminal {
                // Already terminal — no edge, no notification.
                continue
            }

            let fileName = URL(filePath: job.destination).lastPathComponent
            let displayName = fileName.isEmpty ? job.destination : fileName

            let content: GohNotificationContent
            switch currentState {
            case .completed:
                content = GohNotificationContent(
                    title: "Download complete",
                    body: displayName)
            case .failed:
                content = GohNotificationContent(
                    title: "Download failed",
                    body: displayName)
            default:
                // Should not reach here due to isTerminal guard above.
                continue
            }
            toPost.append(content)
        }

        return (toPost: toPost, next: next)
    }
}

// MARK: - JobState terminal helper

private extension JobState {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed: true
        case .queued, .active, .paused: false
        }
    }
}
```

**Step 3 — Run tests, expect green**
```
swift test --filter GohNotificationTransitionDetectorTests
```

**Step 4 — Health check**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -warnings-as-errors 2>&1 | tail -5
```

**Step 5 — Commit**
```
feat(menu): add GohMenuNotifications types + GohNotificationTransitionDetector (pure)
```

---

### Task P1-3 — CREATE `Sources/GohMenuBar/GohMenuLoginItem.swift`

**Responsibility:** `GohLoginItemStatus` enum, `GohMenuLoginItem` protocol, `UnsupportedLoginItem` stub (for debug bare-binary path). The live `SMAppService` impl is wired in Task P2-4.

**Files**
- CREATE `Sources/GohMenuBar/GohMenuLoginItem.swift`
- CREATE `Tests/GohMenuBarTests/GohMenuLoginItemTests.swift`

**Pre-task reads**
- [x] `Sources/GohMenuBar/GohMenuPresenter.swift` — confirm `nonisolated public enum` + Sendable pattern
- [x] `Tests/GohMenuBarTests/GohMenuPresenterTests.swift` — stub/injection pattern

**Step 1 — Failing tests**

File: `Tests/GohMenuBarTests/GohMenuLoginItemTests.swift` (CREATE)

```swift
import Foundation
import Testing
@testable import GohMenuBar

// AC3: login-item protocol + status enum; stubbed service; unsupported path.
@Suite("GohMenuLoginItem")
struct GohMenuLoginItemTests {

    // AC3: stub returns scripted status — enabled
    @Test func stubReturnsEnabled() {
        let stub = StubLoginItem(status: .enabled)
        #expect(stub.status() == .enabled)
    }

    // AC3: stub returns requiresApproval — UI must render this honestly
    @Test func stubReturnsRequiresApproval() {
        let stub = StubLoginItem(status: .requiresApproval)
        #expect(stub.status() == .requiresApproval)
    }

    // AC3: unsupported path — bare binary without .app bundle
    @Test func unsupportedLoginItemReturnsUnsupported() {
        let item = UnsupportedLoginItem()
        #expect(item.status() == .unsupported)
    }

    // AC3: unsupported register throws
    @Test func unsupportedRegisterThrows() throws {
        let item = UnsupportedLoginItem()
        #expect(throws: (any Error).self) {
            try item.register()
        }
    }

    // AC3: stub records register/unregister calls
    @Test func stubRecordsCalls() throws {
        let stub = StubLoginItem(status: .notRegistered)
        try stub.register()
        #expect(stub.registerCallCount == 1)
        try stub.unregister()
        #expect(stub.unregisterCallCount == 1)
    }
}

// MARK: - Test helpers

final class StubLoginItem: GohMenuLoginItem, @unchecked Sendable {
    private let stubbedStatus: GohLoginItemStatus
    var registerCallCount = 0
    var unregisterCallCount = 0

    init(status: GohLoginItemStatus) {
        self.stubbedStatus = status
    }

    func status() -> GohLoginItemStatus { stubbedStatus }
    func register() throws { registerCallCount += 1 }
    func unregister() throws { unregisterCallCount += 1 }
}
```

Run: `swift test --filter GohMenuLoginItemTests` — expect failure.

**Step 2 — Minimal implementation**

File: `Sources/GohMenuBar/GohMenuLoginItem.swift` (CREATE)

```swift
import Foundation

/// Registration state of the tray app as a login item (spec §7.3).
/// Maps SMAppService.Status + an unsupported sentinel for the debug bare-binary path.
nonisolated public enum GohLoginItemStatus: Sendable, Equatable {
    /// Registered and confirmed enabled by the user.
    case enabled
    /// Registered; awaiting user confirmation in System Settings → Login Items.
    case requiresApproval
    /// Not currently registered.
    case notRegistered
    /// The app identifier was not found — typically indicates a stale registration.
    case notFound
    /// Running outside a proper .app bundle (debug dogfood bare binary).
    /// Login-item controls must be disabled in the UI when this is returned.
    case unsupported
}

/// Protocol-fronted login-item service (spec §7.3).
/// Sendable + nonisolated per GohMenuBar convention.
/// Live impl (SMAppService) is wired in goh-menu; unit tests use StubLoginItem.
public protocol GohMenuLoginItem: Sendable {
    /// Returns the current registration status without modifying it.
    func status() -> GohLoginItemStatus
    /// Registers the tray app as a login item. Throws on failure so the UI can surface a message.
    func register() throws
    /// Unregisters the tray app. Throws on failure so the UI can surface a message.
    func unregister() throws
}

// MARK: - Unsupported sentinel (debug bare-binary path)

/// Returned when the app is running outside a proper .app bundle.
/// register()/unregister() throw `GohLoginItemError.unsupported` so callers can surface a message.
nonisolated public struct UnsupportedLoginItem: GohMenuLoginItem, Sendable {
    public init() {}

    public func status() -> GohLoginItemStatus { .unsupported }

    public func register() throws {
        throw GohLoginItemError.unsupported
    }

    public func unregister() throws {
        throw GohLoginItemError.unsupported
    }
}

/// Errors surfaced by login-item operations (mapped to plain English by the preferences view).
nonisolated public enum GohLoginItemError: Error, Sendable, Equatable {
    /// The app is running outside a proper .app bundle.
    case unsupported
    /// SMAppService returned an error; message is surfaced to the user.
    case registrationFailed(String)
}
```

**Step 3 — Run tests, expect green**
```
swift test --filter GohMenuLoginItemTests
```

**Step 4 — Full test suite + build health check**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -warnings-as-errors 2>&1 | tail -5
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -10
```
All 716+ tests must pass; build must be warning-free.

**Step 5 — Write phase 1 artifact**

Write `docs/superpowers/progress/2026-06-06-tray-app-distribution-phase1.md` (see separate artifact file).

**Step 6 — Commit**
```
feat(menu): add GohMenuLoginItem protocol, GohLoginItemStatus, UnsupportedLoginItem
```

---

## Phase 2 — Wiring layer

### Task P2-1 — MODIFY `Sources/goh-menu/main.swift`: move subscription ownership to composition root

**Responsibility:** The progress subscription that today lives in `GohMenuView.body` (`.task { model.start() }` / `.onDisappear { model.stop() }`) moves to `GohMenuAppDelegate`. `start()` is called once at `applicationDidFinishLaunching`; `stop()` is called at termination. The view retains `refreshClipboard()` on appear (cheap, view-scoped). No new actor; the model stays `@MainActor`.

**Files**
- MODIFY `Sources/goh-menu/main.swift`
- MODIFY `Sources/GohMenuBar/GohMenuView.swift`

**Pre-task reads**
- [x] `Sources/goh-menu/main.swift` — full file: `@StateObject private var model`, `GohMenuAppDelegate.applicationDidFinishLaunching`, `GohMenuApp.body`
- [x] `Sources/GohMenuBar/GohMenuView.swift` — `.task { model.start(); await model.refreshClipboard() }` lines 27–29; `.onDisappear { model.stop() }` line 31–33; footer section

**No new unit test** — this is a structural lifecycle change; the existing `GohMenuProgressStreamTests` + `GohMenuPresenterTests` continue to validate the model. Verify by inspection and build.

**Step 1 — Modify `GohMenuAppDelegate`**

In `Sources/goh-menu/main.swift`, the `GohMenuAppDelegate` class currently has only `applicationDidFinishLaunching` setting the activation policy. **Store the model directly on the delegate** (which AppKit owns for the full process lifetime) and eliminate the `@StateObject` in `GohMenuApp` — this is the single correct wiring; do not introduce a separate `@StateObject` and a bridge step. Since `GohMenuViewModel` is already `@MainActor`-isolated and `ObservableObject`:

```swift
@MainActor
final class GohMenuAppDelegate: NSObject, NSApplicationDelegate {
    let model: GohMenuViewModel = GohMenuViewModel(
        client: LiveGohMenuClient(),
        pasteboardText: { NSPasteboard.general.string(forType: .string) },
        revealInFinder: { destination in
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: destination)])
        },
        openTerminalDashboard: { openTopInTerminal() },
        openDoctor: { openDoctorInTerminal() },
        copyText: { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}

@main
struct GohMenuApp: App {
    @NSApplicationDelegateAdaptor(GohMenuAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            GohMenuView(
                model: appDelegate.model,
                quitApplication: { NSApplication.shared.terminate(nil) })
        } label: {
            Label("goh", systemImage: "arrow.down.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
```

This eliminates `@StateObject` entirely; the model lifetime is tied to `GohMenuAppDelegate` (which AppKit owns for the full process lifetime). `GohMenuView` receives `model` as `@ObservedObject` — unchanged. No reference cycles; the delegate outlives the view.

**Step 2 — Modify `GohMenuView.swift`**

Remove `model.start()` from `.task` and `model.stop()` from `.onDisappear`. Keep `await model.refreshClipboard()` in `.task` (cheap, view-scoped, correct behavior).

```swift
// BEFORE (lines 27–33):
.task {
    model.start()
    await model.refreshClipboard()
}
.onDisappear {
    model.stop()
}

// AFTER:
.task {
    await model.refreshClipboard()
}
// .onDisappear removed — subscription is now owned by GohMenuAppDelegate
```

**Step 3 — Build verification**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -warnings-as-errors 2>&1 | tail -10
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -10
```
All tests must remain green.

**Step 4 — Commit**
```
refactor(menu): move subscription lifecycle to GohMenuAppDelegate (composition root)
```

---

### Task P2-2 — MODIFY `Sources/GohMenuBar/GohMenuView.swift`: add Preferences footer entry

**Responsibility:** Add a "Preferences…" button to the footer that opens `GohMenuPreferencesView` (sheet or popover). The preferences service and login-item service are passed in from the composition root.

**Files**
- MODIFY `Sources/GohMenuBar/GohMenuView.swift`

**Pre-task reads**
- [x] `Sources/GohMenuBar/GohMenuView.swift` — the `footer` computed var, `GohMenuView.init`, how `quitApplication` closure is threaded
- [x] `Sources/GohMenuBar/GohMenuModels.swift` — `GohMenuState` structure

**No new unit test** — view layout; validated by running the app (Task P2-6 integration smoke).

**Implementation note:** `GohMenuView` must accept `GohMenuPreferences` and `GohMenuLoginItem` from the caller and pass them to `GohMenuPreferencesView`. Add them to `GohMenuView.init` as injectable dependencies. Mark both as `any GohMenuPreferences` / `any GohMenuLoginItem` so the view does not need to know the concrete type.

Changes to `GohMenuView`:

1. Add stored properties:
   ```swift
   private let preferences: any GohMenuPreferences
   private let loginItem: any GohMenuLoginItem
   @State private var showPreferences = false
   ```

2. Update `init` to accept them (with default `UserDefaultsMenuPreferences()` and `UnsupportedLoginItem()` so existing tests compile without changes):
   ```swift
   public init(
       model: GohMenuViewModel,
       preferences: any GohMenuPreferences = UserDefaultsMenuPreferences(),
       loginItem: any GohMenuLoginItem = UnsupportedLoginItem(),
       quitApplication: @escaping () -> Void
   )
   ```

3. In the `footer` computed var, add a Preferences button before the Spacer:
   ```swift
   Button {
       showPreferences = true
   } label: {
       Label("Preferences…", systemImage: "gearshape")
   }
   .help("Open goh preferences")
   .sheet(isPresented: $showPreferences) {
       GohMenuPreferencesView(preferences: preferences, loginItem: loginItem)
   }
   ```

**Step 1 — Build**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -warnings-as-errors 2>&1 | tail -10
```

**Step 2 — Commit**
```
feat(menu): add Preferences entry to GohMenuView footer
```

---

### Task P2-3 — CREATE `Sources/GohMenuBar/GohMenuNotificationsLive.swift` + notification coordinator wiring

**Responsibility:** Live `UNUserNotificationCenter` impl of `GohMenuNotificationService`. The notification coordinator that calls `GohNotificationTransitionDetector` lives in `GohMenuAppDelegate` (in `goh-menu/main.swift`) and is wired to the existing `[ProgressSnapshot]` update stream from `GohMenuViewModel`. Authorization is requested once at first launch.

**Files**
- CREATE `Sources/GohMenuBar/GohMenuNotificationsLive.swift` (live impl only; pure types already in GohMenuNotifications.swift)
- MODIFY `Sources/goh-menu/main.swift` (coordinator wiring in `applicationDidFinishLaunching`)

**Pre-task reads**
- [x] `Sources/GohMenuBar/GohMenuViewModel.swift` — `applyProgressSnapshots(_:)` at line 166; how to hook into the snapshot stream from outside the model (the model publishes via `@Published var state`; the coordinator needs the raw `[ProgressSnapshot]` — add a `@Published private(set) var snapshots: [ProgressSnapshot]` to the model, or expose via a publisher)
- [x] `Sources/GohMenuBar/GohMenuNotifications.swift` — `GohMenuNotificationService` protocol and `GohNotificationTransitionDetector`
- [x] `Sources/GohMenuBar/GohMenuPreferences.swift` — `GohMenuPreferences.notificationsEnabled`
- [x] `Sources/GohCore/Platform/SpotlightMetadataTagger.swift` — best-effort error-swallow pattern
- [x] `Sources/goh-menu/main.swift` — current `GohMenuAppDelegate` after Task P2-1

**Step 1 — No unit test** for the live `UNUserNotificationCenter` wrapper (it calls a real framework). Validate via build. The pure detector is already tested in P1-2.

**Step 2 — Implementation: live notification service**

File: `Sources/GohMenuBar/GohMenuNotificationsLive.swift` (CREATE)

```swift
import Foundation
import UserNotifications

/// Live implementation of GohMenuNotificationService backed by UNUserNotificationCenter.
/// Errors are swallowed (best-effort); the view never sees raw errors — mirroring
/// SpotlightMetadataTagger's pattern (spec §6 "best-effort side effects").
///
/// The methods are deliberately MainActor-isolated (NOT `nonisolated`). The class is
/// `@MainActor` and holds a non-Sendable `UNUserNotificationCenter`; a `nonisolated`
/// method touching `center` would fail to compile ("non-Sendable type ... cannot exit
/// main actor-isolated context"). A `@MainActor` class is implicitly `Sendable`, so it
/// still satisfies the `Sendable` `GohMenuNotificationService` protocol, and a
/// MainActor-isolated `async` method validly witnesses a `nonisolated async` protocol
/// requirement (the call hops to the actor). The coordinator/caller is `@MainActor`, so
/// `await service.post(...)` continues to work.
@MainActor
public final class LiveNotificationService: GohMenuNotificationService {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func authorizationStatus() async -> GohNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .undetermined
        @unknown default:
            return .undetermined
        }
    }

    public func requestAuthorization() async {
        // Request alert + sound; never throws to caller (best-effort).
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    public func post(_ content: GohNotificationContent) async {
        let status = await authorizationStatus()
        guard status == .authorized else { return }

        let notifContent = UNMutableNotificationContent()
        notifContent.title = content.title
        notifContent.body = content.body
        notifContent.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: notifContent,
            trigger: nil)
        // Swallow: best-effort, view never sees errors (spec §7.2 + §6 rule).
        _ = try? await center.add(request)
    }
}
```

**Step 3 — Add a synchronous, ordered snapshot hook to GohMenuViewModel**

Do **NOT** use `@Published` + Combine `.sink` for the notification feed. `@Published`
replays its current value (`[]`) synchronously to a new subscriber, so the coordinator
would seed its prior-state map from the empty replay and then treat the *real* seed
snapshot (which may contain pre-launch terminal jobs, spec §6) as transitions — firing
spurious "download complete" notifications for old downloads on every launch.

Instead, add a plain synchronous closure hook called at the end of `applyProgressSnapshots`.
Because `applyProgressSnapshots` runs sequentially on `@MainActor`, deliveries arrive in
order (seed first, then updates) with no replay. In `Sources/GohMenuBar/GohMenuViewModel.swift`:

```swift
// Add this stored property to GohMenuViewModel (MainActor-isolated; no Sendable needed
// — it is only ever set/called on the main actor):
public var onProgressSnapshots: (([ProgressSnapshot]) -> Void)?

// In applyProgressSnapshots(_:), call the hook AFTER applying state:
private func applyProgressSnapshots(_ snapshots: [ProgressSnapshot]) {
    self.snapshots = snapshots
    render(health: .connected)
    onProgressSnapshots?(snapshots)   // add this line — the seed is the first call
}
```

No new `latestSnapshots` array, no `import Combine`, no `@Published` duplication.

**Step 3b — Create the testable notification coordinator**

File: `Sources/GohMenuBar/GohNotificationCoordinator.swift` (CREATE). It owns the
nil-seed prior-state and runs the pure detector; it returns the content to post (the
caller does the posting), so the seed/dedup logic is unit-testable with no framework and
no async. The first `evaluate` call is the seed (`previous == nil` → suppressed); state
advances even when notifications are disabled, so enabling mid-session never replays
already-terminal jobs.

```swift
import Foundation
import GohCore

@MainActor
public final class GohNotificationCoordinator {
    private let detector = GohNotificationTransitionDetector()
    private let preferences: any GohMenuPreferences
    private var previous: [UInt64: JobState]? = nil  // nil = not yet seeded

    public init(preferences: any GohMenuPreferences) {
        self.preferences = preferences
    }

    /// Call once per REAL snapshot delivery, in order (seed first, then updates).
    /// Returns the notifications to post. State advances regardless of the
    /// notifications-enabled toggle so that enabling later does not replay history.
    public func evaluate(_ snapshots: [ProgressSnapshot]) -> [GohNotificationContent] {
        let (toPost, next) = detector.evaluate(previous: previous, snapshots: snapshots)
        previous = next
        guard preferences.notificationsEnabled else { return [] }
        return toPost
    }
}
```

**Step 3c — Unit test the coordinator** (this is the round-2 review's required test:
a pre-launch terminal job must produce zero notifications across the seed).

File: `Tests/GohMenuBarTests/GohNotificationCoordinatorTests.swift` (CREATE). Use the
existing `@Suite`/`@Test` + stub-injection pattern; reuse the `ProgressSnapshot`/`JobSummary`
fixture helper from `GohNotificationTransitionDetectorTests` (P1-2).

```swift
import Testing
import GohCore
@testable import GohMenuBar

@Suite struct GohNotificationCoordinatorTests {
    final class StubPreferences: GohMenuPreferences, @unchecked Sendable {
        var notificationsEnabled: Bool
        var launchAtLoginEnabled: Bool = false
        init(notificationsEnabled: Bool) { self.notificationsEnabled = notificationsEnabled }
    }

    @Test func seedSuppressesPreLaunchTerminalJobs() {
        // AC2: a download already complete before the app started must NOT notify.
        let coord = GohNotificationCoordinator(preferences: StubPreferences(notificationsEnabled: true))
        let out = coord.evaluate([makeSnapshot(id: 1, state: .completed)]) // seed
        #expect(out.isEmpty)
    }

    @Test func postSeedTransitionFiresOnce() {
        let coord = GohNotificationCoordinator(preferences: StubPreferences(notificationsEnabled: true))
        _ = coord.evaluate([makeSnapshot(id: 1, state: .active)])          // seed (non-terminal)
        let out1 = coord.evaluate([makeSnapshot(id: 1, state: .completed)]) // transition → fire
        let out2 = coord.evaluate([makeSnapshot(id: 1, state: .completed)]) // repeat → no refire
        #expect(out1.count == 1)
        #expect(out2.isEmpty)
    }

    @Test func disabledSuppressesButAdvancesState() {
        let prefs = StubPreferences(notificationsEnabled: false)
        let coord = GohNotificationCoordinator(preferences: prefs)
        _ = coord.evaluate([makeSnapshot(id: 1, state: .active)])          // seed
        let outOff = coord.evaluate([makeSnapshot(id: 1, state: .completed)]) // disabled → []
        #expect(outOff.isEmpty)
        prefs.notificationsEnabled = true
        let outOn = coord.evaluate([makeSnapshot(id: 1, state: .completed)]) // already terminal → no replay
        #expect(outOn.isEmpty)
    }

    // Helper — self-contained (the P1-2 helper is `private` to the detector suite).
    // Mirrors the P1-2 fixture exactly; `.active` is the real non-terminal JobState case
    // (the enum is queued/active/paused/completed/failed — there is no `.running`).
    private func makeSnapshot(id: UInt64, state: JobState) -> ProgressSnapshot {
        ProgressSnapshot(
            job: JobSummary(
                id: id,
                url: "https://example.com/\(id).bin",
                destination: "/tmp/\(id).bin",
                state: state,
                progress: JobProgress(bytesCompleted: 0, bytesTotal: 0, bytesPerSecond: 0),
                createdAt: Date(timeIntervalSince1970: 0),
                lastProgressAt: nil,
                requestedConnectionCount: 1,
                actualConnectionCount: 0),
            lanes: [])
    }
}
```

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohNotificationCoordinatorTests`
Expected: 3 tests pass.

**Step 4 — Wire coordinator in GohMenuAppDelegate**

In `Sources/goh-menu/main.swift`, wire the hook BEFORE `start()` so the seed is captured.
No Combine. The posting is done in the (synchronous) hook by spawning one Task per content;
ordering of the prior-state mutation is preserved because `evaluate` is synchronous and
runs inside the ordered `applyProgressSnapshots` call.

```swift
@MainActor
final class GohMenuAppDelegate: NSObject, NSApplicationDelegate {
    let model: GohMenuViewModel = GohMenuViewModel(/* ... unchanged ... */)
    let preferences: UserDefaultsMenuPreferences = UserDefaultsMenuPreferences()
    let notificationService: LiveNotificationService = LiveNotificationService()
    let loginItem: any GohMenuLoginItem = GohMenuAppDelegate.makeLoginItem()
    private lazy var coordinator = GohNotificationCoordinator(preferences: preferences)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        // Wire the notification feed BEFORE start() so the first (seed) delivery is captured.
        model.onProgressSnapshots = { [weak self] snapshots in
            guard let self else { return }
            let toPost = self.coordinator.evaluate(snapshots)   // sync, ordered, MainActor
            for content in toPost {
                let service = self.notificationService
                Task { await service.post(content) }
            }
        }

        // Request notification authorization once (best-effort; never blocks start()).
        Task { await notificationService.requestAuthorization() }

        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.onProgressSnapshots = nil
        model.stop()
    }

    private static func makeLoginItem() -> any GohMenuLoginItem {
        // SMAppService requires a real .app bundle. Return UnsupportedLoginItem
        // when running as a bare binary (no bundle identifier).
        guard Bundle.main.bundleIdentifier != nil else {
            return UnsupportedLoginItem()
        }
        return SMAppServiceLoginItem()
    }
}
```

**Step 5 — Build verification**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -warnings-as-errors 2>&1 | tail -10
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -10
```

**Step 6 — Commit**
```
feat(menu): add LiveNotificationService + notification coordinator in app delegate
```

---

### Task P2-4 — CREATE `Sources/GohMenuBar/GohMenuLoginItemLive.swift` (SMAppService impl)

**Responsibility:** `SMAppServiceLoginItem` — maps `SMAppService.mainApp` status/register/unregister to `GohLoginItemStatus`/`GohLoginItemError`.

**Files**
- CREATE `Sources/GohMenuBar/GohMenuLoginItemLive.swift`

**Pre-task reads**
- [x] `Sources/GohMenuBar/GohMenuLoginItem.swift` — `GohMenuLoginItem` protocol, `GohLoginItemStatus`, `GohLoginItemError`
- [x] `Sources/GohMenuBar/GohMenuNotifications.swift` — confirm `nonisolated` + Sendable on impls

**No new unit test** — `SMAppService.mainApp` is a real framework API requiring a bundle; cannot be called in unit tests. The `StubLoginItem` in P1-3 covers the protocol contract. Validate via build.

**Implementation**

File: `Sources/GohMenuBar/GohMenuLoginItemLive.swift` (CREATE)

```swift
import Foundation
import ServiceManagement

/// Live implementation of GohMenuLoginItem backed by SMAppService.mainApp.
/// Requires a valid .app bundle with CFBundleIdentifier.
/// Use UnsupportedLoginItem when running as a bare binary.
nonisolated public final class SMAppServiceLoginItem: GohMenuLoginItem, Sendable {
    public init() {}

    public func status() -> GohLoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled:           return .enabled
        case .requiresApproval:  return .requiresApproval
        case .notRegistered:     return .notRegistered
        case .notFound:          return .notFound
        @unknown default:        return .notFound
        }
    }

    public func register() throws {
        do {
            try SMAppService.mainApp.register()
        } catch {
            throw GohLoginItemError.registrationFailed(error.localizedDescription)
        }
    }

    public func unregister() throws {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            throw GohLoginItemError.registrationFailed(error.localizedDescription)
        }
    }
}
```

**Step 1 — Build**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -warnings-as-errors 2>&1 | tail -5
```

**Step 2 — Commit**
```
feat(menu): add SMAppServiceLoginItem live implementation
```

---

### Task P2-5 — CREATE `Sources/GohMenuBar/GohMenuPreferencesView.swift`

**Responsibility:** SwiftUI preferences surface: two toggles (notifications, launch-at-login). The launch-at-login toggle reflects `GohMenuLoginItem.status()` and renders the `.requiresApproval` affordance. Uses `@AppStorage`-style binding via the `GohMenuPreferences` protocol (no direct `@AppStorage` in this file — the injectable store is the source of truth, per project convention).

**Files**
- CREATE `Sources/GohMenuBar/GohMenuPreferencesView.swift`

**Pre-task reads**
- [x] `Sources/GohMenuBar/GohMenuView.swift` — SwiftUI style conventions (font, .controlSize, .buttonStyle, .help usage)
- [x] `Sources/GohMenuBar/GohMenuLoginItem.swift` — `GohLoginItemStatus` cases incl. `.requiresApproval` and `.unsupported`
- [x] `Sources/GohMenuBar/GohMenuPreferences.swift` — `GohMenuPreferences` protocol

**No unit test** — SwiftUI view; validated by running the app.

**Implementation**

File: `Sources/GohMenuBar/GohMenuPreferencesView.swift` (CREATE)

```swift
import SwiftUI

/// Preferences sheet: two toggles — notifications and launch-at-login.
/// Injected with GohMenuPreferences and GohMenuLoginItem so the view never
/// touches UserDefaults or SMAppService directly (unit-test-safe contract).
public struct GohMenuPreferencesView: View {
    private let preferences: any GohMenuPreferences
    private let loginItem: any GohMenuLoginItem

    @State private var notificationsEnabled: Bool
    @State private var launchAtLoginEnabled: Bool
    @State private var loginItemStatus: GohLoginItemStatus
    @State private var loginItemError: String? = nil

    public init(
        preferences: any GohMenuPreferences,
        loginItem: any GohMenuLoginItem
    ) {
        self.preferences = preferences
        self.loginItem = loginItem
        _notificationsEnabled = State(initialValue: preferences.notificationsEnabled)
        _launchAtLoginEnabled = State(
            initialValue: loginItem.status() == .enabled || loginItem.status() == .requiresApproval)
        _loginItemStatus = State(initialValue: loginItem.status())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preferences")
                .font(.headline)

            Toggle("Enable completion notifications", isOn: $notificationsEnabled)
                .onChange(of: notificationsEnabled) { _, newValue in
                    preferences.notificationsEnabled = newValue
                }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    loginItemStatus == .unsupported
                        ? "Launch at login (not available in debug mode)"
                        : "Launch at login",
                    isOn: $launchAtLoginEnabled)
                .disabled(loginItemStatus == .unsupported)
                .onChange(of: launchAtLoginEnabled) { _, newValue in
                    applyLoginItemToggle(newValue)
                }

                if loginItemStatus == .requiresApproval {
                    Text("Enabled — approve in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = loginItemError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 320, height: 200)
        .onAppear {
            // Refresh status when the sheet opens (user may have approved in Settings).
            loginItemStatus = loginItem.status()
            launchAtLoginEnabled = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        }
    }

    private func applyLoginItemToggle(_ enable: Bool) {
        loginItemError = nil
        do {
            if enable {
                try loginItem.register()
            } else {
                try loginItem.unregister()
            }
            preferences.launchAtLoginEnabled = enable
            loginItemStatus = loginItem.status()
            // Reflect the actual post-operation status.
            launchAtLoginEnabled = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        } catch GohLoginItemError.registrationFailed(let message) {
            loginItemError = "Could not update login item: \(message)"
            preferences.launchAtLoginEnabled = loginItem.status() == .enabled
            launchAtLoginEnabled = preferences.launchAtLoginEnabled
        } catch {
            loginItemError = "Unexpected error: \(error.localizedDescription)"
        }
    }
}
```

**Step 1 — Build**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -warnings-as-errors 2>&1 | tail -5
```

**Step 2 — Wire into GohMenuView's footer (connect to Task P2-2)**

Verify the `GohMenuView.init` now accepts `preferences` and `loginItem`, and that `GohMenuAppDelegate` passes the live instances:
```swift
// In GohMenuApp.body:
GohMenuView(
    model: appDelegate.model,
    preferences: appDelegate.preferences,
    loginItem: appDelegate.loginItem,
    quitApplication: { NSApplication.shared.terminate(nil) })
```

**Step 3 — Full test + build health check**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -warnings-as-errors 2>&1 | tail -5
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -10
```

**Step 4 — Write phase 2 artifact**

Write `docs/superpowers/progress/2026-06-06-tray-app-distribution-phase2.md`.

**Step 5 — Commit**
```
feat(menu): add GohMenuPreferencesView with notifications + login-item toggles
```

---

## Phase 3 — Packaging layer

### Task P3-1 — CREATE `Resources/app-Info.plist` (Info.plist template)

**Responsibility:** The checked-in `Info.plist` template for `goh.app`. `LSMinimumSystemVersion` is `26.5` to match the PKG `requirements.plist` `os` pin (single-sourced via `package-app.sh` reading from the template; if the PKG pin changes, this file changes with it — spec §2 OS-floor note).

**Files**
- CREATE `Resources/app-Info.plist`

**Pre-task reads**
- [x] `Resources/dev.goh.daemon.plist` — confirm Resources directory location; confirm plist conventions
- [x] `Scripts/package-pkg.sh` — the `os` pin in `requirements.plist` is `26.5`; `LSMinimumSystemVersion` must match

**No unit test** — a static XML file. Validated by `plutil -lint` and `defaults read` in Task P3-2.

**Implementation**

File: `Resources/app-Info.plist` (CREATE)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>goh</string>
    <key>CFBundleDisplayName</key>
    <string>goh</string>
    <key>CFBundleIdentifier</key>
    <string>dev.goh.menu</string>
    <key>CFBundleExecutable</key>
    <string>goh-menu</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>__VERSION__</string>
    <key>CFBundleShortVersionString</key>
    <string>__VERSION__</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.5</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2025 goh contributors. MIT License.</string>
</dict>
</plist>
```

**Validation:**
```bash
plutil -lint /Users/shane/claude/goh/Resources/app-Info.plist
```
Must print `OK`.

**Step 1 — Commit**
```
chore(pkg): add app-Info.plist template for goh.app bundle
```

---

### Task P3-2 — CREATE `Scripts/package-app.sh`

**Responsibility:** Assembles `goh.app` from the `swift build --release` `goh-menu` binary + the checked-in `Resources/app-Info.plist` template. The output path is consumed identically by `package-pkg.sh` and by the (future) signing script.

**Files**
- CREATE `Scripts/package-app.sh`

**Pre-task reads**
- [x] `Scripts/package-pkg.sh` — arg parsing, version validation regex, `repo_root` pattern, `output_dir` case statement — mirror exactly
- [x] `Resources/app-Info.plist` — the `__VERSION__` placeholder

**No Swift unit test** — shell script. Validated by the manual verification commands below.

**Implementation**

File: `Scripts/package-app.sh` (CREATE)

```bash
#!/usr/bin/env bash
set -euo pipefail

# Assembles goh.app from a swift build --release output.
# Usage: Scripts/package-app.sh <version> [output-directory]
#
# THE BET (Approach B): engine + tray app are versioned together in the PKG.
# This script is called by package-pkg.sh; the output path must not drift
# between the two scripts (advisory E from spec §7.5).
#
# Exit codes:
#   0   success
#   64  usage / bad version / missing CFBundleIdentifier in template

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: Scripts/package-app.sh <version> [output-directory]" >&2
  exit 64
fi

version="$1"

if [[ ! "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  echo "version may contain only letters, numbers, dots, underscores, and hyphens" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
output_arg="${2:-.build/release-artifacts}"

case "$output_arg" in
  /*) output_dir="$output_arg" ;;
  *) output_dir="$repo_root/$output_arg" ;;
esac

template="$repo_root/Resources/app-Info.plist"
app_dir="$output_dir/goh.app"
contents="$app_dir/Contents"
macos_dir="$contents/MacOS"
resources_dir="$contents/Resources"
info_plist="$contents/Info.plist"

# Guard: template must declare a CFBundleIdentifier (needed by SMAppService +
# UNUserNotificationCenter).
if ! /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$template" >/dev/null 2>&1; then
  echo "error: Info.plist template at $template is missing CFBundleIdentifier" >&2
  exit 64
fi

swift build --package-path "$repo_root" --configuration release --disable-sandbox

rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir" "$output_dir"

install -m 0755 "$repo_root/.build/release/goh-menu" "$macos_dir/goh-menu"

# Substitute __VERSION__ placeholder with the actual version string.
sed "s/__VERSION__/$version/g" "$template" > "$info_plist"
plutil -lint "$info_plist" >/dev/null

# Verify the identifier round-trips correctly.
bundle_id="$(defaults read "$contents/Info" CFBundleIdentifier 2>/dev/null || true)"
if [[ -z "$bundle_id" ]]; then
  echo "error: CFBundleIdentifier not readable from assembled Info.plist" >&2
  exit 1
fi

xattr -cr "$app_dir"

echo "app=$app_dir"
echo "bundle_id=$bundle_id"
```

**Validation (manual):**
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Scripts/package-app.sh 0.0.1-test
# Expected output lines:
#   app=<repo>/.build/release-artifacts/goh.app
#   bundle_id=dev.goh.menu

defaults read "$(pwd)/.build/release-artifacts/goh.app/Contents/Info" CFBundleIdentifier
# Expected: dev.goh.menu

defaults read "$(pwd)/.build/release-artifacts/goh.app/Contents/Info" LSUIElement
# Expected: 1

defaults read "$(pwd)/.build/release-artifacts/goh.app/Contents/Info" LSMinimumSystemVersion
# Expected: 26.5
```

**Step 1 — Build health (no regression to `swift build`)**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -warnings-as-errors 2>&1 | tail -5
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -10
```

**Step 2 — Commit**
```
feat(pkg): add Scripts/package-app.sh for goh.app assembly
```

---

### Task P3-3 — MODIFY `Scripts/package-pkg.sh` + MODIFY `Scripts/private-release-candidate.sh` + CREATE `Scripts/_stage-app-payload.sh` helper + MODIFY `DESIGN.md`

**Responsibility:**
1. Extract the `goh.app` staging block into a small shared helper `Scripts/_stage-app-payload.sh` (or at minimum edit both scripts in lockstep and comment them; the helper is preferred — single point of change, eliminates the advisory-E drift risk).
2. Extend `package-pkg.sh` to call `package-app.sh` and include `goh.app` in the PKG payload at `/Applications/goh.app`.
3. Extend `private-release-candidate.sh` to sign `goh-menu` (inner Mach-O first with `--timestamp -o runtime`, hardened runtime) and sign `goh.app` last (inside-out per research brief §4), then include the app in the payload. Document the post-credential step.
4. Add a `DESIGN.md` §menu-bar-distribution subsection.

**THE BET load-bearing location:** This task is where the bet matters. The PKG now contains `goh` + `gohd` + `goh.app` under a single version. A version bump forces re-cutting the whole PKG. This is intentional and documented in the PKG script header comment.

**Files**
- CREATE `Scripts/_stage-app-payload.sh` (shared staging helper, named with `_` prefix to signal it is not called directly)
- MODIFY `Scripts/package-pkg.sh`
- MODIFY `Scripts/private-release-candidate.sh`
- MODIFY `DESIGN.md`

**Pre-task reads**
- [x] `Scripts/package-pkg.sh` — lines 40–57 (payload staging block); lines 76–96 (pkgbuild + productbuild)
- [x] `Scripts/private-release-candidate.sh` — lines 142–157 (staging block); lines 154–157 (codesign loop for goh + gohd)
- [x] `Scripts/package-app.sh` — the `app_dir` output variable convention

**No Swift unit test** — shell scripts. Validated by the manual verification commands below.

**Step 1 — Create shared staging helper**

File: `Scripts/_stage-app-payload.sh` (CREATE)

```bash
#!/usr/bin/env bash
# _stage-app-payload.sh — shared payload staging for package-pkg.sh and
# private-release-candidate.sh. Source this file after setting:
#   repo_root, payload_root, version
# This file is sourced, not executed directly.
#
# THE BET (Approach B — All-in-One PKG): engine + tray app are versioned
# together. A single double-click installs CLI, daemon, and the tray app.
# Reversal cost is low: extract goh.app into a standalone DMG later if needed.

# Assemble goh.app into a temp dir, then copy it into the payload.
app_stage_dir="$(mktemp -d)"
app_output_dir="$app_stage_dir"

"$repo_root/Scripts/package-app.sh" "$version" "$app_output_dir"

# Install goh.app into /Applications in the payload.
app_dest="$payload_root/Applications"
mkdir -p "$app_dest"
cp -R "$app_output_dir/goh.app" "$app_dest/"
xattr -cr "$app_dest/goh.app"

# Clean up the temp staging dir (the copy is in payload_root now).
rm -rf "$app_stage_dir"
```

**Step 2 — Extend `package-pkg.sh`**

After the existing `xattr -cr "$payload_root"` line (~line 57) and before the `requirements.plist` heredoc, insert a source call:

```bash
# Stage goh.app into the payload (Approach B — All-in-One PKG).
# THE BET: engine + tray app are versioned together for the tester phase.
# See Scripts/_stage-app-payload.sh — this is the single point of truth for
# the goh.app staging logic. private-release-candidate.sh sources the same helper.
source "$script_dir/_stage-app-payload.sh"
```

**Step 3 — Extend `private-release-candidate.sh`**

After the existing binary staging and plist editing block and before the codesign loop (~line 154), insert:

```bash
# Stage goh.app into the payload.
# NOTE: package-app.sh runs swift build again; it is idempotent (same release build).
source "$script_dir/_stage-app-payload.sh"
```

Then extend the codesign loop to sign inside-out:

```bash
# Sign inside-out: inner Mach-Os first, then the .app bundle last.
# The goh-menu binary inside the .app must be signed before the bundle seal.
for binary in "$payload_root/usr/local/bin/goh" "$payload_root/usr/local/bin/gohd" \
              "$payload_root/Applications/goh.app/Contents/MacOS/goh-menu"; do
  codesign --force --sign "$GOH_APP_SIGN_IDENTITY" \
    --options runtime --timestamp --keychain "$keychain" "$binary"
  codesign --verify --strict --verbose=2 "$binary"
done

# Sign the .app bundle last (after inner binary is signed).
codesign --force --sign "$GOH_APP_SIGN_IDENTITY" \
  --options runtime --timestamp --keychain "$keychain" \
  "$payload_root/Applications/goh.app"
codesign --verify --strict --verbose=2 "$payload_root/Applications/goh.app"

# POST-CREDENTIAL NOTE: after the PKG is notarized and stapled, the .app
# inside it is also covered by the PKG's notarization ticket. No separate
# staple on the .app is required when it is delivered inside a notarized PKG.
```

**Step 4 — Add DESIGN.md menu-bar-distribution subsection**

Find the `goh-menu` section in `DESIGN.md` (search for `goh-menu` heading) and append:

```markdown
#### Menu-bar distribution (2026-06-06, Slice: tray-app-distribution)

The tray app is distributed as part of the All-in-One PKG (Approach B).
THE BET: versioning the engine and tray app together is acceptable for the
tester phase (they move in lockstep; independent versioning deferred).

**Bundle assembly:** `Scripts/package-app.sh <version>` hand-assembles
`goh.app/Contents/{MacOS/goh-menu, Info.plist}` from the `swift build --release`
output and the checked-in `Resources/app-Info.plist` template. `LSMinimumSystemVersion`
in the template is `26.5`, matching the PKG `requirements.plist` `os` pin — single-
sourced via the template file (spec §2 OS-floor note: if the PKG pin changes, the
template changes with it).

**PKG inclusion:** `Scripts/package-pkg.sh` sources
`Scripts/_stage-app-payload.sh` to add `goh.app` to `/Applications` in the PKG
payload. `private-release-candidate.sh` sources the same helper to ensure the two
scripts are never out of sync (advisory E fix from spec §7.5).

**Signing order (inside-out, post-credential):** `goh`, `gohd`, and
`goh-menu` (inner Mach-O) are signed individually with `--timestamp -o runtime`
(hardened runtime) first; `goh.app` is signed last. The PKG installer is signed
with the Developer ID Installer certificate. The whole PKG is submitted to
`notarytool` and stapled; the `.app` inside is covered by the PKG ticket.

**Subscription lifecycle:** The progress subscription moves from popover-scoped
(`.task`/`.onDisappear` in `GohMenuView`) to composition-root-owned
(`GohMenuAppDelegate`). `start()` at `applicationDidFinishLaunching`;
`stop()` at `applicationWillTerminate`. This keeps the notification coordinator
running regardless of whether the popover is open.

**Trust model:** No change. `XPCPeerRequirement + XPCRequirement.isFromSameTeam`
is unchanged. The `#if RELEASE #error(...)` tripwire in `GohXPCService.peerValidationMode`
is present and unmodified. The `.app`, `goh`, and `gohd` must be signed with the
same Developer ID team so `.isFromSameTeam()` passes.
```

**Step 5 — Manual verification (PKG path)**
```bash
# Build the PKG (unsigned, no credentials needed):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Scripts/package-pkg.sh 0.0.1-test

# Verify goh.app is in the PKG payload:
pkgutil --expand .build/release-artifacts/goh-0.0.1-test-macos-arm64.pkg /tmp/goh-test-pkg
ls /tmp/goh-test-pkg
# Should show: Distribution, payload.pkg (and possibly Resources)

# Inspect the expanded PKG payload:
cd /tmp/goh-test-pkg && xar -xf payload.pkg Payload
# The Payload is a gzip archive; list its contents:
gunzip -c Payload | pax -f - 2>/dev/null | grep goh.app
# Expected: ./Applications/goh.app/Contents/... lines

# Clean up:
rm -rf /tmp/goh-test-pkg
```

**Step 6 — Full test suite (AC5 regression check)**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -warnings-as-errors 2>&1 | tail -5
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -10
```
All existing 716+ tests must pass. Build must be warning-free.

**Step 7 — AC5 tripwire grep**
```bash
grep -n '#error' /Users/shane/claude/goh/Sources/GohCore/IPC/XPCService.swift | grep RELEASE
# Must return at least one hit — the peer-relaxation tripwire must be present and unmodified.
```

**Step 8 — Write phase 3 artifact**

Write `docs/superpowers/progress/2026-06-06-tray-app-distribution-phase3.md`.

**Step 9 — Commit**
```
feat(pkg): extend package-pkg.sh to include goh.app; add signing seam; update DESIGN.md
```

---

## Final health check

After all phases are committed on `feat/tray-app-distribution`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
# All 716+ tests green; build clean.

# AC5 tripwire:
grep -n '#error' Sources/GohCore/IPC/XPCService.swift | grep RELEASE

# AC1 manual spot-check:
Scripts/package-app.sh 0.0.1-final
defaults read "$(pwd)/.build/release-artifacts/goh.app/Contents/Info" CFBundleIdentifier
# → dev.goh.menu
defaults read "$(pwd)/.build/release-artifacts/goh.app/Contents/Info" LSUIElement
# → 1

# No #available ladder introduced (no forking):
grep -rn '#available' Sources/goh-menu Sources/GohMenuBar
# Must return zero results (or only pre-existing hits outside goh-menu/GohMenuBar).
```
