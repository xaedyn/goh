import Foundation

// MARK: - ProbeTermination (spec §2.1 and §8)

/// Typed termination result from `GohDiagnoseProbe.run()`.
/// The command maps these to exit codes — it NEVER inspects `verdictText`.
/// `diagnosed`→0, `unreachable`→2, `httpError`→3, `authRequired`→4.
/// (Exit 64 is handled at the arg-parse layer, before the probe runs.)
public enum ProbeTermination: Sendable {
    /// Diagnosis completed — any finding (rate-limit, no-range, scaled, etc.) exits 0.
    case diagnosed
    /// Transport failure (DNS / connect / TLS / timeout). Report has `reachable = false`.
    case unreachable(GohError)
    /// HTTP error on Phase 0 (4xx/5xx other than 401/403). Carries the status code.
    case httpError(Int)
    /// HTTP 401 or 403 on Phase 0.
    case authRequired
}

// MARK: - GohDiagnoseProbe

/// The async probe engine for `goh diagnose`.
///
/// Runs in three phases per the spec §2.1:
///   Phase 0 — Reachability + Range detection (one ranged GET).
///   Phase 1 — Single-connection throughput sample (T₁).
///   Phase 2 — N-connection ramp sample (Tₙ). Skipped if range unsupported or size unknown.
///
/// Bytes are discarded — no disk write, no temp file.
/// All timing uses `ContinuousClock` (monotonic), not wall-clock.
///
/// `GohDiagnoseProbe` lives in `GohCore/CLI/` and therefore has access to the
/// module-internal `URLSession.streamingResponse(for:onMetrics:)`.
struct GohDiagnoseProbe: Sendable {
    let urlString: String
    let config: DiagnoseConfig
    let session: URLSession
    let full: Bool

    init(
        urlString: String,
        config: DiagnoseConfig,
        session: URLSession,
        full: Bool
    ) {
        self.urlString = urlString
        self.config = config
        self.session = session
        self.full = full
    }

    /// Runs the complete probe and returns a populated `DiagnosisReport` and a typed
    /// `ProbeTermination`. Never throws; all errors are captured into the report.
    ///
    /// The command maps `ProbeTermination` to exit codes — it NEVER inspects `verdictText`.
    /// A `DiagnosisReport` is produced in every case (best-effort; `reachable=false` on
    /// `unreachable`) to honour the always-report guarantee and feed `--json`.
    func run() async -> (DiagnosisReport, ProbeTermination) {
        var report = DiagnosisReport(url: urlString)

        // NOTE: malformed-URL is caught at the command arg-parse layer BEFORE run() is called.
        // The probe is only invoked with a parseable absolute URL (enforced by the command).
        // The guard below is a defensive fallback only — it is not on any reachable path.
        guard let url = URL(string: urlString) else {
            return (report, .unreachable(GohError(code: .unsupportedURL, message: "Malformed URL.")))
        }

        // Phase 0 — Reachability + Range probe.
        return await runPhase0(url: url, report: &report)
    }

    // MARK: - Phase 0

    /// Issues Range: bytes=0- and interprets the response.
    /// Returns (report, ProbeTermination) — the termination drives exit codes in the command.
    private func runPhase0(
        url: URL,
        report: inout DiagnosisReport
    ) async -> (DiagnosisReport, ProbeTermination) {
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("bytes=0-", forHTTPHeaderField: "Range")

        let response: HTTPURLResponse
        let stream: AsyncThrowingStream<Data, Error>
        let cancelStream: @Sendable () -> Void

        do {
            (response, stream, cancelStream) = try await session.streamingResponse(
                for: urlRequest,
                onMetrics: { @Sendable metrics in
                    // networkProtocolName is only available post-hoc (on terminal state).
                    // The probe stores it via a Mutex so runPhase1/2 can read it after
                    // the stream drains or is cancelled.
                    // NOTE: Task 5 adds the Mutex; Phase 0 skeleton just reads the
                    // response headers here.
                    _ = metrics.networkProtocolName   // captured by Task 5
                })
        } catch {
            report.reachable = false
            let gohError = GohError(code: .connectionFailed, message: error.localizedDescription)
            return (report, .unreachable(gohError))
        }

        switch response.statusCode {
        case 206:
            report.reachable = true
            report.rangeSupported = true
            report.accepted = 1
            // Parse Content-Range for total size.
            if let cr = Self.contentRange(response) {
                report.totalBytes = cr.total
            }
            // Phase 1: drain the open stream and sample T₁.
            await runPhase1(
                url: url,
                stream: stream,
                cancelStream: cancelStream,
                report: &report)
            return (report, .diagnosed)

        case 200..<300:
            report.reachable = true
            report.rangeSupported = false
            report.accepted = 1
            // Phase 1 (single-stream only): drain the 200 stream.
            await runPhase1(
                url: url,
                stream: stream,
                cancelStream: cancelStream,
                report: &report)
            return (report, .diagnosed)

        case 401, 403:
            report.reachable = true
            cancelStream()
            return (report, .authRequired)

        default:
            report.reachable = true
            cancelStream()
            return (report, .httpError(response.statusCode))
        }
    }

    // MARK: - Sampling probe stub (replaced entirely in Task 5)
    //
    // Task 5 replaces this file with the full concurrent-drain implementation
    // (`runSamplingProbe`). This stub exists only so Task 4's Phase 0 tests compile
    // and pass; it is not called with a meaningful body.

    /// Stub: drains the Phase-0 stream with no timing, so Phase 0 tests compile.
    /// Replaced by `runSamplingProbe` in Task 5.
    private func runPhase1(
        url: URL,
        stream: AsyncThrowingStream<Data, Error>,
        cancelStream: @Sendable () -> Void,
        report: inout DiagnosisReport
    ) async {
        defer { cancelStream() }
        // Consume the stream (discard bytes); real sampling added in Task 5.
        do {
            for try await _ in stream { }
        } catch { }
    }

    // MARK: - Inlined helpers (from DownloadEngine private surface — do NOT widen engine)

    private struct ContentRange: Sendable {
        var start: UInt64
        var end: UInt64
        var total: UInt64
    }

    /// Parses `Content-Range: bytes START-END/TOTAL`.
    /// Returns `nil` for absent, unparseable, or internally inconsistent values.
    private static func contentRange(_ response: HTTPURLResponse) -> ContentRange? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              value.hasPrefix("bytes ")
        else { return nil }
        let payload = value.dropFirst("bytes ".count)
        guard let slash = payload.lastIndex(of: "/") else { return nil }
        let rangePart = payload[..<slash]
        guard let dash = rangePart.firstIndex(of: "-") else { return nil }
        let startStr = rangePart[..<dash].trimmingCharacters(in: .whitespaces)
        let endStr = rangePart[rangePart.index(after: dash)...]
            .trimmingCharacters(in: .whitespaces)
        let totalStr = payload[payload.index(after: slash)...]
            .trimmingCharacters(in: .whitespaces)
        guard
            let start = UInt64(startStr),
            let end = UInt64(endStr),
            let total = UInt64(totalStr),
            total > 0,
            start <= end,
            end < total
        else { return nil }
        return ContentRange(start: start, end: end, total: total)
    }
}
