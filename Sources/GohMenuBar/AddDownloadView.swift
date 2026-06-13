import GohCore
import SwiftUI

/// The Add Download window — a grouped form on a translucent Liquid Glass window.
/// Rebinds the existing `AddDownloadViewModel` (URL, destination, automatic /
/// connection count, error). The window title + traffic lights come from the
/// hosting `Window` scene; this view supplies the grouped content.
public struct AddDownloadView: View {
    @ObservedObject private var vm: AddDownloadViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var urlFocused: Bool

    public init(vm: AddDownloadViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            urlCard
            settingsCard
            reassurance
            if let errorText = vm.errorText {
                Text(errorText)
                    .font(GohTheme.Typography.secondary)
                    .foregroundStyle(GohTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(errorText)")
            }
            footer
        }
        .padding(16)
        .frame(width: 340)
        .containerBackground(.thinMaterial, for: .window)
    }

    // MARK: URL

    private var urlCard: some View {
        GohModuleCard {
            VStack(alignment: .leading, spacing: 7) {
                Text("URL")
                    .font(GohTheme.Typography.groupLabel)
                    .foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    Image(systemName: "link")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("https://", text: $vm.urlText)
                        .textFieldStyle(.plain)
                        .focused($urlFocused)
                        .accessibilityLabel("Download URL")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            urlFocused ? GohTheme.accent : GohTheme.separator,
                            lineWidth: urlFocused ? 2 : GohTheme.Metrics.hairline))
            }
        }
    }

    // MARK: Save to + Connections

    private var settingsCard: some View {
        GohModuleCard(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Save to").font(GohTheme.Typography.rowTitle)
                    Spacer(minLength: 8)
                    saveToMenu
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                hairline

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connections").font(GohTheme.Typography.rowTitle)
                        Text("Automatic — learns the best count per host")
                            .font(GohTheme.Typography.secondary)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $vm.automaticConnections)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(GohTheme.accent)
                        .accessibilityLabel("Automatic connection count")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                if !vm.automaticConnections {
                    hairline
                    HStack {
                        Text("Number of connections").font(GohTheme.Typography.rowTitle)
                        Spacer(minLength: 8)
                        Stepper(value: $vm.connectionCount, in: 1...16) {
                            Text("\(vm.connectionCount)").monospacedDigit()
                        }
                        .accessibilityLabel("Connection count \(vm.connectionCount)")
                        .fixedSize()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var saveToMenu: some View {
        Menu {
            Button { vm.useDefaultFolder() } label: { Label("Downloads", systemImage: "folder") }
            Button { Task { await vm.chooseFolder() } } label: { Label("Choose folder…", systemImage: "folder.badge.plus") }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: 11))
                Text(folderName).font(GohTheme.Typography.rowTitle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Choose destination folder")
    }

    private var folderName: String {
        guard let folder = vm.chosenFolder else { return "Downloads" }
        let name = URL(fileURLWithPath: folder).lastPathComponent
        return name.isEmpty ? folder : name
    }

    // MARK: Reassurance + footer

    private var reassurance: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 13))
                .foregroundStyle(GohTheme.accent)
            Text("Hashed in-flight and recorded to your ledger on completion.")
                .font(GohTheme.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel add download")
            Button {
                Task { if await vm.submit() { dismiss() } }
            } label: {
                Label("Add", systemImage: "arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(GohTheme.accent)
            .controlSize(.large)
            .disabled(!vm.canAdd)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Add download")
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(GohTheme.separator)
            .frame(height: GohTheme.Metrics.hairline)
    }
}
