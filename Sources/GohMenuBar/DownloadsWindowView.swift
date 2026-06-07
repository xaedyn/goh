import AppKit
import SwiftUI

/// The full Downloads dashboard window. Receives the live state from
/// GohMenuViewModel (same @Published state as the popover). One rich row per job.
public struct DownloadsWindowView: View {
    @ObservedObject private var model: GohMenuViewModel

    public init(model: GohMenuViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.state.rows.isEmpty {
                Text("No downloads yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.state.rows) { row in
                            DownloadRowView(row: row, model: model)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 200)
    }
}

private struct DownloadRowView: View {
    var row: GohMenuJobRow
    @ObservedObject var model: GohMenuViewModel
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: fileTypeIcon(for: row.title))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(row.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isHovered {
                    hoverControls
                }
            }
            if let fraction = row.progressFraction {
                ProgressView(value: fraction)
                    .accessibilityLabel("Download progress \(Int(fraction * 100))%")
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Download progress unknown")
            }
            Text(secondaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var secondaryText: String {
        var parts: [String] = []
        if row.stateText == "Paused" { parts.append("Paused") }
        parts.append(row.sizeText)
        if let eta = row.etaText { parts.append("ETA \(eta)") }
        if let elapsed = row.elapsedText { parts.append(elapsed) }
        if let conn = row.connectionText { parts.append(conn) }
        if let verify = row.verifyStatus { parts.append(verify) }
        return parts.joined(separator: " · ")
    }

    private var hoverControls: some View {
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

    private func fileTypeIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar": return "doc.zipper"
        case "iso", "dmg", "img": return "opticaldiscdrive"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "mp3", "m4a", "flac", "aac": return "music.note"
        case "pdf": return "doc.richtext"
        default: return "doc"
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
