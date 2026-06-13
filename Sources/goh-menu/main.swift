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

/// The status item's content view: it **draws** the wordmark icon itself (an
/// NSImage rendered per state by the controller) and handles both the click
/// (`mouseDown` → toggle) and the URL drop target. A plain drawing NSView — unlike
/// an `NSHostingView` (SwiftUI), which consumes the mouse event before AppKit
/// dispatch — receives `mouseDown` normally as the hit-test target, so it can own
/// clicks *and* be a drag destination (a transparent overlay can't: a `hitTest`-nil
/// view receives neither clicks nor drags).
@MainActor
final class GohStatusItemView: NSView {
    var onClick: () -> Void = {}
    var onDropURL: (URL) -> Void = { _ in }
    private var iconImage: NSImage?
    private var dragTargeted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "goh"
        registerForDraggedTypes([.URL, .string])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setIcon(_ image: NSImage) {
        iconImage = image
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if dragTargeted {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 5, yRadius: 5).fill()
        }
        guard let iconImage else { return }
        let s = iconImage.size
        iconImage.draw(in: NSRect(
            x: ((bounds.width - s.width) / 2).rounded(),
            y: ((bounds.height - s.height) / 2).rounded(),
            width: s.width, height: s.height))
    }

    override func mouseDown(with event: NSEvent) { onClick() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard droppedURL(from: sender) != nil else { return [] }
        dragTargeted = true
        toolTip = "Drop to download with goh"
        needsDisplay = true
        return .copy
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { resetDrag() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { resetDrag() }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        resetDrag()
        guard let url = droppedURL(from: sender) else { return false }
        onDropURL(url)
        return true
    }

    private func resetDrag() {
        dragTargeted = false
        toolTip = "goh"
        needsDisplay = true
    }

    /// The first HTTP(S) URL on the drag pasteboard (NSURL or a string that parses).
    private func droppedURL(from sender: any NSDraggingInfo) -> URL? {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first(where: { $0.scheme == "http" || $0.scheme == "https" }) {
            return url
        }
        if let string = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: string), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        return nil
    }
}

