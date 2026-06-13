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

// MARK: - Step 4: Add Download window

/// No-op stubs — the snapshot renders a static form, so these are never called.
@MainActor
final class SnapshotMenuClient: GohMenuClient {
    func progressSnapshots() -> AsyncThrowingStream<[ProgressSnapshot], any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func add(_ request: AddRequest) async throws -> JobSummary { throw CancellationError() }
    func pause(jobID: UInt64) async throws {}
    func resume(jobID: UInt64) async throws {}
    func remove(jobID: UInt64, keepPartialFile: Bool) async throws {}
    func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry]) async throws {}
    func ls() async throws -> LsReply { throw CancellationError() }
    func forget(paths: [String]) async throws {}
}

struct SnapshotFolderPicker: FolderPicker {
    func chooseFolder() async -> String? { nil }
}

/// The Add Download content inside a faux window chrome (title bar + traffic
/// lights) so the snapshot reads like the real window.
@MainActor
func addDownloadBoard() -> some View {
    let vm = AddDownloadViewModel(
        initialURL: "https://huggingface.co/org/model-00003.safetensors",
        client: SnapshotMenuClient(),
        folderPicker: SnapshotFolderPicker())

    return VStack(spacing: 0) {
        ZStack {
            Text("Add Download").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                Spacer()
            }
            .padding(.horizontal, 13)
        }
        .frame(width: 340, height: 38)

        AddDownloadView(vm: vm)
    }
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    .padding(34)
}

// MARK: - Step 5: Downloads window

@MainActor
func downloadsBoard() -> some View {
    let vm = GohMenuViewModel(
        client: SnapshotMenuClient(),
        pasteboardText: { nil }, revealInFinder: { _ in },
        openTerminalDashboard: {}, copyText: { _ in })

    func active(_ id: UInt64, _ title: String, _ state: GohMenuJobDisplayState,
                _ frac: Double?, _ size: String, _ speed: String = "", _ eta: String? = nil) -> GohMenuJobRow {
        GohMenuJobRow(
            id: id, title: title, subtitle: title, stateText: "", displayState: state,
            progressText: "", speedText: speed, destination: "/Users/me/Downloads/\(title)",
            url: "https://huggingface.co/org/\(title)", controls: [],
            progressFraction: frac, sizeText: size, etaText: eta)
    }
    func recent(_ id: UInt64, _ title: String, _ bytes: UInt64, _ sha: String, _ date: String) -> GohMenuJobRow {
        GohMenuJobRow(
            id: id, title: title, subtitle: title, stateText: "", displayState: .completed,
            progressText: "", speedText: "", destination: "/Users/me/Downloads/\(title)",
            url: "https://huggingface.co/org/\(title)", controls: [],
            completedDateText: date, bytesTotal: bytes, sha256Short: sha)
    }

    let downloading = [
        active(1, "llama-3.1-70b-instruct.safetensors", .active, 0.66, "43.6 of 66.4 GB", "5.1 MB/s", "1m 12s"),
        active(2, "imagenet-val.tar.zst", .active, 0.28, "1.79 of 6.40 GB", "1.3 MB/s", "4m 03s"),
        active(3, "dataset-shard-00007.parquet", .queued, 0, ""),
    ]
    let recents = [
        recent(4, "sd-xl-base-1.0.safetensors", 6_940_000_000, "a1f3…9c20", "Today"),
        recent(5, "config.json", 4_200, "773e…01de", "Today"),
        recent(6, "tokenizer.model", 2_100_000, "6820…1a4c", "Today"),
    ]

    func sectionCard<R: View>(_ rows: [GohMenuJobRow], @ViewBuilder row: @escaping (GohMenuJobRow) -> R) -> some View {
        GohModuleCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    if i > 0 {
                        Rectangle().fill(GohTheme.separator).frame(height: 0.5).padding(.leading, 50)
                    }
                    row(r)
                }
            }
        }
    }

    let body = VStack(spacing: 0) {
        // faux title bar
        ZStack {
            Text("Downloads").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                Spacer()
            }.padding(.horizontal, 13)
        }.frame(height: 38)
        // faux toolbar (the real segmented/search controls don't render in ImageRenderer)
        HStack(spacing: 8) {
            ForEach(["All", "Downloading", "Completed", "Failed"], id: \.self) { label in
                Text(label).font(.system(size: 12, weight: label == "All" ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(label == "All" ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                in: Capsule())
                    .foregroundStyle(label == "All" ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.tertiary)
                Text("Search downloads").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7)).frame(width: 180)
        }.padding(.horizontal, 14).padding(.vertical, 9)

        // Plain VStack (not ScrollView): ImageRenderer doesn't lay out ScrollView
        // content. The real DownloadsWindowView keeps its ScrollView.
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                GohSectionHeader("Downloading") {
                    Text("2 active").font(GohTheme.Typography.secondary).foregroundStyle(.secondary)
                }
                sectionCard(downloading) { DownloadsActiveRow(row: $0, model: vm) }
            }
            VStack(alignment: .leading, spacing: 6) {
                GohSectionHeader("Recent") {
                    Text("46 total").font(GohTheme.Typography.secondary).foregroundStyle(.secondary)
                }
                sectionCard(recents) { DownloadsRecentRow(row: $0, model: vm, openTrust: {}) }
            }
            Spacer(minLength: 0)
        }.padding(14)

        // faux footer
        HStack {
            Text("46 downloads · 3 active · 109 GB total")
                .font(GohTheme.Typography.secondary).foregroundStyle(.secondary)
            Spacer()
            Label("Open Folder", systemImage: "folder").font(.system(size: 12))
            Text("Clear Completed").font(.system(size: 12))
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }
    .frame(width: 540, height: 560)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    .padding(34)

    return body
}

