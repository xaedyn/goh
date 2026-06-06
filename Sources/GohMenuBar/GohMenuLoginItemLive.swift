import Foundation
import ServiceManagement

/// Live implementation of GohMenuLoginItem backed by SMAppService.mainApp.
/// Requires a valid .app bundle with CFBundleIdentifier.
/// Use UnsupportedLoginItem when running as a bare binary.
nonisolated public final class SMAppServiceLoginItem: GohMenuLoginItem, Sendable {
    public init() {}

    public nonisolated func status() -> GohLoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled:           return .enabled
        case .requiresApproval:  return .requiresApproval
        case .notRegistered:     return .notRegistered
        case .notFound:          return .notFound
        @unknown default:        return .notFound
        }
    }

    public nonisolated func register() throws {
        do {
            try SMAppService.mainApp.register()
        } catch {
            throw GohLoginItemError.registrationFailed(error.localizedDescription)
        }
    }

    public nonisolated func unregister() throws {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            throw GohLoginItemError.registrationFailed(error.localizedDescription)
        }
    }
}
