import GohCore
import SwiftUI

/// Visual style (short label, icon, tint) for a Trust display status.
public struct TrustStatusStyle {
    public let label: String
    public let systemImage: String
    public let color: Color

    public init(_ status: TrustDisplayStatus) {
        switch status {
        case .verified:
            self = .init(label: "Verified", systemImage: "checkmark.shield.fill", color: GohTheme.accent)
        case .looksUnchanged:
            self = .init(label: "Looks unchanged", systemImage: "checkmark.circle", color: .teal)
        case .changed:
            self = .init(label: "Changed", systemImage: "exclamationmark.circle.fill", color: GohTheme.error)
        case .missing:
            self = .init(label: "Missing", systemImage: "questionmark.circle.fill", color: GohTheme.error)
        case .indeterminate:
            self = .init(label: "Unreadable", systemImage: "lock.slash", color: .orange)
        case .notBaselined:
            self = .init(label: "No baseline", systemImage: "minus.circle", color: .secondary)
        case .recordedOnly:
            self = .init(label: "Download-only", systemImage: "arrow.down.circle", color: .secondary)
        }
    }

    private init(label: String, systemImage: String, color: Color) {
        self.label = label
        self.systemImage = systemImage
        self.color = color
    }
}

/// A row in the Trust window's left list: status icon + name + "status · size".
public struct TrustListRow: View {
    let row: GohTrustEntryRow
    let status: TrustDisplayStatus
    let selected: Bool

    public init(row: GohTrustEntryRow, status: TrustDisplayStatus, selected: Bool) {
        self.row = row
        self.status = status
        self.selected = selected
    }

    public var body: some View {
        let style = TrustStatusStyle(status)
        return HStack(spacing: 9) {
            Image(systemName: style.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(style.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: row.displayPath).lastPathComponent)
                    .font(GohTheme.Typography.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(style.label) · \(TrustFormat.size(row.size))")
                    .font(GohTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            selected ? AnyShapeStyle(style.color.opacity(0.14)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// A SHA-256 rendered in 8-character groups, monospaced. When `current` is given,
/// it is shown beneath the recorded hash with the differing characters tinted red
/// (the changed-file mismatch view).
public struct TrustHashDiff: View {
    let recorded: String
    let current: String?

    public init(recorded: String, current: String?) {
        self.recorded = recorded
        self.current = current
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recorded")
                    .font(GohTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
                hashText(TrustFormat.hex(recorded), against: nil)
                    .foregroundStyle(.secondary)
            }
            if let current {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Current (on disk)")
                        .font(GohTheme.Typography.secondary)
                        .foregroundStyle(GohTheme.error)
                    hashText(TrustFormat.hex(current), against: TrustFormat.hex(recorded))
                }
            }
        }
    }

    /// Renders a grouped hash as an attributed string; when `against` is provided,
    /// characters that differ from it are tinted red.
    private func hashText(_ hex: String, against: String?) -> Text {
        let groups = TrustFormat.grouped(hex)
        let baseline = against.map(Array.init)
        var attributed = AttributedString()
        var hexIndex = 0
        for char in groups {
            var piece = AttributedString(String(char))
            piece.font = .system(size: 11, design: .monospaced)
            if char != " " {
                if let baseline {
                    let differs = hexIndex >= baseline.count || baseline[hexIndex] != char
                    piece.foregroundColor = differs ? GohTheme.error : Color.secondary
                } else {
                    piece.foregroundColor = Color.secondary
                }
                hexIndex += 1
            }
            attributed.append(piece)
        }
        return Text(attributed)
    }
}

/// Formatting helpers for the Trust window.
public enum TrustFormat {
    /// Strips a leading "sha256:" and lowercases — the bare hex digest.
    public static func hex(_ sha: String) -> String {
        let bare = sha.hasPrefix("sha256:") ? String(sha.dropFirst(7)) : sha
        return bare.lowercased()
    }

    /// Hex split into 8-character groups separated by spaces.
    public static func grouped(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 8).map { start in
            let s = hex.index(hex.startIndex, offsetBy: start)
            let e = hex.index(s, offsetBy: 8, limitedBy: hex.endIndex) ?? hex.endIndex
            return String(hex[s..<e])
        }.joined(separator: " ")
    }

    public static func size(_ bytes: Int) -> String {
        JobDisplayFormatter.formatBytes(UInt64(max(0, bytes)))
    }

    public static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
