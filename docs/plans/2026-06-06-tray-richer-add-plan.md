---
date: 2026-06-06
feature: tray-richer-add
REQUIRED_SKILL: superpowers:subagent-driven-development
Goal: Add an "Add Download…" window to the tray app, giving users per-download destination-folder and connection-count control while leaving the one-tap clipboard add completely unchanged.
Architecture: Approach A — Add Download window. THE BET: "A dedicated add window is acceptable UX for the choose-where/how case (the fast one-tap add stays in the popover for everyone else)."
Tech Stack: Swift 6.2 (swift-tools-version), Swift 6.3.x toolchain, SwiftPM, macOS 26.0 floor, SwiftUI + AppKit MenuBarExtra(.window) / .accessory activation policy, Swift Testing (NOT XCTest).
---

# Implementation Plan — Richer Add in the Tray

## Acceptance criteria map

| AC | Description | Owning task(s) |
|----|-------------|----------------|
| AC1 | When a folder is chosen, `AddRequest.destination` carries that path; when none chosen, `nil` | Task P1-3 (AddDownloadViewModel), Task P1-4 (tests) |
| AC2 | When connections are pinned, `AddRequest.connectionCount` carries that `UInt8`; when Automatic, `nil` | Task P1-3 (AddDownloadViewModel), Task P1-4 (tests) |
| AC3 | The connection-count control cannot emit a value outside 1–16; out-of-range input is clamped in `submit()`, never traps | Task P1-3 (AddDownloadViewModel), Task P1-4 (tests) |
| AC4 | The existing one-tap clipboard add still sends `AddRequest(url:)` only — no `destination`, no `connectionCount`; existing tests unchanged and green | Anchored by the EXISTING `GohMenuViewModelTests.startsClipboardURLThroughDaemon` (drives the real `performPrimaryAction`); P1-4 must leave it unchanged/green and add NO tautological copy |
| AC5 | `protocolVersion` and `AddRequest` wire shape unchanged; `swift build -warnings-as-errors` clean; full suite green | Verified at end of every phase health check; no diff to `Sources/GohCore` |

## THE BET — load-bearing note

> Approach A bet: "A dedicated add window is acceptable UX for the choose-where/how case (the fast one-tap add stays in the popover for everyone else)."
>
> This drives Task P2-1 (Window scene + wiring). The folder picker must live in a persistent window
> — not the popover — because `NSOpenPanel` acquiring key focus dismisses `MenuBarExtra(.window)`
> popovers (FB11984872). The popover's only job is to launch the window. Any future "set-once
> defaults" (Approach B) is additive on top of this; the reversal path is removing the window scene
> and the popover button.

## Phase structure

> 7 tasks → 2 phases segmented at deployment-independence boundary.
> Phase artifacts: `docs/superpowers/progress/2026-06-06-tray-richer-add-phase{1,2}.md`

- **Phase 1 (Tasks P1-1 – P1-4): Value layer.** `GohMenuError.userFacingMessage`; `FolderPicker` protocol; `AddDownloadViewModel`; all unit tests. Everything in `GohMenuBar` + its test target; zero AppKit panels, zero XPC, zero file I/O. Gate: `swift build -warnings-as-errors` + `swift test` green.
- **Phase 2 (Tasks P2-1 – P2-3): UI / wiring layer.** `AddDownloadView` (SwiftUI form); `main.swift` Window scene + `NSOpenPanelFolderPicker` live impl + popover button activation; `GohMenuView` "Add download…" button. Gate: `swift build -warnings-as-errors` clean (no unit tests for AppKit/main.swift layer; manual smoke note required).

---

## Phase 1 — Value layer

### Task P1-1 — MODIFY `Sources/GohMenuBar/GohMenuModels.swift`

**Responsibility:** Add `nonisolated public var userFacingMessage: String` to `GohMenuError`, covering every case with a plain-English sentence. This is the single source of UI error text — never `String(describing:)`, never an enum case name.

**Files**
- MODIFY `Sources/GohMenuBar/GohMenuModels.swift`

**Pre-task reads**
- [x] `Sources/GohMenuBar/GohMenuModels.swift` — read the exact `GohMenuError` cases: `daemonUnavailable(String)`, `peerValidation(String)`, `protocolMismatch(String)`, `daemon(GohError)`, `malformedReply(String)`. Five cases total.
- [x] `Sources/GohMenuBar/GohMenuProgressStream.swift` — confirm `GohMenuErrorMapper.map(_:) -> GohMenuError` is `public static nonisolated`; confirm it is the existing mapping path (the accessor is additive on top, does not replace the mapper).

**Step 1 — Failing test stub (in Task P1-4 file)**

The direct `GohMenuError.userFacingMessage` per-case tests live in Task P1-4 (`AddDownloadViewModelTests.swift`). Write the `@Test` stub there before touching this file (see P1-4 step 1). Come back to implement after the stub exists.

**Step 2 — Implementation**

Add to `GohMenuError` in `GohMenuModels.swift`, immediately after the last `case`:

