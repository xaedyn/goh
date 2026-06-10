import Testing
import Foundation
import GohCore

/// A stub DaemonRestarting for unit tests — records calls, returns a configured result.
final class StubDaemonRestarter: DaemonRestarting, @unchecked Sendable {
    var callCount = 0
    var shouldSucceed: Bool

    init(shouldSucceed: Bool = true) {
        self.shouldSucceed = shouldSucceed
    }

    func kickstart() throws {
        callCount += 1
        if !shouldSucceed {
            throw DaemonRestartError.launchctlFailed(exitCode: 1, stderr: "stub failure")
        }
    }
}

@Suite("DaemonRestarting")
struct DaemonRestartingTests {

    @Test("StubDaemonRestarter records calls on success")
    func stubSuccessRecordsCalls() throws {
        let stub = StubDaemonRestarter(shouldSucceed: true)
        try stub.kickstart()
        #expect(stub.callCount == 1)
    }

    @Test("StubDaemonRestarter throws on failure")
    func stubFailureThrows() {
        let stub = StubDaemonRestarter(shouldSucceed: false)
        #expect(throws: DaemonRestartError.self) {
            try stub.kickstart()
        }
    }

    @Test("LaunchctlDaemonRestarter builds the correct launchctl arguments")
    func launchctlRestartBuildsCorrectArguments() {
        let restarter = LaunchctlDaemonRestarter(uid: 501, machServiceName: "dev.goh.daemon")
        #expect(restarter.kickstartTarget == "gui/501/dev.goh.daemon")
    }
}
