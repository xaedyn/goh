# Menu Bar Companion MB1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first private dogfood native menu bar companion for `goh`: copy a URL, click **Get over here!**, watch live daemon progress, then reveal the completed file.

**Architecture:** Add a testable `GohMenuBar` library plus a thin `goh-menu` SwiftPM executable. The library owns pure presentation state, clipboard URL detection, and view-model behavior; the executable owns the SwiftUI `MenuBarExtra`, AppKit process policy, Finder reveal, Terminal handoff, and live XPC wiring. `gohd` remains the only download engine and job source of truth.

**Tech Stack:** Swift 6.2 package manifest, SwiftUI `MenuBarExtra`, AppKit `NSApplication` / `NSWorkspace`, XPC through existing `GohCore` command and progress subscription types, Swift Testing.

---

## Scope

MB1 ships a private dogfood companion, not a public app bundle or launch-at-login product. It should be useful from source immediately:

- `goh-menu` appears in the macOS menu bar as an accessory app.
- The popover shows daemon health, active count, aggregate speed, and job rows.
- If the clipboard contains an `http` or `https` URL, the primary action is **Get over here!**.
- The primary action sends `Command.add` through the same daemon surface as `goh add`.
- Live updates come from `Command.subscribe(scope: .all)`.
- Active and paused rows expose pause/resume controls through existing commands.
- Completed rows can be revealed in Finder.
- The popover can open `goh top` in Terminal for power users.
- Daemon, peer-validation, and protocol-version failures show doctor-style recovery text.

Explicitly out of scope for MB1: notifications, launch-at-login, app bundle packaging, public distribution, browser extension integration, mirror racing, adaptive scheduling, preferences UI, and any new daemon wire command.

Apple API verification performed on 2026-05-25 against primary Apple documentation:

- SwiftUI `MenuBarExtra` is the native scene for menu bar extras.
- `NSApplication.setActivationPolicy(.accessory)` is the private dogfood path for hiding Dock presence from a SwiftPM executable.
- `NSWorkspace.activateFileViewerSelecting(_:)` is the native Finder reveal API.

## File Structure

- Modify `Package.swift`
  - Add product `.executable(name: "goh-menu", targets: ["goh-menu"])`.
  - Add target `GohMenuBar`, depending on `GohCore`, with `.defaultIsolation(MainActor.self)`.
  - Add executable target `goh-menu`, depending on `GohMenuBar` and `GohCore`, with `.defaultIsolation(MainActor.self)`.
  - Add test target `GohMenuBarTests`.

- Create `Sources/GohCore/IPC/GohCommandClient.swift`
  - Shared command envelope helper so the menu bar target does not duplicate private CLI encoding logic.

- Create `Sources/GohMenuBar/GohMenuModels.swift`
  - Pure state structs: `GohMenuState`, `GohMenuHealth`, `GohMenuJobRow`, `GohMenuControl`, `GohMenuRecoveryAction`.

- Create `Sources/GohMenuBar/GohMenuPresenter.swift`
  - Pure conversion from `[ProgressSnapshot]` and errors to menu state.

- Create `Sources/GohMenuBar/GohClipboardURLDetector.swift`
  - Pure URL candidate detection from clipboard text.

- Create `Sources/GohMenuBar/GohMenuViewModel.swift`
  - MainActor view model that binds daemon client, clipboard detector, and UI actions.

- Create `Sources/GohMenuBar/GohMenuView.swift`
  - SwiftUI popover content. Compact operational layout, no decorative dashboard.

- Create `Sources/goh-menu/main.swift`
  - SwiftUI app entry point, `MenuBarExtra`, AppKit accessory policy, live XPC client, Finder/Terminal side effects.

- Modify `Scripts/dogfood-build.sh`
  - Install `goh-menu` beside `goh` and `gohd` under `.build/dogfood/current/bin`.

- Modify `DESIGN.md`
  - Update the architecture overview to include optional `goh-menu` / `GohMenuBar`.

- Modify `STATE.md`
  - Record the active branch and handoff.

- Create tests:
  - `Tests/GohCoreTests/GohCommandClientTests.swift`
  - `Tests/GohMenuBarTests/GohMenuPresenterTests.swift`
  - `Tests/GohMenuBarTests/GohClipboardURLDetectorTests.swift`
  - `Tests/GohMenuBarTests/GohMenuViewModelTests.swift`

## Task 1: Package And State Setup

**Files:**
- Modify: `Package.swift`
- Modify: `STATE.md`

- [ ] **Step 1: Add package targets**

Patch `Package.swift` so the products and targets include:

```swift
products: [
    .executable(name: "goh", targets: ["goh"]),
    .executable(name: "gohd", targets: ["gohd"]),
    .executable(name: "goh-menu", targets: ["goh-menu"]),
],
```

Add these targets before the test targets:

```swift
.executableTarget(
    name: "goh-menu",
    dependencies: ["GohCore", "GohMenuBar"],
    swiftSettings: [.defaultIsolation(MainActor.self)]
),
.target(
    name: "GohMenuBar",
    dependencies: ["GohCore"],
    swiftSettings: [.defaultIsolation(MainActor.self)]
),
```

Add the test target:

```swift
.testTarget(
    name: "GohMenuBarTests",
    dependencies: ["GohMenuBar"]
),
```

- [ ] **Step 2: Verify package shape**

Run:

```bash
swift package describe --type json >/tmp/goh-package.json
```

Expected: command exits `0`, and `/tmp/goh-package.json` contains `goh-menu`, `GohMenuBar`, and `GohMenuBarTests`.