```swift
nonisolated public var userFacingMessage: String {
    switch self {
    case .daemonUnavailable:
        return "goh's background service isn't reachable — run goh doctor."
    case .peerValidation:
        return "The background service failed peer validation — try reinstalling goh."
    case .protocolMismatch:
        return "The tray app and background service are on different versions — restart goh."
    case .daemon(let error):
        return "The background service reported an error: \(error.message ?? error.code.rawValue)"
    case .malformedReply:
        return "The background service sent an unexpected response — run goh doctor."
    }
}
```

Rules:
- Sentences are plain English; no enum case names, no `String(describing:)`, no raw associated values surfaced as-is except within a calibrated sentence for `.daemon`.
- The accessor is `nonisolated` (the enum is `nonisolated public enum GohMenuError`; members must also be `nonisolated` for nonisolated test bodies to call them — verified pattern from prior slices: GohMenuPreferences, GohNotificationTransitionDetector).
- Do NOT modify `GohMenuErrorMapper.map(_:)` — the accessor is additive only.

**Step 3 — Build check**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
```

Must be clean before proceeding.

---

### Task P1-2 — CREATE `Sources/GohMenuBar/FolderPicker.swift`

**Responsibility:** Define the `FolderPicker` protocol (the injectable seam between the view model and AppKit). The live `NSOpenPanelFolderPicker` implementation goes in `goh-menu`, NOT here, so `GohMenuBar` stays unit-testable without AppKit panels.

**Files**
- CREATE `Sources/GohMenuBar/FolderPicker.swift`

**Pre-task reads**
- [x] `Sources/GohMenuBar/GohMenuModels.swift` — confirm `nonisolated public` pattern on protocols
- [x] `Package.swift` — confirm `GohMenuBar` target has `.defaultIsolation(MainActor.self)`; confirm `goh-menu` imports `GohMenuBar`

**Step 1 — Failing test stub**

The stub `FolderPicker` used in tests is declared inside `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift` (Task P1-4), not here. Write that stub in P1-4 step 1 before implementing.

**Step 2 — Implementation**

```swift
import Foundation

/// Injectable seam for choosing a folder. The live impl (NSOpenPanelFolderPicker)
/// lives in goh-menu so GohMenuBar stays AppKit-panel-free and unit-testable.
public protocol FolderPicker: Sendable {
    /// Presents a directory chooser. Returns the chosen folder path, or nil if cancelled.
    @MainActor func chooseFolder() async -> String?
}
```

Rules:
- `public protocol FolderPicker: Sendable` — `Sendable` conformance required so `AddDownloadViewModel` can hold `any FolderPicker` safely on a `@MainActor` class.
- The `@MainActor` annotation on `chooseFolder()` matches the view-model's isolation and enables the live impl to call `NSApp.activate` + `NSOpenPanel.begin` without crossing actors.
- No concrete type here; the protocol is the entire file.

**Step 3 — Build check**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
```

---

### Task P1-3 — CREATE `Sources/GohMenuBar/AddDownloadViewModel.swift`

**Responsibility:** The form view model. Pure-ish (injectable client + picker), `@MainActor`, `ObservableObject`. Contains `canAdd` (delegates to `GohClipboardURLDetector`), `chooseFolder()`, `useDefaultFolder()`, and `submit()` with full clamping, normalization, and error mapping.

**Files**
- CREATE `Sources/GohMenuBar/AddDownloadViewModel.swift`

**Pre-task reads**
- [x] `Sources/GohMenuBar/GohMenuViewModel.swift` — read `GohMenuClient` protocol exactly (used as `any GohMenuClient`); read `performPrimaryAction()` → `client.add(AddRequest(url: url.absoluteString))` pattern; confirm `@MainActor public final class`
- [x] `Sources/GohMenuBar/GohClipboardURLDetector.swift` — read `url(from: String?) -> URL?` signature; confirm `nonisolated public struct GohClipboardURLDetector: Sendable`; confirm `GohClipboardURLDetector().url(from:)` is safe to call from `@MainActor` context
- [x] `Sources/GohCore/Model/Command.swift` — confirm `AddRequest` fields: `url: String`, `destination: String?`, `connectionCount: UInt8?`, `useImportedCookies: Bool?`, `priority: Priority?`; confirm memberwise init with all-optional defaulting
- [x] `Sources/GohMenuBar/GohMenuProgressStream.swift` — confirm `GohMenuErrorMapper.map(_:) -> GohMenuError` is `public static`; confirm it returns `GohMenuError`
- [x] `Sources/GohMenuBar/GohMenuModels.swift` — confirm `GohMenuError.userFacingMessage` was added in P1-1

**Step 1 — Write failing test stubs first (P1-4)**

See Task P1-4 step 1. All `AddDownloadViewModel` tests are written as failing stubs before this task's implementation.

**Step 2 — Implementation**

