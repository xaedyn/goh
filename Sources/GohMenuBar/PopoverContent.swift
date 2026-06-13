import GohCore
import SwiftUI

/// The callbacks the popover invokes. Bundled so the pure `PopoverContent` view
/// stays decoupled from `GohMenuViewModel` / window plumbing — `GohMenuView` wires
/// these to the live model, and the snapshot harness wires them to no-ops.
public struct PopoverActions {
    public var performPrimary: () -> Void
    public var pause: (GohMenuJobRow) -> Void
    public var resume: (GohMenuJobRow) -> Void
    public var remove: (GohMenuJobRow) -> Void
    public var retry: (GohMenuJobRow) -> Void
    public var copy: (String) -> Void
    public var reveal: (String) -> Void
    public var open: (String) -> Void
    public var openAddDownload: () -> Void
    public var openDownloadsFolder: () -> Void
    public var openAllDownloads: () -> Void
    public var openTrust: () -> Void
    public var openTerminal: () -> Void
    public var openSettings: () -> Void
    public var quit: () -> Void
    public var recover: (GohMenuRecoveryAction) -> Void
    public var restartDaemon: () -> Void

    public init(
        performPrimary: @escaping () -> Void = {},
        pause: @escaping (GohMenuJobRow) -> Void = { _ in },
        resume: @escaping (GohMenuJobRow) -> Void = { _ in },
        remove: @escaping (GohMenuJobRow) -> Void = { _ in },
        retry: @escaping (GohMenuJobRow) -> Void = { _ in },
        copy: @escaping (String) -> Void = { _ in },
        reveal: @escaping (String) -> Void = { _ in },
        open: @escaping (String) -> Void = { _ in },
        openAddDownload: @escaping () -> Void = {},
        openDownloadsFolder: @escaping () -> Void = {},
        openAllDownloads: @escaping () -> Void = {},
        openTrust: @escaping () -> Void = {},
        openTerminal: @escaping () -> Void = {},
        openSettings: @escaping () -> Void = {},
        quit: @escaping () -> Void = {},
        recover: @escaping (GohMenuRecoveryAction) -> Void = { _ in },
        restartDaemon: @escaping () -> Void = {}
    ) {
        self.performPrimary = performPrimary
        self.pause = pause
        self.resume = resume
        self.remove = remove
        self.retry = retry
        self.copy = copy
        self.reveal = reveal
        self.open = open
        self.openAddDownload = openAddDownload
        self.openDownloadsFolder = openDownloadsFolder
        self.openAllDownloads = openAllDownloads
        self.openTrust = openTrust
        self.openTerminal = openTerminal
        self.openSettings = openSettings
        self.quit = quit
        self.recover = recover
        self.restartDaemon = restartDaemon
    }
}

/// The redesigned popover body — pure and data-driven so it renders identically
/// from the live view-model or from sample data in the snapshot harness. Layout
/// follows `design/menubar-redesign` README §Popover and the reference
/// screenshots: header (wordmark tile + plain-language status + + / folder / ⋯),
/// optional banners, clipboard CTA, hero active card, "Downloading" group, and
/// "Recent" group.
public struct PopoverContent: View {
    public var state: GohMenuState
    public var trust: GohTrustOverview
    public var daemonSkew: DaemonSkew?
    public var clipboardURL: URL?
    public var actions: PopoverActions

    public init(
        state: GohMenuState,
        trust: GohTrustOverview,
        daemonSkew: DaemonSkew?,
        clipboardURL: URL?,
        actions: PopoverActions
    ) {
        self.state = state
        self.trust = trust
        self.daemonSkew = daemonSkew
        self.clipboardURL = clipboardURL
        self.actions = actions
    }

    // MARK: Derived grouping

