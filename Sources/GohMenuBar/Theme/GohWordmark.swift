import AppKit
import SwiftUI

/// The lifecycle state of the `goh` wordmark's arrow — the single sanctioned
/// piece of motion/semantics in the brand mark. Drives the arrow's tint; the
/// letters always render in the primary label color (adapting to appearance).
nonisolated public enum GohWordmarkState: Sendable, Equatable {
    /// No active downloads — the arrow is hidden.
    case idle
    /// Downloads are live — the arrow lights brand green.
    case active
    /// Paused — the arrow dims to a faint green.
    case paused
    /// A completion just landed — held briefly at full brand green.
    case done
    /// A transfer failed / a tracked file changed — the arrow turns red.
    case error
}

/// Loads the authoritative `goh` wordmark SVG and exposes it as two independently
/// tintable **template** images: the serif letters and the arrow. Keeping them
/// separate lets the letters follow the semantic label color while the arrow
/// recolors by `GohWordmarkState` — and because both derive from the same
/// 530×350 viewBox, overlaying them re-registers the arrow through the *o*
/// exactly as authored.
///
/// The mark is the *only* non-SF, non-semantic brand element in the running UI,
/// and it appears solely inside the Liquid Glass tile (status item + popover
/// header) — see `GohWordmarkTile`.
public enum GohWordmark {
    /// The wordmark's intrinsic aspect ratio (viewBox 530×350).
    public static let aspectRatio: CGFloat = 530.0 / 350.0

    /// The serif `goh` letters, as a template image (tint via `foregroundStyle`).
    public static let letters: NSImage = makeTemplate(showLetters: true, showArrow: false)

    /// The arrow through the *o*, as a template image (tint via `foregroundStyle`).
    public static let arrow: NSImage = makeTemplate(showLetters: false, showArrow: true)

    // The two literal fills in the master SVG (`assets/brand/wordmark/goh-wordmark.svg`).
    private static let arrowFill = "#AADB35"
    private static let lettersFill = "#F8F5EF"

    private static func makeTemplate(showLetters: Bool, showArrow: Bool) -> NSImage {
        guard
            let url = Bundle.module.url(forResource: "goh-wordmark", withExtension: "svg"),
            var svg = try? String(contentsOf: url, encoding: .utf8)
        else {
            return NSImage(size: NSSize(width: 530, height: 350))
        }
        // Recolor to a flat black for the visible group and to `none` for the
        // hidden group, then flag the result as a template so SwiftUI tints it.
        svg = svg.replacingOccurrences(of: arrowFill, with: showArrow ? "#000000" : "none")
        svg = svg.replacingOccurrences(of: lettersFill, with: showLetters ? "#000000" : "none")
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage(size: NSSize(width: 530, height: 350))
        image.isTemplate = true
        return image
    }
}

extension GohWordmarkState {
    /// The arrow's tint for this state. `.clear` hides it (idle).
    var arrowColor: Color {
        switch self {
        case .idle: return .clear
        case .active, .done: return GohTheme.accent
        case .paused: return GohTheme.accent.opacity(0.45)
        case .error: return GohTheme.error
        }
    }
}
