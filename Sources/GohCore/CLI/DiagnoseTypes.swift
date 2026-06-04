import Foundation

// MARK: - DiagnoseConfig

/// Injectable timing constants for `goh diagnose`.
/// Default values match the spec §2.2 table.
/// Tests inject small values to keep suites fast.
public struct DiagnoseConfig: Sendable {
    /// Target number of parallel connections in Phase 2 (default 8; clamped 1–16 by arg parser).
    public var targetConnections: Int
    /// Seconds to discard at the start of Phase 1 (TCP slow-start exclusion).
    public var warmupSeconds: Double
    /// Seconds of steady-state measurement per phase.
    public var sampleWindowSeconds: Double
    /// Seconds to wait after opening N–1 additional connections before the Phase 2 window.
    public var rampWarmupSeconds: Double
    /// Global wall-clock deadline for default (non-`--full`) mode, in seconds.
    public var defaultDeadlineSeconds: Double
    /// Minimum byte delta for a throughput estimate to be considered reliable.
    public var minSampleBytes: Int
    /// T_n / T_1 ratio threshold for the `scaled` verdict.
    public var scalingFactor: Double
    /// Per-connection connect/idle timeout, in seconds.
    public var connectTimeoutSeconds: Double

    public init(
        targetConnections: Int = 8,
        warmupSeconds: Double = 1.5,
        sampleWindowSeconds: Double = 4.0,
        rampWarmupSeconds: Double = 1.0,
        defaultDeadlineSeconds: Double = 12.0,
        minSampleBytes: Int = 8_000_000,
        scalingFactor: Double = 1.3,
        connectTimeoutSeconds: Double = 10.0
    ) {
        self.targetConnections = targetConnections
        self.warmupSeconds = warmupSeconds
        self.sampleWindowSeconds = sampleWindowSeconds
        self.rampWarmupSeconds = rampWarmupSeconds
        self.defaultDeadlineSeconds = defaultDeadlineSeconds
        self.minSampleBytes = minSampleBytes
        self.scalingFactor = scalingFactor
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }
}

// MARK: - Verdict

/// The bottleneck verdict from a `goh diagnose` run.
/// Raw values are the frozen `--json` v1 contract — do NOT rename.
public enum Verdict: String, Codable, Sendable, CaseIterable {
    case insufficientData
    case rangeUnsupported
    case rangeSupportedSizeUnknown
    case rateLimited
    case scaled
    case didNotScaleMultiplexed
    case didNotScaleHTTP1
}

// MARK: - DiagnosisReport

/// Structured result of `goh diagnose`. The `--json` output contract (v1).
/// Fields named here are frozen; `verdictText` is human display only (not frozen).
public struct DiagnosisReport: Codable, Sendable {
    /// Always 1 for v1; bump only if a field name/type or enum raw value changes.
    public var reportVersion: Int = 1
    /// The URL as supplied by the user (may contain query strings).
    public var url: String
    /// `false` only on transport failure.
    public var reachable: Bool = false
    /// `true` when Phase 0 received 206.
    public var rangeSupported: Bool = false
    /// Total file size from `Content-Range`, or `nil` if absent/unparseable or range unsupported.
    public var totalBytes: UInt64?
    /// ALPN-reported protocol string: "h3", "h2", "http/1.1", or nil → "unknown".
    public var networkProtocol: String?
    /// How many parallel range requests were attempted (Phase 2), or 1 if Phase 2 skipped.
    public var attempted: Int = 1
    /// Count of 206 responses across attempted requests.
    public var accepted: Int = 0
    /// HTTP-status-string → count of rejected ranged requests. `[String: Int]` so JSON is an object.
    public var rejections: [String: Int] = [:]
    /// Phase 1 throughput estimate in decimal MB/s; nil = insufficient sample.
    public var singleConnMBps: Double?
    /// Phase 2 throughput estimate in decimal MB/s; nil = skipped or insufficient.
    public var multiConnMBps: Double?
    /// Whole-file average MB/s (only with `--full`); nil otherwise.
    public var wholeFileMBps: Double?
    /// The selected verdict case.
    public var verdict: Verdict = .insufficientData
    /// Human-readable verdict sentence (NOT frozen; may change without a version bump).
    public var verdictText: String = ""

    public init(url: String) {
        self.url = url
    }
}

// MARK: - Pure logic

