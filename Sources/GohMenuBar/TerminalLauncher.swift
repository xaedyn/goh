import Foundation

/// The terminal emulators `goh-menu` knows how to hand a command to.
///
/// Each case carries the bundle identifier the launcher detects via
/// ``TerminalDiscovery`` and the macOS invocation that opens a fresh window
/// running a shell command. The single-arg `command` is passed through unmodified
/// (already shell-quoted by ``GohTerminalCommandBuilder``); CLI-based terminals
/// wrap it through `/bin/sh -c` so embedded `export FOO=bar; …` runs as expected.
nonisolated public enum TerminalLauncher: String, CaseIterable, Sendable, Equatable {
    case ghostty
    case iTerm
    case wezterm
    case alacritty
    case kitty
    case appleTerminal

    /// The macOS bundle identifier used for installation detection.
    public var bundleIdentifier: String {
        switch self {
        case .ghostty: return "com.mitchellh.ghostty"
        case .iTerm: return "com.googlecode.iterm2"
        case .wezterm: return "com.github.wez.wezterm"
        case .alacritty: return "org.alacritty"
        case .kitty: return "net.kovidgoyal.kitty"
        case .appleTerminal: return "com.apple.Terminal"
        }
    }

    /// Returns the `Process`-ready invocation that opens a fresh terminal
    /// window running `command`.
    public func invocation(for command: String) -> TerminalInvocation {
        switch self {
        case .appleTerminal:
            // Apple Terminal's AppleScript dictionary speaks `do script` —
            // open a new window/tab and run the script there.
            let script = """
                tell application "Terminal"
                  activate
                  do script \(Self.appleScriptStringLiteral(command))
                end tell
                """
            return TerminalInvocation(
                executablePath: "/usr/bin/osascript",
                arguments: ["-e", script])

        case .iTerm:
            // iTerm2's AppleScript dictionary uses `create window with default
            // profile command "…"` to spawn a new window running the command.
            let script = """
                tell application "iTerm"
                  activate
                  create window with default profile command \(Self.appleScriptStringLiteral(command))
                end tell
                """
            return TerminalInvocation(
                executablePath: "/usr/bin/osascript",
                arguments: ["-e", script])

        case .ghostty:
            // Ghostty on macOS: per its own `--help`, CLI launching is not
            // supported — use `open -na Ghostty.app --args …`. The `-e` flag
            // follows the xterm convention: `-e <prog> [args…]` execs `prog`
            // directly, no shell interpretation. To run a command string that
            // may include `export FOO=bar; …`, wrap it in `/bin/sh -c`.
            return TerminalInvocation(
                executablePath: "/usr/bin/open",
                arguments: [
                    "-na", "Ghostty.app", "--args",
                    "-e", "/bin/sh", "-c", command,
                ])

        case .wezterm:
            // WezTerm's `start` subcommand spawns a new window;
            // `--always-new-process` avoids attaching to an existing one.
            return TerminalInvocation(
                executablePath: "/usr/bin/open",
                arguments: [
                    "-na", "WezTerm.app", "--args",
                    "start", "--always-new-process",
                    "/bin/sh", "-c", command,
                ])

        case .alacritty:
            // Alacritty's `-e` runs the given command as its child process.
            return TerminalInvocation(
                executablePath: "/usr/bin/open",
                arguments: [
                    "-na", "Alacritty.app", "--args",
                    "-e", "/bin/sh", "-c", command,
                ])

        case .kitty:
            // kitty.app takes the executable + args directly after `--args`.
            return TerminalInvocation(
                executablePath: "/usr/bin/open",
                arguments: [
                    "-na", "kitty.app", "--args",
                    "/bin/sh", "-c", command,
                ])
        }
    }

    /// AppleScript string-literal escaping for `value` — backslashes, double
    /// quotes, and newlines are the three sequences that break the parser.
    private static func appleScriptStringLiteral(_ value: String) -> String {
        "\""
            + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            + "\""
    }
}

/// A `Process`-ready invocation: the executable to run and the args to pass.
nonisolated public struct TerminalInvocation: Sendable, Equatable {
    public var executablePath: String
    public var arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

/// Detects whether a terminal emulator is installed by bundle identifier.
nonisolated public protocol TerminalDiscovery: Sendable {
    func isAppInstalled(bundleIdentifier: String) -> Bool
}

extension TerminalLauncher {
    /// The fixed priority order auto-detect walks: modern user-installed
    /// terminals first, Apple Terminal last (always present).
    public static let priorityOrder: [TerminalLauncher] = [
        .ghostty, .iTerm, .wezterm, .alacritty, .kitty, .appleTerminal,
    ]

    /// The highest-priority installed terminal. Always returns a value —
    /// Apple Terminal is the universal fallback.
    public static func preferred(in discovery: any TerminalDiscovery) -> TerminalLauncher {
        for launcher in priorityOrder
            where discovery.isAppInstalled(bundleIdentifier: launcher.bundleIdentifier) {
            return launcher
        }
        return .appleTerminal
    }
}
