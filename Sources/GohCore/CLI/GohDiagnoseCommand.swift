import Dispatch
import Foundation

// MARK: - Exit codes (diagnose-specific per spec §8)
// 0 — diagnosis completed (ProbeTermination.diagnosed — any finding)
// 1 — defensive bridge guard (unreachable in practice — see comment in run())
// 2 — target unreachable (ProbeTermination.unreachable)
// 3 — HTTP error on Phase 0 (ProbeTermination.httpError)
// 4 — authentication required (ProbeTermination.authRequired)
// 64 — usage error (caught at arg-parse, before probe runs)

/// CLI-local verb `goh diagnose <url>`.
///
/// Synchronous face: returns `GohCommandLineResult`.
///
/// The async `GohDiagnoseProbe` is bridged to the synchronous CLI boundary via a
/// `DispatchSemaphore` blocking runner: a `Task` runs the async probe on the cooperative
/// pool to completion and signals the semaphore; the synchronous `run()` waits on it.
/// This is a self-contained pattern confined to `GohDiagnoseCommand` — it is NOT a re-use
/// of `GohForegroundDownload`'s semaphore (that semaphore is used for XPC delivery
/// callbacks between threads, not as an async→sync bridge). The shape mirrors the
/// `doctor`-style synchronous closure wiring so `GohCommandLine.run()` and `main.swift`
/// stay synchronous and unchanged.
public enum GohDiagnoseCommand {

    public typealias SessionFactory = (URLSessionConfiguration) -> URLSession

    /// Parses `arguments` (everything after "diagnose"), runs the probe, renders output.
    ///
    /// - Parameters:
    ///   - arguments: The arguments following `diagnose` (not including "diagnose" itself).
    ///   - sessionFactory: Injected for tests; defaults to `URLSession(configuration:)`.
    ///   - config: Injected for tests; defaults to the spec §2.2 table.
    public static func run(
        arguments: [String],
        sessionFactory: @escaping SessionFactory = { URLSession(configuration: $0) },
        config: DiagnoseConfig = DiagnoseConfig()
    ) -> GohCommandLineResult {
        let usageLine = "usage: goh diagnose <url> [--full] [--json] [--connections N | -c N]\n"

        // BLOCK 8: malformed URL (and all usage errors) are caught HERE at arg-parse,
        // before the probe runs. The probe is only reached with a parseable absolute URL.
        let parsed: ParsedArgs
        do {
            parsed = try parseArgs(arguments)
        } catch let e as UsageError {
            return GohCommandLineResult(
                exitCode: 64,
                standardError: "\(usageLine)\(e.message)\n")
        } catch {
            return GohCommandLineResult(exitCode: 64, standardError: usageLine)
        }

        // BLOCK 8: single malformed-URL gate — catches non-URL strings that passed the
        // arg parser (no scheme, no host). The probe is never reached with a malformed URL.
        guard URL(string: parsed.url) != nil, parsed.url.contains("://") else {
            return GohCommandLineResult(
                exitCode: 64,
                standardError: "\(usageLine)malformed URL: \(parsed.url)\n")
        }

        // Build session with diagnose's own config copy.
        // BLOCK 1: set timeoutIntervalForRequest so stalled connections fail fast
        // (idle timeout backstop; critical in --full mode where there is no deadline child task).
        let sessionConfig = GohCore.downloadSessionConfiguration()
        sessionConfig.timeoutIntervalForRequest = config.connectTimeoutSeconds
        let session = sessionFactory(sessionConfig)

        // Effective config — override targetConnections if --connections was passed.
        var effectiveConfig = config
        if let c = parsed.connections {
            effectiveConfig.targetConnections = c
        }

        let probe = GohDiagnoseProbe(
            urlString: parsed.url,
            config: effectiveConfig,
            session: session,
            full: parsed.full)

        // Async→sync bridge: a Task runs the probe on the cooperative pool while this
        // function blocks on the semaphore. IMPORTANT: this MUST be called from a thread
        // that is NOT part of the Swift-concurrency cooperative pool — in production the CLI
        // invokes it from the process main thread, which is safe. Calling it from a pool
        // thread (e.g. directly inside a Swift Testing `@Test` body) blocks a pool thread;
        // enough concurrent such calls block every pool thread and the probe Task can never
        // run → deadlock. Tests hop onto a detached thread (see GohDiagnoseCommandTests).
        // BLOCK 7: nonisolated(unsafe) satisfies Swift 6 Sendable checking for the write-before-
        // signal / read-after-wait pattern. The semaphore establishes a happens-before edge.
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var probeResult: (DiagnosisReport, ProbeTermination)?

        Task {
            probeResult = await probe.run()
            semaphore.signal()
        }
        semaphore.wait()

        // BLOCK 8: exit 1 is a defensive guard — it is not reached on any normal path.
        // The Task always assigns probeResult before signalling; this branch exists as an
        // explicit defensive catch-all and is intentionally untested (spec §8).
        guard let (report, termination) = probeResult else {
            return GohCommandLineResult(
                exitCode: 1,
                standardError: "Internal error: probe bridge returned without a result.\n")
        }

        // BLOCK 3: exit codes are driven by ProbeTermination — NEVER by verdictText.
        // verdictText is human-display prose (unfrozen); termination is the typed signal.
        switch termination {
        case .unreachable:
            let output = parsed.json ? (jsonString(report) ?? "") : "Target unreachable.\n"
            return GohCommandLineResult(exitCode: 2, standardOutput: output)

        case .authRequired:
            let output = parsed.json
                ? (jsonString(report) ?? "")
                : "Authentication required (HTTP 401/403).\n"
            return GohCommandLineResult(exitCode: 4, standardOutput: output)

        case .httpError(let code):
            let output = parsed.json
                ? (jsonString(report) ?? "")
                : "HTTP \(code) — cannot diagnose.\n"
            return GohCommandLineResult(exitCode: 3, standardOutput: output)

        case .diagnosed:
            // Apply the pure verdict function to fill verdict and verdictText.
            var finalReport = report
            let (v, text) = verdict(finalReport, config: effectiveConfig)
            finalReport.verdict = v
            finalReport.verdictText = text

            let output: String
            if parsed.json {
                output = jsonString(finalReport) ?? ""
            } else {
                output = humanOutput(finalReport, url: parsed.url)
            }
            return GohCommandLineResult(exitCode: 0, standardOutput: output)
        }
    }

