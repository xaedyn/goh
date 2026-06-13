import Foundation
import GohCore

nonisolated public enum GohMenuHealth: Sendable, Equatable {
    case connecting
    case connected
    case failed(GohMenuError)
}

nonisolated public enum GohMenuError: Error, Sendable, Equatable {
    case daemonUnavailable(String)
    case peerValidation(String)
    case protocolMismatch(String)
    case daemon(GohError)
    case malformedReply(String)

    nonisolated public var userFacingMessage: String {
        switch self {
        case .daemonUnavailable:
            return "goh's background service isn't reachable — run goh doctor."
        case .peerValidation:
            return "The background service failed peer validation — try reinstalling goh."
        case .protocolMismatch:
            return "The tray app and background service are on different versions — restart goh."
        case .daemon(let error):
            return "The background service reported an error: \(error.message ?? error.code.rawValue)."
        case .malformedReply:
            return "The background service sent an unexpected response — run goh doctor."
        }
    }
}

nonisolated public enum GohMenuControl: Sendable, Hashable {
    case pause
    case resume
    case remove
    case revealInFinder
    case copyURL
    case copyDestination
}

/// A row's lifecycle state, mirrored from `GohCore.JobState` so the presentation
/// layer can group rows (hero / Downloading / Recent) and pick per-state context
/// menus without string-comparing `stateText`. Derived presentation data, not new
/// app state — the same role `isPaused` already played, generalized.
nonisolated public enum GohMenuJobDisplayState: Sendable, Equatable {
    case queued
    case active
    case paused
    case completed
    case failed
}

nonisolated public enum GohMenuPrimaryAction: Sendable, Equatable {
    case addClipboardURL(URL)
    case pasteURL
    case diagnose
}

nonisolated public enum GohMenuRecoveryAction: Sendable, Equatable {
    case copyCommand(String)
    case openDoctor
}

nonisolated public struct GohMenuJobRow: Sendable, Equatable, Identifiable {
    public var id: UInt64
    public var title: String
    public var subtitle: String
    public var stateText: String
    /// Lifecycle state mirrored from `JobState`; drives grouping + context menus.
    public var displayState: GohMenuJobDisplayState
    public var progressText: String
    public var speedText: String
    public var destination: String
    public var url: String
    public var controls: Set<GohMenuControl>

    // Rich dashboard fields — all nonisolated Sendable Equatable (same convention).
    /// bytesCompleted/bytesTotal as a fraction [0,1]; nil when bytesTotal is nil.
    public var progressFraction: Double?
    /// Human-readable "downloaded / total" or "downloaded/?" when total unknown.
    public var sizeText: String
    /// "ETA Xs" string; nil when total unknown, rate warming, or job not active.
    public var etaText: String?
    /// Human-readable elapsed time since createdAt (rounded to seconds).
    public var elapsedText: String?
    /// "N connections" string; nil when actualConnectionCount is 0.
    public var connectionText: String?
    /// Verify/provenance status for completed rows; nil for other states or when
    /// the ledger entry is absent/unreadable.
    public var verifyStatus: String?
    /// Short relative completion date for terminal rows ("now", "Jun 5"); nil
    /// while the job is in progress.
    public var completedDateText: String?
    /// Human-readable failure reason for failed rows (from the job's error); nil
    /// otherwise. Drives the red reason line + Retry affordance.
    public var failureReason: String?
    /// Total file size in bytes when known; drives the Downloads-window size
    /// column + the footer total.
    public var bytesTotal: UInt64?
    /// Abbreviated recorded SHA-256 ("a1f3…9c20") for completed rows with a ledger
    /// entry; nil otherwise.
    public var sha256Short: String?

    public init(
        id: UInt64,
        title: String,
        subtitle: String,
        stateText: String,
        displayState: GohMenuJobDisplayState,
        progressText: String,
        speedText: String,
        destination: String,
        url: String,
        controls: Set<GohMenuControl>,
        progressFraction: Double? = nil,
        sizeText: String = "",
        etaText: String? = nil,
        elapsedText: String? = nil,
        connectionText: String? = nil,
        verifyStatus: String? = nil,
        completedDateText: String? = nil,
        failureReason: String? = nil,
        bytesTotal: UInt64? = nil,
        sha256Short: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.stateText = stateText
        self.displayState = displayState
        self.progressText = progressText
        self.speedText = speedText
        self.destination = destination
        self.url = url
        self.controls = controls
        self.progressFraction = progressFraction
        self.sizeText = sizeText
        self.etaText = etaText
        self.elapsedText = elapsedText
        self.connectionText = connectionText
        self.verifyStatus = verifyStatus
        self.completedDateText = completedDateText
        self.failureReason = failureReason
        self.bytesTotal = bytesTotal
        self.sha256Short = sha256Short
    }
}

extension GohMenuJobRow {
    /// True when the job is paused. Preserved as a convenience over `displayState`
    /// so existing call sites keep working.
    public var isPaused: Bool { displayState == .paused }

    /// In-progress rows — queued, active, or paused — that belong in the hero +
    /// "Downloading" region of the popover.
    public var isInProgress: Bool {
        switch displayState {
        case .queued, .active, .paused: return true
        case .completed, .failed: return false
        }
    }

    /// Terminal rows — completed or failed — that belong in "Recent".
    public var isTerminal: Bool {
        switch displayState {
        case .completed, .failed: return true
        case .queued, .active, .paused: return false
        }
    }

    /// Controls ordered for display: pause/resume first, then utility controls, remove last.
    var orderedControls: [GohMenuControl] {
        [
            .pause,
            .resume,
            .revealInFinder,
            .copyURL,
            .copyDestination,
            .remove,
        ].filter { controls.contains($0) }
    }
}

nonisolated public struct GohMenuState: Sendable, Equatable {
    public var health: GohMenuHealth
    public var healthTitle: String
    public var healthDetail: String?
    public var activeCount: Int
    public var aggregateSpeedText: String
    public var primaryAction: GohMenuPrimaryAction
    public var recoveryAction: GohMenuRecoveryAction?
    public var rows: [GohMenuJobRow]
    /// Neutral informational notice when the running daemon is an older build.
    /// `nil` when the daemon is current or skew state is unknown.
    public var daemonSkewNotice: String?

    public init(
        health: GohMenuHealth,
        healthTitle: String,
        healthDetail: String?,
        activeCount: Int,
        aggregateSpeedText: String,
        primaryAction: GohMenuPrimaryAction,
        recoveryAction: GohMenuRecoveryAction?,
        rows: [GohMenuJobRow],
        daemonSkewNotice: String? = nil
    ) {
        self.health = health
        self.healthTitle = healthTitle
        self.healthDetail = healthDetail
        self.activeCount = activeCount
        self.aggregateSpeedText = aggregateSpeedText
        self.primaryAction = primaryAction
        self.recoveryAction = recoveryAction
        self.rows = rows
        self.daemonSkewNotice = daemonSkewNotice
    }
}
