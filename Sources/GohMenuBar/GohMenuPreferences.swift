import Foundation

/// Protocol-fronted preferences store for goh-menu.
/// Conforms to Sendable (nonisolated) per the GohMenuBar convention.
/// The injectable interface uses UserDefaults directly; @AppStorage is confined
/// to the SwiftUI view layer (spec §7.1).
public protocol GohMenuPreferences: AnyObject, Sendable {
    /// Whether completion/failure notifications are enabled. Defaults to true when absent.
    var notificationsEnabled: Bool { get set }
    /// Whether the tray app registers as a login item. Defaults to false when absent.
    var launchAtLoginEnabled: Bool { get set }
    /// Whether the menu-bar icon reflects download progress (green-when-active +
    /// the completion bloom). Defaults to true when absent.
    var showProgressOnIcon: Bool { get set }
}

/// Live implementation backed by UserDefaults.
/// Keys are prefixed with the bundle identifier at runtime; tests may pass a
/// uniquely-named suite to isolate state.
/// Marked nonisolated per the GohMenuBar convention (the target defaults to MainActor
/// isolation; this class opts out because UserDefaults is already thread-safe and the
/// class must be callable from any context — including nonisolated test bodies).
nonisolated public final class UserDefaultsMenuPreferences: GohMenuPreferences, @unchecked Sendable {
    private let defaults: UserDefaults
    private enum Key {
        static let notificationsEnabled = "GohMenuNotificationsEnabled"
        static let launchAtLoginEnabled = "GohMenuLaunchAtLoginEnabled"
        static let showProgressOnIcon = "GohMenuShowProgressOnIcon"
    }

    /// Production initializer: uses standard UserDefaults (keyed by bundle ID).
    public nonisolated convenience init() {
        self.init(defaults: .standard)
    }

    /// Test initializer: uses a named suite so tests are isolated and removable.
    /// Fails loudly on an invalid suite name rather than silently collapsing to
    /// `.standard` (which would pollute the real defaults during tests).
    public nonisolated convenience init(suiteName: String) {
        guard let suite = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("invalid UserDefaults suite name: \(suiteName)")
        }
        self.init(defaults: suite)
    }

    private nonisolated init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Defaults to `true` when absent — completion notifications are a core
    /// affordance; users opt out, not in.
    public nonisolated var notificationsEnabled: Bool {
        get { defaults.object(forKey: Key.notificationsEnabled) == nil ? true : defaults.bool(forKey: Key.notificationsEnabled) }
        set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    public nonisolated var launchAtLoginEnabled: Bool {
        get { defaults.bool(forKey: Key.launchAtLoginEnabled) }
        set { defaults.set(newValue, forKey: Key.launchAtLoginEnabled) }
    }

    /// Defaults to `true` when absent (most users want the icon to reflect activity).
    public nonisolated var showProgressOnIcon: Bool {
        get { defaults.object(forKey: Key.showProgressOnIcon) == nil ? true : defaults.bool(forKey: Key.showProgressOnIcon) }
        set { defaults.set(newValue, forKey: Key.showProgressOnIcon) }
    }
}
