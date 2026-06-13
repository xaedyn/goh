import AppKit
import GohCore
import SwiftUI

/// A leading badge — an SF Symbol on a tinted rounded square — for a Downloads row.
private struct RowBadge: View {
    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// An in-progress row in the Downloads window: file-type badge, name, static
/// accent progress bar with a circular control, and a size/speed/ETA line.
public struct DownloadsActiveRow: View {
    let row: GohMenuJobRow
    @ObservedObject var model: GohMenuViewModel

    public init(row: GohMenuJobRow, model: GohMenuViewModel) {
        self.row = row
        self.model = model
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 11) {
            RowBadge(systemName: fileTypeIcon(row.title), tint: GohTheme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(row.title)
                    .font(GohTheme.Typography.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    GohProgressBar(fraction: row.progressFraction ?? 0, paused: row.isPaused)
                    control
                }
                Text(statsLine)
                    .font(GohTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .contextMenu { activeMenu }
    }

    @ViewBuilder
    private var control: some View {
        switch row.displayState {
        case .active:
            GohCircularControl(systemName: "pause.fill", help: "Pause") {
                Task { await model.pause(jobID: row.id) }
            }
        case .paused:
            GohCircularControl(systemName: "play.fill", tint: GohTheme.accent, help: "Resume") {
                Task { await model.resume(jobID: row.id) }
            }
        case .queued:
            GohCircularControl(systemName: "play.fill", help: "Start") {
                Task { await model.resume(jobID: row.id) }
            }
        case .completed, .failed:
            EmptyView()
        }
    }

    private var statsLine: String {
        switch row.displayState {
        case .queued:
            return "Waiting…"
        case .paused:
            return "Paused · \(row.sizeText)"
        default:
            var parts = [row.sizeText, row.speedText]
            if let eta = row.etaText { parts.append("\(eta) left") }
            return parts.filter { !$0.isEmpty }.joined(separator: " — ")
        }
    }

    @ViewBuilder
    private var activeMenu: some View {
        if row.displayState == .paused {
            Button("Resume") { Task { await model.resume(jobID: row.id) } }
        } else if row.displayState == .active {
            Button("Pause") { Task { await model.pause(jobID: row.id) } }
        }
        Button("Copy URL") { model.copy(row.url) }
        Button("Reveal in Finder") { model.reveal(destination: row.destination) }
        Divider()
        Button("Remove", role: .destructive) {
            Task { await model.remove(jobID: row.id, keepPartialFile: true) }
        }
    }
}

/// A completed/failed row in the Downloads window: status badge, name, a
/// host · size · sha256 detail line (or red failure reason), and the date.
public struct DownloadsRecentRow: View {
    let row: GohMenuJobRow
    @ObservedObject var model: GohMenuViewModel
    let openTrust: () -> Void

    public init(row: GohMenuJobRow, model: GohMenuViewModel, openTrust: @escaping () -> Void) {
        self.row = row
        self.model = model
        self.openTrust = openTrust
    }

    private var failed: Bool { row.displayState == .failed }

    public var body: some View {
        HStack(alignment: .center, spacing: 11) {
            RowBadge(
                systemName: failed ? "exclamationmark.triangle" : "checkmark.circle",
                tint: failed ? GohTheme.error : GohTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(GohTheme.Typography.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detailLine)
                    .font(GohTheme.Typography.secondary)
                    .foregroundStyle(failed ? GohTheme.error : .secondary)
                    .lineLimit(1)
                    .truncationMode(failed ? .tail : .middle)
            }
            Spacer(minLength: 8)
            if let date = row.completedDateText {
                Text(date)
                    .font(GohTheme.Typography.secondary)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu { failed ? AnyView(failedMenu) : AnyView(completedMenu) }
    }

    private var detailLine: String {
        if failed { return row.failureReason ?? "Failed" }
        var parts: [String] = []
        if let host = URL(string: row.url)?.host() { parts.append(host) }
        if let bytes = row.bytesTotal, bytes > 0 { parts.append(JobDisplayFormatter.formatBytes(bytes)) }
        if let sha = row.sha256Short { parts.append("sha256 \(sha)") }
        return parts.joined(separator: " · ")
    }

    private var completedMenu: some View {
        Group {
            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: row.destination)) }
            Button("Reveal in Finder") { model.reveal(destination: row.destination) }
            Button("Copy URL") { model.copy(row.url) }
            Button("Verify & Trust…") { openTrust() }
            Divider()
            Button("Remove from List", role: .destructive) {
                Task { await model.remove(jobID: row.id, keepPartialFile: true) }
            }
        }
    }

    private var failedMenu: some View {
        Group {
            Button("Retry") { Task { await model.retry(url: row.url) } }
            Button("Copy URL") { model.copy(row.url) }
            Divider()
            Button("Remove", role: .destructive) {
                Task { await model.remove(jobID: row.id, keepPartialFile: true) }
            }
        }
    }
}

/// An SF Symbol for a filename's type, used as the Downloads row badge glyph.
func fileTypeIcon(_ filename: String) -> String {
    switch (filename as NSString).pathExtension.lowercased() {
    case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "zst": return "doc.zipper"
    case "iso", "dmg", "img": return "opticaldiscdrive"
    case "mp4", "mov", "mkv", "avi": return "film"
    case "mp3", "m4a", "flac", "aac": return "music.note"
    case "pdf": return "doc.richtext"
    case "json", "txt", "md", "yaml", "yml": return "doc.text"
    case "safetensors", "bin", "pt", "ckpt", "gguf", "model", "parquet": return "cpu"
    default: return "arrow.down.doc"
    }
}