```swift
import Combine
import Foundation
import GohCore

@MainActor
public final class AddDownloadViewModel: ObservableObject {
    @Published public var urlText: String
    @Published public var chosenFolder: String?
    @Published public var automaticConnections: Bool
    @Published public var connectionCount: Int
    @Published public private(set) var errorText: String?

    private let client: any GohMenuClient
    private let folderPicker: any FolderPicker
    private let detector: GohClipboardURLDetector

    public var canAdd: Bool {
        detector.url(from: urlText) != nil
    }

    public init(
        initialURL: String?,
        client: any GohMenuClient,
        folderPicker: any FolderPicker,
        detector: GohClipboardURLDetector = GohClipboardURLDetector()
    ) {
        self.urlText = initialURL ?? ""
        self.chosenFolder = nil
        self.automaticConnections = true
        self.connectionCount = 8
        self.client = client
        self.folderPicker = folderPicker
        self.detector = detector
    }

    public func chooseFolder() async {
        if let path = await folderPicker.chooseFolder() {
            chosenFolder = path
        }
        // Cancelled pick: chosenFolder is unchanged (spec §6, §7.2)
    }

    public func useDefaultFolder() {
        chosenFolder = nil
    }

    /// Builds and submits AddRequest. Returns true on success (caller should close window).
    /// Returns false on validation failure (no-op) or on error (errorText set, window stays open).
    @discardableResult
    public func submit() async -> Bool {
        guard let url = detector.url(from: urlText) else {
            // canAdd == false; no-op — spec §7.2
            return false
        }

        let request = AddRequest(
            url: url.absoluteString,
            destination: chosenFolder,
            connectionCount: automaticConnections
                ? nil
                : UInt8(min(16, max(1, connectionCount)))
        )

        do {
            _ = try await client.add(request)
            errorText = nil
            return true
        } catch {
            errorText = GohMenuErrorMapper.map(error).userFacingMessage
            return false
        }
    }
}
```

Key rules:
- `url.absoluteString` (normalized by `URLComponents`) is submitted, never raw `urlText`.
- `UInt8(min(16, max(1, connectionCount)))` — never a trapping conversion; clamping happens before the `UInt8` initializer sees the value.
- `automaticConnections ? nil : ...` — when Automatic is ON, `connectionCount` is `nil` (governor runs; NOT forced to 8).
- `destination: chosenFolder` — when `nil`, daemon's `~/Downloads` default applies; never reconstruct `~/Downloads`.
- On error: `GohMenuErrorMapper.map(error).userFacingMessage` — never `String(describing:)`.
- `GohClipboardURLDetector` is injectable for testing (default instance is fine for production).
- No AppKit imports; no `NSOpenPanel` here.

**Step 3 — Build check**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
```

---

### Task P1-4 — CREATE `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift`

**Responsibility:** Full unit test coverage for `AddDownloadViewModel` + `GohMenuError.userFacingMessage` per-case + AC4 regression. Uses `FakeMenuClient` (from `GohMenuViewModelTests.swift`) and a new stub `FolderPicker`. No AppKit, no XPC, no file I/O.

**Files**
- CREATE `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift`

**Pre-task reads**
- [x] `Tests/GohMenuBarTests/GohMenuViewModelTests.swift` — read `FakeMenuClient` shape exactly: `@MainActor final class`, `addedRequests: [AddRequest]`, `addError: (any Error)?`, `add(_ request:) async throws -> JobSummary`; read `FakeMenuError` enum; read the existing `startsClipboardURLThroughDaemon` test that asserts `client.addedRequests == [AddRequest(url: "https://example.com/big.iso")]` — this is the AC4 regression anchor.
- [x] `Sources/GohMenuBar/GohMenuModels.swift` — read all five `GohMenuError` cases for per-case `userFacingMessage` tests.
- [x] `Sources/GohMenuBar/GohClipboardURLDetector.swift` — read what returns `nil` vs non-nil to craft `canAdd` false cases.

**Note on FakeMenuClient visibility:** `FakeMenuClient` is declared `private` in `GohMenuViewModelTests.swift`. Declare a parallel `FakeMenuClient` (same shape) in this test file, also `private`. Do NOT reach across test files — each file is self-contained.

**Step 1 — Write all failing stubs first, then implement**

```swift
import Foundation
import Testing
import GohCore
@testable import GohMenuBar

// ── Stub: FolderPicker ────────────────────────────────────────────────────────

@MainActor
private final class StubFolderPicker: FolderPicker {
    var result: String?      // nil = simulates cancel
    nonisolated init(result: String? = nil) { self.result = result }
    func chooseFolder() async -> String? { result }
}

// ── Stub: FakeMenuClient (parallel to GohMenuViewModelTests.swift) ────────────

@MainActor
private final class FakeMenuClient: GohMenuClient {
    var addedRequests: [AddRequest] = []
    var addError: (any Error)?

    func progressSnapshots() -> AsyncThrowingStream<[ProgressSnapshot], any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func add(_ request: AddRequest) async throws -> JobSummary {
        if let addError { throw addError }
        addedRequests.append(request)
        return JobSummary(
            id: 1,
            url: request.url,
            destination: "/tmp/big.iso",
            state: .queued,
            progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
            createdAt: Date(timeIntervalSince1970: 1),
            lastProgressAt: nil,
            requestedConnectionCount: request.connectionCount ?? 8,
            actualConnectionCount: 0)
    }