    // MARK: - Human output

    private static func humanOutput(_ report: DiagnosisReport, url: String) -> String {
        var lines: [String] = []
        lines.append("URL:          \(url)")
        lines.append("Reachable:    \(report.reachable ? "yes" : "no")")
        lines.append("Range support: \(report.rangeSupported ? "supported" : "not supported")")
        if let total = report.totalBytes {
            let mb = Double(total) / 1_000_000
            lines.append("File size:    \(String(format: "%.1f", mb)) MB")
        }
        let proto = report.networkProtocol ?? "unknown"
        lines.append("Protocol:     \(proto)")
        lines.append("Connections:  \(report.accepted) accepted of \(report.attempted) attempted")
        if !report.rejections.isEmpty {
            let desc = report.rejections
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            lines.append("Rejections:   \(desc)")
        }
        if let t1 = report.singleConnMBps {
            lines.append("T1:           \(String(format: "%.2f", t1)) MB/s (1 connection)")
        } else {
            lines.append("T1:           insufficient data")
        }
        if let tn = report.multiConnMBps {
            lines.append("Tn:           \(String(format: "%.2f", tn)) MB/s (\(report.attempted) connections)")
        } else if report.attempted > 1 {
            lines.append("Tn:           insufficient data")
        }
        if let wf = report.wholeFileMBps {
            lines.append("Whole file:   \(String(format: "%.2f", wf)) MB/s")
        }
        lines.append("")
        lines.append("Verdict:      \(report.verdictText)")
        return lines.map { $0 + "\n" }.joined()
    }

    // MARK: - JSON output

    private static func jsonString(_ report: DiagnosisReport) -> String? {
        guard let data = try? JSONEncoder().encode(report) else { return nil }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - Arg parsing

    private struct ParsedArgs: Sendable {
        var url: String
        var full: Bool = false
        var json: Bool = false
        var connections: Int?
    }

    private struct UsageError: Error {
        var message: String
    }

    private static func parseArgs(_ args: [String]) throws -> ParsedArgs {
        guard !args.isEmpty else {
            throw UsageError(message: "URL is required")
        }

        var url: String?
        var full = false
        var json = false
        var connections: Int?
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--full":
                full = true
                index += 1
            case "--json":
                json = true
                index += 1
            case "--connections", "-c":
                guard index + 1 < args.count else {
                    throw UsageError(message: "\(arg) requires a value")
                }
                let raw = args[index + 1]
                guard let n = Int(raw), (1...16).contains(n) else {
                    throw UsageError(message: "connections must be an integer from 1 to 16")
                }
                connections = n
                index += 2
            default:
                guard !arg.hasPrefix("-") else {
                    throw UsageError(message: "unknown option \(arg)")
                }
                guard url == nil else {
                    throw UsageError(message: "diagnose accepts exactly one URL")
                }
                url = arg
                index += 1
            }
        }

        guard let resolvedURL = url else {
            throw UsageError(message: "URL is required")
        }

        return ParsedArgs(url: resolvedURL, full: full, json: json, connections: connections)
    }
}
