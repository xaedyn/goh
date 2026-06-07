import Foundation
import GohCore

nonisolated public enum GohMenuHealth: Sendable, Equatable {
    case connecting
    case connected
    case reconnecting
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
    public var progressText: String
    public var speedText: String
    public var destination: String
    public var url: String
    public var controls: Set<GohMenuControl>

    public init(
        id: UInt64,
        title: String,
        subtitle: String,
        stateText: String,
        progressText: String,
        speedText: String,
        destination: String,
        url: String,
        controls: Set<GohMenuControl>
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.stateText = stateText
        self.progressText = progressText
        self.speedText = speedText
        self.destination = destination
        self.url = url
        self.controls = controls
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

    public init(
        health: GohMenuHealth,
        healthTitle: String,
        healthDetail: String?,
        activeCount: Int,
        aggregateSpeedText: String,
        primaryAction: GohMenuPrimaryAction,
        recoveryAction: GohMenuRecoveryAction?,
        rows: [GohMenuJobRow]
    ) {
        self.health = health
        self.healthTitle = healthTitle
        self.healthDetail = healthDetail
        self.activeCount = activeCount
        self.aggregateSpeedText = aggregateSpeedText
        self.primaryAction = primaryAction
        self.recoveryAction = recoveryAction
        self.rows = rows
    }
}
