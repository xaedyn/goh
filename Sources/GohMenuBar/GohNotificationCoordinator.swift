import Foundation
import GohCore

@MainActor
public final class GohNotificationCoordinator {
    private let detector = GohNotificationTransitionDetector()
    private let preferences: any GohMenuPreferences
    private var previous: [UInt64: JobState]? = nil  // nil = not yet seeded

    public init(preferences: any GohMenuPreferences) {
        self.preferences = preferences
    }

    /// Call once per REAL snapshot delivery, in order (seed first, then updates).
    /// Returns the notifications to post. State advances regardless of the
    /// notifications-enabled toggle so that enabling later does not replay history.
    public func evaluate(_ snapshots: [ProgressSnapshot]) -> [GohNotificationContent] {
        let (toPost, next) = detector.evaluate(previous: previous, snapshots: snapshots)
        previous = next
        guard preferences.notificationsEnabled else { return [] }
        return toPost
    }
}
