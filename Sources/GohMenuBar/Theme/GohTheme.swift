import AppKit
import SwiftUI

/// Design tokens for the menu-bar redesign — the single source of truth for
/// color, geometry, and type. The design language is intentionally quiet and
/// Apple-native (macOS 26 HIG): one type family (SF), semantic system colors
/// with a single brand-green accent, and translucent Liquid Glass surfaces.
///
/// Resolve from the system wherever a system color already exists; the brand
/// contributes exactly one hue (the accent green) tuned to `systemGreen`.
public enum GohTheme {

    // MARK: Color

    /// The brand accent — a green tuned to `systemGreen`. Used for progress,
    /// primary buttons, the live arrow, and the app's `accentColor`.
    /// Dark `#34D266`, Light `#28A85A` (per the spec token table).
    public static let accent = Color(nsColor: accentNSColor)

    /// Failure / changed. The plain system red, which already adapts.
    public static let error = Color(nsColor: .systemRed)

    /// Hairline separator between grouped rows. Adapts with appearance.
    public static let separator = Color(nsColor: .separatorColor)

    /// AppKit form of the accent, for the non-template colored menu-bar status
    /// item and any place that needs an `NSColor` rather than a SwiftUI `Color`.
    public static let accentNSColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0x34 / 255, green: 0xD2 / 255, blue: 0x66 / 255, alpha: 1)
            : NSColor(srgbRed: 0x28 / 255, green: 0xA8 / 255, blue: 0x5A / 255, alpha: 1)
    }

    // MARK: Geometry (pt). Native metrics win where they differ — these are targets.

    public enum Metrics {
        /// Popover content width (the spec target; native hugging decides height).
        public static let popoverWidth: CGFloat = 320
        public static let popoverRadius: CGFloat = 18
        /// Grouped "card" / module corner radius.
        public static let moduleRadius: CGFloat = 11
        /// Inset of modules from the popover edge.
        public static let moduleInset: CGFloat = 12
        /// The Liquid Glass wordmark tile corner radius.
        public static let tileRadius: CGFloat = 11
        /// Hairline rule between rows within a module.
        public static let hairline: CGFloat = 0.5
        /// Determinate progress bar.
        public static let progressBarHeight: CGFloat = 4
        public static let progressBarRadius: CGFloat = 2
        /// Circular Safari-style row control (stop/pause/resume).
        public static let rowControlDiameter: CGFloat = 22
        /// Window corner radius.
        public static let windowRadius: CGFloat = 12
    }

    // MARK: Type

    public enum Typography {
        /// Popover header `goh` title — SF Pro Rounded 16/600. The rounded face is
        /// reserved for this one title; everything else is SF Pro.
        public static let headerTitle = Font.system(size: 16, weight: .semibold, design: .rounded)
        /// A grouped module's header label (13/600).
        public static let moduleHeader = Font.system(size: 13, weight: .semibold)
        /// 11/600 uppercase group label.
        public static let groupLabel = Font.system(size: 11, weight: .semibold)
        /// Primary row title (13).
        public static let rowTitle = Font.system(size: 13)
        /// Secondary status line (11–12). Pair with `.monospacedDigit()` for numbers.
        public static let secondary = Font.system(size: 12)
    }
}

extension NSAppearance {
    /// Whether this appearance resolves to a dark variant — for `NSColor`
    /// dynamic providers, which receive the appearance rather than a `ColorScheme`.
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