/// A borderless, non-activating floating panel for the menu-bar content — the
/// macOS 26 Control-Center look (detached rounded rectangle below the bar, no
/// NSPopover beak). Borderless windows can't become key by default; we override
/// so the panel can receive keyboard input (Esc to dismiss) and SwiftUI clicks.
final class GohMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the menu-bar `NSStatusItem` and the floating panel. The `goh` wordmark is
/// drawn by a custom `GohStatusItemView` (so it owns clicks *and* a URL drop
/// target), driven by the view-model's download lifecycle; a click toggles a
/// borderless `GohMenuPanel` (no beak) hosting the existing `GohMenuView`,
/// dismissed by click-outside / Esc / app-deactivate. (Completion bloom is next.)
@MainActor
final class GohStatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private var panel: GohMenuPanel!
    private let model: GohMenuViewModel
    private let preferences: any GohMenuPreferences
    private let statusView = GohStatusItemView(frame: .zero)
    private var cancellable: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?
    /// Local + global event monitors for click-outside / Esc dismissal (installed
    /// while the panel is open). The borderless panel has no NSPopover transient
    /// auto-dismiss, so we drive it ourselves.
    private var eventMonitors: [Any] = []
    /// The popover content, built once and re-parented between the glass and solid
    /// surfaces as the system reduce-transparency setting toggles.
    private let contentHost: NSHostingView<GohMenuView>
    /// The live Liquid Glass surface, or nil while the reduce-transparency solid
    /// fallback is installed. Held for the on-show backdrop-refresh nudge.
    private var glassView: NSGlassEffectView?
    /// Observes system reduce-transparency changes so the panel swaps its surface
    /// live (no relaunch needed). Retained for the controller's (app-)lifetime —
    /// the status item lives until quit, so the observation needs no teardown.
    private var reduceTransparencyObserver: NSObjectProtocol?

    init(
        model: GohMenuViewModel,
        preferences: any GohMenuPreferences,
        loginItem: any GohMenuLoginItem,
        quit: @escaping () -> Void
    ) {
        self.model = model
        self.preferences = preferences
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        contentHost = NSHostingView(rootView: GohMenuView(
            model: model,
            preferences: preferences,
            loginItem: loginItem,
            quitApplication: quit))

        super.init()

        panel = Self.makePanel()
        installContentSurface()
        reduceTransparencyObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.installContentSurface() }
        }

        if let button = statusItem.button {
            statusView.onClick = { [weak self] in self?.togglePopover() }
            statusView.onDropURL = { [weak self] url in
                guard let self else { return }
                Task { await self.model.addDownload(url: url.absoluteString) }
            }
            button.addSubview(statusView)
            statusView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                statusView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                statusView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                statusView.topAnchor.constraint(equalTo: button.topAnchor),
                statusView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            // Fallback in case AppKit routes the click to the button rather than the view.
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

    /// Builds the borderless floating panel window — clear background so its glass
    /// surface can sample the desktop, continuous rounded corners, soft shadow. The
    /// content surface itself is installed by `installContentSurface()`.
    private static func makePanel() -> GohMenuPanel {
        // A titled window with a hidden/transparent titlebar + full-size content —
        // NOT `.borderless`, which composites unreliably (isVisible true, correct
        // frame, but no pixels) with an NSHostingController.
        let panel = GohMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        // NOT hidesOnDeactivate: an accessory app doesn't reliably stay active after
        // the panel shows, so it would hide immediately. Dismissal is driven by the
        // click-outside / Esc event monitors instead.
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        return panel
    }

    /// Installs the popover content on the panel's surface, honoring the system
    /// **Reduce Transparency** setting: real macOS 26 Liquid Glass
    /// (`NSGlassEffectView`, which lenses/refracts the desktop behind the clear
    /// panel — a frosted NSVisualEffectView can't) when transparency is allowed, or
    /// a solid opaque surface when the user has reduced it. Re-invoked live when the
    /// setting toggles. The content view is set directly (NOT via
    /// contentViewController, which collapses a no-intrinsic-size view to 0×0).
    private func installContentSurface() {
        contentHost.removeFromSuperview()
        let surface: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView()
            solid.wantsLayer = true
            solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            solid.layer?.cornerRadius = 14
            solid.layer?.cornerCurve = .continuous
            solid.layer?.masksToBounds = true
            contentHost.translatesAutoresizingMaskIntoConstraints = false
            solid.addSubview(contentHost)
            NSLayoutConstraint.activate([
                contentHost.leadingAnchor.constraint(equalTo: solid.leadingAnchor),
                contentHost.trailingAnchor.constraint(equalTo: solid.trailingAnchor),
                contentHost.topAnchor.constraint(equalTo: solid.topAnchor),
                contentHost.bottomAnchor.constraint(equalTo: solid.bottomAnchor),
            ])
            glassView = nil
            surface = solid
        } else {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 14
            glass.style = .regular
            contentHost.translatesAutoresizingMaskIntoConstraints = true
            glass.contentView = contentHost
            glassView = glass
            surface = glass
        }
        panel.contentView = surface
    }

    @objc private func togglePopover() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        // Re-check the clipboard on every open (the on-open detection that used to
        // hang off the MenuBarExtra menu's lifecycle).
        Task { await model.refreshClipboard() }

        // Size the panel to the SwiftUI content.
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 346, height: 400)
        panel.setContentSize(size)

        // Detached, right-aligned under the status item, ~7px below the bar,
        // clamped on-screen.
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let gap: CGFloat = 7
        var origin = NSPoint(x: buttonFrame.maxX - size.width, y: buttonFrame.minY - gap - size.height)
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrameOrigin(origin)

        // Activate the app so the window server composites the panel onto the
        // active space (an inactive accessory app's panel isn't displayed).
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // macOS 26.2: a non-movable borderless window's NSGlassEffectView can cache
        // its backdrop and fail to re-sample when content moves beneath it (Apple
        // Forums 810314). Nudge a redisplay on show so the glass re-samples the
        // current desktop. (If stale glass persists on 26.2, the heavier fix is a
        // movable window or a frame jitter — escalate only if observed live.)
        glassView?.needsDisplay = true
        glassView?.displayIfNeeded()
        installEventMonitors()
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeEventMonitors()
    }

    /// Click-outside / Esc dismissal — the borderless panel has no NSPopover
    /// transient behavior, so we monitor events while it's open.
    private func installEventMonitors() {
        removeEventMonitors()
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.hidePanel(); return nil }   // Esc
                return event
            }
            // Mouse down inside the panel or on the status item → not a dismiss
            // (the status item's own click toggles).
            let point = NSEvent.mouseLocation
            if self.panel.frame.contains(point) { return event }
            if let button = self.statusItem.button, let window = button.window,
               window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) {
                return event
            }
            self.hidePanel()
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
        eventMonitors = [local, global].compactMap { $0 }
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors = []
    }

    // MARK: Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let image = Self.wordmarkImage(for: currentState(), appearance: button.effectiveAppearance)
        statusView.setIcon(image)
        // Size the status item to the icon so the custom view (and its click/drop
        // area) has a defined width.
        statusItem.length = image.size.width + 14
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
