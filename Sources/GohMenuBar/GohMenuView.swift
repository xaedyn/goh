import SwiftUI

public struct GohMenuView: View {
    @ObservedObject private var model: GohMenuViewModel
    private let preferences: any GohMenuPreferences
    private let loginItem: any GohMenuLoginItem
    private let quitApplication: () -> Void
    @State private var showPreferences = false

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
        VStack(alignment: .leading, spacing: 10) {
            header
            recoveryAction
            primaryAction
            Divider()
            jobs
            Divider()
            footer
        }
        .frame(width: 380)
        .padding(12)
        .task {
            await model.refreshClipboard()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.state.healthTitle)
                    .font(.headline)
                    .lineLimit(1)

                if let detail = model.state.healthDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("\(model.state.activeCount) active · \(model.state.aggregateSpeedText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                Task { await model.refreshClipboard() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Refresh clipboard")
            .help("Refresh clipboard")
        }
    }

    @ViewBuilder
    private var recoveryAction: some View {
        if let action = model.state.recoveryAction {
            Button {
                performRecovery(action)
            } label: {
                Label(action.buttonTitle, systemImage: action.systemImageName)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(action.accessibilityLabel)
            .help(action.helpText)
        }
    }

    private var primaryAction: some View {
        Button {
            Task { await model.performPrimaryAction() }
        } label: {
            Label(
                model.state.primaryAction.buttonTitle,
                systemImage: model.state.primaryAction.systemImageName)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func performRecovery(_ action: GohMenuRecoveryAction) {
        switch action {
        case .copyCommand(let command):
            model.copy(command)
        case .openDoctor:
            model.openDoctor()
        }
    }

    private var jobs: some View {
        Group {
            if model.state.rows.isEmpty {
                Text("No downloads.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.state.rows) { row in
                            GohMenuJobRowView(row: row, model: model)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: 260)
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
            .help("Open goh top in Terminal")

            Button {
                showPreferences = true
            } label: {
                Label("Preferences…", systemImage: "gearshape")
            }
            .accessibilityLabel("Open goh preferences")
            .help("Open goh preferences")
            .sheet(isPresented: $showPreferences) {
                GohMenuPreferencesView(preferences: preferences, loginItem: loginItem)
            }

            Spacer()

            Button {
                quitApplication()
            } label: {
                Label("Quit", systemImage: "xmark.circle")
            }
            .help("Quit goh menu")
        }
    }
}

private struct GohMenuJobRowView: View {
    var row: GohMenuJobRow
    @ObservedObject var model: GohMenuViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(row.stateText) · \(row.progressText) · \(row.speedText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            controls
        }
        .frame(minHeight: 32)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            ForEach(row.orderedControls, id: \.self) { control in
                Button {
                    perform(control)
                } label: {
                    Image(systemName: control.systemImageName)
                        .frame(width: 22, height: 22)
                        .foregroundStyle(control == .remove ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(control.accessibilityLabel)
                .help(control.helpText)
            }
        }
    }

    private func perform(_ control: GohMenuControl) {
        switch control {
        case .pause:
            Task { await model.pause(jobID: row.id) }
        case .resume:
            Task { await model.resume(jobID: row.id) }
        case .remove:
            Task { await model.remove(jobID: row.id, keepPartialFile: true) }
        case .revealInFinder:
            model.reveal(destination: row.destination)
        case .copyURL:
            model.copy(row.url)
        case .copyDestination:
            model.copy(row.destination)
        }
    }
}

extension GohMenuRecoveryAction {
    nonisolated var buttonTitle: String {
        switch self {
        case .copyCommand:
            return "Copy recovery command"
        case .openDoctor:
            return "Open doctor"
        }
    }

    nonisolated var systemImageName: String {
        switch self {
        case .copyCommand:
            return "doc.on.doc"
        case .openDoctor:
            return "stethoscope"
        }
    }

    nonisolated var accessibilityLabel: String {
        buttonTitle
    }

    nonisolated var helpText: String {
        switch self {
        case .copyCommand:
            return "Copy recovery command"
        case .openDoctor:
            return "Open goh doctor in Terminal"
        }
    }
}

extension GohMenuPrimaryAction {
    nonisolated var buttonTitle: String {
        switch self {
        case .addClipboardURL:
            return "Download clipboard URL"
        case .pasteURL:
            return "Copy a download URL"
        case .diagnose:
            return "Open doctor"
        }
    }

    nonisolated var systemImageName: String {
        switch self {
        case .addClipboardURL:
            return "arrow.down.circle.fill"
        case .pasteURL:
            return "doc.on.clipboard"
        case .diagnose:
            return "stethoscope"
        }
    }
}

extension GohMenuControl {
    nonisolated var systemImageName: String {
        switch self {
        case .pause:
            return "pause.fill"
        case .resume:
            return "play.fill"
        case .remove:
            return "trash"
        case .revealInFinder:
            return "folder"
        case .copyURL:
            return "link"
        case .copyDestination:
            return "doc.on.doc"
        }
    }

    nonisolated var helpText: String {
        switch self {
        case .pause:
            return "Pause"
        case .resume:
            return "Resume"
        case .remove:
            return "Remove job, keep file"
        case .revealInFinder:
            return "Reveal in Finder"
        case .copyURL:
            return "Copy URL"
        case .copyDestination:
            return "Copy destination"
        }
    }

    nonisolated var accessibilityLabel: String {
        helpText
    }
}

private extension GohMenuJobRow {
    var orderedControls: [GohMenuControl] {
        [
            .pause,
            .resume,
            .revealInFinder,
            .copyURL,
            .copyDestination,
            .remove,
        ].filter { controls.contains($0) }
    }
}
