import AppKit
import GohCore
import SwiftUI

/// The "All Downloads" window — the full, filterable dashboard of every transfer.
/// Binds the same live `GohMenuViewModel` state as the popover. Toolbar: a
/// segmented filter + search; body: grouped Downloading / Recent cards; footer:
/// totals + Open Folder + Clear Completed.
public struct DownloadsWindowView: View {
    @ObservedObject private var model: GohMenuViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var filter: DownloadsFilter = .all
    @State private var search = ""

    public init(model: GohMenuViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .frame(minWidth: 540, minHeight: 440)
        .containerBackground(.thinMaterial, for: .window)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Filter", selection: $filter) {
                ForEach(DownloadsFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search downloads", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .frame(width: 200)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if visibleInProgress.isEmpty && visibleTerminal.isEmpty {
            Text(model.state.rows.isEmpty ? "No downloads yet." : "Nothing matches.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !visibleInProgress.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            GohSectionHeader("Downloading") {
                                Text("\(model.state.activeCount) active")
                                    .font(GohTheme.Typography.secondary)
                                    .foregroundStyle(.secondary)
                            }
                            card(visibleInProgress) { row in
                                DownloadsActiveRow(row: row, model: model)
                            }
                        }
                    }
                    if !visibleTerminal.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            GohSectionHeader("Recent") {
                                Text("\(model.state.rows.filter(\.isTerminal).count) total")
                                    .font(GohTheme.Typography.secondary)
                                    .foregroundStyle(.secondary)
                            }
                            card(visibleTerminal) { row in
                                DownloadsRecentRow(row: row, model: model, openTrust: openTrust)
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func card<Row: View>(_ rows: [GohMenuJobRow], @ViewBuilder row: @escaping (GohMenuJobRow) -> Row) -> some View {
        GohModuleCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, jobRow in
                    if index > 0 {
                        Rectangle().fill(GohTheme.separator)
                            .frame(height: GohTheme.Metrics.hairline)
                            .padding(.leading, 50)
                    }
                    row(jobRow)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(summaryText)
                .font(GohTheme.Typography.secondary)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { openDownloadsFolder() } label: { Label("Open Folder", systemImage: "folder") }
            Button("Clear Completed") { clearCompleted() }
                .disabled(!model.state.rows.contains { $0.displayState == .completed })
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summaryText: String {
        let total = model.state.rows.compactMap(\.bytesTotal).reduce(0, +)
        let totalText = total > 0 ? " · \(JobDisplayFormatter.formatBytes(total)) total" : ""
        return "\(model.state.rows.count) downloads · \(model.state.activeCount) active\(totalText)"
    }

    // MARK: Derived rows

    private func matchesSearch(_ row: GohMenuJobRow) -> Bool {
        search.isEmpty || row.title.localizedCaseInsensitiveContains(search)
    }

    private var visibleInProgress: [GohMenuJobRow] {
        guard filter == .all || filter == .downloading else { return [] }
        return model.state.rows.filter { $0.isInProgress && matchesSearch($0) }
    }

    private var visibleTerminal: [GohMenuJobRow] {
        let base: [GohMenuJobRow]
        switch filter {
        case .all: base = model.state.rows.filter(\.isTerminal)
        case .completed: base = model.state.rows.filter { $0.displayState == .completed }
        case .failed: base = model.state.rows.filter { $0.displayState == .failed }
        case .downloading: base = []
        }
        return base.filter(matchesSearch)
    }

    // MARK: Actions

    private func openTrust() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "trust")
    }

    private func openDownloadsFolder() {
        let url = (try? FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Downloads")
        NSWorkspace.shared.open(url)
    }

    private func clearCompleted() {
        for row in model.state.rows where row.displayState == .completed {
            Task { await model.remove(jobID: row.id, keepPartialFile: true) }
        }
    }
}

enum DownloadsFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case downloading = "Downloading"
    case completed = "Completed"
    case failed = "Failed"
    var id: String { rawValue }
}