    private var heroRow: GohMenuJobRow? {
        state.rows.first { $0.displayState == .active }
    }
    private var downloadingRows: [GohMenuJobRow] {
        let heroID = heroRow?.id
        return state.rows.filter { $0.isInProgress && $0.id != heroID }
    }
    private var recentRows: [GohMenuJobRow] {
        state.rows.filter(\.isTerminal)
    }
    private var trackedCount: Int? {
        if case .summary(let s) = trust { return s.tracked }
        return nil
    }
    private var isUnreachable: Bool {
        if case .failed = state.health { return true }
        return false
    }
    private var showEmptyState: Bool {
        heroRow == nil && downloadingRows.isEmpty && recentRows.isEmpty && !isUnreachable
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isUnreachable, let recovery = state.recoveryAction {
                GohInlineNotice(
                    tone: .error,
                    systemImage: "exclamationmark.triangle.fill",
                    title: "Background service unreachable",
                    detail: state.healthDetail,
                    actionTitle: recovery.shortTitle,
                    action: { actions.recover(recovery) })
            }

            skewBanner

            if let clipboardURL {
                ClipboardCTA(url: clipboardURL, action: actions.performPrimary)
            }

            if let heroRow {
                ActiveDownloadRow(row: heroRow, prominent: true, actions: actions)
            }

            if !downloadingRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    GohSectionHeader("Downloading")
                    GohModuleCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(downloadingRows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { rowDivider }
                                ActiveDownloadRow(row: row, prominent: false, actions: actions)
                                    .padding(11)
                            }
                        }
                    }
                }
            }

            if !recentRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    GohSectionHeader("Recent") {
                        Button("Show All", action: actions.openAllDownloads)
                            .buttonStyle(.plain)
                            .font(GohTheme.Typography.secondary.weight(.semibold))
                            .foregroundStyle(GohTheme.accent)
                    }
                    GohModuleCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(recentRows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { rowDivider }
                                RecentRow(row: row, actions: actions)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 9)
                            }
                        }
                    }
                }
            }

            if showEmptyState {
                emptyState
            }
        }
        .frame(width: GohTheme.Metrics.popoverWidth)
        .padding(13)
    }

    // MARK: Header

    private var header: some View {
        let status = PopoverHeaderStatus(health: state.health, activeCount: state.activeCount,
                                         speedText: state.aggregateSpeedText, trackedCount: trackedCount,
                                         detail: state.healthDetail)
        return HStack(alignment: .center, spacing: 10) {
            GohWordmarkTile(state: status.wordmarkState, glyphWidth: 26)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if status.reconnecting {
                        Circle().fill(GohTheme.accent).frame(width: 6, height: 6)
                            .opacity(0.9)
                    }
                    Text(status.title)
                        .font(GohTheme.Typography.moduleHeader)
                        .foregroundStyle(status.isError ? GohTheme.error : .primary)
                        .lineLimit(1)
                }
                if let subtitle = status.subtitle {
                    Text(subtitle)
                        .font(GohTheme.Typography.secondary)
                        .foregroundStyle(status.isError ? GohTheme.error.opacity(0.9) : .secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            HStack(spacing: 12) {
                headerButton("plus", help: "Add download", action: actions.openAddDownload)
                headerButton("folder", help: "Open Downloads folder", action: actions.openDownloadsFolder)
                overflowMenu
            }
        }
    }

    private func headerButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var overflowMenu: some View {
        Menu {
            Button("All Downloads…", action: actions.openAllDownloads)
            Button("Verify & Trust…", action: actions.openTrust)
            Button("Open in Terminal", action: actions.openTerminal)
            Divider()
            Button("Settings…", action: actions.openSettings)
            Divider()
            Button("Quit goh", action: actions.quit)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .tint(.secondary)
        .fixedSize()
        .help("More")
    }

    @ViewBuilder
    private var skewBanner: some View {
        switch daemonSkew {
        case .staleIdle:
            GohInlineNotice(
                tone: .neutral,
                systemImage: "arrow.clockwise.circle",
                title: "Update ready",
                detail: state.daemonSkewNotice ?? "Background service is ready to update.",
                actionTitle: "Restart",
                action: actions.restartDaemon)
        case .staleBusy:
            if let notice = state.daemonSkewNotice {
                GohInlineNotice(tone: .neutral, systemImage: "clock.arrow.circlepath",
                                title: "Update pending", detail: notice)
            }
        case .current, .none:
            EmptyView()
        }
    }

    private var emptyState: some View {
        GohModuleCard(padding: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing downloading")
                    .font(GohTheme.Typography.rowTitle.weight(.medium))
                    .foregroundStyle(.primary)
                Text("Paste a URL to begin, or use the + button.")
                    .font(GohTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(GohTheme.separator)
            .frame(height: GohTheme.Metrics.hairline)
            .padding(.leading, 11)
    }
}

/// Maps health + activity into the popover's plain-language header status.
nonisolated struct PopoverHeaderStatus {
    let title: String
    let subtitle: String?
    let reconnecting: Bool
    let isError: Bool
    let wordmarkState: GohWordmarkState

    init(health: GohMenuHealth, activeCount: Int, speedText: String, trackedCount: Int?, detail: String?) {
        let trackedText = trackedCount.map { "\($0) tracked" }
        switch health {
        case .connecting:
            title = "Reconnecting…"
            subtitle = trackedText
            reconnecting = true
            isError = false
            wordmarkState = .idle
        case .failed:
            title = "Service unreachable"
            subtitle = detail ?? "Background service is not responding."
            reconnecting = false
            isError = true
            wordmarkState = .error
        case .connected:
            reconnecting = false
            isError = false
            if activeCount > 0 {
                title = "\(activeCount) downloading"
                subtitle = [speedText, trackedText].compactMap { $0 }.joined(separator: " · ")
                wordmarkState = .active
            } else {
                title = "Ready"
                subtitle = trackedText
                wordmarkState = .idle
            }
        }
    }
}

extension GohMenuRecoveryAction {
    /// A compact label for the recovery notice's trailing action.
    nonisolated var shortTitle: String {
        switch self {
        case .copyCommand: return "Copy command"
        case .openDoctor: return "Open doctor"
        }
    }
}
