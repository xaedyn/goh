import GohCore
import SwiftUI

/// The Trust window's right-hand inspector for the selected file. Pure/data-driven
/// so it renders from the live view-model or from sample data in the harness.
/// `currentHash` is the on-disk SHA-256 for a changed file (when available);
/// `changeReason` describes why the fast-check flagged it.
public struct TrustInspector: View {
    let row: GohTrustEntryRow
    let status: TrustDisplayStatus
    let currentHash: String?
    let isComputingHash: Bool
    let changeReason: String?
    let onReveal: () -> Void
    let onForget: (() -> Void)?

    public init(
        row: GohTrustEntryRow,
        status: TrustDisplayStatus,
        currentHash: String? = nil,
        isComputingHash: Bool = false,
        changeReason: String? = nil,
        onReveal: @escaping () -> Void = {},
        onForget: (() -> Void)? = nil
    ) {
        self.row = row
        self.status = status
        self.currentHash = currentHash
        self.isComputingHash = isComputingHash
        self.changeReason = changeReason
        self.onReveal = onReveal
        self.onForget = onForget
    }

    private var isChanged: Bool {
        if case .changed = status { return true }
        return status == .missing
    }

    private var matchesRecordedSignature: Bool {
        if case .verified = status { return true }
        return status == .looksUnchanged
    }

    public var body: some View {
        let style = TrustStatusStyle(status)
        // Plain content (no ScrollView) so it renders in ImageRenderer; the live
        // TrustWindowView wraps this in a ScrollView.
        VStack(alignment: .leading, spacing: 18) {
            header(style)
            if isChanged { changedBanner }
            sourceSection
            integritySection(style)
            historySection
            if isChanged || onForget != nil {
                HStack(spacing: 10) {
                    Button { onReveal() } label: { Label("Reveal in Finder", systemImage: "folder") }
                    if let onForget {
                        Button(role: .destructive) { onForget() } label: { Label("Forget", systemImage: "trash") }
                            .help("Remove this missing file's saved provenance record")
                    }
                    Spacer()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private func header(_ style: TrustStatusStyle) -> some View {
        HStack(spacing: 11) {
            Image(systemName: style.systemImage)
                .font(.system(size: 22))
                .foregroundStyle(style.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(URL(fileURLWithPath: row.displayPath).lastPathComponent)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(style.label)
                    .font(GohTheme.Typography.secondary.weight(.semibold))
                    .foregroundStyle(style.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(style.color.opacity(0.16), in: Capsule())
            }
            Spacer(minLength: 8)
        }
    }

    private var changedBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(GohTheme.error)
            VStack(alignment: .leading, spacing: 3) {
                Text(status == .missing ? "This file is missing" : "This file changed since it was recorded")
                    .font(GohTheme.Typography.rowTitle.weight(.semibold))
                    .foregroundStyle(.primary)
                // The change reason is surfaced here (not buried in Integrity) so the
                // alarm is specific and prominent before any deep verify runs.
                if status != .missing, let changeReason {
                    Text(changeReason)
                        .font(GohTheme.Typography.secondary.weight(.semibold))
                        .foregroundStyle(GohTheme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(status == .missing
                    ? "The recorded file is no longer on disk. Re-download it or forget the record."
                    : "It no longer matches what you downloaded. Re-download or update the record to restore provenance.")
                    .font(GohTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GohTheme.error.opacity(0.12), in: RoundedRectangle(cornerRadius: GohTheme.Metrics.moduleRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GohTheme.Metrics.moduleRadius, style: .continuous)
                .strokeBorder(GohTheme.error.opacity(0.35), lineWidth: GohTheme.Metrics.hairline))
    }

    // MARK: Sections

    private var sourceSection: some View {
        section("Source") {
            labelRow("URL", row.sanitizedURL)
            labelRow("Size", TrustFormat.size(row.size))
            labelRow("Downloaded", TrustFormat.dateTime(row.downloadedAt))
            labelRow("Last checked", row.verifiedAt.map(TrustFormat.dateTime) ?? "Never")
        }
    }

    @ViewBuilder
    private func integritySection(_ style: TrustStatusStyle) -> some View {
        if case .changed = status {
            section("Integrity — SHA-256 mismatch") {
                if let currentHash {
                    // The real recorded-vs-on-disk byte-diff.
                    TrustHashDiff(recorded: row.sha256, current: currentHash)
                } else if isComputingHash {
                    // Alarm is already in the banner above; the diff populates when
                    // the on-demand hash finishes.
                    TrustHashDiff(recorded: row.sha256, current: nil)
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Computing on-disk hash…")
                            .font(GohTheme.Typography.secondary)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TrustHashDiff(recorded: row.sha256, current: nil)
                    Text("Run Verify All to compute the on-disk hash.")
                        .font(GohTheme.Typography.secondary)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            section("Integrity — SHA-256") {
                TrustHashDiff(recorded: row.sha256, current: nil)
                if matchesRecordedSignature {
                    Label("Matches the recorded signature", systemImage: "checkmark.seal.fill")
                        .font(GohTheme.Typography.secondary)
                        .foregroundStyle(GohTheme.accent)
                }
            }
        }
    }

    private var historySection: some View {
        section("History") {
            VStack(alignment: .leading, spacing: 8) {
                timelineRow("Downloaded", TrustFormat.dateTime(row.downloadedAt))
                if let verifiedAt = row.verifiedAt {
                    timelineRow("Verified", TrustFormat.dateTime(verifiedAt))
                }
            }
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(GohTheme.Typography.groupLabel)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func labelRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(GohTheme.Typography.rowTitle)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(GohTheme.Typography.rowTitle)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
    }

    private func timelineRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 9) {
            Circle().fill(GohTheme.accent).frame(width: 7, height: 7)
            Text(label).font(GohTheme.Typography.rowTitle).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(value).font(GohTheme.Typography.secondary).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
