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
        NavigationStack {
            downloadsList
                .navigationTitle("Downloads")
                .searchable(text: $search, prompt: "Search downloads")
                .toolbar { downloadsToolbar }
                .safeAreaInset(edge: .bottom) { statusBar }
        }
        .frame(minWidth: 540, minHeight: 440)
    }

    // MARK: List (native — sections + system separators)

    @ViewBuilder
    private var downloadsList: some View {
        if model.state.rows.isEmpty {
            ContentUnavailableView(
                "No Downloads Yet", systemImage: "arrow.down.circle",
                description: Text("Downloads you start with goh appear here."))
        } else if visibleInProgress.isEmpty && visibleTerminal.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            List {
                if !visibleInProgress.isEmpty {
                    Section("Downloading") {
                        ForEach(visibleInProgress, id: \.id) { row in
                            DownloadsActiveRow(row: row, model: model)
                                .listRowInsets(EdgeInsets())
                        }
                    }
                }
                if !visibleTerminal.isEmpty {
                    Section("Recent") {
                        ForEach(visibleTerminal, id: \.id) { row in
                            DownloadsRecentRow(row: row, model: model, openTrust: openTrust)
                                .listRowInsets(EdgeInsets())
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: Toolbar (native — filter + actions get Liquid Glass automatically)

    @ToolbarContentBuilder
    private var downloadsToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Filter", selection: $filter) {
                ForEach(DownloadsFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { openDownloadsFolder() } label: { Label("Open Folder", systemImage: "folder") }
            Button("Clear Completed") { clearCompleted() }
                .disabled(!model.state.rows.contains { $0.displayState == .completed })
        }
    }

    // MARK: Status bar (native bottom bar — totals)

    private var statusBar: some View {
        HStack {
            Text(summaryText)
                .font(GohTheme.Typography.secondary)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
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