    func pause(jobID: UInt64) async throws {}
    func resume(jobID: UInt64) async throws {}
    func remove(jobID: UInt64, keepPartialFile: Bool) async throws {}
}

// ── GohMenuError.userFacingMessage — direct per-case tests ───────────────────

@Suite("GohMenuError.userFacingMessage")
struct GohMenuErrorUserFacingMessageTests {

    // AC5 / §7.3: each case returns a plain sentence; no enum name, no String(describing:)

    @Test func daemonUnavailableIsPlainSentence() {
        let msg = GohMenuError.daemonUnavailable("some detail").userFacingMessage
        // Must not contain the raw enum case name or the associated value verbatim
        #expect(!msg.isEmpty)
        #expect(!msg.contains("daemonUnavailable"))
        #expect(msg.hasSuffix("."))
    }

    @Test func peerValidationIsPlainSentence() {
        let msg = GohMenuError.peerValidation("some peer error").userFacingMessage
        #expect(!msg.isEmpty)
        #expect(!msg.contains("peerValidation"))
        #expect(msg.hasSuffix("."))
    }

    @Test func protocolMismatchIsPlainSentence() {
        let msg = GohMenuError.protocolMismatch("v2 vs v3").userFacingMessage
        #expect(!msg.isEmpty)
        #expect(!msg.contains("protocolMismatch"))
        #expect(msg.hasSuffix("."))
    }

    @Test func daemonErrorIncludesContextSentence() {
        let gohError = GohError(code: .protocolVersionMismatch, message: "v1 != v2")
        let msg = GohMenuError.daemon(gohError).userFacingMessage
        #expect(!msg.isEmpty)
        #expect(!msg.contains("daemon("))
        #expect(msg.hasSuffix(".") || msg.hasSuffix(")"))
    }

    @Test func malformedReplyIsPlainSentence() {
        let msg = GohMenuError.malformedReply("unexpected field").userFacingMessage
        #expect(!msg.isEmpty)
        #expect(!msg.contains("malformedReply"))
        #expect(msg.hasSuffix("."))
    }
}

// ── AddDownloadViewModel tests ────────────────────────────────────────────────

@Suite("AddDownloadViewModel")
@MainActor
struct AddDownloadViewModelTests {

    // AC1: folder chosen → destination set in AddRequest
    @Test func folderChosenSetsDestination() async {
        let client = FakeMenuClient()
        let picker = StubFolderPicker(result: "/Users/test/Movies")
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: picker)

        await vm.chooseFolder()
        #expect(vm.chosenFolder == "/Users/test/Movies")

