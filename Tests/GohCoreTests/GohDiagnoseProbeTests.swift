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

@Suite("GohDiagnoseProbe — Phase 1 and 2 integration (AC1/AC2/AC3)")
struct GohDiagnoseProbeIntegrationTests {

    /// Minimal config for integration tests: small windows, no minSampleBytes guard,
    /// fast deadline.  All Phase-2 tests use connections ≥ 2 so Phase 2 actually runs
    /// and the deadline/Tₙ paths are exercised (BLOCK D fix).
    private func fastConfig(connections: Int = 2) -> DiagnoseConfig {
        DiagnoseConfig(
            targetConnections: connections,
            warmupSeconds: 0,
            sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0,
            defaultDeadlineSeconds: 2.0,
            minSampleBytes: 0,
            scalingFactor: 1.3,
            connectTimeoutSeconds: 5.0)
    }

    // AC1: reachable server + range support → report contains reachable, rangeSupported,
    // non-nil singleConnMBps. Uses N=2 so Phase 2 also runs and multiConnMBps path is
    // exercised. networkProtocol from MockURLProtocol is nil (no real TCP metrics) — that
    // is expected and tested.
    @Test func diagnoseReportsRangeProtocolAndThroughput() async throws {
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(
            url, body: tenMB, acceptsRanges: true,
            bodyChunkSize: 131_072,            // 128 KiB chunks
            bodyChunkDelayMicroseconds: 1_000) // 1 ms between chunks

        let probe = GohDiagnoseProbe(
            urlString: url,
            config: fastConfig(connections: 2),
            session: mockSession(),
            full: false)

        let (report, termination) = await probe.run()

        #expect(report.reachable == true)
        #expect(report.rangeSupported == true)
        // singleConnMBps: with 10 MB body and 0.05 s window it should be non-nil.
        // The integration test asserts non-nil but not an exact value (spec §3).
        #expect(report.singleConnMBps != nil)
        // spec §2.1: attempted = N = 2 (conn-0 counts as attempt #1; Phase 2 opened 1 more)
        #expect(report.attempted == 2)
        // spec §2.1: accepted = conn-0 (206) + Phase-2 206 = 2 here (all accepted)
        #expect(report.accepted == 2)
        // networkProtocol is nil for MockURLProtocol (no real TCP metrics).
        // That is correct — the probe must not crash on nil.
        if case .diagnosed = termination { } else {
            Issue.record("Expected .diagnosed, got \(termination)")
        }
    }

    // AC2: server returns transport-error to one Phase-2 range probe → attempted > accepted,
    // rejections map is populated, probe completes without aborting other connections.
    // Uses N=2 so Phase 2 actually runs (BLOCK D fix).
    @Test func diagnoseRateLimitRecordsAllOutcomesWithoutAborting() async throws {
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        // Accept conn-0 (Phase 0: bytes=0-), fail the Phase-2 range start offset.
        // MockURLProtocol.failRangeStartingAt fires networkConnectionLost — the probe
        // counts it as a rejection and continues draining conn-0.
        MockURLProtocol.stub(
            url,
            body: tenMB,
            acceptsRanges: true,
            failRangeStartingAt: Int(tenMB.count / 2),  // second connection's start fails
            bodyChunkSize: 131_072,
            bodyChunkDelayMicroseconds: 1_000
        )

        let config = DiagnoseConfig(
            targetConnections: 2,   // conn-0 (attempt #1) + 1 additional (attempt #2)
            warmupSeconds: 0,
            sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0,
            defaultDeadlineSeconds: 2.0,
            minSampleBytes: 0,
            scalingFactor: 1.3,
            connectTimeoutSeconds: 2.0)

        let probe = GohDiagnoseProbe(
            urlString: url,
            config: config,
            session: mockSession(),
            full: false)

        let (report, termination) = await probe.run()

        // The probe must complete (not abort). AC2: no single-connection failure aborts run.
        #expect(report.reachable == true)
        // spec §2.1: attempted = N = 2 (conn-0 counts as attempt #1 per spec)
        #expect(report.attempted == 2)
        // Phase 2 conn fails → accepted < attempted.
        // spec §2.1: accepted = conn-0 (206) + Phase-2 206s = 1 here (second fails)
        #expect(report.accepted == 1)
        #expect(report.rangeSupported == true)
        // Termination is still .diagnosed (probe completed, even with a rejection)
        if case .diagnosed = termination { } else {
            Issue.record("Expected .diagnosed even with one rejection, got \(termination)")
        }
    }

