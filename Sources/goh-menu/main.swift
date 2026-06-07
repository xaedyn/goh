import AppKit
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

@main
struct GohMenuApp: App {
    @NSApplicationDelegateAdaptor(GohMenuAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            GohMenuView(
                model: appDelegate.model,
                preferences: appDelegate.preferences,
                loginItem: appDelegate.loginItem,
                quitApplication: { NSApplication.shared.terminate(nil) })
        } label: {
            Label("goh", systemImage: "arrow.down.circle")
        }
        .menuBarExtraStyle(.window)

        Window("Add Download", id: "add-download") {
            AddDownloadWindowRoot(
                makeViewModel: appDelegate.model.makeAddDownloadViewModel(
                    folderPicker: NSOpenPanelFolderPicker()))
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private func openTopInTerminal() {
    openGohCommandInTerminal(.top)
}

private func openDoctorInTerminal() {
    openGohCommandInTerminal(.doctor)
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
