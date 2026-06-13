import AppKit
import GohCore
import SwiftUI

/// The Trust window — a master-detail view of recorded provenance with an
/// on-demand background verify. Binds the existing `TrustWindowViewModel`
/// (overview, rows, fast-check statuses, verify run state, forget). The redesign
/// only re-presents what the view-model already publishes.
public struct TrustWindowView: View {
    @ObservedObject private var viewModel: TrustWindowViewModel
    private let onAttest: () -> Void

    @State private var selection: String?
    @State private var search = ""
    @State private var confirmForgetPath: String?

    public init(viewModel: TrustWindowViewModel, onAttest: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onAttest = onAttest
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            inspector
        }
        .frame(minWidth: 760, minHeight: 460)
        .toolbar { trustToolbar }
        .safeAreaInset(edge: .bottom) { statusBar }
        .task {
            await viewModel.loadOverview()
            selectDefault()
        }
        .onChange(of: viewModel.rows.map(\.displayPath)) { _, _ in selectDefault() }
        .onChange(of: selection) { _, _ in hashSelectedIfChanged() }
        .onDisappear { viewModel.reset() }
        .confirmationDialog(
            "Forget this download's provenance?",
            isPresented: Binding(
                get: { confirmForgetPath != nil },
                set: { if !$0 { confirmForgetPath = nil } }),
            titleVisibility: .visible,
            presenting: confirmForgetPath
        ) { path in
            Button("Forget", role: .destructive) {
                confirmForgetPath = nil
                Task { await viewModel.forgetRow(path: path) }
            }
            Button("Cancel", role: .cancel) { confirmForgetPath = nil }
        } message: { path in
            Text("Removes the saved download record for \(URL(fileURLWithPath: path).lastPathComponent). The file is already missing; this does not delete anything from disk.")
        }
        .alert(
            "Couldn’t Forget",
            isPresented: Binding(
                get: { viewModel.forgetError != nil },
                set: { if !$0 { viewModel.clearForgetError() } })
        ) {
            Button("OK", role: .cancel) { viewModel.clearForgetError() }
        } message: {
            Text(viewModel.forgetError ?? "")
        }
    }

    // MARK: Sidebar (native NavigationSplitView master list)

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(filteredRows, id: \.displayPath) { row in
                // selected:false — the native List draws the selection highlight.
                TrustListRow(row: row, status: status(for: row), selected: false)
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    .tag(row.displayPath)
                    .contextMenu {
                        Button { reveal(row) } label: { Label("Reveal in Finder", systemImage: "folder") }
                        if viewModel.isForgettable(path: row.displayPath) {
                            Divider()
                            Button(role: .destructive) {
                                confirmForgetPath = row.displayPath
                            } label: { Label("Forget Download…", systemImage: "trash") }
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search files")
        .onDeleteCommand { forgetSelectedIfMissing() }
        .frame(minWidth: 240)
        .overlay {
            if viewModel.overview == .unavailable {
                ContentUnavailableView("Trust Data Unavailable", systemImage: "lock.slash")
            } else if viewModel.rows.isEmpty {
                ContentUnavailableView(
                    "No Recorded Downloads", systemImage: "checkmark.shield",
                    description: Text("Files you download with goh are recorded here."))
            } else if filteredRows.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    // MARK: Toolbar (native — actions get Liquid Glass automatically)

    @ToolbarContentBuilder
    private var trustToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if case .running = viewModel.runState {
                Button("Cancel") { viewModel.cancelVerify() }
                    .help("Stop the verification in progress")
            } else {
                Button { onAttest() } label: { Label("Attest…", systemImage: "checkmark.seal") }
                    .help("Attest your download records with a Secure Enclave signature (opens Terminal)")
                Button { viewModel.startVerify() } label: { Label("Verify All", systemImage: "checkmark.shield") }
                    .disabled(viewModel.rows.isEmpty || viewModel.overview == .unavailable)
                    .help("Re-hash every recorded file and check it against its recorded SHA-256")
            }
        }
    }

    // MARK: Status bar (native bottom bar — counts + verify status)

    private var statusBar: some View {
        HStack(spacing: 0) {
            if case .summary(let s) = viewModel.overview {
                count(s.tracked, "tracked", .primary)
                separator
                count(s.verified, "verified", GohTheme.accent)
                if changedCount > 0 {
                    separator
                    count(changedCount, "changed", GohTheme.error)
                }
            }
            Spacer(minLength: 12)
            footerStatus
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func count(_ value: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(value)").font(GohTheme.Typography.secondary.weight(.semibold)).foregroundStyle(color).monospacedDigit()
            Text(label).font(GohTheme.Typography.secondary).foregroundStyle(.secondary)
        }
    }

    private var separator: some View {
        Text("·").font(GohTheme.Typography.secondary).foregroundStyle(.tertiary).padding(.horizontal, 8)
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if let selectedRow {
            ScrollView {
                TrustInspector(
                    row: selectedRow,
                    status: status(for: selectedRow),
                    currentHash: viewModel.currentHashes[selectedRow.displayPath],
                    isComputingHash: viewModel.hashingPath == selectedRow.displayPath,
                    changeReason: changeReason(for: selectedRow),
                    onReveal: { reveal(selectedRow) },
                    onForget: viewModel.isForgettable(path: selectedRow.displayPath)
                        ? { confirmForgetPath = selectedRow.displayPath }
                        : nil)
            }
        } else {
            ContentUnavailableView(
                "No File Selected", systemImage: "sidebar.squares.left",
                description: Text("Select a file to inspect its provenance."))
        }
    }

    // MARK: Verify status (shown in the bottom status bar)

    @ViewBuilder
    private var footerStatus: some View {
        switch viewModel.runState {
        case .idle:
            Text(changedCount > 0 ? "\(changedCount) changed since recorded" : "Not yet checked this session")
                .font(GohTheme.Typography.secondary).foregroundStyle(.secondary)
        case .running(let progress):
            let stats = viewModel.liveStats(for: progress)
            HStack(spacing: 8) {
                ProgressView(value: stats.fraction).frame(width: 140)
                Text("\(progress.completed) / \(progress.total) files")
                    .font(GohTheme.Typography.secondary).foregroundStyle(.secondary).monospacedDigit()
            }
        case .finished(let report), .cancelled(let report):
            Text(reportSummary(report))
                .font(GohTheme.Typography.secondary).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(GohTheme.Typography.secondary).foregroundStyle(GohTheme.error).lineLimit(1)
        }
    }

    private func reportSummary(_ report: VerifyAllReport) -> String {
        var parts = ["Last check: \(report.summary.ok) OK"]
        if report.summary.failed > 0 { parts.append("\(report.summary.failed) changed") }
        if report.summary.missing > 0 { parts.append("\(report.summary.missing) missing") }
        return parts.joined(separator: " · ")
    }

    // MARK: Derived

    private var filteredRows: [GohTrustEntryRow] {
        guard !search.isEmpty else { return viewModel.rows }
        return viewModel.rows.filter {
            URL(fileURLWithPath: $0.displayPath).lastPathComponent.localizedCaseInsensitiveContains(search)
        }
    }

    private var selectedRow: GohTrustEntryRow? {
        viewModel.rows.first { $0.displayPath == selection }
    }

    private var changedCount: Int {
        viewModel.fastStatuses.values.filter { if case .changed = $0 { return true } else { return false } }.count
    }

    private func status(for row: GohTrustEntryRow) -> TrustDisplayStatus {
        GohTrustPresenter.displayStatus(verifiedAt: row.verifiedAt, fastStatus: viewModel.fastStatuses[row.displayPath])
    }

    private func changeReason(for row: GohTrustEntryRow) -> String? {
        guard case .changed(let reason) = status(for: row) else { return nil }
        switch reason {
        case .identity: return "The file was replaced (its identity on disk changed)."
        case .size: return "The file's size differs from the recorded \(TrustFormat.size(row.size))."
        case .mtime: return "The file was modified after it was recorded."
        }
    }

    private func selectDefault() {
        let paths = viewModel.rows.map(\.displayPath)
        if let selection, paths.contains(selection) { return }
        // Prefer a changed/missing row, else the first.
        selection = viewModel.rows.first { row in
            if case .changed = status(for: row) { return true }
            return status(for: row) == .missing
        }?.displayPath ?? paths.first
    }

    private func reveal(_ row: GohTrustEntryRow) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.displayPath)])
    }

    /// Delete-key forget for the selected row. Only missing (deleted-on-disk)
    /// entries are forgettable — a present file's provenance record is kept.
    private func forgetSelectedIfMissing() {
        guard let selection, viewModel.isForgettable(path: selection) else { return }
        confirmForgetPath = selection
    }

    /// When a CHANGED file is selected, kick off the on-demand on-disk re-hash so
    /// the inspector can show the real byte-diff. Other states need no hash.
    private func hashSelectedIfChanged() {
        guard let row = selectedRow, case .changed = status(for: row) else { return }
        viewModel.computeCurrentHash(forPath: row.displayPath)
    }
}
