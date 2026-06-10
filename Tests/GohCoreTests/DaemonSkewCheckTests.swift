import Testing
import GohCore

@Suite("DaemonSkewCheck.evaluate — AC2 table")
struct DaemonSkewCheckTests {

    // Nil reported == stale (pre-feature daemon). NOT "unknown" — the first
    // upgrade must self-heal. (spec §3 "nil reported == stale")
    @Test("nil reported with 0 active → staleIdle", arguments: [0, nil] as [Int?])
    func nilReportedIdleIsStaleIdle(reported: Int?) {
        #expect(DaemonSkewCheck.evaluate(reported: reported, expected: 1, activeDownloadCount: 0) == .staleIdle)
    }

    @Test("nil reported with active downloads → staleBusy")
    func nilReportedBusyIsStaleBusy() {
        #expect(DaemonSkewCheck.evaluate(reported: nil, expected: 1, activeDownloadCount: 2) == .staleBusy)
    }

    @Test("0 reported (older level) with 0 active → staleIdle")
    func zeroReportedIdleIsStaleIdle() {
        #expect(DaemonSkewCheck.evaluate(reported: 0, expected: 1, activeDownloadCount: 0) == .staleIdle)
    }

    @Test("0 reported (older level) with active downloads → staleBusy")
    func zeroReportedBusyIsStaleBusy() {
        #expect(DaemonSkewCheck.evaluate(reported: 0, expected: 1, activeDownloadCount: 3) == .staleBusy)
    }

    @Test("reported == expected → current")
    func reportedEqualsExpectedIsCurrent() {
        #expect(DaemonSkewCheck.evaluate(reported: 1, expected: 1, activeDownloadCount: 0) == .current)
    }

    @Test("reported > expected (old client + new daemon) → current")
    func reportedGreaterThanExpectedIsCurrent() {
        #expect(DaemonSkewCheck.evaluate(reported: 2, expected: 1, activeDownloadCount: 0) == .current)
    }

    @Test("reported == expected and active downloads → still current (no idle gate in evaluate)")
    func reportedEqualsExpectedWithActiveIsCurrent() {
        #expect(DaemonSkewCheck.evaluate(reported: 1, expected: 1, activeDownloadCount: 5) == .current)
    }
}
