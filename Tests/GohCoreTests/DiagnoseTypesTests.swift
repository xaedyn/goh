import Foundation
import Testing

@testable import GohCore

@Suite("DiagnoseTypes")
struct DiagnoseTypesTests {

    @Test func configDefaultsMatchSpec() {
        let c = DiagnoseConfig()
        #expect(c.targetConnections == 8)
        #expect(c.warmupSeconds == 1.5)
        #expect(c.sampleWindowSeconds == 4.0)
        #expect(c.rampWarmupSeconds == 1.0)
        #expect(c.defaultDeadlineSeconds == 12.0)
        #expect(c.minSampleBytes == 8_000_000)
        #expect(c.scalingFactor == 1.3)
        #expect(c.connectTimeoutSeconds == 10.0)
    }

    @Test func verdictRawValuesAreFrozen() {
        // The --json contract: raw values must not change.
        #expect(Verdict.insufficientData.rawValue == "insufficientData")
        #expect(Verdict.rangeUnsupported.rawValue == "rangeUnsupported")
        #expect(Verdict.rangeSupportedSizeUnknown.rawValue == "rangeSupportedSizeUnknown")
        #expect(Verdict.rateLimited.rawValue == "rateLimited")
        #expect(Verdict.scaled.rawValue == "scaled")
        #expect(Verdict.didNotScaleMultiplexed.rawValue == "didNotScaleMultiplexed")
        #expect(Verdict.didNotScaleHTTP1.rawValue == "didNotScaleHTTP1")
    }

    @Test func diagnosisReportRoundTripsJSON() throws {
        var report = DiagnosisReport(url: "https://example.com/f.bin")
        report.reachable = true
        report.rangeSupported = true
        report.totalBytes = 100_000_000
        report.networkProtocol = "h2"
        report.attempted = 8
        report.accepted = 6
        report.rejections = ["429": 2]
        report.singleConnMBps = 12.5
        report.multiConnMBps = 80.3
        report.verdict = .scaled
        report.verdictText = "Throughput scaled."

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        let decoded = try JSONDecoder().decode(DiagnosisReport.self, from: data)

        #expect(decoded.reportVersion == 1)
        #expect(decoded.url == "https://example.com/f.bin")
        #expect(decoded.totalBytes == 100_000_000)
        #expect(decoded.networkProtocol == "h2")
        #expect(decoded.rejections == ["429": 2])
        #expect(decoded.singleConnMBps == 12.5)
        #expect(decoded.multiConnMBps == 80.3)
        #expect(decoded.verdict == .scaled)
    }

    @Test func rejectionsEncodesAsJSONObject() throws {
        // [String: Int] must encode as a JSON object, not an array.
        var report = DiagnosisReport(url: "https://example.com/f.bin")
        report.rejections = ["429": 3]
        let data = try JSONEncoder().encode(report)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"429\""))
        #expect(!json.contains("[{"))
    }

    @Test func diagnosisReportMatchesGoldenFixture() throws {
        // Golden-file fixture test per project convention (§ "Test discipline" in CLAUDE.md:
        // golden-file fixtures for any wire format). The fixture is the frozen v1 --json
        // contract; if a field name, type, or Verdict raw value changes, this test breaks
        // and forces a reportVersion bump.
        //
        // Fixture: Tests/GohCoreTests/Fixtures/diagnose-report-v1.json
        // The fixture is created on first run by writing the encoded output, then locked
        // in as a golden file. On subsequent runs it is read and compared byte-for-byte
        // after normalising the encoder's outputFormatting to .sortedKeys.
        var report = DiagnosisReport(url: "https://cdn.example.com/file.bin")
        report.reachable = true
        report.rangeSupported = true
        report.totalBytes = 1_000_000_000
        report.networkProtocol = "h2"
        report.attempted = 8
        report.accepted = 8
        report.rejections = [:]
        report.singleConnMBps = 45.2
        report.multiConnMBps = 89.1
        report.verdict = .scaled
        report.verdictText = "Throughput scaled with more connections."

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(report)
        let actualJSON = String(decoding: data, as: UTF8.self)

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/diagnose-report-v1.json")

        if !FileManager.default.fileExists(atPath: fixtureURL.path) {
            // First run: write the fixture so CI can lock it in.
            try FileManager.default.createDirectory(
                at: fixtureURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: fixtureURL)
            // Pass on first creation — the file is now the golden baseline.
            return
        }

        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixtureJSON = String(decoding: fixtureData, as: UTF8.self)
        #expect(
            actualJSON == fixtureJSON,
            "DiagnosisReport --json output differs from golden fixture. If this is intentional, bump reportVersion and delete the fixture to regenerate."
        )
    }
}

