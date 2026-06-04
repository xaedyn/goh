import Foundation
import Testing

@testable import GohCore

// Helpers shared by all probe tests.
// MockURLProtocol is registered per-test on a per-test URLSession.
private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

// A small but large-enough body for minSampleBytes to be overridden in tests.
// 1 MB: enough to get a non-nil T₁ when minSampleBytes is set to 0 in tests.
private let oneMB = Data(repeating: 0xAB, count: 1_000_000)
// 10 MB body for more realistic probes (can override minSampleBytes).
private let tenMB = Data(repeating: 0xCD, count: 10_000_000)

@Suite("GohDiagnoseProbe — Phase 0")
struct GohDiagnoseProbePhase0Tests {

    @Test func phase0ReachableAndRangeSupported() async throws {
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, body: tenMB, acceptsRanges: true)

        let config = DiagnoseConfig(
            targetConnections: 1,    // skip Phase 2
            warmupSeconds: 0,
            sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0,
            defaultDeadlineSeconds: 5.0,
            minSampleBytes: 0,       // accept any byte count
            scalingFactor: 1.3,
            connectTimeoutSeconds: 5.0)

        let probe = GohDiagnoseProbe(
            urlString: url,
            config: config,
            session: mockSession(),
            full: false)

        let (report, termination) = await probe.run()

        #expect(report.reachable == true)
        #expect(report.rangeSupported == true)
        #expect(report.totalBytes == UInt64(tenMB.count))
        // spec §2.1: attempted = N (conn-0 is attempt #1); accepted = conn-0 (always 206)
        #expect(report.attempted == 1)
        #expect(report.accepted == 1)
        // With a reachable, range-supporting server → .diagnosed
        if case .diagnosed = termination { } else {
            Issue.record("Expected .diagnosed, got \(termination)")
        }
    }

    @Test func phase0RangeIgnoredReturns200() async throws {
        // AC3: server returns 200 (ignores Range) → rangeSupported = false, Phase 2 skipped.
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, body: tenMB, acceptsRanges: false)

        let config = DiagnoseConfig(
            targetConnections: 8,
            warmupSeconds: 0,
            sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0,
            defaultDeadlineSeconds: 5.0,
            minSampleBytes: 0,
            scalingFactor: 1.3,
            connectTimeoutSeconds: 5.0)

        let probe = GohDiagnoseProbe(
            urlString: url,
            config: config,
            session: mockSession(),
            full: false)

        let (report, termination) = await probe.run()

        #expect(report.reachable == true)
        #expect(report.rangeSupported == false)
        #expect(report.totalBytes == nil)
        #expect(report.attempted == 1)
        // Phase 2 must be skipped; accepted = 1 (the Phase-0 conn that delivered 200)
        #expect(report.accepted == 1)
        // A 200 is a valid diagnosis — termination must be .diagnosed
        if case .diagnosed = termination { } else {
            Issue.record("Expected .diagnosed for 200 response, got \(termination)")
        }
    }

    @Test func phase0TransportFailureSetsReachableFalse() async throws {
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, failure: URLError(.cannotConnectToHost))

        let config = DiagnoseConfig(
            targetConnections: 1,
            warmupSeconds: 0,
            sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0,
            defaultDeadlineSeconds: 5.0,
            minSampleBytes: 0,
            scalingFactor: 1.3,
            connectTimeoutSeconds: 5.0)

        let probe = GohDiagnoseProbe(
            urlString: url,
            config: config,
            session: mockSession(),
            full: false)

        let (report, termination) = await probe.run()

        #expect(report.reachable == false)
        // Transport failure → .unreachable(GohError)
        if case .unreachable = termination { } else {
            Issue.record("Expected .unreachable, got \(termination)")
        }
    }

    @Test func phase0AuthRequiredReturns401() async throws {
        // BLOCK 3 test: 401 → .authRequired termination → exit 4.
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, status: 401, body: Data(), acceptsRanges: false)

        let config = DiagnoseConfig(
            targetConnections: 1, warmupSeconds: 0, sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0, defaultDeadlineSeconds: 5.0,
            minSampleBytes: 0, scalingFactor: 1.3, connectTimeoutSeconds: 5.0)

        let (_, termination) = await GohDiagnoseProbe(
            urlString: url, config: config, session: mockSession(), full: false).run()

        if case .authRequired = termination { } else {
            Issue.record("Expected .authRequired for 401, got \(termination)")
        }
    }

    @Test func phase0HTTPErrorReturnsHttpError() async throws {
        // BLOCK 3 test: 404 → .httpError(404) termination → exit 3.
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, status: 404, body: Data(), acceptsRanges: false)

        let config = DiagnoseConfig(
            targetConnections: 1, warmupSeconds: 0, sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0, defaultDeadlineSeconds: 5.0,
            minSampleBytes: 0, scalingFactor: 1.3, connectTimeoutSeconds: 5.0)

        let (_, termination) = await GohDiagnoseProbe(
            urlString: url, config: config, session: mockSession(), full: false).run()

        if case .httpError(let code) = termination {
            #expect(code == 404)
        } else {
            Issue.record("Expected .httpError(404), got \(termination)")
        }
    }
}
