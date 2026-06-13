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
        VStack(spacing: 0) {
            summaryToolbar
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                entryList.frame(width: 250)
                Divider()
                inspector.frame(maxWidth: .infinity)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(minWidth: 740, minHeight: 460)
        .task {
            await viewModel.loadOverview()
            selectDefault()
        }
        .onChange(of: viewModel.rows.map(\.displayPath)) { _, _ in selectDefault() }
        .onChange(of: selection) { _, _ in hashSelectedIfChanged() }
        .onDisappear { viewModel.reset() }
    }

    // MARK: Summary toolbar

    private var summaryToolbar: some View {
        HStack(spacing: 0) {
            if case .summary(let s) = viewModel.overview {
                count(s.tracked, "tracked", .primary)
                separator
                count(s.verified, "verified", GohTheme.accent)
                separator
                count(s.downloadOnly, "download-only", .secondary)
                if changedCount > 0 {
                    separator
                    count(changedCount, "changed", GohTheme.error)
                }
            } else if viewModel.overview == .unavailable {
                Text("Trust data unavailable").font(GohTheme.Typography.rowTitle).foregroundStyle(.orange)
            } else {
                Text("No downloads recorded yet").font(GohTheme.Typography.rowTitle).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            searchField
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func count(_ value: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(value)").font(GohTheme.Typography.rowTitle.weight(.semibold)).foregroundStyle(color).monospacedDigit()
            Text(label).font(GohTheme.Typography.rowTitle).foregroundStyle(.secondary)
        }
    }

    private var separator: some View {
        Text("·").font(GohTheme.Typography.rowTitle).foregroundStyle(.tertiary).padding(.horizontal, 8)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search", text: $search).textFieldStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .frame(width: 180)
    }

    // MARK: List

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredRows, id: \.displayPath) { row in
                    TrustListRow(row: row, status: status(for: row), selected: selection == row.displayPath)
                        .onTapGesture { selection = row.displayPath }
                }
            }
            .padding(8)
        }
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
        } else {
            Text("Select a file to inspect its provenance.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            footerStatus
            Spacer(minLength: 8)
            if case .running = viewModel.runState {
                Button("Cancel") { viewModel.cancelVerify() }
            } else {
                Button { onAttest() } label: { Label("Attest…", systemImage: "checkmark.seal") }
                Button { viewModel.startVerify() } label: { Label("Verify All", systemImage: "checkmark.shield") }
                    .buttonStyle(.borderedProminent)
                    .tint(GohTheme.accent)
                    .disabled(viewModel.rows.isEmpty || viewModel.overview == .unavailable)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

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

    /// When a CHANGED file is selected, kick off the on-demand on-disk re-hash so
    /// the inspector can show the real byte-diff. Other states need no hash.
    private func hashSelectedIfChanged() {
        guard let row = selectedRow, case .changed = status(for: row) else { return }
        viewModel.computeCurrentHash(forPath: row.displayPath)
    }
}
