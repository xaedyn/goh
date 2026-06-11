import Testing

@testable import GohCore

@Suite("CLIMessages.daemonError")
struct CLIMessagesTests {

    @Test("protocol-version mismatch appends the restart-the-daemon hint")
    func protocolMismatchIncludesRestartHint() {
        let line = CLIMessages.daemonError(
            GohError(code: .protocolVersionMismatch, message: "client and daemon builds differ"))
        #expect(line == "gohd: client and daemon builds differ\nRestart the daemon with: brew services restart goh\n")
    }

    @Test("protocol-version mismatch with no message falls back to the code, still with the hint")
    func protocolMismatchEmptyMessageFallsBackToCode() {
        let line = CLIMessages.daemonError(GohError(code: .protocolVersionMismatch))
        #expect(line == "gohd: protocolVersionMismatch\nRestart the daemon with: brew services restart goh\n")
    }

    @Test("a non-mismatch error with a message uses the plain gohd: prefix and no hint")
    func nonMismatchWithMessage() {
        let line = CLIMessages.daemonError(GohError(code: .jobNotFound, message: "no such job"))
        #expect(line == "gohd: no such job\n")
    }

    @Test("a non-mismatch error without a message falls back to the code name")
    func nonMismatchWithoutMessage() {
        let line = CLIMessages.daemonError(GohError(code: .queueFull))
        #expect(line == "gohd: queueFull\n")
    }
}
