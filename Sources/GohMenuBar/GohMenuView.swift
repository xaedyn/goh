import AppKit
import SwiftUI

/// The menu-bar popover. A thin wrapper that owns the live `GohMenuViewModel` and
/// forwards its published state into the pure, data-driven `PopoverContent` — so
/// the redesign's presentation is decoupled from the model and renderable from
/// sample data in the snapshot harness. The public init is unchanged; the app's
/// scene graph binds exactly as before.
public struct GohMenuView: View {
    @ObservedObject private var model: GohMenuViewModel
    private let preferences: any GohMenuPreferences
    private let loginItem: any GohMenuLoginItem
    private let quitApplication: () -> Void
    @Environment(\.openWindow) private var openWindow

    public init(
        model: GohMenuViewModel,
        preferences: any GohMenuPreferences = UserDefaultsMenuPreferences(),
        loginItem: any GohMenuLoginItem = UnsupportedLoginItem(),
        quitApplication: @escaping () -> Void
    ) {
        self.model = model
        self.preferences = preferences
        self.loginItem = loginItem
        self.quitApplication = quitApplication
    }

    public var body: some View {
        PopoverContent(
            state: model.state,
            trust: model.trustOverview,
            daemonSkew: model.daemonSkew,
            clipboardURL: clipboardURL,
            actions: actions)
            .task { await model.refreshClipboard() }
    }

    /// The detected pasteboard URL, surfaced by the presenter as the primary action.
    private var clipboardURL: URL? {
        if case .addClipboardURL(let url) = model.state.primaryAction { return url }
        return nil
    }

    private var actions: PopoverActions {
        PopoverActions(
            performPrimary: { Task { await model.performPrimaryAction() } },
            pause: { row in Task { await model.pause(jobID: row.id) } },
            resume: { row in Task { await model.resume(jobID: row.id) } },
            remove: { row in Task { await model.remove(jobID: row.id, keepPartialFile: true) } },
            retry: { row in Task { await model.retry(url: row.url) } },
            copy: { model.copy($0) },
            reveal: { model.reveal(destination: $0) },
            open: { openFile($0) },
            openAddDownload: { openManagedWindow("add-download") },
            openDownloadsFolder: { openDownloadsFolder() },
            openAllDownloads: { openManagedWindow("downloads") },
            openTrust: { openManagedWindow("trust") },
            openTerminal: { model.openTop() },
            openSettings: { openManagedWindow("preferences") },
            quit: quitApplication,
            recover: { performRecovery($0) },
            restartDaemon: { Task { await model.restartDaemon() } })
    }

    private func openManagedWindow(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }

    private func openFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func openDownloadsFolder() {
        let url = (try? FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Downloads")
        NSWorkspace.shared.open(url)
    }

    private func performRecovery(_ action: GohMenuRecoveryAction) {
        switch action {
        case .copyCommand(let command):
            model.copy(command)
        case .openDoctor:
            model.openDoctor()
        }
    }
}
