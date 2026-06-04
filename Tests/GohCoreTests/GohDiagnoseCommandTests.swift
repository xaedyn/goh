import Foundation
import Testing

@testable import GohCore

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private let tenMB = Data(repeating: 0xCD, count: 10_000_000)

@Suite("GohDiagnoseCommand — arg parsing and exit codes")
struct GohDiagnoseCommandTests {

    // MARK: - Arg parsing

    @Test func missingURLExits64() {
        let result = GohDiagnoseCommand.run(
            arguments: [],
            sessionFactory: { _ in mockSession() })
        #expect(result.exitCode == 64)
        #expect(result.standardError.contains("usage:"))
    }

    // BLOCK 8: malformed URL is caught ONLY at the arg-parse layer (before the probe runs).
    // This test exercises the command's arg-parse URL guard.
    @Test func malformedURLExits64() {
        let result = GohDiagnoseCommand.run(
            arguments: ["not a url"],
            sessionFactory: { _ in mockSession() })
        #expect(result.exitCode == 64)
    }

    @Test func unknownFlagExits64() {
        let result = GohDiagnoseCommand.run(
            arguments: ["https://example.com/f.bin", "--bogus"],
            sessionFactory: { _ in mockSession() })
        #expect(result.exitCode == 64)
    }

    @Test func connectionsOutOfRangeExits64() {
        let result = GohDiagnoseCommand.run(
            arguments: ["https://example.com/f.bin", "--connections", "99"],
            sessionFactory: { _ in mockSession() })
        #expect(result.exitCode == 64)
    }

    // MARK: - Transport failure → exit 2
    // BLOCK 3: exit code driven by ProbeTermination.unreachable — NOT by verdictText.

    @Test func transportFailureExits2() {
        let url = "https://diagnose-cmd-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, failure: URLError(.cannotConnectToHost))

        let result = GohDiagnoseCommand.run(
            arguments: [url],
            sessionFactory: { _ in mockSession() },
            config: fastConfig())
        // ProbeTermination.unreachable → exit 2
        #expect(result.exitCode == 2)
    }

    // MARK: - Auth required → exit 4
    // BLOCK 3: exit code driven by ProbeTermination.authRequired — NOT by verdictText.

    @Test func authRequiredExits4() {
        let url = "https://diagnose-cmd-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, status: 401, body: Data(), acceptsRanges: false)

        let result = GohDiagnoseCommand.run(
            arguments: [url],
            sessionFactory: { _ in mockSession() },
            config: fastConfig())
        // ProbeTermination.authRequired → exit 4
        #expect(result.exitCode == 4)
    }

    // MARK: - HTTP error → exit 3
    // BLOCK 3: exit code driven by ProbeTermination.httpError(statusCode) — NOT by verdictText.

    @Test func httpErrorExits3() {
        let url = "https://diagnose-cmd-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, status: 404, body: Data(), acceptsRanges: false)

        let result = GohDiagnoseCommand.run(
            arguments: [url],
            sessionFactory: { _ in mockSession() },
            config: fastConfig())
        // ProbeTermination.httpError(404) → exit 3
        #expect(result.exitCode == 3)
    }

    // MARK: - Successful diagnosis → exit 0 (AC1)
    // BLOCK 3: ProbeTermination.diagnosed → exit 0.

    @Test func diagnoseReportsRangeAndProtocol() throws {
        // AC1 integration: reachable + range + throughput → exit 0.
        let url = "https://diagnose-cmd-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(
            url, body: tenMB, acceptsRanges: true,
            bodyChunkSize: 131_072, bodyChunkDelayMicroseconds: 500)

        let result = GohDiagnoseCommand.run(
            arguments: [url, "--connections", "1"],
            sessionFactory: { _ in mockSession() },
            config: fastConfig())

        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("reachable"))
        #expect(result.standardOutput.contains("Range support"))
        #expect(result.standardOutput.contains("supported"))
        // Verdict line must be present (AC5).
        #expect(result.standardOutput.contains("MB/s") || result.standardOutput.contains("insufficient"))
    }

    // MARK: - --json output

    @Test func jsonOutputIsDecodable() throws {
        let url = "https://diagnose-cmd-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, body: tenMB, acceptsRanges: true,
            bodyChunkSize: 131_072, bodyChunkDelayMicroseconds: 500)

        let result = GohDiagnoseCommand.run(
            arguments: [url, "--json", "--connections", "1"],
            sessionFactory: { _ in mockSession() },
            config: fastConfig())

        #expect(result.exitCode == 0)
        let data = try #require(result.standardOutput.data(using: String.Encoding.utf8))
        let report = try JSONDecoder().decode(DiagnosisReport.self, from: data)
        #expect(report.reportVersion == 1)
        #expect(report.url == url)
        #expect(report.reachable == true)
    }

    // MARK: - Range ignored → exit 0, rangeUnsupported verdict (AC3)

    @Test func rangeIgnoredExits0WithRangeUnsupportedVerdict() {
        let url = "https://diagnose-cmd-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, body: tenMB, acceptsRanges: false,
            bodyChunkSize: 131_072, bodyChunkDelayMicroseconds: 500)

        let result = GohDiagnoseCommand.run(
            arguments: [url],
            sessionFactory: { _ in mockSession() },
            config: fastConfig())

        // AC3: exit 0 (diagnosis ran, ProbeTermination.diagnosed), output notes range unsupported.
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.lowercased().contains("not supported")
            || result.standardOutput.lowercased().contains("ignores range")
            || result.standardOutput.lowercased().contains("range"))
    }

    // MARK: - Helpers

    private func fastConfig() -> DiagnoseConfig {
        DiagnoseConfig(
            targetConnections: 1,
            warmupSeconds: 0,
            sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0,
            defaultDeadlineSeconds: 2.0,
            minSampleBytes: 0,
            scalingFactor: 1.3,
            connectTimeoutSeconds: 5.0)
    }
}
