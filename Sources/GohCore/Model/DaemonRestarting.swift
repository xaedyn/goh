import Darwin   // getuid() — confined to this file (B-1 fix); not assumed reachable via Foundation on CI's stable SDK
import Foundation

/// Errors from a daemon restart attempt.
public enum DaemonRestartError: Error, Sendable, Equatable {
    /// `launchctl kickstart` exited with a non-zero code.
    case launchctlFailed(exitCode: Int32, stderr: String)
    /// `launchctl` binary was not found or could not be launched.
    case launchctlUnavailable(String)
}

/// Injectable seam for restarting the daemon.
///
/// Production implementation shells `launchctl kickstart -k gui/<uid>/<label>`.
/// Tests inject a stub to verify the decision→action wiring without forking a process.
public protocol DaemonRestarting: Sendable {
    /// Restarts the daemon. Throws `DaemonRestartError` on failure.
    func kickstart() throws
}

/// Live implementation: runs `launchctl kickstart -k gui/<uid>/<machServiceName>`.
///
/// `kickstart -k` is force-restart: it bypasses the KeepAlive semantics and
/// relaunches immediately without throttle. The daemon's plist
/// `KeepAlive = { SuccessfulExit: false }` is irrelevant — `-k` overrides it.
public struct LaunchctlDaemonRestarter: DaemonRestarting {
    public let kickstartTarget: String

    /// - Parameters:
    ///   - uid: User ID for the launchctl `gui/<uid>` domain. Defaults to the
    ///     calling user's uid. `getuid()` is confined to this Darwin-importing
    ///     file so CLI call sites need not import `Darwin` (B-1 fix).
    ///   - machServiceName: The daemon's launchd label (e.g. `dev.goh.daemon`).
    public init(uid: Int = Int(Darwin.getuid()), machServiceName: String) {
        self.kickstartTarget = "gui/\(uid)/\(machServiceName)"
    }

    public func kickstart() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", kickstartTarget]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw DaemonRestartError.launchctlUnavailable("\(error)")
        }
        process.waitUntilExit()
        let status = process.terminationStatus
        guard status == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DaemonRestartError.launchctlFailed(exitCode: status, stderr: stderr)
        }
    }
}
