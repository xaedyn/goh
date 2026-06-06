import Foundation

/// Registration state of the tray app as a login item (spec §7.3).
/// Maps SMAppService.Status + an unsupported sentinel for the debug bare-binary path.
nonisolated public enum GohLoginItemStatus: Sendable, Equatable {
    /// Registered and confirmed enabled by the user.
    case enabled
    /// Registered; awaiting user confirmation in System Settings → Login Items.
    case requiresApproval
    /// Not currently registered.
    case notRegistered
    /// The app identifier was not found — typically indicates a stale registration.
    case notFound
    /// Running outside a proper .app bundle (debug dogfood bare binary).
    /// Login-item controls must be disabled in the UI when this is returned.
    case unsupported
}

/// Protocol-fronted login-item service (spec §7.3).
/// Sendable + nonisolated per GohMenuBar convention.
/// Live impl (SMAppService) is wired in goh-menu; unit tests use StubLoginItem.
public protocol GohMenuLoginItem: Sendable {
    /// Returns the current registration status without modifying it.
    nonisolated func status() -> GohLoginItemStatus
    /// Registers the tray app as a login item. Throws on failure so the UI can surface a message.
    nonisolated func register() throws
    /// Unregisters the tray app. Throws on failure so the UI can surface a message.
    nonisolated func unregister() throws
}

// MARK: - Unsupported sentinel (debug bare-binary path)

/// Returned when the app is running outside a proper .app bundle.
/// register()/unregister() throw `GohLoginItemError.unsupported` so callers can surface a message.
nonisolated public struct UnsupportedLoginItem: GohMenuLoginItem, Sendable {
    public nonisolated init() {}

    public nonisolated func status() -> GohLoginItemStatus { .unsupported }

    public nonisolated func register() throws {
        throw GohLoginItemError.unsupported
    }

    public nonisolated func unregister() throws {
        throw GohLoginItemError.unsupported
    }
}

/// Errors surfaced by login-item operations (mapped to plain English by the preferences view).
nonisolated public enum GohLoginItemError: Error, Sendable, Equatable {
    /// The app is running outside a proper .app bundle.
    case unsupported
    /// SMAppService returned an error; message is surfaced to the user.
    case registrationFailed(String)
}
