import AppKit

/// The production ``TerminalDiscovery`` — looks up bundle identifiers via
/// `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`.
///
/// `NSWorkspace`'s URL lookup is a Launch Services query, not a directory
/// scan. It is safe to call from any actor context.
nonisolated public struct NSWorkspaceTerminalDiscovery: TerminalDiscovery {
    public init() {}

    public func isAppInstalled(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
}
