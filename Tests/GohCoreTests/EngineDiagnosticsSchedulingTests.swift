import Foundation
import Testing

@testable import GohCore

@Suite("Engine diagnostics — scheduling decision trace (AC12)")
struct EngineDiagnosticsSchedulingTests {

    @Test("AC: recordSchedulingDecision accepts hostKey, chosenN, reason, armEWMAs (compile check)")
    func ac12MethodExistsAndCompiles() {
        let diag = EngineDiagnostics(enabled: false)
        diag.recordSchedulingDecision(
            hostKey: "https://example.com:443",
            chosenN: 8,
            reason: SelectionReason.cold,
            armEWMAs: [8: 10_000_000.0, 16: 15_000_000.0])
        #expect(diag.peakActive == 0)
    }

    @Test("SM1 prerequisite: recordGovernorDecision exists and is a no-op when disabled")
    func governorTraceExists() {
        let diag = EngineDiagnostics(enabled: false)
        diag.recordGovernorDecision(phase: "probe", decision: "addWorkers(2)", currentN: 2,
            hostKey: "https://example.com:443")
        // No assertion on output (disabled → no emit); this is a compile + no-crash guard.
        #expect(Bool(true))
    }

    @Test("AC: recordSchedulingDecision with enabled trace does not crash")
    func ac12EnabledDoesNotCrash() {
        let diag = EngineDiagnostics(enabled: true)
        diag.recordSchedulingDecision(
            hostKey: "https://example.com:443", chosenN: 8,
            reason: .cold, armEWMAs: [:])
        diag.recordSchedulingDecision(
            hostKey: "https://example.com:443", chosenN: 16,
            reason: .exploit, armEWMAs: [8: 9_000_000, 16: 18_000_000])
        diag.recordSchedulingDecision(
            hostKey: "https://example.com:443", chosenN: 4,
            reason: .explore, armEWMAs: [4: 5_000_000])
        diag.recordSchedulingDecision(
            hostKey: "https://example.com:443", chosenN: 4,
            reason: .explicit, armEWMAs: [:])
        diag.recordSchedulingDecision(
            hostKey: nil, chosenN: 8, reason: .cold, armEWMAs: [:])
        #expect(diag.peakActive == 0)
    }
}
