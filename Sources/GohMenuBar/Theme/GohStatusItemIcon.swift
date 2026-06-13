import SwiftUI

/// The menu-bar status item: the `goh` wordmark rendered at status-bar scale,
/// driven by the download lifecycle. The letters follow the menu-bar's label
/// color; the arrow tints by state (idle hides it, active/done = brand green,
/// paused = faint green, error = red).
///
/// Completion is the *only* sanctioned motion: when `state` becomes `.done`, the
/// arrow blooms — a brief brighten + scale pulse — then recedes to idle. The
/// bloom honors Reduce Motion (it collapses to a non-animated brighten). The
/// recede (done → idle, ~600ms later) is driven by the host that owns the state.
public struct GohStatusItemIcon: View {
    public var state: GohWordmarkState
    /// The rendered height of the wordmark in the menu bar (~15–16pt typical).
    public var glyphHeight: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bloom = false

    public init(state: GohWordmarkState, glyphHeight: CGFloat = 15) {
        self.state = state
        self.glyphHeight = glyphHeight
    }

    private var glyphWidth: CGFloat { glyphHeight * GohWordmark.aspectRatio }

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
                // Bloom: brighten + briefly scale the arrow at the completion moment.
                .brightness(bloom ? 0.25 : 0)
                .scaleEffect(bloom && !reduceMotion ? 1.18 : 1, anchor: .center)
        }
        .frame(width: glyphWidth, height: glyphHeight)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.55), value: bloom)
        .onChange(of: state) { _, newValue in
            guard newValue == .done else { return }
            triggerBloom()
        }
        .onAppear {
            if state == .done { triggerBloom() }
        }
        .accessibilityElement()
        .accessibilityLabel("goh")
        .accessibilityValue(accessibilityValue)
    }

    private func triggerBloom() {
        bloom = true
        // Settle back to the steady arrow after the bloom peak. The host recedes
        // the state itself (done → idle); this only relaxes the visual pulse.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 360))
            bloom = false
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .idle: return "idle"
        case .active: return "downloading"
        case .paused: return "paused"
        case .done: return "complete"
        case .error: return "error"
        }
    }
}