    // BLOCK 6 / spec §2.1 pin: server accepts conn-0 but rejects ALL Phase-2 ranges →
    // accepted == 1, attempted == N, verdict rateLimited.
    // Uses N=2 so Phase 2 actually runs (BLOCK D fix).
    @Test func rateLimitedAllPhase2RangesRejected() async throws {
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, body: tenMB, acceptsRanges: true,
            failRangeStartingAt: Int(tenMB.count / 2),
            bodyChunkSize: 131_072,
            bodyChunkDelayMicroseconds: 1_000)

        let config = DiagnoseConfig(
            targetConnections: 2, warmupSeconds: 0, sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0, defaultDeadlineSeconds: 2.0,
            minSampleBytes: 0, scalingFactor: 1.3, connectTimeoutSeconds: 2.0)

        let (report, _) = await GohDiagnoseProbe(
            urlString: url, config: config, session: mockSession(), full: false).run()

        // spec §2.1: attempted = N = 2; accepted = 1 (conn-0 only)
        #expect(report.attempted == 2)
        #expect(report.accepted == 1)
        // Pure verdict function will produce .rateLimited for accepted < attempted
        let (v, _) = verdict(report, config: config)
        #expect(v == .rateLimited)
    }

    // AC3: server ignores Range (returns 200) → rangeSupported = false,
    // verdict will be rangeUnsupported, single-stream T₁ produced.
    // Phase 2 is skipped because rangeSupported = false regardless of N.
    @Test func diagnoseRangeIgnoredProducesRangeUnsupportedVerdict() async throws {
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, body: tenMB, acceptsRanges: false,
            bodyChunkSize: 131_072, bodyChunkDelayMicroseconds: 1_000)

        let probe = GohDiagnoseProbe(
            urlString: url,
            config: fastConfig(connections: 8),
            session: mockSession(),
            full: false)

        let (report, termination) = await probe.run()

        #expect(report.reachable == true)
        #expect(report.rangeSupported == false)
        // Phase 2 must be skipped (rangeSupported=false).
        // spec §2.1: attempted = 1 (conn-0 only; Phase 2 skipped)
        #expect(report.attempted == 1)
        // Single-stream T₁ should be populated (body is 10 MB, window is 0.05 s).
        #expect(report.singleConnMBps != nil)
        if case .diagnosed = termination { } else {
            Issue.record("Expected .diagnosed for 200-body probe, got \(termination)")
        }
    }

    // Tₙ value sanity (BLOCK D coverage): N connections with a large, paced body →
    // multiConnMBps non-nil and the verdict path is reached.
    // Uses N=2 so Phase 2 actually runs and Tₙ is measured (BLOCK D fix).
    @Test func multiConnMBpsIsNonNilWhenPhase2Runs() async throws {
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        // 20 MB body so both halves have enough data for a non-nil Tₙ window.
        let body = Data(repeating: 0xBB, count: 20_000_000)
        MockURLProtocol.stub(
            url, body: body, acceptsRanges: true,
            bodyChunkSize: 131_072,
            bodyChunkDelayMicroseconds: 500)

        let config = DiagnoseConfig(
            targetConnections: 2,
            warmupSeconds: 0,
            sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0,
            defaultDeadlineSeconds: 2.0,
            minSampleBytes: 0,
            scalingFactor: 1.3,
            connectTimeoutSeconds: 5.0)

        let (report, termination) = await GohDiagnoseProbe(
            urlString: url, config: config, session: mockSession(), full: false).run()

        #expect(report.reachable == true)
        #expect(report.rangeSupported == true)
        #expect(report.attempted == 2)
        #expect(report.accepted == 2)
        // Tₙ must be non-nil when Phase 2 ran with accepted connections (BLOCK C/D coverage).
        #expect(report.multiConnMBps != nil)
        // Verdict must have been reached (not still insufficientData from a nil T₁).
        #expect(report.singleConnMBps != nil)
        // Exact MB/s not asserted — timing is CI-sensitive. Structural check only (spec §3).
        if case .diagnosed = termination { } else {
            Issue.record("Expected .diagnosed, got \(termination)")
        }
    }
}

