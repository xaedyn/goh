import SwiftUI

/// The `goh` wordmark on a small translucent **Liquid Glass** tile — the one
/// branded piece of chrome, reused as both the menu-bar status item and the
/// popover header mark. The serif letters follow the primary label color; the
/// arrow through the *o* tints by `GohWordmarkState` (idle hides it, active/done
/// are brand green, paused is a faint green, error is red).
///
/// The tile is a reusable building block: size it via `glyphWidth` (the popover
/// header uses a larger mark than the menu-bar item). The glass background tints
/// with the wallpaper in the running app; in static renders it approximates as a
/// translucent fill.
public struct GohWordmarkTile: View {
    public var state: GohWordmarkState
    public var glyphWidth: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - state: the arrow lifecycle state (defaults to idle).
    ///   - glyphWidth: the rendered width of the wordmark glyph. Height is
    ///     derived from the mark's intrinsic aspect ratio. Default suits the
    ///     popover header; the menu-bar status item uses a smaller value.
    public init(state: GohWordmarkState = .idle, glyphWidth: CGFloat = 30) {
        self.state = state
        self.glyphWidth = glyphWidth
    }

    private var glyphHeight: CGFloat { glyphWidth / GohWordmark.aspectRatio }

    public var body: some View {
        ZStack {
            Image(nsImage: GohWordmark.letters)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.primary)

            Image(nsImage: GohWordmark.arrow)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(state.arrowColor)
        }
        .frame(width: glyphWidth, height: glyphHeight)
        .padding(.horizontal, glyphWidth * 0.22)
        .padding(.vertical, glyphWidth * 0.18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: GohTheme.Metrics.tileRadius, style: .continuous))
        .overlay(
            // Soft bright top highlight — the Liquid Glass edge.
            RoundedRectangle(cornerRadius: GohTheme.Metrics.tileRadius, style: .continuous)
                .strokeBorder(
                    .white.opacity(colorScheme == .dark ? 0.18 : 0.55),
                    lineWidth: GohTheme.Metrics.hairline)
        )
        .accessibilityElement()
        .accessibilityLabel("goh")
    }
}