        let success = await vm.submit()
        #expect(success)
        #expect(client.addedRequests.first?.destination == "/Users/test/Movies")
    }

    // AC1: no folder chosen → destination nil
    @Test func noFolderChosenLeavesDestinationNil() async {
        let client = FakeMenuClient()
        let picker = StubFolderPicker(result: nil)  // simulates cancel
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: picker)

        await vm.chooseFolder()     // cancelled pick; chosenFolder stays nil
        let success = await vm.submit()
        #expect(success)
        #expect(client.addedRequests.first?.destination == nil)
    }

    // §7.2: cancelled pick leaves chosenFolder UNCHANGED (not cleared)
    @Test func cancelledPickLeavesChosenFolderUnchanged() async {
        let client = FakeMenuClient()
        let picker = StubFolderPicker(result: "/Users/test/Prior")
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: picker)

        await vm.chooseFolder()     // sets /Users/test/Prior
        #expect(vm.chosenFolder == "/Users/test/Prior")

        picker.result = nil         // now cancel
        await vm.chooseFolder()     // cancel — must NOT clear
        #expect(vm.chosenFolder == "/Users/test/Prior")
    }

    // useDefaultFolder clears chosenFolder → nil
    @Test func useDefaultFolderClearsChosen() async {
        let client = FakeMenuClient()
        let picker = StubFolderPicker(result: "/Users/test/Movies")
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: picker)

        await vm.chooseFolder()
        #expect(vm.chosenFolder == "/Users/test/Movies")
        vm.useDefaultFolder()
        #expect(vm.chosenFolder == nil)
    }

    // AC2: automatic ON → connectionCount nil
    @Test func automaticOnSendsNilConnectionCount() async {
        let client = FakeMenuClient()
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: StubFolderPicker())

        vm.automaticConnections = true
        _ = await vm.submit()
        #expect(client.addedRequests.first?.connectionCount == nil)
    }

    // AC2: pinned count is sent as the exact UInt8
    @Test func pinnedCountSendsExactUInt8() async {
        let client = FakeMenuClient()
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: StubFolderPicker())

        vm.automaticConnections = false
        vm.connectionCount = 6
        _ = await vm.submit()
        #expect(client.addedRequests.first?.connectionCount == 6)
    }

    // AC3: out-of-range count 0 clamps to 1 (never traps)
    @Test func outOfRangeZeroClampedToOne() async {
        let client = FakeMenuClient()
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: StubFolderPicker())

        vm.automaticConnections = false
        vm.connectionCount = 0          // below 1
        _ = await vm.submit()
        #expect(client.addedRequests.first?.connectionCount == 1)
    }

    // AC3: out-of-range count 99 clamps to 16 (never traps)
    @Test func outOfRangeHighClampedToSixteen() async {
        let client = FakeMenuClient()
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: StubFolderPicker())

        vm.automaticConnections = false
        vm.connectionCount = 99         // above 16
        _ = await vm.submit()
        #expect(client.addedRequests.first?.connectionCount == 16)
    }

    // §7.2: submitted url == detector's normalized absoluteString, not raw text
    @Test func submitsNormalizedURL() async {
        // The detector normalizes via URLComponents; give a URL that survives the trip
        let rawURL = "https://example.com/file.iso"
        let client = FakeMenuClient()
        let vm = AddDownloadViewModel(
            initialURL: rawURL,
            client: client,
            folderPicker: StubFolderPicker())

        _ = await vm.submit()
        let sent = client.addedRequests.first?.url
        // Must equal the detector's normalized absoluteString — not the raw text
        let expected = GohClipboardURLDetector().url(from: rawURL)?.absoluteString
        #expect(sent == expected)
    }

    // canAdd == false for various invalid inputs
    @Test func canAddFalseForEmptyString() {
        let vm = AddDownloadViewModel(
            initialURL: nil,
            client: FakeMenuClient(),
            folderPicker: StubFolderPicker())
        vm.urlText = ""
        #expect(vm.canAdd == false)
    }

    @Test func canAddFalseForWhitespace() {
        let vm = AddDownloadViewModel(
            initialURL: nil,
            client: FakeMenuClient(),
            folderPicker: StubFolderPicker())
        vm.urlText = "   "
        #expect(vm.canAdd == false)
    }

    @Test func canAddFalseForBareWord() {
        let vm = AddDownloadViewModel(
            initialURL: nil,
            client: FakeMenuClient(),
            folderPicker: StubFolderPicker())
        vm.urlText = "foo"
        #expect(vm.canAdd == false)
    }

    @Test func canAddFalseForFileURL() {
        let vm = AddDownloadViewModel(
            initialURL: nil,
            client: FakeMenuClient(),
            folderPicker: StubFolderPicker())
        vm.urlText = "file:///Users/test/file.iso"
        #expect(vm.canAdd == false)
    }

    @Test func canAddTrueForValidHTTPS() {
        let vm = AddDownloadViewModel(
            initialURL: nil,
            client: FakeMenuClient(),
            folderPicker: StubFolderPicker())
        vm.urlText = "https://example.com/big.iso"
        #expect(vm.canAdd == true)
    }

    // submit() while canAdd == false is a no-op (no add recorded)
    @Test func submitWhileInvalidIsNoOp() async {
        let client = FakeMenuClient()
        let vm = AddDownloadViewModel(
            initialURL: nil,
            client: client,
            folderPicker: StubFolderPicker())
        vm.urlText = "not-a-url"
        let success = await vm.submit()
        #expect(success == false)
        #expect(client.addedRequests.isEmpty)
    }

    // Add failure: errorText == specific userFacingMessage (assert the string)
    @Test func addFailureSetsErrorTextToUserFacingMessage() async {
        let client = FakeMenuClient()
        let expectedError = GohMenuError.daemonUnavailable("test unavailable")
        client.addError = expectedError
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: StubFolderPicker())

        let success = await vm.submit()
        #expect(success == false)
        #expect(vm.errorText == expectedError.userFacingMessage)
        // Must not be raw String(describing:) of the error
        #expect(vm.errorText?.contains("daemonUnavailable") == false)
    }

    // Add failure: peerValidation error maps correctly
    @Test func peerValidationErrorMapsToUserFacingMessage() async {
        let client = FakeMenuClient()
        let expectedError = GohMenuError.peerValidation("requirement mismatch")
        client.addError = expectedError
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: StubFolderPicker())

        _ = await vm.submit()
        #expect(vm.errorText == expectedError.userFacingMessage)
    }

    // AC4 regression: DO NOT add a hand-built-AddRequest test here — that would be a
    // tautology (it asserts on a value the test itself constructs, never exercising the
    // production one-tap path). The AC4 anchor is the EXISTING, real test in
    // GohMenuViewModelTests.swift: `startsClipboardURLThroughDaemon`, which drives
    // `GohMenuViewModel.performPrimaryAction()` and asserts
    // `client.addedRequests == [AddRequest(url: "https://example.com/big.iso")]`.
    // This task MUST leave that test unchanged and green. If a future edit makes the
    // one-tap path send a destination/connectionCount, THAT test fails — which is the
    // regression signal AC4 requires. No new AC4 test is added in this suite.
}
```

**Step 2 — Run tests (expect failures before P1-1/P1-3 implementations exist, then all green)**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AddDownloadViewModelTests 2>&1 | tail -20
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohMenuErrorUserFacingMessageTests 2>&1 | tail -20
```