- [ ] **Step 3: Commit package setup**

```bash
git add Package.swift STATE.md
git commit -m "chore: start menu bar companion slice"
```

## Task 2: Shared Command Client

**Files:**
- Create: `Sources/GohCore/IPC/GohCommandClient.swift`
- Test: `Tests/GohCoreTests/GohCommandClientTests.swift`

- [ ] **Step 1: Write failing command-client tests**

Create `Tests/GohCoreTests/GohCommandClientTests.swift`:

```swift
import Foundation
import Testing
import XPC
@testable import GohCore

@Suite("GohCommandClient")
struct GohCommandClientTests {
    @Test func decodesSuccessfulReply() throws {
        let expected = JobSummary(
            id: 42,
            url: "https://example.com/file.iso",
            destination: "/tmp/file.iso",
            state: .queued,
            progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
            createdAt: Date(timeIntervalSince1970: 1),
            lastProgressAt: nil,
            requestedConnectionCount: 8,
            actualConnectionCount: 0)

        let client = GohCommandClient { request in
            let requestID = try request.withUnsafeUnderlyingDictionary { object in
                try GohEnvelope<Command>(xpcDictionary: object).requestID
            }
            let reply = try GohEnvelope(
                protocolVersion: CommandService.protocolVersion,
                requestID: requestID,
                messageType: .reply,
                payload: expected)
                .xpcDictionary()
            return XPCDictionary(reply)
        }

        let actual: JobSummary = try client.send(
            .add(request: AddRequest(url: expected.url)),
            expecting: JobSummary.self)

        #expect(actual == expected)
    }

    @Test func throwsDaemonErrorReply() throws {
        let daemonError = GohError(
            code: .protocolVersionMismatch,
            message: "client and daemon builds differ")
        let client = GohCommandClient { request in
            let requestID = try request.withUnsafeUnderlyingDictionary { object in
                try GohEnvelope<Command>(xpcDictionary: object).requestID
            }
            let reply = try GohEnvelope(
                protocolVersion: CommandService.protocolVersion,
                requestID: requestID,
                messageType: .error,
                payload: daemonError)
                .xpcDictionary()
            return XPCDictionary(reply)
        }

        #expect(throws: GohCommandClientError.daemon(daemonError)) {
            let _: LsReply = try client.send(.ls, expecting: LsReply.self)
        }
    }

    @Test func rejectsMismatchedRequestID() throws {
        let client = GohCommandClient { _ in
            let reply = try GohEnvelope(
                protocolVersion: CommandService.protocolVersion,
                requestID: UUID(),
                messageType: .reply,
                payload: LsReply(jobs: []))
                .xpcDictionary()
            return XPCDictionary(reply)
        }

        #expect(throws: GohCommandClientError.malformedReply("daemon reply requestID did not match the request")) {
            let _: LsReply = try client.send(.ls, expecting: LsReply.self)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter GohCommandClientTests
```

Expected: FAIL because `GohCommandClient` and `GohCommandClientError` do not exist.

- [ ] **Step 3: Implement shared command client**

Create `Sources/GohCore/IPC/GohCommandClient.swift`:

```swift
import Foundation
import XPC

public enum GohCommandClientError: Error, Sendable, Equatable {
    case daemon(GohError)
    case malformedReply(String)
}

public struct GohCommandClient {
    public typealias Sender = (XPCDictionary) throws -> XPCDictionary

    private let sendEnvelope: Sender

    public init(send: @escaping Sender) {
        self.sendEnvelope = send
    }

    public func send<Reply: Codable & Sendable>(
        _ command: Command,
        expecting _: Reply.Type
    ) throws -> Reply {
        try sendWithRequestID(command, expecting: Reply.self).reply
    }

    public func sendWithRequestID<Reply: Codable & Sendable>(
        _ command: Command,
        expecting _: Reply.Type
    ) throws -> (requestID: UUID, reply: Reply) {
        let requestID = UUID()
        let request = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .request,
            payload: command)
            .xpcDictionary()
        let response = try sendEnvelope(XPCDictionary(request))

        return try response.withUnsafeUnderlyingDictionary { object in
            if let reply = try? GohEnvelope<Reply>(xpcDictionary: object),
               reply.messageType == .reply
            {
                guard reply.requestID == requestID else {
                    throw GohCommandClientError.malformedReply(
                        "daemon reply requestID did not match the request")
                }
                return (requestID, reply.payload)
            }

            if let error = try? GohEnvelope<GohError>(xpcDictionary: object),
               error.messageType == .error
            {
                guard error.requestID == requestID else {
                    throw GohCommandClientError.malformedReply(
                        "daemon error requestID did not match the request")
                }
                throw GohCommandClientError.daemon(error.payload)
            }

            throw GohCommandClientError.malformedReply(
                "daemon returned an unrecognized reply")
        }
    }
}
```

- [ ] **Step 4: Run command-client tests**

Run:

```bash
swift test --filter GohCommandClientTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/GohCore/IPC/GohCommandClient.swift Tests/GohCoreTests/GohCommandClientTests.swift
git commit -m "feat: add shared command client"
```

## Task 3: Menu Presentation Model

**Files:**
- Create: `Sources/GohMenuBar/GohMenuModels.swift`
- Create: `Sources/GohMenuBar/GohMenuPresenter.swift`
- Test: `Tests/GohMenuBarTests/GohMenuPresenterTests.swift`

- [ ] **Step 1: Write failing presenter tests**

Create `Tests/GohMenuBarTests/GohMenuPresenterTests.swift`:

