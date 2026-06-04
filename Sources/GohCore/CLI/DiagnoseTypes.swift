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