// MARK: - verdict() exhaustive tests (AC5)

extension DiagnoseTypesTests {

    // AC5 — verdict must never over-claim; protocol-gated split is load-bearing.

    @Test func verdictInsufficientDataWhenSingleConnNil() {
        // Case 1: singleConnMBps nil → insufficientData regardless of other fields.
        var r = DiagnosisReport(url: "https://example.com/f.bin")
        r.reachable = true
        r.rangeSupported = true
        r.totalBytes = 100_000_000
        r.singleConnMBps = nil
        let (v, _) = verdict(r, config: DiagnoseConfig())
        #expect(v == .insufficientData)
    }

    @Test func verdictRangeUnsupportedWhenRangeIsFalse() {
        // Case 2: rangeSupported == false → rangeUnsupported.
        var r = DiagnosisReport(url: "https://example.com/f.bin")
        r.reachable = true
        r.rangeSupported = false
        r.singleConnMBps = 10.0
        let (v, _) = verdict(r, config: DiagnoseConfig())
        #expect(v == .rangeUnsupported)
    }

    @Test func verdictRangeSupportedSizeUnknownWhenTotalBytesNil() {
        // Case 3: rangeSupported == true but totalBytes == nil → rangeSupportedSizeUnknown.
        var r = DiagnosisReport(url: "https://example.com/f.bin")
        r.reachable = true
        r.rangeSupported = true
        r.totalBytes = nil
        r.singleConnMBps = 10.0
        let (v, _) = verdict(r, config: DiagnoseConfig())
        #expect(v == .rangeSupportedSizeUnknown)
    }

    @Test func verdictRateLimitedWhenAcceptedLessThanAttempted() {
        // Case 4: Phase 2 ran, accepted < attempted → rateLimited.
        // bestObserved = max(singleConnMBps, multiConnMBps).
        var r = DiagnosisReport(url: "https://example.com/f.bin")
        r.reachable = true
        r.rangeSupported = true
        r.totalBytes = 100_000_000
        r.attempted = 8
        r.accepted = 5
        r.singleConnMBps = 10.0
        r.multiConnMBps = 45.0
        let (v, text) = verdict(r, config: DiagnoseConfig())
        #expect(v == .rateLimited)
        #expect(text.contains("45"))    // bestObserved = 45 (multiConnMBps is higher)
        #expect(text.contains("5 of 8"))
    }

    @Test func verdictRateLimitedBestObservedUsesSingleWhenHigher() {
        // bestObserved = max(singleConnMBps ?? 0, multiConnMBps ?? 0)
        var r = DiagnosisReport(url: "https://example.com/f.bin")
        r.reachable = true
        r.rangeSupported = true
        r.totalBytes = 100_000_000
        r.attempted = 8
        r.accepted = 3
        r.singleConnMBps = 50.0
        r.multiConnMBps = 30.0   // single is higher
        let (v, _) = verdict(r, config: DiagnoseConfig())
        #expect(v == .rateLimited)
    }

    @Test func verdictScaledWhenTnExceedsThreshold() {
        // Case 5: Phase 2 ran, all accepted, Tₙ ≥ scalingFactor * T₁ → scaled.
        var r = DiagnosisReport(url: "https://example.com/f.bin")
        r.reachable = true
        r.rangeSupported = true
        r.totalBytes = 100_000_000
        r.attempted = 8
        r.accepted = 8
        r.singleConnMBps = 10.0
        r.multiConnMBps = 14.0    // 14.0 >= 1.3 * 10.0 = 13.0 ✓
        let (v, _) = verdict(r, config: DiagnoseConfig())
        #expect(v == .scaled)
    }