```swift
import Foundation
import Testing
import GohCore
@testable import GohMenuBar

@Suite("GohMenuPresenter")
struct GohMenuPresenterTests {
    @Test func summarizesActiveDownloadsAndAggregateSpeed() {
        let snapshots = [
            snapshot(id: 1, state: .active, completed: 512, total: 1024, speed: 1000),
            snapshot(id: 2, state: .active, completed: 256, total: 1024, speed: 2000),
            snapshot(id: 3, state: .completed, completed: 1024, total: 1024, speed: 0),
        ]

        let state = GohMenuPresenter().state(
            health: .connected,
            snapshots: snapshots,
            clipboardURL: URL(string: "https://example.com/big.iso"))

        #expect(state.activeCount == 2)
        #expect(state.aggregateSpeedText == "2.9 KB/s")
        #expect(state.primaryAction == .addClipboardURL(URL(string: "https://example.com/big.iso")!))
        #expect(state.rows.map(\.id) == [1, 2, 3])
        #expect(state.rows[0].controls.contains(.pause))
        #expect(state.rows[1].controls.contains(.pause))
        #expect(state.rows[2].controls.contains(.revealInFinder))
    }

    @Test func explainsPeerValidationFailure() {
        let error = GohMenuError.peerValidation("Peer forbidden (code signing)")

        let state = GohMenuPresenter().state(
            health: .failed(error),
            snapshots: [],
            clipboardURL: nil)

        #expect(state.healthTitle == "Peer validation blocked")
        #expect(state.healthDetail.contains("GOH_XPC_ALLOW_UNVALIDATED_PEERS=1"))
        #expect(state.recoveryAction == .copyCommand("export GOH_XPC_ALLOW_UNVALIDATED_PEERS=1"))
    }

    private func snapshot(
        id: UInt64,
        state: JobState,
        completed: UInt64,
        total: UInt64,
        speed: UInt64
    ) -> ProgressSnapshot {
        ProgressSnapshot(
            job: JobSummary(
                id: id,
                url: "https://example.com/\(id).iso",
                destination: "/tmp/\(id).iso",
                state: state,
                progress: JobProgress(
                    bytesCompleted: completed,
                    bytesTotal: total,
                    bytesPerSecond: speed),
                createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
                lastProgressAt: Date(timeIntervalSince1970: TimeInterval(id + 10)),
                requestedConnectionCount: 8,
                actualConnectionCount: state == .active ? 8 : 0),
            lanes: [])
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter GohMenuPresenterTests
```

Expected: FAIL because `GohMenuBar` model types do not exist.

- [ ] **Step 3: Implement models**

Create `Sources/GohMenuBar/GohMenuModels.swift`:

```swift
import Foundation
import GohCore

public enum GohMenuHealth: Sendable, Equatable {
    case connecting
    case connected
    case reconnecting
    case failed(GohMenuError)
}

public enum GohMenuError: Error, Sendable, Equatable {
    case daemonUnavailable(String)
    case peerValidation(String)
    case protocolMismatch(String)
    case daemon(GohError)
    case malformedReply(String)
}

public enum GohMenuControl: Sendable, Hashable {
    case pause
    case resume
    case remove
    case revealInFinder
    case copyURL
    case copyDestination
}

public enum GohMenuPrimaryAction: Sendable, Equatable {
    case addClipboardURL(URL)
    case pasteURL
    case diagnose
}

public enum GohMenuRecoveryAction: Sendable, Equatable {
    case copyCommand(String)
    case openDoctor
}

public struct GohMenuJobRow: Sendable, Equatable, Identifiable {
    public var id: UInt64
    public var title: String
    public var subtitle: String
    public var stateText: String
    public var progressText: String
    public var speedText: String
    public var destination: String
    public var url: String
    public var controls: Set<GohMenuControl>
}

public struct GohMenuState: Sendable, Equatable {
    public var health: GohMenuHealth
    public var healthTitle: String
    public var healthDetail: String?
    public var activeCount: Int
    public var aggregateSpeedText: String
    public var primaryAction: GohMenuPrimaryAction
    public var recoveryAction: GohMenuRecoveryAction?
    public var rows: [GohMenuJobRow]
}
```

- [ ] **Step 4: Implement presenter**

Create `Sources/GohMenuBar/GohMenuPresenter.swift`:

