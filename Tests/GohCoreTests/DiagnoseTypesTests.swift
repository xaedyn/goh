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