// MARK: - Step 6: Trust window

@MainActor
func countPair(_ value: String, _ label: String, _ color: Color) -> some View {
    HStack(spacing: 3) {
        Text(value).fontWeight(.semibold).foregroundStyle(color).monospacedDigit()
        Text(label).foregroundStyle(.secondary)
    }
}

@MainActor
func trustBoard(liveCurrentHash: String?) -> some View {
    func entry(_ path: String, _ url: String, _ sha: String, _ size: Int, verified: Bool) -> GohTrustEntryRow {
        GohTrustEntryRow(
            displayPath: "/Users/me/Downloads/\(path)", sanitizedURL: url, sha256: sha,
            downloadedAt: Date(timeIntervalSince1970: 1_748_600_000),
            verifiedAt: verified ? Date(timeIntervalSince1970: 1_749_370_000) : nil, size: size)
    }

    let rows: [(GohTrustEntryRow, TrustDisplayStatus)] = [
        (entry("llama-3.1-70b-instruct.safetensors", "huggingface.co/meta/llama", "sha256:11aa…", 66_400_000_000, verified: true), .verified(at: Date(timeIntervalSince1970: 1_749_370_000))),
        (entry("sd-xl-base-1.0.safetensors", "huggingface.co/stabilityai/sdxl", "sha256:22bb…", 6_940_000_000, verified: true), .verified(at: Date(timeIntervalSince1970: 1_749_370_000))),
        (entry("imagenet-val.tar.zst", "academictorrents.com/imagenet", "sha256:33cc…", 6_400_000_000, verified: true), .verified(at: Date(timeIntervalSince1970: 1_749_370_000))),
        (entry("tokenizer.model", "huggingface.co/meta/llama", "sha256:44dd…", 2_100_000, verified: false), .recordedOnly),
        (entry("vocab.bpe", "cdn.example.com/gpt2/vocab.bpe", "sha256:80aa559f31b1c2774aae478c285c1f0a77b2b82877be8201da55985d9a11ee47", 1_000_000, verified: false), .changed(.size)),
    ]
    let changed = rows.last!.0

    let body = VStack(spacing: 0) {
        // faux title bar
        ZStack {
            Text("Trust").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                Spacer()
            }.padding(.horizontal, 13)
        }.frame(height: 38)
        // summary toolbar
        HStack(spacing: 7) {
            countPair("48", "tracked", .primary)
            Text("·").foregroundStyle(.tertiary)
            countPair("41", "verified", GohTheme.accent)
            Text("·").foregroundStyle(.tertiary)
            countPair("6", "download-only", .secondary)
            Text("·").foregroundStyle(.tertiary)
            countPair("1", "changed", GohTheme.error)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.tertiary)
                Text("Search").font(.system(size: 12)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7)).frame(width: 150)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14).padding(.vertical, 10)
        Divider().opacity(0.5)

        HStack(spacing: 0) {
            // list
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                    TrustListRow(row: item.0, status: item.1, selected: item.0.displayPath == changed.displayPath)
                }
                Spacer(minLength: 0)
            }
            .padding(8).frame(width: 250)
            Divider()
            // inspector (changed file with the hash diff)
            TrustInspector(
                row: changed,
                status: .changed(.size),
                currentHash: liveCurrentHash,
                changeReason: "The file's size differs from the recorded 1.0 MB.")
                .frame(maxWidth: .infinity)
        }
        .frame(height: 470)

        Divider().opacity(0.5)
        HStack {
            Text("Last check: 47 OK · 1 changed").font(GohTheme.Typography.secondary).foregroundStyle(.secondary)
            Spacer()
            Label("Attest…", systemImage: "checkmark.seal").font(.system(size: 12))
            Label("Verify All", systemImage: "checkmark.shield").font(.system(size: 12)).foregroundStyle(GohTheme.accent)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }
    .frame(width: 760)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    .padding(34)

    return body
}

// MARK: - Step 7: Settings window

/// Stub login item + preferences for the static Settings render.
struct SnapshotLoginItem: GohMenuLoginItem {
    func status() -> GohLoginItemStatus { .enabled }
    func register() throws {}
    func unregister() throws {}
}

@MainActor
func settingsBoard() -> some View {
    let body = VStack(spacing: 0) {
        ZStack {
            Text("goh Settings").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                Spacer()
            }.padding(.horizontal, 13)
        }.frame(height: 38)

        GohMenuPreferencesView(
            preferences: UserDefaultsMenuPreferences(suiteName: "goh.snapshot.settings"),
            loginItem: SnapshotLoginItem())
    }
    .frame(width: 380)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    .padding(34)

    return body
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

    render("add-download", scheme: .dark, into: dir, addDownloadBoard())
    render("add-download", scheme: .light, into: dir, addDownloadBoard())

    render("downloads", scheme: .dark, into: dir, downloadsBoard())
    render("downloads", scheme: .light, into: dir, downloadsBoard())

    let sampleCurrent = "80aa559f31b1c2774a978a9382be81779c28a1f3c8a24b7d8f9123ac77be8281"
    render("trust", scheme: .dark, into: dir, trustBoard(liveCurrentHash: sampleCurrent))
    render("trust", scheme: .light, into: dir, trustBoard(liveCurrentHash: sampleCurrent))
    // The live shipping state (no on-disk hash computed yet) — must still read alarming.
    render("trust-live", scheme: .dark, into: dir, trustBoard(liveCurrentHash: nil))
    render("trust-live", scheme: .light, into: dir, trustBoard(liveCurrentHash: nil))

    render("settings", scheme: .dark, into: dir, settingsBoard())
    render("settings", scheme: .light, into: dir, settingsBoard())
}

MainActor.assumeIsolated { main() }