```swift
import Foundation
import GohCore

public struct GohMenuPresenter: Sendable {
    public init() {}

    public func state(
        health: GohMenuHealth,
        snapshots: [ProgressSnapshot],
        clipboardURL: URL?
    ) -> GohMenuState {
        let jobs = snapshots.map(\.job).sorted { $0.id < $1.id }
        let activeJobs = jobs.filter { $0.state == .active }
        let aggregateSpeed = activeJobs.reduce(UInt64(0)) {
            $0 + $1.progress.bytesPerSecond
        }
        let rows = jobs.map(row)
        let healthCopy = copy(for: health)

        return GohMenuState(
            health: health,
            healthTitle: healthCopy.title,
            healthDetail: healthCopy.detail,
            activeCount: activeJobs.count,
            aggregateSpeedText: Self.formatBytes(aggregateSpeed) + "/s",
            primaryAction: clipboardURL.map(GohMenuPrimaryAction.addClipboardURL) ?? .pasteURL,
            recoveryAction: healthCopy.recovery,
            rows: rows)
    }

    private func row(for job: JobSummary) -> GohMenuJobRow {
        let destinationURL = URL(filePath: job.destination)
        return GohMenuJobRow(
            id: job.id,
            title: destinationURL.lastPathComponent.isEmpty ? job.destination : destinationURL.lastPathComponent,
            subtitle: job.destination,
            stateText: job.state.rawValue,
            progressText: Self.progressText(job.progress),
            speedText: Self.formatBytes(job.progress.bytesPerSecond) + "/s",
            destination: job.destination,
            url: job.url,
            controls: controls(for: job))
    }

    private func controls(for job: JobSummary) -> Set<GohMenuControl> {
        switch job.state {
        case .queued:
            return [.remove, .copyURL, .copyDestination]
        case .active:
            return [.pause, .copyURL, .copyDestination]
        case .paused:
            return [.resume, .remove, .copyURL, .copyDestination]
        case .completed:
            return [.revealInFinder, .copyURL, .copyDestination]
        case .failed:
            return [.resume, .remove, .copyURL, .copyDestination]
        }
    }

    private func copy(for health: GohMenuHealth) -> (
        title: String,
        detail: String?,
        recovery: GohMenuRecoveryAction?
    ) {
        switch health {
        case .connecting:
            return ("Connecting to gohd", nil, nil)
        case .connected:
            return ("gohd connected", nil, nil)
        case .reconnecting:
            return ("Reconnecting to gohd", "Downloads continue in the daemon while the companion reconnects.", nil)
        case .failed(.peerValidation(let detail)):
            return (
                "Peer validation blocked",
                "\(detail). For unsigned dogfood builds, run: export GOH_XPC_ALLOW_UNVALIDATED_PEERS=1",
                .copyCommand("export GOH_XPC_ALLOW_UNVALIDATED_PEERS=1"))
        case .failed(.protocolMismatch(let detail)):
            return ("Builds differ", "\(detail). Restart the daemon after rebuilding.", .copyCommand("brew services restart goh"))
        case .failed(.daemonUnavailable(let detail)):
            return ("gohd unavailable", "\(detail). Run goh doctor for exact recovery.", .openDoctor)
        case .failed(.daemon(let error)):
            return ("gohd error", error.message ?? error.code.rawValue, .openDoctor)
        case .failed(.malformedReply(let detail)):
            return ("Invalid daemon reply", detail, .openDoctor)
        }
    }

    private static func progressText(_ progress: JobProgress) -> String {
        guard let total = progress.bytesTotal else {
            return "\(formatBytes(progress.bytesCompleted))/?"
        }
        let percent = total == 0
            ? 100
            : Int((Double(progress.bytesCompleted) / Double(total) * 100).rounded())
        return "\(formatBytes(progress.bytesCompleted))/\(formatBytes(total)) (\(percent)%)"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        guard bytes >= 1024 else {
            return "\(bytes) B"
        }
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            return "\(Int(rounded)) \(units[unitIndex])"
        }
        return String(
            format: "%.1f %@",
            locale: Locale(identifier: "en_US_POSIX"),
            value,
            units[unitIndex])
    }
}
```

- [ ] **Step 5: Run presenter tests**

Run:

```bash
swift test --filter GohMenuPresenterTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/GohMenuBar/GohMenuModels.swift Sources/GohMenuBar/GohMenuPresenter.swift Tests/GohMenuBarTests/GohMenuPresenterTests.swift
git commit -m "feat: model menu bar companion state"
```

## Task 4: Clipboard URL Detection

**Files:**
- Create: `Sources/GohMenuBar/GohClipboardURLDetector.swift`
- Test: `Tests/GohMenuBarTests/GohClipboardURLDetectorTests.swift`

- [ ] **Step 1: Write failing clipboard tests**

Create `Tests/GohMenuBarTests/GohClipboardURLDetectorTests.swift`:

```swift
import Foundation
import Testing
@testable import GohMenuBar

@Suite("GohClipboardURLDetector")
struct GohClipboardURLDetectorTests {
    @Test func acceptsHTTPSURLWithWhitespace() {
        let url = GohClipboardURLDetector().url(from: " \n https://example.com/big.iso \n ")
        #expect(url == URL(string: "https://example.com/big.iso"))
    }

    @Test func acceptsHTTPURL() {
        let url = GohClipboardURLDetector().url(from: "http://example.com/file.zip")
        #expect(url == URL(string: "http://example.com/file.zip"))
    }

    @Test func rejectsNonHTTPURL() {
        #expect(GohClipboardURLDetector().url(from: "file:///tmp/file.iso") == nil)
    }

    @Test func rejectsURLWithoutHost() {
        #expect(GohClipboardURLDetector().url(from: "https:///missing-host") == nil)
    }

    @Test func rejectsMultipleLinesOfText() {
        #expect(GohClipboardURLDetector().url(from: "https://example.com/a\nhttps://example.com/b") == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter GohClipboardURLDetectorTests
```

Expected: FAIL because `GohClipboardURLDetector` does not exist.

- [ ] **Step 3: Implement detector**

Create `Sources/GohMenuBar/GohClipboardURLDetector.swift`:

```swift
import Foundation

public struct GohClipboardURLDetector: Sendable {
    public init() {}

    public func url(from rawText: String?) -> URL? {
        guard let rawText else { return nil }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n"), !text.contains("\r") else {
            return nil
        }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              let url = components.url
        else {
            return nil
        }
        return url
    }
}
```

- [ ] **Step 4: Run clipboard tests**

Run:

```bash
swift test --filter GohClipboardURLDetectorTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/GohMenuBar/GohClipboardURLDetector.swift Tests/GohMenuBarTests/GohClipboardURLDetectorTests.swift
git commit -m "feat: detect clipboard download URLs"
```

## Task 5: View Model Behavior

