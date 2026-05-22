import Testing

import GohCore

@Suite("XPC bounded reconnect")
struct XPCReconnectTests {

    @Test("reconnect succeeds immediately when the first attempt connects")
    func reconnectsImmediately() {
        var attempts = 0
        let outcome = XPCReconnect.attempt(
            within: .milliseconds(200), pollInterval: .milliseconds(20)
        ) {
            attempts += 1
            return true
        }
        #expect(outcome == .reconnected)
        #expect(attempts == 1)
    }

    @Test("reconnect succeeds when a later attempt connects within the window")
    func reconnectsAfterRetries() {
        var attempts = 0
        let outcome = XPCReconnect.attempt(
            within: .milliseconds(500), pollInterval: .milliseconds(10)
        ) {
            attempts += 1
            return attempts >= 3
        }
        #expect(outcome == .reconnected)
        #expect(attempts == 3)
    }

    @Test("reconnect gives up when the window elapses without connecting")
    func givesUpAfterWindow() {
        var attempts = 0
        let outcome = XPCReconnect.attempt(
            within: .milliseconds(60), pollInterval: .milliseconds(15)
        ) {
            attempts += 1
            return false
        }
        #expect(outcome == .gaveUp)
        #expect(attempts >= 1)
    }
}
