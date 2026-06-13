// goh-snapshots — a developer-only render harness for the menu-bar redesign.
//
// Renders the real `GohMenuBar` SwiftUI views to PNG in both appearances via
// SwiftUI's `ImageRenderer`, so a redesign step can be eyeballed without
// launching the app. It is NOT a shipped product and binds to no daemon.
//
// Caveat: `ImageRenderer` approximates `.regularMaterial` as a flat translucent
// fill — true Liquid Glass vibrancy (desktop blur-through) only appears in the
// running app. Layout, type, color, geometry, and state are faithful.
//
// Usage: goh-snapshots <output-dir>

import AppKit
import GohCore
import GohMenuBar
import SwiftUI

@MainActor
func render(_ name: String, scheme: ColorScheme, into dir: URL, _ content: some View) {
    let board = content
        .environment(\.colorScheme, scheme)
        .background(wallpaper(scheme))
    let renderer = ImageRenderer(content: board)
    renderer.scale = 2
    guard let cg = renderer.cgImage else {
        FileHandle.standardError.write(Data("render failed: \(name)\n".utf8))
        return
    }
    let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
    let url = dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
    try? png.write(to: url)
    print("wrote \(url.lastPathComponent) (\(cg.width)×\(cg.height))")
}

/// A representative wallpaper gradient so the glass tile has something to tint.
@MainActor
func wallpaper(_ scheme: ColorScheme) -> some View {
    let colors: [Color] = scheme == .dark
        ? [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.20, green: 0.10, blue: 0.18)]
        : [Color(red: 0.80, green: 0.86, blue: 0.98), Color(red: 0.96, green: 0.90, blue: 0.80)]
    return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Step 1 board: the wordmark tile across every arrow state, at two sizes
/// (popover-header scale and menu-bar-item scale).
struct WordmarkTileBoard: View {
    let states: [(String, GohWordmarkState)] = [
        ("idle", .idle), ("active", .active), ("paused", .paused),
        ("done", .done), ("error", .error),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            row(glyphWidth: 30, caption: "Popover header (30pt)")
            row(glyphWidth: 18, caption: "Menu-bar status item (18pt)")
        }
        .padding(32)
    }

    func row(glyphWidth: CGFloat, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption)
                .font(GohTheme.Typography.groupLabel)
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                ForEach(states, id: \.0) { label, state in
                    VStack(spacing: 7) {
                        GohWordmarkTile(state: state, glyphWidth: glyphWidth)
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Step 2: the popover

/// A busy popover matching the reference screenshots: clipboard CTA, a hero
/// active download, a second downloading row, and three recent rows.
@MainActor
func samplePopover() -> some View {
    func row(
        id: UInt64, title: String, state: GohMenuJobDisplayState,
        fraction: Double? = nil, size: String = "", speed: String = "",
        eta: String? = nil, completed: String? = nil, failure: String? = nil
    ) -> GohMenuJobRow {
        GohMenuJobRow(
            id: id, title: title, subtitle: "/Users/me/Downloads/\(title)",
            stateText: "", displayState: state, progressText: "",
            speedText: speed, destination: "/Users/me/Downloads/\(title)",
            url: "https://huggingface.co/\(title)", controls: [],
            progressFraction: fraction, sizeText: size, etaText: eta,
            completedDateText: completed, failureReason: failure)
    }

    let rows = [
        row(id: 1, title: "mistral-7b-v0.3.safetensors", state: .active,
            fraction: 0.92, size: "13.4 of 14.5 GB", speed: "7.2 MB/s", eta: "1s"),
        row(id: 2, title: "dataset-shard-00007.parquet", state: .active,
            fraction: 0.10, size: "5.01 of 512 MB", speed: "3.4 MB/s", eta: "2m"),
        row(id: 3, title: "llama-3.1-70b-instruct.safetensors", state: .completed, completed: "now"),
        row(id: 4, title: "imagenet-val.tar.zst", state: .failed,
            failure: "Couldn't connect — server returned 503"),
        row(id: 5, title: "sd-xl-base-1.0.safetensors", state: .completed, completed: "Jun 5"),
    ]

    let state = GohMenuState(
        health: .connected, healthTitle: "", healthDetail: nil,
        activeCount: 2, aggregateSpeedText: "6.4 MB/s",
        primaryAction: .addClipboardURL(URL(string: "https://huggingface.co/meta-llama/Llama-3.1-70B")!),
        recoveryAction: nil, rows: rows)

    let trust = GohTrustOverview.summary(GohTrustSummary(tracked: 48, verified: 41, downloadOnly: 7))

    return PopoverContent(
        state: state, trust: trust, daemonSkew: nil,
        clipboardURL: URL(string: "https://huggingface.co/meta-llama/Llama-3.1-70B"),
        actions: PopoverActions())
}

// MARK: - Step 3: the menu-bar status item

/// A simulated menu-bar strip carrying the status item in each lifecycle state,
/// plus a manual filmstrip of the completion bloom (active → bloom peak → recede).
struct StatusItemBoard: View {
    let states: [(String, GohWordmarkState)] = [
        ("idle", .idle), ("active", .active), ("paused", .paused),
        ("done", .done), ("error", .error),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Status item — states")
                    .font(GohTheme.Typography.groupLabel).foregroundStyle(.secondary)
                HStack(spacing: 26) {
                    ForEach(states, id: \.0) { label, state in
                        VStack(spacing: 8) {
                            menuBarChip { GohStatusItemIcon(state: state, glyphHeight: 16) }
                            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Completion bloom (motion) — left→right")
                    .font(GohTheme.Typography.groupLabel).foregroundStyle(.secondary)
                HStack(spacing: 22) {
                    bloomFrame(0.0, arrowVisible: true)   // active, steady
                    bloomFrame(0.5, arrowVisible: true)   // brightening
                    bloomFrame(1.0, arrowVisible: true)   // peak bloom
                    bloomFrame(0.4, arrowVisible: true)   // settling
                    bloomFrame(0.0, arrowVisible: false)  // receded → idle
                }
            }
        }
        .padding(30)
    }

    /// A small rounded menu-bar-like chip behind the icon.
    func menuBarChip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Manual depiction of one bloom frame (the live view's bloom is @State-driven
    /// and can't be captured statically): the arrow brightens + scales at `t`.
    func bloomFrame(_ t: Double, arrowVisible: Bool) -> some View {
        let glyphHeight: CGFloat = 16
        return menuBarChip {
            ZStack {
                Image(nsImage: GohWordmark.letters).resizable().renderingMode(.template)
                    .scaledToFit().foregroundStyle(.primary)
                Image(nsImage: GohWordmark.arrow).resizable().renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(arrowVisible ? GohTheme.accent : .clear)
                    .brightness(0.25 * t)
                    .scaleEffect(1 + 0.18 * t)
            }
            .frame(width: glyphHeight * GohWordmark.aspectRatio, height: glyphHeight)
        }
    }
}

@MainActor
func main() {
    let args = CommandLine.arguments
    let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    render("wordmark-tile", scheme: .dark, into: dir, WordmarkTileBoard())
    render("wordmark-tile", scheme: .light, into: dir, WordmarkTileBoard())

    render("popover", scheme: .dark, into: dir, samplePopover().padding(28))
    render("popover", scheme: .light, into: dir, samplePopover().padding(28))

    render("status-item", scheme: .dark, into: dir, StatusItemBoard())
    render("status-item", scheme: .light, into: dir, StatusItemBoard())
}

MainActor.assumeIsolated { main() }