**Files:**
- Create: `Sources/GohMenuBar/GohMenuViewModel.swift`
- Test: `Tests/GohMenuBarTests/GohMenuViewModelTests.swift`

- [ ] **Step 1: Write failing view-model tests**

Create `Tests/GohMenuBarTests/GohMenuViewModelTests.swift`:

```swift
import Foundation
import Testing
import GohCore
@testable import GohMenuBar

@Suite("GohMenuViewModel")
@MainActor
struct GohMenuViewModelTests {
    @Test func startsClipboardURLThroughDaemon() async throws {
        let client = FakeMenuClient()
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { "https://example.com/big.iso" },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        await model.refreshClipboard()
        await model.performPrimaryAction()

        #expect(client.addedRequests == [AddRequest(url: "https://example.com/big.iso")])
    }

    @Test func mapsProgressStreamIntoState() async throws {
        let client = FakeMenuClient()
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { nil },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        client.emit([Self.snapshot(id: 9, state: .active, speed: 4096)])
        await model.consumeOneProgressUpdateForTesting()

        #expect(model.state.activeCount == 1)
        #expect(model.state.aggregateSpeedText == "4 KB/s")
        #expect(model.state.rows.first?.id == 9)
    }

    @Test func pauseAndResumeSendExistingCommands() async throws {
        let client = FakeMenuClient()
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { nil },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        await model.pause(jobID: 7)
        await model.resume(jobID: 7)

        #expect(client.pausedIDs == [7])
        #expect(client.resumedIDs == [7])
    }

    private static func snapshot(id: UInt64, state: JobState, speed: UInt64) -> ProgressSnapshot {
        ProgressSnapshot(
            job: JobSummary(
                id: id,
                url: "https://example.com/\(id).iso",
                destination: "/tmp/\(id).iso",
                state: state,
                progress: JobProgress(bytesCompleted: 128, bytesTotal: 1024, bytesPerSecond: speed),
                createdAt: Date(timeIntervalSince1970: 1),
                lastProgressAt: Date(timeIntervalSince1970: 2),
                requestedConnectionCount: 8,
                actualConnectionCount: state == .active ? 8 : 0),
            lanes: [])
    }
}

@MainActor
private final class FakeMenuClient: GohMenuClient {
    var addedRequests: [AddRequest] = []
    var pausedIDs: [UInt64] = []
    var resumedIDs: [UInt64] = []
    private var bufferedSnapshots: [[ProgressSnapshot]] = []

    func progressSnapshots() -> AsyncThrowingStream<[ProgressSnapshot], any Error> {
        AsyncThrowingStream { continuation in
            for snapshots in bufferedSnapshots {
                continuation.yield(snapshots)
            }
        }
    }

    func add(_ request: AddRequest) async throws -> JobSummary {
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

    func pause(jobID: UInt64) async throws {
        pausedIDs.append(jobID)
    }

    func resume(jobID: UInt64) async throws {
        resumedIDs.append(jobID)
    }

    func remove(jobID: UInt64, keepPartialFile: Bool) async throws {}

    func emit(_ snapshots: [ProgressSnapshot]) {
        bufferedSnapshots.append(snapshots)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter GohMenuViewModelTests
```

Expected: FAIL because `GohMenuViewModel` and `GohMenuClient` do not exist.

- [ ] **Step 3: Implement client protocol and view model**

Create `Sources/GohMenuBar/GohMenuViewModel.swift`:

```swift
import Combine
import Foundation
import GohCore

@MainActor
public protocol GohMenuClient: AnyObject {
    func progressSnapshots() -> AsyncThrowingStream<[ProgressSnapshot], any Error>
    func add(_ request: AddRequest) async throws -> JobSummary
    func pause(jobID: UInt64) async throws
    func resume(jobID: UInt64) async throws
    func remove(jobID: UInt64, keepPartialFile: Bool) async throws
}

@MainActor
public final class GohMenuViewModel: ObservableObject {
    @Published public private(set) var state: GohMenuState

    private let client: GohMenuClient
    private let presenter: GohMenuPresenter
    private let clipboard: GohClipboardURLDetector
    private let pasteboardText: () -> String?
    private let revealInFinder: (String) -> Void
    private let openTerminalDashboard: () -> Void
    private let copyText: (String) -> Void
    private var snapshots: [ProgressSnapshot] = []
    private var clipboardURL: URL?
    private var progressIterator: AsyncThrowingStream<[ProgressSnapshot], any Error>.Iterator?

    public init(
        client: GohMenuClient,
        presenter: GohMenuPresenter = GohMenuPresenter(),
        clipboard: GohClipboardURLDetector = GohClipboardURLDetector(),
        pasteboardText: @escaping () -> String?,
        revealInFinder: @escaping (String) -> Void,
        openTerminalDashboard: @escaping () -> Void,
        copyText: @escaping (String) -> Void
    ) {
        self.client = client
        self.presenter = presenter
        self.clipboard = clipboard
        self.pasteboardText = pasteboardText
        self.revealInFinder = revealInFinder
        self.openTerminalDashboard = openTerminalDashboard
        self.copyText = copyText
        self.state = presenter.state(health: .connecting, snapshots: [], clipboardURL: nil)
    }

    public func start() {
        progressIterator = client.progressSnapshots().makeAsyncIterator()
        Task { [weak self] in
            while await self?.consumeOneProgressUpdateForTesting() == true {}
        }
    }

    @discardableResult
    public func consumeOneProgressUpdateForTesting() async -> Bool {
        do {
            guard var iterator = progressIterator else {
                progressIterator = client.progressSnapshots().makeAsyncIterator()
                return await consumeOneProgressUpdateForTesting()
            }
            guard let next = try await iterator.next() else {
                progressIterator = nil
                return false
            }
            progressIterator = iterator
            snapshots = next
            render(health: .connected)
            return true
        } catch let error as GohMenuError {
            render(health: .failed(error))
            return false
        } catch {
            render(health: .failed(.daemonUnavailable("\(error)")))
            return false
        }
    }

    public func refreshClipboard() async {
        clipboardURL = clipboard.url(from: pasteboardText())
        render(health: state.health)
    }

    public func performPrimaryAction() async {
        switch state.primaryAction {
        case .addClipboardURL(let url):
            do {
                _ = try await client.add(AddRequest(url: url.absoluteString))
            } catch {
                render(health: .failed(.daemonUnavailable("\(error)")))
            }
        case .pasteURL:
            await refreshClipboard()
        case .diagnose:
            openTerminalDashboard()
        }
    }

    public func pause(jobID: UInt64) async {
        do {
            try await client.pause(jobID: jobID)
        } catch {
            render(health: .failed(.daemonUnavailable("\(error)")))
        }
    }

    public func resume(jobID: UInt64) async {
        do {
            try await client.resume(jobID: jobID)
        } catch {
            render(health: .failed(.daemonUnavailable("\(error)")))
        }
    }

    public func remove(jobID: UInt64, keepPartialFile: Bool) async {
        do {
            try await client.remove(jobID: jobID, keepPartialFile: keepPartialFile)
        } catch {
            render(health: .failed(.daemonUnavailable("\(error)")))
        }
    }

    public func reveal(destination: String) {
        revealInFinder(destination)
    }

    public func copy(_ text: String) {
        copyText(text)
    }

    public func openTop() {
        openTerminalDashboard()
    }

    private func render(health: GohMenuHealth) {
        state = presenter.state(
            health: health,
            snapshots: snapshots,
            clipboardURL: clipboardURL)
    }
}
```

