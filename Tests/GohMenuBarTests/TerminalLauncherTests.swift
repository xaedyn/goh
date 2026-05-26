import Testing

@testable import GohMenuBar

@Suite("TerminalLauncher")
struct TerminalLauncherTests {

    private struct MockDiscovery: TerminalDiscovery {
        let installed: Set<String>
        func isAppInstalled(bundleIdentifier: String) -> Bool {
            installed.contains(bundleIdentifier)
        }
    }

    // MARK: - Priority order

    @Test("Ghostty wins when installed alongside Apple Terminal")
    func ghosttyPreferredOverAppleTerminal() {
        let discovery = MockDiscovery(installed: [
            "com.mitchellh.ghostty",
            "com.apple.Terminal",
        ])
        #expect(TerminalLauncher.preferred(in: discovery) == .ghostty)
    }

    @Test("Ghostty wins when every modern terminal is installed")
    func ghosttyWinsAtTheTop() {
        let discovery = MockDiscovery(installed: Set(
            TerminalLauncher.allCases.map(\.bundleIdentifier)))
        #expect(TerminalLauncher.preferred(in: discovery) == .ghostty)
    }

    @Test("iTerm wins below Ghostty but above WezTerm/Alacritty/kitty/Terminal")
    func iTermPriorityOrdering() {
        let discovery = MockDiscovery(installed: [
            "com.googlecode.iterm2",
            "com.github.wez.wezterm",
            "org.alacritty",
            "net.kovidgoyal.kitty",
            "com.apple.Terminal",
        ])
        #expect(TerminalLauncher.preferred(in: discovery) == .iTerm)
    }

    @Test("Apple Terminal is the universal fallback when nothing is detected")
    func appleTerminalFallback() {
        let discovery = MockDiscovery(installed: [])
        #expect(TerminalLauncher.preferred(in: discovery) == .appleTerminal)
    }

    @Test("priorityOrder lists every launcher exactly once")
    func priorityOrderIsComplete() {
        let priority = TerminalLauncher.priorityOrder
        #expect(Set(priority) == Set(TerminalLauncher.allCases))
        #expect(priority.count == TerminalLauncher.allCases.count)
    }

    @Test("Apple Terminal is the last element of priorityOrder")
    func appleTerminalIsLast() {
        #expect(TerminalLauncher.priorityOrder.last == .appleTerminal)
    }

    // MARK: - Invocations

    @Test("Ghostty invocation uses `open -na Ghostty.app --args -e /bin/sh -c <command>`")
    func ghosttyInvocation() {
        // Ghostty's `-e` is xterm-convention — argument is a program path,
        // not a shell string — so multi-statement commands must be wrapped
        // in `/bin/sh -c`. Verified live against the user's Ghostty install.
        let invocation = TerminalLauncher.ghostty.invocation(for: "goh top")
        #expect(invocation.executablePath == "/usr/bin/open")
        #expect(invocation.arguments == [
            "-na", "Ghostty.app", "--args",
            "-e", "/bin/sh", "-c", "goh top",
        ])
    }

    @Test("Apple Terminal invocation uses osascript with `tell application Terminal`")
    func appleTerminalInvocation() {
        let invocation = TerminalLauncher.appleTerminal.invocation(for: "goh top")
        #expect(invocation.executablePath == "/usr/bin/osascript")
        #expect(invocation.arguments.count == 2)
        #expect(invocation.arguments[0] == "-e")
        #expect(invocation.arguments[1].contains(#"tell application "Terminal""#))
        #expect(invocation.arguments[1].contains(#"do script "goh top""#))
        #expect(invocation.arguments[1].contains("activate"))
    }

    @Test("iTerm invocation uses osascript with `create window with default profile command`")
    func iTermInvocation() {
        let invocation = TerminalLauncher.iTerm.invocation(for: "goh top")
        #expect(invocation.executablePath == "/usr/bin/osascript")
        #expect(invocation.arguments[1].contains(#"tell application "iTerm""#))
        #expect(invocation.arguments[1].contains(
            #"create window with default profile command "goh top""#))
    }

    @Test("WezTerm invocation passes through `/bin/sh -c` so multi-statement commands work")
    func wezTermInvocation() {
        let invocation = TerminalLauncher.wezterm.invocation(for: "goh top")
        #expect(invocation.executablePath == "/usr/bin/open")
        #expect(invocation.arguments == [
            "-na", "WezTerm.app", "--args",
            "start", "--always-new-process",
            "/bin/sh", "-c", "goh top",
        ])
    }

    @Test("Alacritty invocation uses `-e /bin/sh -c <command>`")
    func alacrittyInvocation() {
        let invocation = TerminalLauncher.alacritty.invocation(for: "goh top")
        #expect(invocation.executablePath == "/usr/bin/open")
        #expect(invocation.arguments == [
            "-na", "Alacritty.app", "--args",
            "-e", "/bin/sh", "-c", "goh top",
        ])
    }

    @Test("kitty invocation wraps the command in `/bin/sh -c`")
    func kittyInvocation() {
        let invocation = TerminalLauncher.kitty.invocation(for: "goh top")
        #expect(invocation.executablePath == "/usr/bin/open")
        #expect(invocation.arguments == [
            "-na", "kitty.app", "--args",
            "/bin/sh", "-c", "goh top",
        ])
    }

    // MARK: - Escaping

    @Test("AppleScript escaping handles embedded double quotes")
    func appleScriptEscapesDoubleQuotes() {
        let command = #"export X="hello"; goh top"#
        let invocation = TerminalLauncher.appleTerminal.invocation(for: command)
        // The outer "..." quote literal contains escaped \"hello\".
        #expect(invocation.arguments[1].contains(#"\"hello\""#))
    }

    @Test("AppleScript escaping handles embedded backslashes")
    func appleScriptEscapesBackslashes() {
        let command = #"goh add 'C:\path\to\file'"#
        let invocation = TerminalLauncher.appleTerminal.invocation(for: command)
        // Backslashes are doubled in the AppleScript string literal.
        #expect(invocation.arguments[1].contains(#"C:\\path\\to\\file"#))
    }

    @Test("AppleScript escaping handles embedded newlines")
    func appleScriptEscapesNewlines() {
        let command = "goh top\nrm -rf /"
        let invocation = TerminalLauncher.appleTerminal.invocation(for: command)
        // Newlines become \n escapes inside the string literal.
        #expect(invocation.arguments[1].contains(#"goh top\nrm -rf /"#))
        // And the raw newline must NOT survive into the script body.
        #expect(invocation.arguments[1].contains(#"do script "goh top\nrm -rf /""#))
    }

    @Test("multi-statement commands with `export … ; goh …` round-trip unchanged through CLI launchers")
    func dogfoodCommandRoundTrip() {
        let command = "export GOH_XPC_ALLOW_UNVALIDATED_PEERS=1; goh top"
        // CLI launchers carry the whole string in a single arg, so embedded
        // semicolons and spaces are not split.
        let ghosttyArgs = TerminalLauncher.ghostty.invocation(for: command).arguments
        #expect(ghosttyArgs.last == command)
        let wezArgs = TerminalLauncher.wezterm.invocation(for: command).arguments
        #expect(wezArgs.last == command)
    }

    @Test("every launcher has a non-empty bundle identifier")
    func everyLauncherHasABundleID() {
        for launcher in TerminalLauncher.allCases {
            #expect(!launcher.bundleIdentifier.isEmpty)
        }
    }
}
