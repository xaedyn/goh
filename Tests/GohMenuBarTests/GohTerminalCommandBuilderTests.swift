import Testing
@testable import GohMenuBar

@Suite("Goh terminal command builder")
struct GohTerminalCommandBuilderTests {
    @Test func commandUsesSiblingGohExecutable() {
        let command = GohTerminalCommandBuilder(
            companionExecutablePath: "/Applications/Goh.app/Contents/MacOS/goh-menu",
            environment: [:])
            .command(for: .top)

        #expect(command == "'/Applications/Goh.app/Contents/MacOS/goh' 'top'")
    }

    @Test func commandCarriesDogfoodPeerValidationEnvironment() {
        let command = GohTerminalCommandBuilder(
            companionExecutablePath: "/tmp/goh-menu",
            environment: ["GOH_XPC_ALLOW_UNVALIDATED_PEERS": "1"])
            .command(for: .doctor)

        #expect(command == "export GOH_XPC_ALLOW_UNVALIDATED_PEERS='1'; '/tmp/goh' 'doctor'")
    }

    @Test func commandShellQuotesDogfoodEnvironmentValueAndExecutablePath() {
        let command = GohTerminalCommandBuilder(
            companionExecutablePath: "/tmp/Goh Menu/goh-menu",
            environment: ["GOH_XPC_ALLOW_UNVALIDATED_PEERS": "dev mode"])
            .command(for: .top)

        #expect(command == "export GOH_XPC_ALLOW_UNVALIDATED_PEERS='dev mode'; '/tmp/Goh Menu/goh' 'top'")
    }

    @Test func commandShellQuotesSingleQuotes() {
        let command = GohTerminalCommandBuilder(
            companionExecutablePath: "/tmp/Shane's Apps/goh-menu",
            environment: ["GOH_XPC_ALLOW_UNVALIDATED_PEERS": "owner's shell"])
            .command(for: .doctor)

        #expect(command == "export GOH_XPC_ALLOW_UNVALIDATED_PEERS='owner'\\''s shell'; '/tmp/Shane'\\''s Apps/goh' 'doctor'")
    }
}