- [ ] **Step 4: Run view-model tests**

Run:

```bash
swift test --filter GohMenuViewModelTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/GohMenuBar/GohMenuViewModel.swift Tests/GohMenuBarTests/GohMenuViewModelTests.swift
git commit -m "feat: add menu bar view model"
```

## Task 6: Live XPC Menu Client

**Files:**
- Create: `Sources/goh-menu/main.swift`

- [ ] **Step 1: Add the live client skeleton**

Create `Sources/goh-menu/main.swift` with the live client and AppKit helpers first. Keep SwiftUI view wiring for Task 7.

```swift
import AppKit
import Foundation
import AppKit
import SwiftUI
import XPC

import GohCore
import GohMenuBar

@MainActor
final class LiveGohMenuClient: GohMenuClient {
    private let validationMode: PeerValidationMode

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        validationMode = GohXPCService.peerValidationMode(environment: environment)
    }

    func progressSnapshots() -> AsyncThrowingStream<[ProgressSnapshot], any Error> {
        AsyncThrowingStream { continuation in
            let inbox = GohXPCNotificationInbox()
            do {
                let session = try makeSession(inbox: inbox)
                let commandClient = GohCommandClient { request in
                    try session.sendSync(request)
                }
                let (requestID, reply): (UUID, SubscribeReply) = try commandClient
                    .sendWithRequestID(
                        .subscribe(request: SubscribeRequest(scope: .all)),
                        expecting: SubscribeReply.self)
                continuation.yield(reply.snapshot)

                let task = Task.detached {
                    while !Task.isCancelled {
                        do {
                            let envelope = try inbox.receive()
                            guard envelope.messageType == .notification,
                                  envelope.requestID == requestID
                            else {
                                throw GohMenuError.malformedReply(
                                    "daemon sent a progress notification for a different request")
                            }
                            continuation.yield(envelope.payload.snapshot)
                        } catch GohXPCNotificationInboxError.interrupted {
                            continuation.finish()
                            return
                        } catch GohXPCNotificationInboxError.sessionInvalidated(let reason) {
                            continuation.finish(throwing: GohMenuError.daemonUnavailable(reason))
                            return
                        } catch GohXPCNotificationInboxError.malformedProgressNotification(let message) {
                            continuation.finish(throwing: GohMenuError.malformedReply(message))
                            return
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                }

                continuation.onTermination = { _ in
                    task.cancel()
                    inbox.interrupt()
                    session.cancel()
                }
            } catch let error as GohCommandClientError {
                continuation.finish(throwing: Self.map(error))
            } catch {
                continuation.finish(throwing: Self.map(error))
            }
        }
    }

    func add(_ request: AddRequest) async throws -> JobSummary {
        try oneShot().send(.add(request: request), expecting: JobSummary.self)
    }

    func pause(jobID: UInt64) async throws {
        let _: JobSummary = try oneShot().send(.pause(jobID: jobID), expecting: JobSummary.self)
    }

    func resume(jobID: UInt64) async throws {
        let _: JobSummary = try oneShot().send(.resume(jobID: jobID), expecting: JobSummary.self)
    }

    func remove(jobID: UInt64, keepPartialFile: Bool) async throws {
        let _: RmReply = try oneShot().send(
            .rm(request: RmRequest(jobID: jobID, keepPartialFile: keepPartialFile)),
            expecting: RmReply.self)
    }

    private func oneShot() throws -> GohCommandClient {
        let client = try GohXPCClient(
            machServiceName: GohXPCService.machServiceName,
            mode: validationMode)
        return GohCommandClient { request in
            defer { client.cancel() }
            return try client.sendSync(request)
        }
    }

    private func makeSession(inbox: GohXPCNotificationInbox) throws -> GohProgressSubscriptionSession {
        let client = try GohXPCClient(
            machServiceName: GohXPCService.machServiceName,
            mode: validationMode,
            incomingMessageHandler: { message in
                inbox.handle(message)
            },
            cancellationHandler: { error in
                inbox.sessionInvalidated("\(error)")
            })
        return GohProgressSubscriptionSession(
            sendSync: { request in try client.sendSync(request) },
            receiveNotification: { try inbox.receive() },
            cancel: { client.cancel() })
    }

    private nonisolated static func map(_ error: any Error) -> GohMenuError {
        if let error = error as? GohMenuError {
            return error
        }
        if let error = error as? GohCommandClientError {
            switch error {
            case .daemon(let daemonError):
                if daemonError.code == .protocolVersionMismatch {
                    return .protocolMismatch(daemonError.message ?? daemonError.code.rawValue)
                }
                return .daemon(daemonError)
            case .malformedReply(let message):
                return .malformedReply(message)
            }
        }
        let text = "\(error)"
        if text.localizedCaseInsensitiveContains("peer") {
            return .peerValidation(text)
        }
        return .daemonUnavailable(text)
    }
}
```