**Step 3 — Full suite (Phase 1 exit gate)**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -10
```

All existing tests must remain green. New tests must pass.

---

## Phase 1 exit criteria

- [ ] `swift build -Xswiftc -warnings-as-errors` clean
- [ ] `swift test` green — all existing tests + all new `AddDownloadViewModelTests` + all `GohMenuErrorUserFacingMessageTests`
- [ ] `GohMenuError.userFacingMessage` returns plain sentences for all 5 cases; no enum case names
- [ ] `AddDownloadViewModel.submit()` normalizes URL via detector; clamps connectionCount to 1...16; passes destination as-is or nil
- [ ] No AppKit import in `GohMenuBar` target; no `NSOpenPanel` in tests
- [ ] No new `#available` ladders; no diff to `Sources/GohCore`

---

## Phase 2 — UI / wiring layer

### Task P2-1 — CREATE `Sources/GohMenuBar/AddDownloadView.swift`

**Responsibility:** SwiftUI form for the Add Download window. Binds to `AddDownloadViewModel`. URL field, destination row (Choose folder… / path label / Use default), automatic toggle + connections stepper, Add/Cancel, error text. Full accessibility labels.

**Files**
- CREATE `Sources/GohMenuBar/AddDownloadView.swift`

**Pre-task reads**
- [x] `Sources/GohMenuBar/GohMenuView.swift` — confirm SwiftUI patterns: `VStack`, `Button`, `.buttonStyle`, `.controlSize`, accessibility labels via `.accessibilityLabel`, `.help`; confirm how `@ObservedObject` is used on the model
- [x] `Sources/GohMenuBar/AddDownloadViewModel.swift` — read all `@Published` fields and all methods (`canAdd`, `chooseFolder()`, `useDefaultFolder()`, `submit()`)

**No unit test** (SwiftUI view; AppKit `dismiss` env action required for close-on-success). Build verification is the gate.

**Step 1 — Failing build: create a minimal placeholder**

```swift
import SwiftUI
import GohCore

public struct AddDownloadView: View {
    @ObservedObject private var vm: AddDownloadViewModel
    @Environment(\.dismiss) private var dismiss

    public init(vm: AddDownloadViewModel) {
        self.vm = vm
    }

    public var body: some View {
        Text("placeholder — implement in next step")
    }
}
```

Build:
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
```

**Step 2 — Full implementation**

Replace the placeholder body:

```swift
import SwiftUI
import GohCore

public struct AddDownloadView: View {
    @ObservedObject private var vm: AddDownloadViewModel
    @Environment(\.dismiss) private var dismiss

