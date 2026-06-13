import AppKit
import Combine
import Foundation
import ServiceManagement
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
        let validationMode = validationMode
        return GohMenuProgressStream.snapshots {
            try Self.makeSubscription(validationMode: validationMode)
                .progressSubscription()
        }
    }

    func add(_ request: AddRequest) async throws -> JobSummary {
        do {
            return try await Self.sendOneShot(
                .add(request: request),
                expecting: JobSummary.self,
                validationMode: validationMode)
        } catch {
            throw Self.map(error)
        }
    }

    func pause(jobID: UInt64) async throws {
        do {
            let _: JobSummary = try await Self.sendOneShot(
                .pause(jobID: jobID),
                expecting: JobSummary.self,
                validationMode: validationMode)
        } catch {
            throw Self.map(error)
        }
    }

    func resume(jobID: UInt64) async throws {
        do {
            let _: JobSummary = try await Self.sendOneShot(
                .resume(jobID: jobID),
                expecting: JobSummary.self,
                validationMode: validationMode)
        } catch {
            throw Self.map(error)
        }
    }

    func remove(jobID: UInt64, keepPartialFile: Bool) async throws {
        do {
            let _: RmReply = try await Self.sendOneShot(
                .rm(request: RmRequest(
                    jobID: jobID,
                    keepPartialFile: keepPartialFile)),
                expecting: RmReply.self,
                validationMode: validationMode)
        } catch {
            throw Self.map(error)
        }
    }

    func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry]) async throws {
        do {
            // .ack reply has no payload; send as a fire-and-forget one-shot.
            // The daemon returns .ack; we decode it as AckReply (a void-like Codable type).
            _ = try await Self.sendOneShot(
                .recordVerifiedProvenance(
                    request: RecordVerifiedProvenanceRequest(entries: entries)),
                expecting: AckReply.self,
                validationMode: validationMode)
        } catch {
            throw Self.map(error)
        }
    }

    func ls() async throws -> LsReply {
        do {
            return try await Self.sendOneShot(
                .ls,
                expecting: LsReply.self,
                validationMode: validationMode)
        } catch {
            throw Self.map(error)
        }
    }

    func forget(paths: [String]) async throws {
        do {
            let _: ForgetProvenanceReply = try await Self.sendOneShot(
                .forgetProvenance(request: ForgetProvenanceRequest(paths: paths)),
                expecting: ForgetProvenanceReply.self,
                validationMode: validationMode)
        } catch {
            throw Self.map(error)
        }
    }

    private nonisolated static func makeSubscription(
        validationMode: PeerValidationMode
    ) throws -> LiveProgressSubscription {
        let inbox = GohXPCNotificationInbox()
        let session = try makeSession(inbox: inbox, validationMode: validationMode)
        return LiveProgressSubscription(inbox: inbox, session: session)
    }

    private nonisolated static func makeSession(
        inbox: GohXPCNotificationInbox,
        validationMode: PeerValidationMode
    ) throws -> GohProgressSubscriptionSession {
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

    private nonisolated static func sendOneShot<Reply: Codable & Sendable>(
        _ command: Command,
        expecting _: Reply.Type,
        validationMode: PeerValidationMode
    ) async throws -> Reply {
        try await Task.detached {
            let client = try GohXPCClient(
                machServiceName: GohXPCService.machServiceName,
                mode: validationMode)
            defer { client.cancel() }

            return try GohCommandClient { request in
                try client.sendSync(request)
            }
            .send(command, expecting: Reply.self)
        }.value
    }

    private nonisolated static func map(_ error: any Error) -> GohMenuError {
        GohMenuErrorMapper.map(error)
    }
}

/// @unchecked Sendable invariant: this private wrapper contains the synchronized
/// XPC notification inbox and the XPC session closure bundle. The baseline send
/// and blocking receive happen on the stream worker off the MainActor, while
/// cancellation may race intentionally with setup/receive and is routed through
/// the inbox interrupt plus session cancel hooks.
nonisolated private final class LiveProgressSubscription: @unchecked Sendable {
    private let inbox: GohXPCNotificationInbox
    private let session: GohProgressSubscriptionSession

    init(
        inbox: GohXPCNotificationInbox,
        session: GohProgressSubscriptionSession
    ) {
        self.inbox = inbox
        self.session = session
    }

    func sendSync(_ request: XPCDictionary) throws -> XPCDictionary {
        try session.sendSync(request)
    }

    func receive() throws -> GohEnvelope<ProgressEvent> {
        try session.receiveNotification()
    }

    func cancel() {
        inbox.interrupt()
        session.cancel()
    }

    func progressSubscription() -> GohMenuProgressSubscription {
        GohMenuProgressSubscription(
            sendSync: { [self] request in
                try sendSync(request)
            },
            receiveNotification: { [self] in
                try receive()
            },
            cancel: { [self] in
                cancel()
            })
    }
}

