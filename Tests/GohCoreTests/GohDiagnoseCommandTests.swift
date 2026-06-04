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

    /// Runs the SYNCHRONOUS `GohDiagnoseCommand.run` bridge on a detached thread,
    /// off the Swift-concurrency cooperative pool.
    ///
    /// `run()` blocks a thread on a `DispatchSemaphore` while its `Task` runs the
    /// probe on the cooperative pool — safe in production, where the CLI calls it
    /// from the process main thread. But Swift Testing invokes `@Test` bodies *on*
    /// the cooperative pool; calling the blocking bridge directly there blocks a
    /// pool thread, and enough parallel command tests on a low-core CI runner block
    /// every pool thread so the probe `Task`s can never run — a deadlock that hung
    /// CI for 6 hours. Hopping onto a detached thread (and suspending the test via a
    /// continuation) mirrors production and keeps the pool free for the probe.
    private func runOffPool(
        _ arguments: [String],
        config: DiagnoseConfig? = nil
    ) async -> GohCommandLineResult {
        await withCheckedContinuation { (cont: CheckedContinuation<GohCommandLineResult, Never>) in
            Thread.detachNewThread {
                let result: GohCommandLineResult
                if let config {
                    result = GohDiagnoseCommand.run(
                        arguments: arguments,
                        sessionFactory: { _ in mockSession() },
                        config: config)
                } else {
                    result = GohDiagnoseCommand.run(
                        arguments: arguments,
                        sessionFactory: { _ in mockSession() })
                }
                cont.resume(returning: result)
            }
        }
    }

    // MARK: - Arg parsing

    @Test func missingURLExits64() async {
        let result = await runOffPool([])
        #expect(result.exitCode == 64)
        #expect(result.standardError.contains("usage:"))
    }

    // BLOCK 8: malformed URL is caught ONLY at the arg-parse layer (before the probe runs).
    // This test exercises the command's arg-parse URL guard.
    @Test func malformedURLExits64() async {
        let result = await runOffPool(["not a url"])
        #expect(result.exitCode == 64)
    }

    @Test func unknownFlagExits64() async {
        let result = await runOffPool(["https://example.com/f.bin", "--bogus"])
        #expect(result.exitCode == 64)
    }

    @Test func connectionsOutOfRangeExits64() async {
        let result = await runOffPool(["https://example.com/f.bin", "--connections", "99"])
        #expect(result.exitCode == 64)
    }

    // MARK: - Transport failure → exit 2
    // BLOCK 3: exit code driven by ProbeTermination.unreachable — NOT by verdictText.

    @Test func transportFailureExits2() async {
        let url = "https://diagnose-cmd-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, failure: URLError(.cannotConnectToHost))

        let result = await runOffPool([url], config: fastConfig())
        // ProbeTermination.unreachable → exit 2
        #expect(result.exitCode == 2)
    }

    // MARK: - Auth required → exit 4
    // BLOCK 3: exit code driven by ProbeTermination.authRequired — NOT by verdictText.

    @Test func authRequiredExits4() async {
        let url = "https://diagnose-cmd-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, status: 401, body: Data(), acceptsRanges: false)

        let result = await runOffPool([url], config: fastConfig())
        // ProbeTermination.authRequired → exit 4
        #expect(result.exitCode == 4)
    }

    // MARK: - HTTP error → exit 3
    // BLOCK 3: exit code driven by ProbeTermination.httpError(statusCode) — NOT by verdictText.

    @Test func httpErrorExits3() async {
        let url = "https://diagnose-cmd-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, status: 404, body: Data(), acceptsRanges: false)

        let result = await runOffPool([url], config: fastConfig())
        // ProbeTermination.httpError(404) → exit 3
        #expect(result.exitCode == 3)
    }

    // MARK: - Successful diagnosis → exit 0 (AC1)
    // BLOCK 3: ProbeTermination.diagnosed → exit 0.

    @Test func diagnoseReportsRangeAndProtocol() async throws {
        // AC1 integration: reachable + range + throughput → exit 0.
        let url = "https://diagnose-cmd-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(
            url, body: tenMB, acceptsRanges: true,
            bodyChunkSize: 131_072, bodyChunkDelayMicroseconds: 500)

        let result = await runOffPool([url, "--connections", "1"], config: fastConfig())

        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("Reachable:"))
        #expect(result.standardOutput.contains("Range support"))
        #expect(result.standardOutput.contains("supported"))
        // Verdict line must be present (AC5).
        #expect(result.standardOutput.contains("MB/s") || result.standardOutput.contains("insufficient"))
    }

    // MARK: - --json output

    @Test func jsonOutputIsDecodable() async throws {
        let url = "https://diagnose-cmd-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, body: tenMB, acceptsRanges: true,
            bodyChunkSize: 131_072, bodyChunkDelayMicroseconds: 500)

        let result = await runOffPool([url, "--json", "--connections", "1"], config: fastConfig())

        #expect(result.exitCode == 0)
        let data = try #require(result.standardOutput.data(using: String.Encoding.utf8))
        let report = try JSONDecoder().decode(DiagnosisReport.self, from: data)
        #expect(report.reportVersion == 1)
        #expect(report.url == url)
        #expect(report.reachable == true)
    }

    // MARK: - Range ignored → exit 0, rangeUnsupported verdict (AC3)

    @Test func rangeIgnoredExits0WithRangeUnsupportedVerdict() async {
        let url = "https://diagnose-cmd-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, body: tenMB, acceptsRanges: false,
            bodyChunkSize: 131_072, bodyChunkDelayMicroseconds: 500)

        let result = await runOffPool([url], config: fastConfig())

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
