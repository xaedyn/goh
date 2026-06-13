import Foundation

/// SF Symbol + accessibility copy for the inline row controls. Used by the
/// Downloads window's per-row control cluster (the popover uses its own circular
/// Safari-style controls).
extension GohMenuControl {
    nonisolated var systemImageName: String {
        switch self {
        case .pause: return "pause.fill"
        case .resume: return "play.fill"
        case .remove: return "trash"
        case .revealInFinder: return "folder"
        case .copyURL: return "link"
        case .copyDestination: return "doc.on.doc"
        }
    }

    nonisolated var helpText: String {
        switch self {
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .remove: return "Remove job, keep file"
        case .revealInFinder: return "Reveal in Finder"
        case .copyURL: return "Copy URL"
        case .copyDestination: return "Copy destination"
        }
    }

    nonisolated var accessibilityLabel: String { helpText }
}