@MainActor
final class GohMenuAppDelegate: NSObject, NSApplicationDelegate {
    /// Resolved once at startup; passed to both GohMenuViewModel and the Trust window.
    /// Resolves to the canonical provenance.plist path without creating the directory
    /// (`create: false` — the daemon owns creation). Falls back to "" on resolution
    /// failure, causing LiveProvenanceReader to return .absent gracefully.
    let provenancePath: String = {
        (try? ProvenanceStoreLocation.defaultURL(create: false))?.path ?? ""
    }()

    let model: GohMenuViewModel
    let preferences: UserDefaultsMenuPreferences = UserDefaultsMenuPreferences()
    /// Shared client for both the menu view model and TrustWindowViewModel.
    /// Stored as a let so the Window @autoclosure can reference it without
    /// constructing a new instance per evaluation.
    let menuClientForTrust: LiveGohMenuClient

    override init() {
        let menuClient = LiveGohMenuClient()
        self.menuClientForTrust = menuClient
        self.model = GohMenuViewModel(
            client: menuClient,
            restarter: LaunchctlDaemonRestarter(
                machServiceName: GohXPCService.machServiceName),
            pasteboardText: { NSPasteboard.general.string(forType: .string) },
            revealInFinder: { destination in
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: destination)])
            },
            openTerminalDashboard: { openTopInTerminal() },
            openDoctor: { openDoctorInTerminal() },
            copyText: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            trustReader: LiveProvenanceReader(path: provenancePath))
        super.init()
    }
    let notificationService: LiveNotificationService = LiveNotificationService()
    let loginItem: any GohMenuLoginItem = GohMenuAppDelegate.makeLoginItem()
    private lazy var coordinator = GohNotificationCoordinator(preferences: preferences)
    /// Owns the menu-bar status item + popover (created at launch).
    private var statusItemController: GohStatusItemController?

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

        // The menu-bar status item (wordmark icon + popover).
        statusItemController = GohStatusItemController(
            model: model,
            preferences: preferences,
            loginItem: loginItem,
            quit: { NSApplication.shared.terminate(nil) })
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

/// Live implementation of ProvenanceReading — reads provenance.plist directly.
/// Unsandboxed; same access pattern as the CLI (goh which / goh verify --all).
/// Read-only: never calls record/recordVerified.
nonisolated private struct LiveProvenanceReader: ProvenanceReading, @unchecked Sendable {
    private let path: String

    init(path: String) { self.path = path }

    nonisolated func read() -> ProvenanceReadOutcome {
        ProvenanceLedgerReader.read(at: path)
    }
}

/// Owns TrustWindowViewModel via @StateObject so it is built exactly once and its state
/// persists across scene re-evaluation.
struct TrustWindowRoot: View {
    @StateObject private var viewModel: TrustWindowViewModel

    init(makeViewModel: @autoclosure @escaping () -> TrustWindowViewModel) {
        _viewModel = StateObject(wrappedValue: makeViewModel())
    }

    var body: some View {
        TrustWindowView(viewModel: viewModel, onAttest: { openAttestInTerminal() })
    }
}

/// Passes the shared GohMenuViewModel (owned by the app delegate) into DownloadsWindowView.
/// Uses @ObservedObject — not @StateObject — because the model is owned externally.
struct DownloadsWindowRoot: View {
    @ObservedObject private var model: GohMenuViewModel

    init(model: GohMenuViewModel) { self.model = model }

    var body: some View {
        DownloadsWindowView(model: model)
    }
}

