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
