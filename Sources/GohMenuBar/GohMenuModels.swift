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
    /// True when the job is paused. Drives paused-specific display without an
    /// English-string compare against `stateText`.
    public var isPaused: Bool
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

    public init(
        id: UInt64,
        title: String,
        subtitle: String,
        stateText: String,
        isPaused: Bool = false,
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
        verifyStatus: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.stateText = stateText
        self.isPaused = isPaused
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
    }
}

extension GohMenuJobRow {
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