/// Owns the menu-bar `NSStatusItem` and the popover. The `goh` wordmark is drawn
/// as the status button's *image* — driven by the view-model's download lifecycle
/// — and a click toggles a transient `NSPopover` hosting the existing
/// `GohMenuView`.
///
/// Why an image and not a hosted SwiftUI view: an `NSHostingView` placed on the
/// status button consumes the mouse event before it reaches the button's action,
/// so the click never registers (confirmed empirically). Drawing the icon as
/// `button.image` keeps the standard, reliable click path. (Drag-a-URL-onto-the-
/// icon is deferred for the same reason — it needs a drag overlay that doesn't
/// intercept the click — and the completion bloom animation is likewise a
/// follow-up; the icon currently updates per steady state.)
@MainActor
final class GohStatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let model: GohMenuViewModel
    private let preferences: any GohMenuPreferences
    private var cancellable: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?

    init(
        model: GohMenuViewModel,
        preferences: any GohMenuPreferences,
        loginItem: any GohMenuLoginItem,
        quit: @escaping () -> Void
    ) {
        self.model = model
        self.preferences = preferences
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: GohMenuView(
                model: model,
                preferences: preferences,
                loginItem: loginItem,
                quitApplication: quit))

        super.init()

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover)
        }
        updateIcon()

        // Re-render the icon whenever the view-model changes (active count, health).
        cancellable = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }

        // The button's effectiveAppearance isn't final until it settles into the
        // menu bar; re-render then (and on any light/dark change) so the first
        // paint isn't a low-contrast render against the wrong appearance.
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
        Task { @MainActor [weak self] in self?.updateIcon() }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Re-check the clipboard on every open. The popover's SwiftUI `.task`
            // does not reliably re-fire across NSPopover show/hide (the hosting
            // view isn't re-created), so drive the refresh from the show path —
            // this is the on-open clipboard detection that used to hang off the
            // MenuBarExtra menu's lifecycle.
            Task { await model.refreshClipboard() }
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = Self.wordmarkImage(for: currentState(), appearance: button.effectiveAppearance)
    }

    private func currentState() -> GohWordmarkState {
        if case .failed = model.state.health { return .error }
        // "Show progress on the icon" pref: when off, the icon stays neutral
        // regardless of activity (errors still surface).
        guard preferences.showProgressOnIcon else { return .idle }
        if model.state.activeCount > 0 { return .active }
        if model.state.rows.contains(where: { $0.displayState == .paused }) { return .paused }
        return .idle
    }

    /// Renders the `goh` wordmark (letters in the menu-bar label color + a
    /// state-tinted arrow) to a colored, menu-bar-sized image. Non-template so the
    /// arrow keeps its brand green.
    private static func wordmarkImage(for state: GohWordmarkState, appearance: NSAppearance) -> NSImage {
        let height: CGFloat = 15
        let size = NSSize(width: (height * GohWordmark.aspectRatio).rounded(), height: height)

        // Resolve the dynamic colors against the menu bar's appearance.
        var lettersColor = NSColor.labelColor
        var arrowColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            lettersColor = NSColor.labelColor.usingColorSpace(.sRGB) ?? .white
            switch state {
            case .idle:
                arrowColor = nil
            case .active, .done:
                arrowColor = GohTheme.accentNSColor.usingColorSpace(.sRGB)
            case .paused:
                arrowColor = GohTheme.accentNSColor.usingColorSpace(.sRGB)?.withAlphaComponent(0.45)
            case .error:
                arrowColor = NSColor.systemRed.usingColorSpace(.sRGB)
            }
        }

        let lettersImage = tinted(GohWordmark.letters, lettersColor, size)
        let arrowImage = arrowColor.map { tinted(GohWordmark.arrow, $0, size) }

        let image = NSImage(size: size)
        image.lockFocus()
        lettersImage.draw(in: NSRect(origin: .zero, size: size))
        arrowImage?.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Tints a template image with a solid color (the glyph shape in `color`).
    private static func tinted(_ template: NSImage, _ color: NSColor, _ size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        template.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}

@main
struct GohMenuApp: App {
    @NSApplicationDelegateAdaptor(GohMenuAppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu-bar status item itself is an AppKit NSStatusItem owned by the
        // app delegate (see GohStatusItemController) — it needs a colored/animated
        // icon and a drag destination, which MenuBarExtra's label cannot provide.
        // These Window scenes remain SwiftUI; the popover opens them via openWindow.

        Window("Add Download", id: "add-download") {
            AddDownloadWindowRoot(
                makeViewModel: appDelegate.model.makeAddDownloadViewModel(
                    folderPicker: NSOpenPanelFolderPicker()))
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)

        Window("Trust", id: "trust") {
            TrustWindowRoot(
                makeViewModel: TrustWindowViewModel(
                    reader: LiveProvenanceReader(path: appDelegate.provenancePath),
                    provenanceStorePath: appDelegate.provenancePath,
                    probe: LiveFileStatProbe(),
                    client: appDelegate.menuClientForTrust))  // shared stored let
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)

        Window("Downloads", id: "downloads") {
            DownloadsWindowRoot(model: appDelegate.model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 600, height: 400)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)

        Window("goh Settings", id: "preferences") {
            GohMenuPreferencesView(
                preferences: appDelegate.preferences,
                loginItem: appDelegate.loginItem)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
    }
}

private func openTopInTerminal() {
    openGohCommandInTerminal(.top)
}

private func openDoctorInTerminal() {
    openGohCommandInTerminal(.doctor)
}

private func openAttestInTerminal() {
    openGohCommandInTerminal(.attest)
}

private func openGohCommandInTerminal(_ terminalCommand: GohTerminalCommand) {
    let command = GohTerminalCommandBuilder(
        companionExecutablePath: CommandLine.arguments[0],
        environment: ProcessInfo.processInfo.environment)
        .command(for: terminalCommand)
    let launcher = TerminalLauncher.preferred(in: NSWorkspaceTerminalDiscovery())
    let invocation = launcher.invocation(for: command)
    let process = Process()
    process.executableURL = URL(filePath: invocation.executablePath)
    process.arguments = invocation.arguments
    do {
        try process.run()
    } catch {
        fputs("goh-menu: could not open terminal via \(launcher.rawValue): \(error)\n", stderr)
    }
}
