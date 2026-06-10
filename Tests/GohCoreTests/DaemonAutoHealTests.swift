import Testing
import Foundation
import XPC
@testable import GohCore

// StubRestarter, SequencedLsSender, and makeLsSender are defined in
// Tests/GohCoreTests/Support/LsReplyTestSupport.swift (created in Step 0).
// DaemonRestartingTests.swift defines its own StubDaemonRestarter —
// that is separate; no collision.

@Suite("DaemonAutoHeal")
struct DaemonAutoHealTests {

    @Test("staleIdle triggers kickstart and poll; AC4 wiring")
    func staleIdleTriggersKickstart() throws {
        // Sequence: stale (call 1 = initial ls), stale (call 2 = re-check idle),
        // then current (calls 3+ = poll after kickstart).
        let restarter = StubRestarter()
        let sequenced = SequencedLsSender(replies: [
            LsReply(jobs: [], featureLevel: nil),      // call 1: initial classify → staleIdle
            LsReply(jobs: [], featureLevel: nil),      // call 2: re-check still idle → ok to kickstart
            LsReply(jobs: [], featureLevel: GohFeatureLevel.current),  // call 3: poll → current
        ])
        let notice = DaemonAutoHeal.runIfNeeded(
            send: sequenced.sender(),
            restarter: restarter,
            uid: 501,
            pollBudget: .seconds(1),
            pollInterval: .milliseconds(50))
        #expect(restarter.kickstartCalled == 1)
        #expect(notice == nil)  // successful heal → no notice
    }

    @Test("staleBusy does NOT kickstart, emits notice; AC5")
    func staleBusyNoKickstart() throws {
        let restarter = StubRestarter()
        let activeJob = JobSummary(
            id: 0, url: "https://example.com", destination: "/tmp/f",
            state: .active,
            progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
            createdAt: Date(), lastProgressAt: nil,
            requestedConnectionCount: 8, actualConnectionCount: 1)
        let sender = makeLsSender(reply: LsReply(jobs: [activeJob], featureLevel: nil))
        let notice = DaemonAutoHeal.runIfNeeded(send: sender, restarter: restarter, uid: 501)
        #expect(restarter.kickstartCalled == 0)
        #expect(notice != nil)   // busy notice present
    }

    @Test("kickstart unavailable degrades to notice-only; AC7")
    func kickstartUnavailableDegradesGracefully() throws {
        let restarter = StubRestarter(shouldSucceed: false)
        // Always returns stale reply — kickstart will fail, poll will timeout.
        let sequenced = SequencedLsSender(replies: [
            LsReply(jobs: [], featureLevel: nil),  // classify: staleIdle
            LsReply(jobs: [], featureLevel: nil),  // re-check: still idle → attempt kickstart (fails)
        ])
        let notice = DaemonAutoHeal.runIfNeeded(
            send: sequenced.sender(),
            restarter: restarter,
            uid: 501,
            pollBudget: .milliseconds(200),
            pollInterval: .milliseconds(50))
        #expect(restarter.kickstartCalled == 1)
        #expect(notice != nil)   // degraded to notice (kickstart threw)
    }

    @Test("current daemon skips all action")
    func currentDaemonNoOp() throws {
        let restarter = StubRestarter()
        let sender = makeLsSender(reply: LsReply(jobs: [], featureLevel: GohFeatureLevel.current))
        let notice = DaemonAutoHeal.runIfNeeded(send: sender, restarter: restarter, uid: 501)
        #expect(restarter.kickstartCalled == 0)
        #expect(notice == nil)
    }
}