    public init(vm: AddDownloadViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // URL field
            VStack(alignment: .leading, spacing: 4) {
                Text("URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://", text: $vm.urlText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Download URL")
            }

            // Destination row
            VStack(alignment: .leading, spacing: 4) {
                Text("Destination")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Choose folder…") {
                        Task { await vm.chooseFolder() }
                    }
                    .accessibilityLabel("Choose destination folder")
                    if let folder = vm.chosenFolder {
                        Text(folder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Use default") {
                            vm.useDefaultFolder()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityLabel("Use default downloads folder")
                    } else {
                        Text("Downloads (default)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Connections row
            VStack(alignment: .leading, spacing: 4) {
                Text("Connections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Toggle("Automatic", isOn: $vm.automaticConnections)
                        .accessibilityLabel("Automatic connection count")
                    if !vm.automaticConnections {
                        Stepper(
                            value: $vm.connectionCount,
                            in: 1...16
                        ) {
                            Text("\(vm.connectionCount)")
                        }
                        .accessibilityLabel("Connection count \(vm.connectionCount)")
                        .frame(maxWidth: 100)
                    }
                }
            }

            // Error text (shown only on failure)
            if let errorText = vm.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(errorText)")
            }

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel add download")

                Button("Add") {
                    Task {
                        let success = await vm.submit()
                        if success { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canAdd)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Add download")
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
```

**Step 3 — Build check**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
```

**Smoke note:** Verify visually in the running app after P2-2 and P2-3 are complete.

---

### Task P2-2 — MODIFY `Sources/goh-menu/main.swift`

**Responsibility:**
1. Add `NSOpenPanelFolderPicker` — the live `FolderPicker` impl (AppKit, stays in `goh-menu` only).
2. Add a `Window(id: "add-download")` SwiftUI scene hosting `AddDownloadView`.
3. Wire the popover's "Add download…" button (added in P2-3) via `@Environment(\.openWindow)` — this task adds the scene; P2-3 adds the button. `NSApp.activate(ignoringOtherApps: true)` before `openWindow(id:)`.

**Files**
- MODIFY `Sources/goh-menu/main.swift`

**Pre-task reads**
- [x] `Sources/goh-menu/main.swift` — read the full `GohMenuApp` body; understand `@NSApplicationDelegateAdaptor`; read `GohMenuAppDelegate` for how `model` + `preferences` + `loginItem` are constructed and passed; confirm activation policy set in `applicationDidFinishLaunching`. The new `Window` scene must access `appDelegate.model` and the new `NSOpenPanelFolderPicker`.
- [x] `Sources/GohMenuBar/GohMenuView.swift` — `GohMenuView` init signature: `model:`, `preferences:`, `loginItem:`, `quitApplication:` — confirm no `openWindow` env injection needed here (button added in P2-3 uses `@Environment(\.openWindow)` inside `GohMenuView` directly).
- [x] `Sources/GohMenuBar/FolderPicker.swift` — confirm `public protocol FolderPicker: Sendable` with `@MainActor func chooseFolder() async -> String?`.

**No unit test** (live AppKit; not testable in isolation). Build verification + manual smoke note.

**Step 1 — Add `NSOpenPanelFolderPicker` before the `@main` struct**

```swift
// Live folder picker — AppKit, lives in goh-menu only so GohMenuBar stays testable.
@MainActor
final class NSOpenPanelFolderPicker: FolderPicker {
    nonisolated init() {}

    func chooseFolder() async -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a destination folder"

        // NSOpenPanel.begin is the async-safe pattern for accessory apps.
        // Do NOT use runModal() — it blocks the cooperative pool.
        let response = await withCheckedContinuation { (cont: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { response in
                cont.resume(returning: response)
            }
        }

        guard response == .OK, let url = panel.url else { return nil }
        return url.path(percentEncoded: false)
    }
}
```

**Step 2 — Keep `client` private: add a factory on `GohMenuViewModel`**

Do NOT expose `client`. Add this factory to `GohMenuViewModel.swift` (it keeps `client`
private and lets the window prefill the detected clipboard URL):

```swift
public func makeAddDownloadViewModel(
    folderPicker: any FolderPicker
) -> AddDownloadViewModel {
    AddDownloadViewModel(
        initialURL: clipboardURL?.absoluteString,
        client: client,
        folderPicker: folderPicker)
}
```

**Step 3 — Own the view model in a `@StateObject` root (load-bearing)**

The view model MUST be owned by a `@StateObject` so its identity — the typed URL, the
chosen folder, and any in-progress `errorText` during a retry — survives SwiftUI scene
re-evaluation. Constructing it directly inside the `Window { }` content closure would
rebuild a fresh view model (and a fresh `NSOpenPanelFolderPicker`) on every re-eval and
silently discard the user's input. Add this small root view in `main.swift`:

```swift
// Owns AddDownloadViewModel via @StateObject so it is built exactly once and its state
// persists across scene re-evaluation. The @autoclosure defers construction so
// StateObject(wrappedValue:) invokes it a single time (not on every re-eval).
struct AddDownloadWindowRoot: View {
    @StateObject private var viewModel: AddDownloadViewModel

    init(makeViewModel: @autoclosure @escaping () -> AddDownloadViewModel) {
        _viewModel = StateObject(wrappedValue: makeViewModel())
    }

    var body: some View {
        AddDownloadView(vm: viewModel)
    }
}
```

`AddDownloadView` must declare its `vm` as `@ObservedObject var vm: AddDownloadViewModel`
(NOT `@StateObject`) — the root owns it; the view observes it.

**Step 4 — Add the `Window` scene to `GohMenuApp.body`**

Append inside `var body: some Scene { ... }` after the `MenuBarExtra` block:

```swift
Window("Add Download", id: "add-download") {
    AddDownloadWindowRoot(
        makeViewModel: appDelegate.model.makeAddDownloadViewModel(
            folderPicker: NSOpenPanelFolderPicker()))
}
.windowResizability(.contentSize)
.defaultPosition(.center)
```

**Note on `openWindow` reliability in `.accessory` apps:** If `openWindow(id:)` doesn't reliably bring the window front (known gap in accessory-policy apps), fall back:
```swift
// In the "Add download…" button action (added in P2-3):
NSApp.activate(ignoringOtherApps: true)
openWindow(id: "add-download")
// Belt-and-suspenders: order front via NSApp.windows lookup if needed
if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "add-download" }) {
    win.orderFrontRegardless()
}
```
Do NOT switch activation policy to `.regular` (causes dock-flicker / menu-bar-stuck bug FB7743313).

**Step 5 — Build check**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
```

**Smoke note:** Launch `goh-menu`, click "Add download…" in the popover (added in P2-3). Window appears. Choose folder — panel opens, chosen path appears. Automatic toggle disables stepper. Add with a valid URL — window closes. Add with invalid URL — button stays disabled. Cancel — window closes, nothing submitted.

---

### Task P2-3 — MODIFY `Sources/GohMenuBar/GohMenuView.swift`

**Responsibility:** Add the "Add download…" button to the popover's primary-action area. The button calls `NSApp.activate(ignoringOtherApps: true)` (via a closure injected from `main.swift`) and then `openWindow(id: "add-download")`. The existing one-tap clipboard-add button is completely unchanged.

**Files**
- MODIFY `Sources/GohMenuBar/GohMenuView.swift`

**Pre-task reads**
- [x] `Sources/GohMenuBar/GohMenuView.swift` — read the `primaryAction` computed property and the `footer` computed property; decide where the new button goes. The spec says "alongside the existing one-tap quick-add" — place it adjacent to the primary action button, in the same `VStack` below `primaryAction`, before `Divider()`. Alternatively place it in the `footer` HStack. Read the full layout before deciding; the `primaryAction` area is more prominent.
- [x] `Sources/goh-menu/main.swift` — confirm `GohMenuView` init receives closures via the existing init; decide how to inject the `openWindow` action (via a new closure parameter, or via `@Environment(\.openWindow)` inside `GohMenuView` directly).

**Design decision on `openWindow` injection:**

`@Environment(\.openWindow)` is a SwiftUI env action available anywhere inside a SwiftUI view body. `GohMenuView` is already a SwiftUI `View`. Use `@Environment(\.openWindow)` directly inside `GohMenuView` — no new init parameter needed. This keeps the init signature unchanged and the test gap minimal.

**REQUIRED — add `import AppKit`:** the button below calls `NSApp.activate(...)`, and `GohMenuView.swift` currently imports ONLY `SwiftUI` (which does NOT re-export `NSApp`). Add `import AppKit` to the top of `GohMenuView.swift` (matching other GohMenuBar files that use `NS*`, e.g. the terminal-discovery file). Without it, `swift build -warnings-as-errors` fails with "cannot find 'NSApp' in scope."

```swift
// Top of GohMenuView.swift — add alongside the existing `import SwiftUI`:
import AppKit

// Inside GohMenuView, add at top of struct:
@Environment(\.openWindow) private var openWindow
```

Then the button:
```swift
private var addDownloadButton: some View {
    Button {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "add-download")
    } label: {
        Label("Add download…", systemImage: "plus.circle")
            .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
    .accessibilityLabel("Open Add Download window")
    .help("Open the Add Download window to choose folder and connection count")
}
```

Place it in `body` between `primaryAction` and the first `Divider()`:
```swift
primaryAction
addDownloadButton   // ← new
Divider()
```

**Step 1 — Add `@Environment(\.openWindow)` to `GohMenuView`**

Read exact line numbers in `GohMenuView.swift` to find the right insertion points before editing. Edit the file to add the `@Environment` property and the new `addDownloadButton` computed property, then insert the button call in `body`.

**Step 2 — Build check**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
```

**Step 3 — Full suite (Phase 2 exit gate)**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -10
```

All existing tests must remain green. The existing `startsClipboardURLThroughDaemon` test asserting `client.addedRequests == [AddRequest(url: "https://example.com/big.iso")]` must pass unchanged (AC4).

**Smoke note:** See Task P2-2 smoke note.

---

## Phase 2 exit criteria

- [ ] `swift build -Xswiftc -warnings-as-errors` clean
- [ ] `swift test` green — all existing tests + all Phase 1 tests
- [ ] `AddDownloadView` compiles with `@Environment(\.dismiss)` and `@Environment(\.openWindow)` in scope
- [ ] `NSOpenPanelFolderPicker` is in `goh-menu` only (not in `GohMenuBar`)
- [ ] `GohMenuApp.body` contains `Window(id: "add-download")` scene
- [ ] `GohMenuView` contains "Add download…" button; existing one-tap button unchanged
- [ ] No new `#available` ladders; no diff to `Sources/GohCore`
- [ ] Manual smoke: window opens, folder pick works, Automatic toggle disables stepper, Add closes on success, Cancel closes without submitting

---

## Full feature exit criteria (both phases)

- [ ] All 5 ACs verified: AC1 destination set/nil, AC2 connectionCount UInt8/nil, AC3 1...16 clamp, AC4 one-tap unchanged, AC5 no contract change
- [ ] `swift build -Xswiftc -warnings-as-errors` clean
- [ ] `swift test` green (all existing + new tests)
- [ ] `GohMenuError.userFacingMessage` covers all 5 cases; no raw enum names
- [ ] `AddDownloadViewModel` tests: folder chosen, cancel-pick, automatic/pinned, clamping, URL normalization, canAdd false cases, no-op submit, error text, AC4 regression
- [ ] No `Sources/GohCore` diff; `protocolVersion` unchanged
- [ ] THE BET recorded in plan (see header) and in `DESIGN.md` menu-bar subsection

## DESIGN.md note

After both phases pass, append a subsection to `DESIGN.md` under the menu-bar section:

> **Richer Add (2026-06-06):** The tray app's "Add download…" button opens a persistent `Window` scene rather than a popover sheet. This is load-bearing: `NSOpenPanel` acquiring key focus dismisses `MenuBarExtra(.window)` popovers (FB11984872). The popover's role is launch-only. Approach B ("set-once defaults") is a future additive layer; this slice delivers per-download control via Approach A. THE BET: a dedicated add window is acceptable UX for the choose-where/how case.