/// Selects the one verdict for the given report.
/// Pure function: no I/O, no side effects — unit-testable in isolation.
/// Returns (Verdict, verdictText). The text is NOT frozen; the Verdict case is.
///
/// Evaluated in spec priority order (§2.3):
/// 1. insufficientData
/// 2. rangeUnsupported
/// 3. rangeSupportedSizeUnknown
/// 4. rateLimited
/// 5. scaled
/// 6. didNotScaleMultiplexed
/// 7. didNotScaleHTTP1
public func verdict(
    _ report: DiagnosisReport,
    config: DiagnoseConfig
) -> (Verdict, String) {
    // Case 1 — no reliable T₁
    guard let t1 = report.singleConnMBps else {
        return (
            .insufficientData,
            "File too small or too few bytes sampled to estimate throughput reliably."
                + " (Range support: \(report.rangeSupported ? "supported" : "not supported");"
                + " protocol: \(report.networkProtocol ?? "unknown").)"
        )
    }

    // Case 2 — server ignores Range
    guard report.rangeSupported else {
        return (
            .rangeUnsupported,
            "Server ignores Range — single connection only; parallel connections"
                + " won't help. ~\(formatted(t1)) MB/s."
        )
    }

    // Case 3 — Range supported but size unknown (no safe offsets for Phase 2)
    guard report.totalBytes != nil else {
        return (
            .rangeSupportedSizeUnknown,
            "Range supported, but the server didn't report a file size,"
                + " so parallelism couldn't be tested. ~\(formatted(t1)) MB/s."
        )
    }

    // Phase 2 ran (attempted >= 2 and accepted/totalBytes are in hand).
    // Cases 4-7 require Phase 2 to have run (attempted > 1).
    // If targetConnections == 1 or Phase 2 was skipped, report falls to
    // insufficientData or rangeSupportedSizeUnknown above; the only way
    // we reach here with attempted == 1 is a degenerate DiagnosisReport
    // (tests can build that directly — the verdict is well-defined either way).

    // Case 4 — rate-limited: some ranged GETs were rejected
    if report.accepted < report.attempted {
        let bestObserved = max(t1, report.multiConnMBps ?? 0)
        let m = report.accepted
        let n = report.attempted
        return (
            .rateLimited,
            "Server rate-limits parallel range requests (accepted \(m) of \(n))."
                + " goh is limited to ~\(m) connections here."
                + " ~\(formatted(bestObserved)) MB/s."
        )
    }

    // Cases 5-7 — all accepted; compare T₁ vs Tₙ
    let tn = report.multiConnMBps ?? t1   // if Tₙ nil, treat as equal (conservative)
    let n = report.attempted

    if tn >= config.scalingFactor * t1 {
        // Case 5 — throughput scaled
        return (
            .scaled,
            "Throughput scaled with more connections — the source/path is the limit"
                + " and parallelism helps (goh uses up to \(n) connections)."
                + " ~\(formatted(tn)) MB/s at \(n) connections."
        )
    }

    // Did not scale. Branch on protocol — allow-listed: only "http/1.1" exactly
    // triggers the HTTP/1.1 branch (real parallel TCP / separate congestion windows).
    // Any other value — nil, "h2", "h3", "http/1.0", or unexpected ALPN — falls
    // to the conservative multiplexed branch. This is the bet from the research
    // brief: "could not distinguish" is an acceptable honest answer for h2/h3.
    if report.networkProtocol == "http/1.1" {
        // Case 7 — http/1.1: separate TCP connections, but throughput didn't scale
        return (
            .didNotScaleHTTP1,
            "Adding parallel connections didn't increase throughput — either your"
                + " connection is the limit or the server caps total bandwidth per"
                + " client; these can't be told apart without a faster reference."
                + " ~\(formatted(tn)) MB/s."
        )
    } else {
        // Case 6 — h2/h3/unknown: N range requests share ~one connection
        let proto = report.networkProtocol ?? "unknown"
        return (
            .didNotScaleMultiplexed,
            "Throughput didn't increase, but over \(proto) parallel range requests"
                + " share one connection, so this test can't tell whether your link"
                + " or the source is the limit."
                + " ~\(formatted(tn)) MB/s."
                + " (goh's multi-connection speedups apply to HTTP/1.1 origins.)"
        )
    }
}

// MARK: - rate()

/// Converts a byte delta and elapsed duration to decimal MB/s.
/// Pure function: no I/O, no state, unit-testable in isolation.
/// Uses decimal MB (bytes / 1_000_000.0), matching the spec §2.2.
public func rate(byteDelta: Int, over seconds: Double) -> Double {
    guard seconds > 0, byteDelta >= 0 else { return 0 }
    return Double(byteDelta) / 1_000_000.0 / seconds
}

// MARK: - Private formatting

private func formatted(_ mbps: Double) -> String {
    String(format: "%.1f", mbps)
}