    @Test func verdictDidNotScaleMultiplexedForH2() {
        // Case 6: Phase 2 ran, all accepted, Tₙ < threshold, protocol h2 → multiplexed.
        // AC5: must NOT assert link-vs-server for h2.
        var r = DiagnosisReport(url: "https://example.com/f.bin")
        r.reachable = true
        r.rangeSupported = true
        r.totalBytes = 100_000_000
        r.attempted = 8
        r.accepted = 8
        r.networkProtocol = "h2"
        r.singleConnMBps = 10.0
        r.multiConnMBps = 11.0    // 11.0 < 1.3 * 10.0 = 13.0 ✗ (did not scale)
        let (v, text) = verdict(r, config: DiagnoseConfig())
        #expect(v == .didNotScaleMultiplexed)
        #expect(!text.lowercased().contains("your connection"))
    }

    @Test func verdictDidNotScaleMultiplexedForH3() {
        // Case 6: h3 also takes the multiplexed branch.
        var r = DiagnosisReport(url: "https://example.com/f.bin")
        r.reachable = true
        r.rangeSupported = true
        r.totalBytes = 100_000_000
        r.attempted = 8
        r.accepted = 8
        r.networkProtocol = "h3"
        r.singleConnMBps = 10.0
        r.multiConnMBps = 11.0
        let (v, _) = verdict(r, config: DiagnoseConfig())
        #expect(v == .didNotScaleMultiplexed)
    }

    @Test func verdictDidNotScaleMultiplexedForUnknownProtocol() {
        // Case 6: nil (unknown) protocol → conservative multiplexed branch. AC5.
        var r = DiagnosisReport(url: "https://example.com/f.bin")
        r.reachable = true
        r.rangeSupported = true
        r.totalBytes = 100_000_000
        r.attempted = 8
        r.accepted = 8
        r.networkProtocol = nil   // unknown
        r.singleConnMBps = 10.0
        r.multiConnMBps = 11.0
        let (v, _) = verdict(r, config: DiagnoseConfig())
        #expect(v == .didNotScaleMultiplexed)
    }

    @Test func verdictDidNotScaleHTTP1OnlyForExactHTTP1() {
        // Case 7: http/1.1 exactly → HTTP1 branch (real parallel TCP). AC5.
        var r = DiagnosisReport(url: "https://example.com/f.bin")
        r.reachable = true
        r.rangeSupported = true
        r.totalBytes = 100_000_000
        r.attempted = 8
        r.accepted = 8
        r.networkProtocol = "http/1.1"
        r.singleConnMBps = 10.0
        r.multiConnMBps = 11.0    // did not scale
        let (v, _) = verdict(r, config: DiagnoseConfig())
        #expect(v == .didNotScaleHTTP1)
    }

    @Test func verdictDidNotScaleMultiplexedForHTTP10() {
        // "http/1.0" is NOT "http/1.1" — falls to multiplexed (allow-list). AC5.
        var r = DiagnosisReport(url: "https://example.com/f.bin")
        r.reachable = true
        r.rangeSupported = true
        r.totalBytes = 100_000_000
        r.attempted = 8
        r.accepted = 8
        r.networkProtocol = "http/1.0"
        r.singleConnMBps = 10.0
        r.multiConnMBps = 11.0
        let (v, _) = verdict(r, config: DiagnoseConfig())
        #expect(v == .didNotScaleMultiplexed)
    }

    // NOTE — AC5 named anchors:
    // `verdictDidNotScaleOnlyForHTTP1()` and `verdictMultiplexedForH2AndUnknown()` are
    // NOT separate stub tests here; the coverage is already provided by the two tests
    // immediately above (`verdictDidNotScaleHTTP1OnlyForExactHTTP1` and
    // `verdictDidNotScaleMultiplexedForH2`). The AC table references those real tests.
    // Duplicate stubs that only re-assert the same verdict with a different name provide
    // no additional coverage and have been removed to keep the suite DRY.
}
