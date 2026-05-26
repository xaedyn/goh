import AppKit

/// The production ``TerminalDiscovery`` — looks up bundle identifiers via
/// `NSWorkspace.shared`.
///
/// `urlForApplication(withBundleIdentifier:)` is a Launch Services query;
/// `runningApplications` is a snapshot of the workspace's process table. Both
/// are safe to call from any actor context.
nonisolated public struct NSWorkspaceTerminalDiscovery: TerminalDiscovery {
    public init() {}

    public func isAppInstalled(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    public func isAppRunning(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == bundleIdentifier
        }
    }
}
