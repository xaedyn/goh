import SwiftUI

/// A grouped "card" — the inset rounded module the design language is built on
/// (Control Center / Settings / Safari Downloads). A semi-translucent fill on the
/// Liquid Glass surface, with a hairline edge. Separation comes from grouping +
/// spacing, not rules everywhere.
public struct GohModuleCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content
    @Environment(\.colorScheme) private var colorScheme

    public init(padding: CGFloat = 11, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: GohTheme.Metrics.moduleRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GohTheme.Metrics.moduleRadius, style: .continuous)
                    .strokeBorder(GohTheme.separator, lineWidth: GohTheme.Metrics.hairline))
    }

    /// Module fill: dark = white @ 6%, light = white @ 60% (per the token table).
    private var fill: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.6)
    }
}

/// A determinate progress bar — 4pt, solid accent fill, **static** (no shimmer).
/// Paused dims to the secondary label color. A faint brighter cap sits at the
/// fill's leading edge of the remaining track, matching the reference.
public struct GohProgressBar: View {
    public var fraction: Double
    public var paused: Bool

    public init(fraction: Double, paused: Bool = false) {
        self.fraction = max(0, min(1, fraction))
        self.paused = paused
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(GohTheme.separator)
                Capsule()
                    .fill(paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(GohTheme.accent))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: GohTheme.Metrics.progressBarHeight)
    }
}

/// A circular Safari-style row control — a thin ring with a centered glyph
/// (22pt). Used for pause / resume / stop / retry on download rows.
public struct GohCircularControl: View {
    public var systemName: String
    public var tint: Color
    public var help: String
    public var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    public init(systemName: String, tint: Color = .secondary, help: String = "", action: @escaping () -> Void) {
        self.systemName = systemName
        self.tint = tint
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(GohTheme.separator, lineWidth: 1)
                Image(systemName: systemName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: GohTheme.Metrics.rowControlDiameter, height: GohTheme.Metrics.rowControlDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A group label — "Downloading", "Recent" — sitting above its card with a small
/// inset, optionally with a trailing accent action ("Show All").
public struct GohSectionHeader<Accessory: View>: View {
    private let title: String
    private let accessory: Accessory

    public init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(GohTheme.Typography.moduleHeader)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 2)
    }
}

/// The tone of an inline notice module.
public enum GohNoticeTone: Sendable {
    case neutral
    case warning
    case error

    var accent: Color {
        switch self {
        case .neutral: return .secondary
        case .warning: return GohTheme.accent
        case .error: return GohTheme.error
        }
    }
}

/// A reusable inline notice module — the recovery / edge-condition banner. The
/// design language renders these as inline cards at the top of the popover, never
/// as separate alerts. A tone tints the icon (and an error tone tints the title).
public struct GohInlineNotice: View {
    public var tone: GohNoticeTone
    public var systemImage: String
    public var title: String
    public var detail: String?
    public var actionTitle: String?
    public var action: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    public init(
        tone: GohNoticeTone,
        systemImage: String,
        title: String,
        detail: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.tone = tone
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tone.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(GohTheme.Typography.rowTitle)
                    .foregroundStyle(tone == .error ? GohTheme.error : .primary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(GohTheme.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(GohTheme.Typography.secondary.weight(.semibold))
                    .foregroundStyle(GohTheme.accent)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(noticeFill, in: RoundedRectangle(cornerRadius: GohTheme.Metrics.moduleRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GohTheme.Metrics.moduleRadius, style: .continuous)
                .strokeBorder(tone == .error ? GohTheme.error.opacity(0.35) : GohTheme.separator, lineWidth: GohTheme.Metrics.hairline))
    }

    private var noticeFill: Color {
        if tone == .error { return GohTheme.error.opacity(colorScheme == .dark ? 0.12 : 0.08) }
        return colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.6)
    }
}