- [ ] **Step 2: Build the new target**

Run:

```bash
swift build --product goh-menu -Xswiftc -warnings-as-errors
```

Expected: compilation fails only if the skeleton has real type/concurrency issues. Fix the issues in this task before moving on.

- [ ] **Step 3: Commit**

```bash
git add Sources/goh-menu/main.swift
git commit -m "feat: connect menu bar companion to gohd"
```

## Task 7: SwiftUI Menu Bar UI

**Files:**
- Create: `Sources/GohMenuBar/GohMenuView.swift`
- Modify: `Sources/goh-menu/main.swift`

- [ ] **Step 1: Implement the SwiftUI popover**

Create `Sources/GohMenuBar/GohMenuView.swift`:

```swift
import SwiftUI

public struct GohMenuView: View {
    @ObservedObject private var model: GohMenuViewModel

    public init(model: GohMenuViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            primaryAction
            Divider()
            jobs
            Divider()
            footer
        }
        .frame(width: 380)
        .padding(12)
        .task {
            model.start()
            await model.refreshClipboard()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.state.healthTitle)
                    .font(.headline)
                if let detail = model.state.healthDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else {
                    Text("\(model.state.activeCount) active · \(model.state.aggregateSpeedText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await model.refreshClipboard() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
    }

    private var primaryAction: some View {
        Button {
            Task { await model.performPrimaryAction() }
        } label: {
            Label(primaryActionTitle, systemImage: primaryActionIcon)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.borderedProminent)
    }

    private var primaryActionTitle: String {
        switch model.state.primaryAction {
        case .addClipboardURL:
            return "Get over here!"
        case .pasteURL:
            return "Copy a download URL"
        case .diagnose:
            return "Open doctor"
        }
    }

    private var primaryActionIcon: String {
        switch model.state.primaryAction {
        case .addClipboardURL:
            return "arrow.down.circle.fill"
        case .pasteURL:
            return "doc.on.clipboard"
        case .diagnose:
            return "stethoscope"
        }
    }

    private var jobs: some View {
        Group {
            if model.state.rows.isEmpty {
                Text("No downloads.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.state.rows) { row in
                        GohMenuJobRowView(row: row, model: model)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.openTop()
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "xmark.circle")
            }
        }
    }
}

private struct GohMenuJobRowView: View {
    var row: GohMenuJobRow
    @ObservedObject var model: GohMenuViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.callout)
                        .lineLimit(1)
                    Text("\(row.stateText) · \(row.progressText) · \(row.speedText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                controls
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            if row.controls.contains(.pause) {
                Button {
                    Task { await model.pause(jobID: row.id) }
                } label: {
                    Image(systemName: "pause.fill")
                }
                .help("Pause")
            }
            if row.controls.contains(.resume) {
                Button {
                    Task { await model.resume(jobID: row.id) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .help("Resume")
            }
            if row.controls.contains(.revealInFinder) {
                Button {
                    model.reveal(destination: row.destination)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
            }
        }
        .buttonStyle(.borderless)
    }
}
```

- [ ] **Step 2: Wire the SwiftUI app**

Append the app entry point to `Sources/goh-menu/main.swift`:

```swift
@MainActor
final class GohMenuAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

@main
struct GohMenuApp: App {
    @NSApplicationDelegateAdaptor(GohMenuAppDelegate.self) private var appDelegate
    @StateObject private var model = GohMenuViewModel(
        client: LiveGohMenuClient(),
        pasteboardText: {
            NSPasteboard.general.string(forType: .string)
        },
        revealInFinder: { destination in
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: destination)])
        },
        openTerminalDashboard: {
            openTopInTerminal()
        },
        copyText: { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })

    var body: some Scene {
        MenuBarExtra {
            GohMenuView(model: model)
        } label: {
            Label("goh", systemImage: "arrow.down.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

private func openTopInTerminal() {
    let gohPath = URL(filePath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appending(path: "goh")
        .path
    let command = "\(shellQuoted(gohPath)) top"
    let script = """
    tell application "Terminal"
      activate
      do script "\(command.replacingOccurrences(of: "\"", with: "\\\""))"
    end tell
    """
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    try? process.run()
}

private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
```

- [ ] **Step 3: Build the UI target**

Run:

