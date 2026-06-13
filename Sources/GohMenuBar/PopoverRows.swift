import SwiftUI

/// The clipboard call-to-action — appears only when a URL is detected on the
/// pasteboard. Clipboard glyph + "Download from Clipboard" + the URL + a solid
/// green download button.
struct ClipboardCTA: View {
    let url: URL
    let action: () -> Void

    var body: some View {
        GohModuleCard(padding: 10) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Download from Clipboard")
                        .font(GohTheme.Typography.rowTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(displayURL)
                        .font(GohTheme.Typography.secondary)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button(action: action) {
                    ZStack {
                        Circle().fill(GohTheme.accent)
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Download from clipboard")
            }
        }
    }

    /// Host + path, scheme stripped — matches the reference's compact URL line.
    private var displayURL: String {
        let host = url.host() ?? ""
        let path = url.path()
        return (host + path).isEmpty ? url.absoluteString : host + path
    }
}

/// A borderless glyph button revealed on row hover (Safari-style).
struct RowGlyphButton: View {
    let systemName: String
    let help: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(destructive ? AnyShapeStyle(GohTheme.error) : AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// An in-progress download row — the foremost active download as the prominent
/// "hero" card, or a compact row inside the "Downloading" group. Name, static
/// accent progress bar, detail line (size — speed — ETA), a circular pause/resume
/// control (always visible), and Copy URL / Remove glyphs revealed on hover.
public struct ActiveDownloadRow: View {
    let row: GohMenuJobRow
    let prominent: Bool
    let actions: PopoverActions
    /// Forces the hover controls visible — for previews/snapshots only.
    var forceHover = false
    @State private var hovering = false

    public init(row: GohMenuJobRow, prominent: Bool, actions: PopoverActions, forceHover: Bool = false) {
        self.row = row
        self.prominent = prominent
        self.actions = actions
        self.forceHover = forceHover
    }

    public var body: some View {
        Group {
            if prominent {
                GohModuleCard(padding: 12) { content }
            } else {
                content
            }
        }
        .onHover { hovering = $0 }
        .contextMenu { ActiveRowMenu(row: row, actions: actions) }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: prominent ? 9 : 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.title)
                    .font(GohTheme.Typography.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if hovering || forceHover {
                    RowGlyphButton(systemName: "link", help: "Copy URL") { actions.copy(row.url) }
                    RowGlyphButton(systemName: "trash", help: "Remove", destructive: true) { actions.remove(row) }
                } else if prominent, let pct = percentText {
                    Text(pct)
                        .font(GohTheme.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            HStack(spacing: 10) {
                GohProgressBar(fraction: row.progressFraction ?? 0, paused: row.isPaused)
                if !prominent { control }
            }

            HStack(alignment: .center, spacing: 8) {
                Text(detailLine)
                    .font(GohTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                if prominent {
                    Spacer(minLength: 8)
                    control
                }
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch row.displayState {
        case .active:
            GohCircularControl(systemName: "pause.fill", help: "Pause") { actions.pause(row) }
        case .paused:
            GohCircularControl(systemName: "play.fill", tint: GohTheme.accent, help: "Resume") { actions.resume(row) }
        case .queued:
            GohCircularControl(systemName: "xmark", help: "Remove") { actions.remove(row) }
        case .completed, .failed:
            EmptyView()
        }
    }

    private var percentText: String? {
        guard let fraction = row.progressFraction else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    private var detailLine: String {
        if row.isPaused {
            return "Paused · \(row.sizeText)"
        }
        var parts = [row.sizeText, row.speedText]
        if let eta = row.etaText { parts.append("\(eta) left") }
        return parts.filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

/// A terminal row in the "Recent" group — completed shows a green checkmark +
/// date; failed shows a red exclamation + "Failed".
public struct RecentRow: View {
    let row: GohMenuJobRow
    let actions: PopoverActions
    var forceHover = false
    @State private var hovering = false

    public init(row: GohMenuJobRow, actions: PopoverActions, forceHover: Bool = false) {
        self.row = row
        self.actions = actions
        self.forceHover = forceHover
    }

    private var failed: Bool { row.displayState == .failed }

    public var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(GohTheme.Typography.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Transfer-error: a failed row surfaces its red reason in-line.
                if failed, let reason = row.failureReason {
                    Text(reason)
                        .font(GohTheme.Typography.secondary)
                        .foregroundStyle(GohTheme.error)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if hovering || forceHover {
                if failed {
                    RowGlyphButton(systemName: "arrow.clockwise", help: "Retry") { actions.retry(row) }
                } else {
                    RowGlyphButton(systemName: "folder", help: "Reveal in Finder") { actions.reveal(row.destination) }
                }
                RowGlyphButton(systemName: "trash", help: "Remove", destructive: true) { actions.remove(row) }
            } else if failed {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(GohTheme.error)
            } else {
                Text(trailingText)
                    .font(GohTheme.Typography.secondary)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(GohTheme.accent)
            }
        }
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .contextMenu {
            if failed {
                FailedRowMenu(row: row, actions: actions)
            } else {
                CompletedRowMenu(row: row, actions: actions)
            }
        }
    }

    private var trailingText: String {
        row.completedDateText ?? row.verifyStatus ?? "Done"
    }
}

// MARK: - Context menus (real AppKit NSMenus, via SwiftUI .contextMenu)

struct ActiveRowMenu: View {
    let row: GohMenuJobRow
    let actions: PopoverActions
    var body: some View {
        if row.displayState == .paused {
            Button("Resume") { actions.resume(row) }
        } else if row.displayState == .active {
            Button("Pause") { actions.pause(row) }
        }
        Button("Copy URL") { actions.copy(row.url) }
        Button("Copy Destination") { actions.copy(row.destination) }
        Button("Reveal in Finder") { actions.reveal(row.destination) }
        Divider()
        Button("Remove", role: .destructive) { actions.remove(row) }
    }
}

struct CompletedRowMenu: View {
    let row: GohMenuJobRow
    let actions: PopoverActions
    var body: some View {
        Button("Open") { actions.open(row.destination) }
        Button("Reveal in Finder") { actions.reveal(row.destination) }
        Button("Copy URL") { actions.copy(row.url) }
        Button("Verify & Trust…") { actions.openTrust() }
        Divider()
        Button("Remove from List", role: .destructive) { actions.remove(row) }
    }
}

struct FailedRowMenu: View {
    let row: GohMenuJobRow
    let actions: PopoverActions
    var body: some View {
        Button("Retry") { actions.retry(row) }
        Button("Copy URL") { actions.copy(row.url) }
        Divider()
        Button("Remove", role: .destructive) { actions.remove(row) }
    }
}