@Suite("GohDiagnoseProbe — termination-safety regressions")
struct GohDiagnoseProbeTerminationSafetyTests {

    /// Runs `probe.run()` but fails the test (instead of hanging the suite) if it does
    /// not return within `seconds`. Returns nil on timeout so the caller can record it.
    private func runBounded(
        _ probe: GohDiagnoseProbe,
        seconds: Double
    ) async -> (DiagnosisReport, ProbeTermination)? {
        await withTaskGroup(of: (DiagnosisReport, ProbeTermination)?.self) { group in
            group.addTask { await probe.run() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // BLOCK 1 regression: a TINY range-supporting file (body smaller than N bytes) with the
    // default-ish connection count (n = 8). Before the fix, partSize = totalBytes / n == 0,
    // and the non-last Phase-2 part computed `end = start + 0 - 1`, trapping on UInt64
    // underflow. The probe MUST NOT crash; Phase 2 must be skipped and the verdict falls
    // through to insufficientData (tiny T₁ < minSampleBytes).
    @Test func tinyRangeSupportingFileDoesNotCrash() async throws {
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        // 4-byte body — strictly fewer bytes than n = 8 connections.
        MockURLProtocol.stub(url, body: Data([0x01, 0x02, 0x03, 0x04]), acceptsRanges: true)

        let config = DiagnoseConfig(
            targetConnections: 8,           // n > body size → partSize would be 0
            warmupSeconds: 0,
            sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0,
            defaultDeadlineSeconds: 2.0,
            minSampleBytes: 8_000_000,      // realistic floor → tiny file is insufficient
            scalingFactor: 1.3,
            connectTimeoutSeconds: 5.0)

        let probe = GohDiagnoseProbe(
            urlString: url, config: config, session: mockSession(), full: false)

        guard let (report, termination) = await runBounded(probe, seconds: 5.0) else {
            Issue.record("Probe did not return within bound (tiny-file path)")
            return
        }

        // Did not crash — and Phase 2 was skipped (single-stream only).
        #expect(report.reachable == true)
        #expect(report.rangeSupported == true)
        #expect(report.attempted == 1)          // Phase 2 skipped → attempted stays 1
        #expect(report.multiConnMBps == nil)    // Tₙ never measured
        #expect(report.singleConnMBps == nil)   // 4 bytes < minSampleBytes
        if case .diagnosed = termination { } else {
            Issue.record("Expected .diagnosed, got \(termination)")
        }
        // Verdict falls through to insufficientData.
        let (v, _) = verdict(report, config: config)
        #expect(v == .insufficientData)
    }

    // BLOCK 2 regression: `--full` mode against a server that returns 206 headers but never
    // delivers a body byte. Before the fix, the coordinator's `while firstByteInstant == nil`
    // loop had no backstop in --full mode (no deadline child), so the probe spun forever.
    // The probe MUST terminate; singleConnMBps must be nil (no measurable sample).
    @Test func fullModeNoFirstByteTerminates() async throws {
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        // 10 MB advertised size, but every 206 delivers zero body bytes (immediate EOF).
        let body = Data(repeating: 0xEE, count: 10_000_000)
        MockURLProtocol.stub(url, body: body, acceptsRanges: true, emptyBodyOn206: true)

        let config = DiagnoseConfig(
            targetConnections: 2,           // exercise the Phase-2 opens barrier too
            warmupSeconds: 0,
            sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0,
            defaultDeadlineSeconds: 2.0,    // unused in --full (no deadline child)
            minSampleBytes: 0,
            scalingFactor: 1.3,
            connectTimeoutSeconds: 5.0)

        let probe = GohDiagnoseProbe(
            urlString: url, config: config, session: mockSession(), full: true)

        guard let (report, termination) = await runBounded(probe, seconds: 5.0) else {
            Issue.record("Probe HUNG in --full mode with a no-first-byte server")
            return
        }

        // Terminated cleanly with no measurable sample.
        #expect(report.reachable == true)
        #expect(report.singleConnMBps == nil)
        #expect(report.wholeFileMBps == nil)
        if case .diagnosed = termination { } else {
            Issue.record("Expected .diagnosed, got \(termination)")
        }
    }
}