```bash
swift build --product goh-menu -Xswiftc -warnings-as-errors
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/GohMenuBar/GohMenuView.swift Sources/goh-menu/main.swift
git commit -m "feat: add native menu bar companion UI"
```

## Task 8: Dogfood Install And Manual Smoke

**Files:**
- Modify: `Scripts/dogfood-build.sh`
- Modify: `DESIGN.md`

- [ ] **Step 1: Install the menu bar binary in dogfood builds**

Patch `Scripts/dogfood-build.sh` after the existing `gohd` install line:

```bash
install -m 0755 "$repo_root/.build/debug/goh-menu" "$install_root/bin/goh-menu"
```

- [ ] **Step 2: Update design architecture overview**

Patch `DESIGN.md` architecture overview so it says:

```markdown
Six targets, one repository:

- **`goh`** — CLI client. Thin. Talks to `gohd` over XPC. Exits fast.
- **`gohd`** — daemon. Runs under `launchd` as a LaunchAgent. Owns the network,
  the queue, and the disk.
- **`goh-menu`** — optional private dogfood menu bar companion. Talks to `gohd`
  over the same XPC command and progress subscription surface as the CLI.
- **`GohCore`** — shared library. Transport, scheduling, persistence, hashing, auth.
- **`GohTUI`** — terminal UI module. Used by `goh top`.
- **`GohMenuBar`** — shared menu bar presentation and view-model module.
```

Mention `goh-bench` separately as a non-shipped benchmark executable if this section still needs to account for it.

- [ ] **Step 3: Run dogfood build and install**

Run:

```bash
Scripts/dogfood-build.sh
Scripts/dogfood-install.sh
```

Expected: build/install succeed and `.build/dogfood/current/bin/goh-menu` exists and is executable.

- [ ] **Step 4: Manual menu bar smoke**

Run:

```bash
export GOH_XPC_ALLOW_UNVALIDATED_PEERS=1
printf 'https://example.com/' | pbcopy
.build/dogfood/current/bin/goh-menu
```

Expected:

- a `goh` menu bar item appears;
- opening it shows **Get over here!** as the primary action;
- clicking the action adds a daemon job;
- `goh ls` shows the new job;
- completed rows expose Finder reveal;
- Quit exits the companion and leaves `gohd` running.

After the smoke, stop the companion from Activity Monitor or with:

```bash
pkill -x goh-menu || true
```

- [ ] **Step 5: Commit**

```bash
git add Scripts/dogfood-build.sh DESIGN.md
git commit -m "chore: dogfood menu bar companion"
```

## Task 9: Full Verification And PR

**Files:**
- Modify: `STATE.md`

- [ ] **Step 1: Run focused tests**

```bash
swift test --filter GohCommandClientTests
swift test --filter GohMenuPresenterTests
swift test --filter GohClipboardURLDetectorTests
swift test --filter GohMenuViewModelTests
```

Expected: all focused tests PASS.

- [ ] **Step 2: Run full package checks**

```bash
swift build -Xswiftc -warnings-as-errors
swift test
Scripts/verify-dogfood-kit.sh
```

Expected: all commands PASS.

- [ ] **Step 3: Run private dogfood acceptance**

```bash
Scripts/dogfood-acceptance.sh --timeout 45
```

Expected: private dogfood acceptance passes. The acceptance script does not need to launch `goh-menu`; the menu bar app is manually smoked because it requires a logged-in GUI session.

- [ ] **Step 4: Update STATE handoff**

Patch `STATE.md` so the next-session handoff says:

```markdown
Current branch: `feat/menu-bar-companion-mb1`.

MB1 implemented the private menu bar companion: `goh-menu` installs into the
dogfood bin directory, shows daemon state from the progress subscription, adds
clipboard URLs through `Command.add`, controls jobs through existing daemon
commands, and reveals completed files in Finder. Before merge, check CI,
CodeRabbit comments, and confirm the manual logged-in menu bar smoke result.
```

- [ ] **Step 5: Commit state**

```bash
git add STATE.md
git commit -m "docs: refresh state for menu bar companion"
```

- [ ] **Step 6: Push and open PR**

```bash
git push -u origin feat/menu-bar-companion-mb1
gh pr create --draft --title "feat: add menu bar companion" --body-file /tmp/goh-menu-pr.md
```

The PR body should include:

```markdown
## Summary
- adds a private dogfood `goh-menu` menu bar companion
- shows live daemon progress through the existing subscription surface
- adds clipboard URLs through existing daemon commands
- exposes pause/resume and Finder reveal controls without adding daemon IPC

## Verification
- `swift build -Xswiftc -warnings-as-errors`
- `swift test`
- `Scripts/verify-dogfood-kit.sh`
- `Scripts/dogfood-acceptance.sh --timeout 45`
- manual logged-in smoke: clipboard URL -> Get over here! -> `goh ls` job -> reveal in Finder -> quit companion
```

## Self-Review

- Spec coverage: The plan covers the existing companion spec's native menu bar surface, quick-add path, live job list, daemon health, pause/resume controls, Finder reveal, terminal dashboard handoff, and private dogfood posture. Notifications and launch-at-login are intentionally outside MB1 and remain future companion slices.
- Contract safety: No new daemon command, wire schema, protocol version, persistent format, or public installer behavior is introduced.
- Test coverage: Pure formatting, health mapping, clipboard detection, view-model command routing, and shared command envelope handling are unit-tested. Live UI behavior is manually smoked because it requires a logged-in macOS session.
- Product posture: The first user-visible action is **Get over here!** when a valid clipboard URL exists, which directly addresses the no-configuration quick-add path the companion is meant to provide.
