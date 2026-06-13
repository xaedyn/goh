import GohCore
import SwiftUI

/// The Add Download window — a native grouped `Form` (the macOS way to present a
/// short input window). Rebinds the existing `AddDownloadViewModel` (URL,
/// destination, automatic / connection count, error). The window title + traffic
/// lights come from the hosting `Window` scene; this view supplies the form +
/// the Cancel / Add action bar.
public struct AddDownloadView: View {
    @ObservedObject private var vm: AddDownloadViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var urlFocused: Bool

    public init(vm: AddDownloadViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("URL") {
                    TextField("https://", text: $vm.urlText)
                        .focused($urlFocused)
                        .accessibilityLabel("Download URL")
                }

                Section("Destination") {
                    LabeledContent("Save to") { saveToMenu }
                }

                Section {
                    Toggle(isOn: $vm.automaticConnections) {
                        Text("Automatic connections")
                        Text("Learns the best count per host")
                    }
                    .tint(GohTheme.accent)
                    .accessibilityLabel("Automatic connection count")

                    if !vm.automaticConnections {
                        Stepper(value: $vm.connectionCount, in: 1...16) {
                            LabeledContent("Connections", value: "\(vm.connectionCount)")
                        }
                        .accessibilityLabel("Connection count \(vm.connectionCount)")
                    }
                } footer: {
                    Label("Hashed in-flight and recorded to your ledger on completion.",
                          systemImage: "checkmark.seal")
                }

                if let errorText = vm.errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(GohTheme.error)
                            .accessibilityLabel("Error: \(errorText)")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

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
            .padding(14)
        }
        .frame(width: 400, height: 440)
    }

    // MARK: Destination chooser

    private var saveToMenu: some View {
        Menu {
            Button { vm.useDefaultFolder() } label: { Label("Downloads", systemImage: "folder") }
            Button { Task { await vm.chooseFolder() } } label: { Label("Choose Folder…", systemImage: "folder.badge.plus") }
        } label: {
            Label(folderName, systemImage: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Choose destination folder")
    }

    private var folderName: String {
        guard let folder = vm.chosenFolder else { return "Downloads" }
        let name = URL(fileURLWithPath: folder).lastPathComponent
        return name.isEmpty ? folder : name
    }
}
