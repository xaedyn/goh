---
date: 2026-06-06
feature: tray-app-distribution
phase: 2
title: Wiring layer
status: not-started
depends-on: phase1
---

# Phase 2 — Wiring layer

Live framework impls, composition-root lifecycle move, preferences view, footer
entry. No packaging scripts in this phase. CI gate: `swift build -warnings-as-errors`
clean + full test suite green.

## Tasks

- [ ] **P2-1** MODIFY `Sources/goh-menu/main.swift` + MODIFY `Sources/GohMenuBar/GohMenuView.swift`
  - Move model ownership from `@StateObject` in `GohMenuApp` to `GohMenuAppDelegate`
  - `model.start()` called once in `applicationDidFinishLaunching`; `model.stop()` in `applicationWillTerminate`
  - Remove `model.start()` from `GohMenuView.task`; remove `model.stop()` from `.onDisappear`
  - Keep `await model.refreshClipboard()` in `.task` (cheap, view-scoped)
  - AC: subscription runs while popover is closed (always-on); spec §4

- [ ] **P2-2** MODIFY `Sources/GohMenuBar/GohMenuView.swift`
  - Add `preferences: any GohMenuPreferences` and `loginItem: any GohMenuLoginItem` to `GohMenuView.init`
  - Add "Preferences…" button to footer; `showPreferences: Bool` state; `.sheet` presenting `GohMenuPreferencesView`
  - AC4 coverage (entry point)

- [ ] **P2-3** CREATE `Sources/GohMenuBar/GohMenuNotificationsLive.swift` + wire coordinator in `GohMenuAppDelegate`
  - `LiveNotificationService` backed by `UNUserNotificationCenter`; errors swallowed (best-effort)
  - Expose `@Published var latestSnapshots: [ProgressSnapshot]` from `GohMenuViewModel`
  - Notification coordinator in `GohMenuAppDelegate`: subscribes to `model.$latestSnapshots`, calls `GohNotificationTransitionDetector.evaluate`, posts via `LiveNotificationService`, gates on `preferences.notificationsEnabled`
  - `requestAuthorization()` called once in `applicationDidFinishLaunching`
  - AC2 coverage (live path)

- [ ] **P2-4** CREATE `Sources/GohMenuBar/GohMenuLoginItemLive.swift`
  - `SMAppServiceLoginItem` backed by `SMAppService.mainApp`
  - Maps all `SMAppService.Status` cases to `GohLoginItemStatus`; propagates errors as `GohLoginItemError.registrationFailed`
  - `GohMenuAppDelegate.makeLoginItem()` returns `SMAppServiceLoginItem` when `Bundle.main.bundleIdentifier != nil`, else `UnsupportedLoginItem`
  - AC3 coverage (live path)

- [ ] **P2-5** CREATE `Sources/GohMenuBar/GohMenuPreferencesView.swift` + wire into view + delegate
  - Two toggles: notifications (binds to `preferences.notificationsEnabled`) and launch-at-login (calls `loginItem.register()/unregister()`)
  - `.requiresApproval` affordance text; error message on registration failure
  - `onAppear` refreshes `loginItem.status()` (user may have approved in System Settings)
  - `GohMenuAppDelegate` creates `preferences: UserDefaultsMenuPreferences` and `loginItem` instances; passes them to `GohMenuView.init`
  - AC3 + AC4 coverage (view)

## Phase 2 exit criteria

- [ ] `swift build -warnings-as-errors` clean
- [ ] `swift test` green (all tests incl. Phase 1)
- [ ] No `#available` ladders introduced
- [ ] Subscription lifecycle: `start()` at app launch, `stop()` at termination — verified by inspection
- [ ] `GohMenuView.task` no longer calls `model.start()` or `model.stop()`
- [ ] `Combine` import in `GohMenuAppDelegate` for `$latestSnapshots` sink

## Notes

_Filled in during execution._
