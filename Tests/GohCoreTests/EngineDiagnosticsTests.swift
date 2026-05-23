import Foundation
import Testing

@testable import GohCore

@Suite("Engine diagnostics")
struct EngineDiagnosticsTests {

    @Test("a disabled trace is a no-op — methods short-circuit, no state changes")
    func disabledIsNoOp() {
        let trace = EngineDiagnostics(enabled: false)
        trace.rangeStarted(0, bytes: 1024)
        trace.rangeStarted(1, bytes: 1024)
        trace.rangeStarted(2, bytes: 1024)
        trace.rangeFirstByte(1)
        trace.timed(1, .write) { /* the body still runs */ }
        trace.timed(1, .report) { /* the body still runs */ }
        trace.rangeFinished(1, bytes: 1024)
        trace.summary()
        #expect(trace.peakActive == 0)
    }

    @Test("an enabled trace tracks peak concurrent ranges and does not regress on release")
    func enabledTracksPeak() {
        let trace = EngineDiagnostics(enabled: true)
        trace.rangeStarted(0, bytes: 1024)
        trace.rangeStarted(1, bytes: 1024)
        trace.rangeStarted(2, bytes: 1024)
        #expect(trace.peakActive == 3)
        trace.rangeFinished(0, bytes: 1024)
        trace.rangeFinished(1, bytes: 1024)
        trace.rangeStarted(3, bytes: 1024)
        #expect(trace.peakActive == 3)  // peak is high-water; never decreases
    }

    @Test("the body of timed runs whether the trace is enabled or not")
    func timedRunsBody() {
        for enabled in [false, true] {
            let trace = EngineDiagnostics(enabled: enabled)
            var ran = false
            trace.timed(0, .write) { ran = true }
            #expect(ran, "the body must execute regardless of enablement")
        }
    }
}
