import SwiftUI
import GohCore

/// The Trust window — per-file provenance list + background verify.
public struct TrustWindowView: View {
    @ObservedObject private var viewModel: TrustWindowViewModel

    public init(viewModel: TrustWindowViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            entryList
            Divider()
            verifySection
        }
        .frame(minWidth: 480, minHeight: 300)
        .padding(16)
        .task { await viewModel.loadOverview() }
        .onDisappear { viewModel.reset() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Trust")
                .font(.title2)
                .bold()
            overviewLine
        }
    }

    @ViewBuilder
    private var overviewLine: some View {
        switch viewModel.overview {
        case .empty:
            Text("No downloads recorded yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .unavailable:
            Text("Trust data unavailable")
                .font(.subheadline)
                .foregroundStyle(.orange)
        case .summary(let s):
            // AC1: explicitly labelled "last recorded" — NOT a live check
            Text("\(s.tracked) files tracked · last recorded: \(s.verified) verified · \(s.downloadOnly) download-only")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Entry list

    @ViewBuilder
    private var entryList: some View {
        if viewModel.rows.isEmpty {
            Text("No entries to display.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.rows, id: \.displayPath) { row in
                        TrustEntryRowView(row: row, liveResult: liveResult(for: row))
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    /// Look up the live verify result for a row (nil if no completed run yet).
    private func liveResult(for row: GohTrustEntryRow) -> VerifyStatus? {
        switch viewModel.runState {
        case .finished(let report), .cancelled(let report):
            return report.entries.first { $0.path == row.displayPath }?.status
        default:
            return nil
        }
    }

    // MARK: - Verify section

    @ViewBuilder
    private var verifySection: some View {
        switch viewModel.runState {
        case .idle:
            Button {
                viewModel.startVerify()
            } label: {
                Label("Verify now", systemImage: "checkmark.shield")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.rows.isEmpty || viewModel.overview == .unavailable)
            .accessibilityLabel("Start integrity verification of all recorded files")

        case .running(let progress):
            let stats = viewModel.liveStats(for: progress)
            VStack(alignment: .leading, spacing: 6) {
                if let path = progress.currentPath {
                    Text("Verifying \(URL(fileURLWithPath: path).lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 10) {
                    if progress.totalBytes > 0 {
                        ProgressView(value: stats.fraction)
                            .frame(maxWidth: 220)
                            .accessibilityLabel(
                                "Verification progress \(Int(stats.fraction * 100)) percent")
                    } else {
                        ProgressView(
                            value: Double(progress.completed),
                            total: Double(max(progress.total, 1)))
                            .frame(maxWidth: 220)
                            .accessibilityLabel(
                                "Verification progress, file \(progress.completed) of \(progress.total)")
                    }
                    Spacer()
                    Button("Cancel") {
                        viewModel.cancelVerify()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Cancel verify run")
                }
                HStack(spacing: 8) {
                    Text("\(progress.completed) / \(progress.total) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !stats.byteText.isEmpty {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Text(stats.byteText).font(.caption).foregroundStyle(.secondary)
                    }
                    if let eta = stats.etaText {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Text(eta).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

        case .finished(let report):
            liveResultSummary(report: report, cancelled: false)

        case .cancelled(let report):
            VStack(alignment: .leading, spacing: 4) {
                Text("Cancelled (partial result)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                liveResultSummary(report: report, cancelled: true)
            }

        case .failed(let message):
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func liveResultSummary(report: VerifyAllReport, cancelled: Bool) -> some View {
        HStack(spacing: 12) {
            Label("\(report.summary.ok) OK", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if report.summary.failed > 0 {
                Label("\(report.summary.failed) FAILED", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            if report.summary.missing > 0 {
                Label("\(report.summary.missing) MISSING", systemImage: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button {
                viewModel.startVerify()
            } label: {
                Label("Verify again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.rows.isEmpty)
            .accessibilityLabel("Run verification again")
        }
        .font(.subheadline)
    }
}

// MARK: - Per-entry row

private struct TrustEntryRowView: View {
    let row: GohTrustEntryRow
    let liveResult: VerifyStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(URL(fileURLWithPath: row.displayPath).lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                atRestStatusChip
                if let live = liveResult {
                    liveStatusChip(live)
                }
            }
            Text(row.sanitizedURL)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(row.sha256)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// At-rest status chip — labelled "last recorded" semantics (AC1).
    @ViewBuilder
    private var atRestStatusChip: some View {
        if let verifiedAt = row.verifiedAt {
            Text("verified \(verifiedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .cornerRadius(4)
                .foregroundStyle(.green)
        } else {
            Text("downloaded")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
                .foregroundStyle(.secondary)
        }
    }

    /// Live verify status chip — visually distinct from at-rest labels (AC1).
    @ViewBuilder
    private func liveStatusChip(_ status: VerifyStatus) -> some View {
        let (label, color): (String, Color) = switch status {
        case .ok:      ("OK", .green)
        case .failed:  ("FAILED", .red)
        case .missing: ("MISSING", .orange)
        }
        Text(label)
            .font(.caption2)
            .bold()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .cornerRadius(4)
            .foregroundStyle(color)
    }

    private var accessibilityDescription: String {
        let file = URL(fileURLWithPath: row.displayPath).lastPathComponent
        let status = row.verifiedAt != nil ? "verified" : "downloaded only"
        let live = liveResult.map { "live: \($0.rawValue)" } ?? ""
        return "\(file), \(status)\(live.isEmpty ? "" : ", \(live)")"
    }
}
