import Testing
@testable import GohCore

@Suite("ConnectionBudget — global per-host budget")
struct ConnectionBudgetTests {
    @Test("request within budget succeeds") func requestWithinBudget() {
        let b = ConnectionBudget(maxPerHost: 16)
        #expect(b.request(slots: 8, hostKey: "https://example.com:443"))
    }
    @Test("request exceeding budget is denied") func requestExceedsBudget() {
        let b = ConnectionBudget(maxPerHost: 16)
        _ = b.request(slots: 16, hostKey: "https://example.com:443")
        #expect(!b.request(slots: 1, hostKey: "https://example.com:443"))
    }
    @Test("release allows re-request") func releaseAllowsReRequest() {
        let b = ConnectionBudget(maxPerHost: 8); let k = "https://example.com:443"
        _ = b.request(slots: 8, hostKey: k); b.release(slots: 4, hostKey: k)
        #expect(b.request(slots: 4, hostKey: k))
    }
    @Test("different hosts have independent budgets") func independentHostBudgets() {
        let b = ConnectionBudget(maxPerHost: 8)
        _ = b.request(slots: 8, hostKey: "https://a.example.com:443")
        #expect(b.request(slots: 8, hostKey: "https://b.example.com:443"))
    }
    @Test("release of an unknown host is a no-op (no underflow)") func releaseUnknownNoOp() {
        let b = ConnectionBudget(maxPerHost: 8)
        b.release(slots: 4, hostKey: "https://none.example.com:443")
        #expect(b.usage(hostKey: "https://none.example.com:443") == 0)
    }
}
