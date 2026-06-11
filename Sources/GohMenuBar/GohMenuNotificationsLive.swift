import Foundation
import UserNotifications

/// Live implementation of GohMenuNotificationService backed by UNUserNotificationCenter.
/// Errors are swallowed (best-effort); the view never sees raw errors — mirroring
/// SpotlightMetadataTagger's pattern (spec §6 "best-effort side effects").
///
/// The methods are deliberately MainActor-isolated (NOT `nonisolated`). The class is
/// `@MainActor` and holds a non-Sendable `UNUserNotificationCenter`; a `nonisolated`
/// method touching `center` would fail to compile ("non-Sendable type ... cannot exit
/// main actor-isolated context"). A `@MainActor` class is implicitly `Sendable`, so it
/// still satisfies the `Sendable` `GohMenuNotificationService` protocol, and a
/// MainActor-isolated `async` method validly witnesses a `nonisolated async` protocol
/// requirement (the call hops to the actor). The coordinator/caller is `@MainActor`, so
/// `await service.post(...)` continues to work.
@MainActor
public final class LiveNotificationService: GohMenuNotificationService {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func authorizationStatus() async -> GohNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .undetermined
        @unknown default:
            return .undetermined
        }
    }

    public func requestAuthorization() async {
        // Request alert + sound; never throws to caller (best-effort).
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    public func post(_ content: GohNotificationContent) async {
        let status = await authorizationStatus()
        guard status == .authorized else { return }

        let notifContent = UNMutableNotificationContent()
        notifContent.title = content.title
        notifContent.body = content.body
        notifContent.sound = .default
        // Stable thread groups goh's completion banners together in Notification
        // Center instead of stacking them as unrelated alerts.
        notifContent.threadIdentifier = "dev.goh.downloads"

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: notifContent,
            trigger: nil)
        // Swallow: best-effort, view never sees errors (spec §7.2 + §6 rule).
        _ = try? await center.add(request)
    }
}
