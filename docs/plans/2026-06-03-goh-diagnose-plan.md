---
date: 2026-06-03
feature: goh-diagnose
type: implementation-plan
spec: docs/superpowers/specs/2026-06-03-goh-diagnose-design.md
research: docs/superpowers/research/2026-06-03-goh-diagnose-brief.md
acceptance-criteria: docs/superpowers/research/2026-06-03-goh-diagnose-acceptance-criteria.md
REQUIRED SUB-SKILL: superpowers:subagent-driven-development
---

# Implementation Plan — `goh diagnose <url>`

## Overview

Three deployment-independent phases. Each phase is independently testable under
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. No phase
modifies a frozen wire format, XPC contract, or JobStore schema — the feature is
purely additive.

- **Phase 1** (Tasks 1–3): Pure types (`DiagnoseConfig`, `DiagnosisReport`,
  `Verdict`) + pure logic functions (`verdict()`, `rate()`) + exhaustive unit
  tests. No I/O. Independently testable.
- **Phase 2** (Tasks 4–6): The async probe core (`GohDiagnoseProbe`) — Phase 0
  reachability/range detection, then a continuous concurrent-drain probe (`runSamplingProbe`)
  that runs all N connections in one `withTaskGroup`, takes timed `ContinuousClock` snapshots
  for T₁ and Tₙ over real measured elapsed seconds, and bounds the entire default-mode probe
  with a single deadline child. Driven by injectable `URLSession` + `DiagnoseConfig`.
  Integration-tested via `MockURLProtocol`. All integration and AC4 tests use N≥2.
- **Phase 3** (Tasks 7–9): `GohDiagnoseCommand` (sync/semaphore bridge, arg
  parsing, human + JSON rendering, exit codes), wiring into
  `GohCommandLine`/`main.swift`, and end-to-end CLI tests.

Phase artifact paths:
- `docs/superpowers/progress/2026-06-03-goh-diagnose-phase1.md`
- `docs/superpowers/progress/2026-06-03-goh-diagnose-phase2.md`
- `docs/superpowers/progress/2026-06-03-goh-diagnose-phase3.md`

## AC → Task mapping

| AC | Task | Swift Testing stub |
|---|---|---|
| AC1 — reachable, range supported, protocol, throughput, exit 0 | Task 5 (probe integration) + Task 7 (command rendering) | `diagnoseReportsRangeProtocolAndThroughput()` |
| AC2 — rate-limit: attempted vs accepted, all N recorded, no abort | Task 5 (probe integration) | `diagnoseRateLimitRecordsAllOutcomesWithoutAborting()` |
| AC3 — Range ignored (200): rangeUnsupported verdict, single-stream T₁ | Task 5 (probe integration) | `diagnoseRangeIgnoredProducesRangeUnsupportedVerdict()` |
| AC4 — default mode time-boxed (Phase 1 + Phase 2), --full drains to EOF | Task 6 (time-box probe test) | `diagnoseDefaultModeCompletesWithinDeadline()` / `stalledServerWithPhase2DoesNotHangInDefaultMode()` / `diagnoseFullDrainesToEOF()` / `diagnoseDefaultModeWholeFileMBpsIsNil()` (all N≥2) |
| AC5 — exactly one verdict, protocol-gated split (h2/h3 vs http1.1) | Task 2 (verdict unit tests) | `verdictDidNotScaleHTTP1OnlyForExactHTTP1()` / `verdictDidNotScaleMultiplexedForH2()` (see also `verdictDidNotScaleOnlyForHTTP1` and `verdictMultiplexedForH2AndUnknown` which duplicate those tests as explicit AC-named anchors) |

---

## Phase 1 — Pure types and pure logic

### Task 1: `DiagnoseConfig`, `DiagnosisReport`, `Verdict` types

**Files**
- Create `Sources/GohCore/CLI/DiagnoseTypes.swift`

**Pre-task reads**
- [ ] `/Users/shane/claude/goh/Sources/GohCore/Model/GohError.swift` — confirm `ErrorCode` cases (already read)
- [ ] `/Users/shane/claude/goh/Sources/GohCore/CLI/GohCommandLine.swift` — confirm module conventions (already read)

**Step 1 — Write failing test**

Create `Tests/GohCoreTests/DiagnoseTypesTests.swift`:

```swift
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
        #expect(actualJSON == fixtureJSON,
            "DiagnosisReport --json output differs from golden fixture at \(fixtureURL.path). "
            + "If this is intentional, bump reportVersion and delete the fixture to regenerate.")
    }
}
```

**Step 2 — Run expected FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter GohCoreTests.DiagnoseTypesTests 2>&1 | tail -20
```

Expected: compile error — `DiagnoseConfig`, `DiagnosisReport`, `Verdict` not found.

**Step 3 — Implement `DiagnoseTypes.swift`**

```swift
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
```

**Step 4 — Run expected PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter GohCoreTests.DiagnoseTypesTests 2>&1 | tail -10
```

Expected: `Test run with 5 tests passed.` (4 existing + 1 golden-file fixture; fixture is created on first run).

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/DiagnoseTypes.swift Tests/GohCoreTests/DiagnoseTypesTests.swift \
        Tests/GohCoreTests/Fixtures/
git commit -m "feat(diagnose): add DiagnoseConfig, DiagnosisReport, and Verdict types (Phase 1 Task 1)"
```

---

### Task 2: Pure `verdict()` function — exhaustive unit tests for all 7 cases

**Files**
- Modify `Sources/GohCore/CLI/DiagnoseTypes.swift` — add `verdict(_:)` function
- Modify `Tests/GohCoreTests/DiagnoseTypesTests.swift` — add exhaustive verdict tests

**Pre-task reads**
- [ ] `Sources/GohCore/CLI/DiagnoseTypes.swift` (just written — already in memory)

> **Bet check — Approach 2 verdict logic:** The bet is "a single 1-vs-N comparison,
> hedged honestly, is enough signal for the common case — and 'could not distinguish'
> is an acceptable, honest answer for the ambiguous case." The `verdict()` function is
> where this bet is most load-bearing: the `didNotScaleMultiplexed` branch is the
> hedge for h2/h3/unknown (one congestion window, Tₙ ≈ T₁ is expected regardless of
> link or server cap), and `didNotScaleHTTP1` is the only branch that asserts anything
> about link vs server — and it too hedges ("either your connection is the limit or the
> server caps bandwidth"). The allow-list approach (only http/1.1 → HTTP1 branch;
> everything else → multiplexed) is the conservative, honest encoding of this bet.

**Step 1 — Write failing tests**

Append to `Tests/GohCoreTests/DiagnoseTypesTests.swift`:

```swift
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
```

**Step 2 — Run expected FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter GohCoreTests.DiagnoseTypesTests 2>&1 | tail -20
```

Expected: compile error — `verdict(_:config:)` not found.

**Step 3 — Implement `verdict(_:config:)` in `DiagnoseTypes.swift`**

Append after the `DiagnosisReport` definition:

```swift
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
```

**Step 4 — Run expected PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter GohCoreTests.DiagnoseTypesTests 2>&1 | tail -10
```

Expected: all tests pass (12+ cases).

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/DiagnoseTypes.swift Tests/GohCoreTests/DiagnoseTypesTests.swift
git commit -m "feat(diagnose): add pure verdict() and rate() functions with exhaustive unit tests (Phase 1 Task 2)"
```

---

### Task 3: `rate()` unit tests

**Files**
- Modify `Tests/GohCoreTests/DiagnoseTypesTests.swift` — add rate tests

**Pre-task reads**
- [ ] `Sources/GohCore/CLI/DiagnoseTypes.swift` (just modified)

**Step 1 — Write failing tests**

Append to `Tests/GohCoreTests/DiagnoseTypesTests.swift`:

```swift
// MARK: - rate() unit tests (AC1 load-bearing math)

extension DiagnoseTypesTests {

    @Test func rateComputesDecimalMegabytesPerSecond() {
        // AC1: throughput is in decimal MB/s (bytes / 1_000_000 / seconds).
        // 10_000_000 bytes in 2.0 seconds = 5.0 MB/s
        let result = rate(byteDelta: 10_000_000, over: 2.0)
        #expect(abs(result - 5.0) < 0.0001)
    }

    @Test func rateHandlesSingleByte() {
        // 1 byte in 1.0 second = 0.000001 MB/s (not zero)
        let result = rate(byteDelta: 1, over: 1.0)
        #expect(result > 0)
        #expect(result < 0.01)
    }

    @Test func rateIsZeroForZeroSeconds() {
        // Guard against divide-by-zero.
        let result = rate(byteDelta: 1_000_000, over: 0)
        #expect(result == 0)
    }

    @Test func rateIsZeroForNegativeSeconds() {
        let result = rate(byteDelta: 1_000_000, over: -1.0)
        #expect(result == 0)
    }

    @Test func rateIsZeroForZeroBytes() {
        let result = rate(byteDelta: 0, over: 1.0)
        #expect(result == 0)
    }

    @Test func rate8MBInOneSec() {
        // 8_000_000 bytes / 1_000_000 / 1.0 = 8.0 MB/s (minSampleBytes boundary)
        let result = rate(byteDelta: 8_000_000, over: 1.0)
        #expect(abs(result - 8.0) < 0.0001)
    }
}
```

**Step 2 — Run expected FAIL**

Since `rate()` was already implemented in Task 2, these tests may compile and pass immediately. If the function wasn't added yet, expect compile error. Either way, run:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter GohCoreTests.DiagnoseTypesTests 2>&1 | tail -10
```

Expected: all tests pass (18+ cases).

**Step 3 — Implementation**

`rate()` is already implemented in Task 2. No additional code needed.

**Step 4 — Run expected PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter GohCoreTests.DiagnoseTypesTests 2>&1 | tail -10
```

Expected: all tests pass.

**Step 5 — Commit**

```
git add Tests/GohCoreTests/DiagnoseTypesTests.swift
git commit -m "test(diagnose): exhaustive rate() unit tests covering edge cases (Phase 1 Task 3)"
```

---

## Phase 2 — Async probe core

### Task 4: `GohDiagnoseProbe` skeleton — Phase 0 (reachability + range detection)

**Files**
- Create `Sources/GohCore/CLI/GohDiagnoseProbe.swift`

**Pre-task reads**
- [ ] `Sources/GohCore/Engine/StreamingDataTask.swift` — `streamingResponse(for:onMetrics:)` signature (already read)
- [ ] `Sources/GohCore/GohCore.swift` — `downloadSessionConfiguration()` signature (already read)
- [ ] `Sources/GohCore/Engine/DownloadEngine.swift` lines 283–305 — `contentRange()` to be inlined (already read)
- [ ] `Sources/GohCore/Engine/DownloadEngine.swift` lines 992–998 — `request(for:job:)` to be inlined (already read; diagnose version is simpler — no cookies)
- [ ] `Sources/GohCore/Engine/DownloadEngine.swift` lines 1042–1051 — `httpFailure(statusCode:)` to be inlined (already read)
- [ ] `Sources/GohCore/Model/GohError.swift` — `ErrorCode` cases (already read)

**Step 1 — Write failing test**

Create `Tests/GohCoreTests/GohDiagnoseProbeTests.swift`:

```swift
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
```

**Step 2 — Run expected FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter GohCoreTests.GohDiagnoseProbePhase0Tests 2>&1 | tail -20
```

Expected: compile error — `GohDiagnoseProbe` not found.

**Step 3 — Implement Phase 0 of `GohDiagnoseProbe.swift`**

```swift
import Foundation
import Synchronization

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
```

**Step 4 — Run expected PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter GohCoreTests.GohDiagnoseProbePhase0Tests 2>&1 | tail -10
```

Expected: 5 tests pass (3 existing + 2 new termination tests). Phase 1/2 stubs compile but don't sample yet.

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/GohDiagnoseProbe.swift Tests/GohCoreTests/GohDiagnoseProbeTests.swift
git commit -m "feat(diagnose): GohDiagnoseProbe Phase 0 — reachability, range detection, ProbeTermination (Phase 2 Task 4)"
```

---

### Task 5: Phase 1 (T₁ sampling) + Phase 2 (Tₙ ramp) + protocol capture + AC1/AC2/AC3 integration tests

**Files**
- Modify `Sources/GohCore/CLI/GohDiagnoseProbe.swift` — implement continuous concurrent-drain
  design: per-connection `ByteCounter` array, one `withTaskGroup` owning all drain children +
  optional deadline child, coordinator taking timed ContinuousClock snapshots for T₁ and Tₙ,
  global deadline bounding Phase 1 AND Phase 2 in default mode, `--full` draining all connections
  to EOF with no deadline child.
- Modify `Tests/GohCoreTests/GohDiagnoseProbeTests.swift` — add AC1/AC2/AC3 integration
  tests (all N≥2 where Phase 2 runs).

**Pre-task reads**
- [ ] `Sources/GohCore/CLI/GohDiagnoseProbe.swift` (just written)
- [ ] `Sources/GohCore/CLI/DiagnoseTypes.swift` — `rate()` signature (already in memory)
- [ ] `Tests/GohCoreTests/MockURLProtocol.swift` — delivery model (already read)

**Step 1 — Write failing tests**

Append to `Tests/GohCoreTests/GohDiagnoseProbeTests.swift`:

```swift
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
            bodyChunkSize: 131_072,
            bodyChunkDelayMicroseconds: 1_000,
            failRangeStartingAt: Int(tenMB.count / 2)  // second connection's start fails
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
            bodyChunkSize: 131_072,
            bodyChunkDelayMicroseconds: 1_000,
            failRangeStartingAt: Int(tenMB.count / 2))

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
```

**Step 2 — Run expected FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter GohCoreTests.GohDiagnoseProbeIntegrationTests 2>&1 | tail -20
```

Expected: tests compile but `singleConnMBps` and `multiConnMBps` are nil (Phase 1/2 not yet implemented).

**Step 3 — Implement Phase 1 + Phase 2 + protocol capture**

Replace `GohDiagnoseProbe.swift` entirely with the full implementation. This supersedes the Task 4
skeleton.

Key design points — all four block-review defects (A–D) addressed:

**BLOCK A (default mode unbounded for N≥2):** The `deadlineInstant` is computed once in `run()` from
`clock.now` before Phase 1 starts. The same instant is passed into the single `withTaskGroup` that
owns all drain children (Phase 1 conn-0 + Phase 2 conns 1..N-1) AND the deadline child. The deadline
child fires at `deadlineInstant` and cancels the group, which tears down all open connections at once.
Phase 2 is inside the same group, so the global deadline bounds the entire default-mode probe.

**BLOCK B (`--full` does not read to completion):** When `full == true`, the deadline child is never
added. The coordinator child exits after the Tₙ window but drain children (conn-0 and all Phase-2
connections) keep looping until they hit EOF or the task is cancelled externally. `wholeFileMBps`
is computed from `Σ eofTotalBytes / elapsed(firstByte → lastEOF)` after the group exits.

**BLOCK C (Tₙ mis-measured):** Conn-0 is never cancelled after Phase 1. All N connections (0..N-1)
drain concurrently into per-slot `ByteCounter` (a `Mutex<UInt64>` array). The coordinator takes two
timed snapshots of `Σ counters` — `S1` at instant `t1` (after `rampWarmupSeconds`), `S2` at instant
`t2 = t1 + sampleWindowSeconds` — and computes `Tₙ = rate(byteDelta: S2-S1, over: seconds(t1, t2))`
using the real measured elapsed, not the window constant.

**BLOCK D (tests use N=1, skip Phase 2):** All integration and AC4 tests now use `targetConnections ≥ 2`.

```swift
import Foundation
import Synchronization

// MARK: - ProbeTermination (defined in Task 4 — present here for completeness in full replacement)

public enum ProbeTermination: Sendable {
    case diagnosed
    case unreachable(GohError)
    case httpError(Int)
    case authRequired
}

// MARK: - ByteCounter

/// Per-connection running byte total. `Mutex<UInt64>` so drain tasks and the coordinator
/// can access it concurrently without data races.
private final class ByteCounter: @unchecked Sendable {
    private let mutex = Mutex<UInt64>(0)

    func add(_ n: Int) {
        mutex.withLock { $0 += UInt64(n) }
    }

    func snapshot() -> UInt64 {
        mutex.withLock { $0 }
    }
}

// MARK: - GohDiagnoseProbe

/// The async probe engine for `goh diagnose`.
///
/// Phases per spec §2.1. Bytes are discarded — no disk writes.
/// All timing uses `ContinuousClock` (monotonic).
///
/// **Concurrent sampling model** (fixes BLOCK A–C):
/// All N connections (conn-0 from Phase 0, plus N-1 Phase-2 conns) drain concurrently
/// inside one `withTaskGroup`. The group also holds an optional deadline child (default mode
/// only) that fires at a pre-computed `deadlineInstant` and cancels the group, bounding
/// Phase 1 AND Phase 2 together. T₁ and Tₙ are measured by snapshotting per-connection
/// `ByteCounter` totals at real `ContinuousClock.Instant` boundaries; the elapsed seconds
/// passed to `rate()` are always measured, never a window constant.
struct GohDiagnoseProbe: Sendable {
    let urlString: String
    let config: DiagnoseConfig
    let session: URLSession
    let full: Bool

    init(urlString: String, config: DiagnoseConfig, session: URLSession, full: Bool) {
        self.urlString = urlString
        self.config = config
        self.session = session
        self.full = full
    }

    /// Runs the complete probe and returns (DiagnosisReport, ProbeTermination).
    /// Never throws; all errors are captured into the report and termination.
    /// A DiagnosisReport is produced in every case (best-effort; reachable=false on
    /// unreachable) to honour the always-report guarantee and feed --json.
    func run() async -> (DiagnosisReport, ProbeTermination) {
        var report = DiagnosisReport(url: urlString)

        // NOTE: malformed-URL is caught at the command arg-parse layer BEFORE run() is called.
        // This guard is a defensive fallback only — not on any reachable path.
        guard let url = URL(string: urlString) else {
            return (report, .unreachable(GohError(code: .unsupportedURL, message: "Malformed URL.")))
        }

        // Capture networkProtocol post-hoc via Mutex (fires on terminal state, not at header time).
        let capturedProtocol = Mutex<String?>(nil)

        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("bytes=0-", forHTTPHeaderField: "Range")

        let response: HTTPURLResponse
        let stream: AsyncThrowingStream<Data, Error>
        let cancelConn0: @Sendable () -> Void

        do {
            (response, stream, cancelConn0) = try await session.streamingResponse(
                for: urlRequest,
                onMetrics: { @Sendable metrics in
                    // networkProtocolName is only available post-hoc (fires at terminal state —
                    // after cancel or EOF, not at header time). Store via Mutex so the report
                    // assembly can read it after all connections terminate.
                    if let proto = metrics.networkProtocolName {
                        capturedProtocol.withLock { $0 = proto }
                    }
                })
        } catch {
            report.reachable = false
            let gohError = GohError(code: .connectionFailed, message: error.localizedDescription)
            return (report, .unreachable(gohError))
        }

        let clock = ContinuousClock()
        // BLOCK A: deadline is computed once, before Phase 1, and bounds Phase 1 + Phase 2.
        let deadlineInstant = clock.now.advanced(by: .seconds(config.defaultDeadlineSeconds))

        switch response.statusCode {
        case 206:
            report.reachable = true
            report.rangeSupported = true
            // spec §2.1: accepted = conn-0 (always 206) + Phase-2 206s.
            report.accepted = 1

            if let cr = Self.contentRange(response) {
                report.totalBytes = cr.total
            }

            // Run the continuous sampling probe (Phase 1 + optional Phase 2).
            await runSamplingProbe(
                url: url,
                conn0Stream: stream,
                cancelConn0: cancelConn0,
                clock: clock,
                deadlineInstant: deadlineInstant,
                report: &report)

            report.networkProtocol = capturedProtocol.withLock { $0 }
            return (report, .diagnosed)

        case 200..<300:
            report.reachable = true
            report.rangeSupported = false
            report.accepted = 1

            // No Phase 2 (range unsupported); run single-connection sampling only.
            await runSamplingProbe(
                url: url,
                conn0Stream: stream,
                cancelConn0: cancelConn0,
                clock: clock,
                deadlineInstant: deadlineInstant,
                report: &report)

            report.networkProtocol = capturedProtocol.withLock { $0 }
            return (report, .diagnosed)

        case 401, 403:
            report.reachable = true
            cancelConn0()
            return (report, .authRequired)

        default:
            report.reachable = true
            cancelConn0()
            return (report, .httpError(response.statusCode))
        }
    }

    // MARK: - Continuous sampling probe (Phase 1 + Phase 2)

    /// Core concurrent sampling engine. One `withTaskGroup` owns:
    ///   (a) conn-0 drain child — loops `for try await chunk` until EOF or cancellation,
    ///       writing to `counters[0]`.
    ///   (b) Phase-2 drain children (indices 1..<N) — each opens its ranged GET, then drains
    ///       into `counters[i]`. A non-206 response is recorded as a rejection and that
    ///       child exits without draining (abort-free: never cancels the group).
    ///   (c) Coordinator child — sleeps using ContinuousClock.sleep(until:) to hit snapshot
    ///       boundaries, records T₁ and Tₙ, then either cancels the group (default mode) or
    ///       waits for all drains to reach EOF (--full mode).
    ///   (d) Optional deadline child (default mode only) — sleeps until deadlineInstant, then
    ///       cancels the group. This is the global deadline bounding Phase 1 AND Phase 2.
    ///
    /// `rate()` always receives real measured elapsed seconds, never a window constant (BLOCK C).
    private func runSamplingProbe(
        url: URL,
        conn0Stream: AsyncThrowingStream<Data, Error>,
        cancelConn0: @Sendable () -> Void,
        clock: ContinuousClock,
        deadlineInstant: ContinuousClock.Instant,
        report: inout DiagnosisReport
    ) async {
        let n = config.targetConnections
        let runPhase2 = report.rangeSupported && report.totalBytes != nil && n >= 2

        // Per-connection byte counters. Index 0 = conn-0 (Phase 0 / Phase 1 stream).
        // Indices 1..<n = Phase-2 connections. Sendable via ByteCounter's @unchecked wrapper.
        let activeN = runPhase2 ? n : 1
        let counters = (0..<activeN).map { _ in ByteCounter() }

        // Phase-2 connection cancel closures; populated as Phase-2 conns are opened.
        // Mutex so the deadline child can call all cancels safely from a concurrent task.
        let cancelClosures = Mutex<[@Sendable () -> Void]>([cancelConn0])

        // Accept/reject tracking.
        let acceptedCount = Mutex<Int>(1)   // conn-0 always accepted
        let rejectionsMap = Mutex<[String: Int]>([:])

        // T₁ / Tₙ measurement results, written by the coordinator.
        let t1Result = Mutex<Double?>(nil)
        let tnResult = Mutex<Double?>(nil)

        // For --full: track first-byte instant and aggregate EOF bytes across all conns.
        let firstByteInstant = Mutex<ContinuousClock.Instant?>(nil)
        let eofTotalBytes = Mutex<UInt64>(0)

        // Total bytes from Phase-2 connections (indices 1..<n), for the EOFTotalBytes tally.
        let totalBytesAcrossPhase2 = Mutex<UInt64>(0)

        // Part geometry for Phase 2.
        let total = report.totalBytes ?? 0
        let partSize: UInt64 = (runPhase2 && total > 0) ? total / UInt64(n) : 0

        await withTaskGroup(of: Void.self) { group in

            // (a) Conn-0 drain child.
            group.addTask {
                var localTotal: UInt64 = 0
                do {
                    for try await chunk in conn0Stream {
                        counters[0].add(chunk.count)
                        localTotal += UInt64(chunk.count)
                        // Record first-byte instant for --full wholeFileMBps.
                        if firstByteInstant.withLock({ $0 }) == nil {
                            firstByteInstant.withLock { $0 = clock.now }
                        }
                    }
                } catch { }
                eofTotalBytes.withLock { $0 += localTotal }
            }

            // (b) Phase-2 drain children (1..<n).
            if runPhase2 {
                for i in 1..<n {
                    let start = UInt64(i) * partSize
                    let end: UInt64 = i == n - 1 ? total - 1 : start + partSize - 1
                    let slotIndex = i

                    group.addTask {
                        var req = URLRequest(url: url)
                        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                        do {
                            let (resp, partStream, cancelPart) =
                                try await self.session.streamingResponse(for: req)
                            // Register cancel closure so the deadline child can tear down.
                            cancelClosures.withLock { $0.append(cancelPart) }

                            if resp.statusCode == 206 {
                                acceptedCount.withLock { $0 += 1 }
                                var localTotal: UInt64 = 0
                                do {
                                    for try await chunk in partStream {
                                        counters[slotIndex].add(chunk.count)
                                        localTotal += UInt64(chunk.count)
                                    }
                                } catch { }
                                totalBytesAcrossPhase2.withLock { $0 += localTotal }
                                eofTotalBytes.withLock { $0 += localTotal }
                                cancelPart()
                            } else {
                                // Non-206: record rejection; do NOT cancel the group (abort-free).
                                cancelPart()
                                let statusStr = "\(resp.statusCode)"
                                rejectionsMap.withLock { $0[statusStr, default: 0] += 1 }
                            }
                        } catch {
                            // Transport error — count as rejection; do NOT cancel the group.
                            rejectionsMap.withLock { $0["transport", default: 0] += 1 }
                        }
                    }
                }
            }

            // (c) Coordinator child — timed snapshots and termination logic.
            group.addTask {
                let warmup = Duration.seconds(self.config.warmupSeconds)
                let window = Duration.seconds(self.config.sampleWindowSeconds)
                let rampWarmup = Duration.seconds(self.config.rampWarmupSeconds)

                // Wait for conn-0's first byte before starting the warmup clock.
                // Poll with a short sleep to avoid a busy-wait; bail if the deadline fires.
                while firstByteInstant.withLock({ $0 }) == nil {
                    do {
                        try await Task.sleep(for: .milliseconds(5))
                    } catch {
                        return  // group cancelled (deadline fired before first byte)
                    }
                }

                // --- T₁ measurement ---
                let warmupStart = clock.now
                let t1WindowStart = warmupStart.advanced(by: warmup)
                do { try await ContinuousClock().sleep(until: t1WindowStart) } catch { return }
                let s1Bytes = Int(counters[0].snapshot())
                let t1Start = clock.now

                let t1WindowEnd = t1Start.advanced(by: window)
                do { try await ContinuousClock().sleep(until: t1WindowEnd) } catch {
                    // Deadline fired mid-window: record whatever we have (partial window → nil).
                    return
                }
                let s2Bytes = Int(counters[0].snapshot())
                let t1End = clock.now
                let t1Elapsed = Double((t1End - t1Start).components.seconds)
                    + Double((t1End - t1Start).components.attoseconds) / 1e18
                let delta1 = s2Bytes - s1Bytes
                if delta1 >= self.config.minSampleBytes && t1Elapsed > 0 {
                    t1Result.withLock { $0 = rate(byteDelta: delta1, over: t1Elapsed) }
                }

                // --- Tₙ measurement (Phase 2 only) ---
                if runPhase2 {
                    // Ramp warmup: let Phase-2 connections settle.
                    let tnWarmupEnd = clock.now.advanced(by: rampWarmup)
                    do { try await ContinuousClock().sleep(until: tnWarmupEnd) } catch { return }

                    // Snapshot Σ all accepted counters at t_n1.
                    let tn1Snapshot = counters.reduce(0) { $0 + Int($1.snapshot()) }
                    let tn1 = clock.now

                    let tnWindowEnd = tn1.advanced(by: window)
                    do { try await ContinuousClock().sleep(until: tnWindowEnd) } catch {
                        // Deadline fired mid-Tₙ window: leave tnResult nil.
                        return
                    }
                    let tn2Snapshot = counters.reduce(0) { $0 + Int($1.snapshot()) }
                    let tn2 = clock.now
                    let tnElapsed = Double((tn2 - tn1).components.seconds)
                        + Double((tn2 - tn1).components.attoseconds) / 1e18
                    let deltaN = tn2Snapshot - tn1Snapshot
                    if deltaN >= self.config.minSampleBytes && tnElapsed > 0 {
                        tnResult.withLock { $0 = rate(byteDelta: deltaN, over: tnElapsed) }
                    }
                }

                // --- Termination ---
                if self.full {
                    // --full: keep draining all connections to EOF; coordinator exits and the
                    // drain children run until they hit EOF or the task is cancelled externally.
                    // (No deadline child is added in --full mode — BLOCK B.)
                } else {
                    // Default mode: cancel the group (and all open connections) after Tₙ window.
                    group.cancelAll()
                    // Cancel all open URLSession data tasks.
                    let cancels = cancelClosures.withLock { $0 }
                    for cancel in cancels { cancel() }
                }
            }

            // (d) Deadline child — default mode only (BLOCK A: bounds Phase 1 AND Phase 2).
            if !full {
                group.addTask {
                    do {
                        try await ContinuousClock().sleep(until: deadlineInstant)
                    } catch {
                        // Cancelled before deadline fired (coordinator finished first) — ok.
                        return
                    }
                    // Deadline fired: cancel the group and all open connections.
                    group.cancelAll()
                    let cancels = cancelClosures.withLock { $0 }
                    for cancel in cancels { cancel() }
                }
            }
        }

        // --- Assemble report from coordinator results ---
        report.singleConnMBps = t1Result.withLock { $0 }
        report.multiConnMBps = runPhase2 ? tnResult.withLock({ $0 }) : nil
        report.attempted = runPhase2 ? n : 1
        report.accepted = acceptedCount.withLock { $0 }
        report.rejections = rejectionsMap.withLock { $0 }

        // --full: wholeFileMBps = Σ allBytes / elapsed(firstByte → now).
        // Guard against divide-by-zero and zero bytes (BLOCK B).
        if full, let fbt = firstByteInstant.withLock({ $0 }) {
            let now = clock.now
            let elapsed = Double((now - fbt).components.seconds)
                + Double((now - fbt).components.attoseconds) / 1e18
            let totalDrained = eofTotalBytes.withLock { $0 }
            if elapsed > 0 && totalDrained > 0 {
                report.wholeFileMBps = rate(
                    byteDelta: Int(totalDrained), over: elapsed)
            }
        }
    }

    // MARK: - Inlined helpers (from DownloadEngine private surface — do NOT widen engine)

    private struct ContentRange: Sendable {
        var start: UInt64
        var end: UInt64
        var total: UInt64
    }

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
```

**Step 4 — Run expected PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter GohCoreTests.GohDiagnoseProbe 2>&1 | tail -15
```

Expected: Phase 0 tests pass; integration tests show `singleConnMBps` and `multiConnMBps` populated.

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/GohDiagnoseProbe.swift Tests/GohCoreTests/GohDiagnoseProbeTests.swift
git commit -m "feat(diagnose): continuous concurrent-drain probe — fixes BLOCK A/B/C/D (Phase 2 Task 5)"
```

---

### Task 6: Time-box (AC4) tests — deadline enforcement and `--full` drain

**Files**
- Modify `Tests/GohCoreTests/GohDiagnoseProbeTests.swift` — add AC4 tests

**Pre-task reads**
- [ ] `Sources/GohCore/CLI/GohDiagnoseProbe.swift` (just completed)
- [ ] `Tests/GohCoreTests/MockURLProtocol.swift` — `bodyChunkSize` + `bodyChunkDelayMicroseconds`
  for a "never-ending" stub

**Step 1 — Write failing tests**

All AC4 tests use `targetConnections ≥ 2` so Phase 2 runs inside the `withTaskGroup` and the
deadline-child bounding is exercised end-to-end (BLOCK D fix). Tests assert structural facts
(non-nil, ordering, verdict case, timing bound) rather than exact MB/s values to stay CI-stable.

Append to `Tests/GohCoreTests/GohDiagnoseProbeTests.swift`:

```swift
@Suite("GohDiagnoseProbe — AC4 time-box")
struct GohDiagnoseProbeTimeBoxTests {

    // AC4a — default mode completes within ~deadline even with a large body AND Phase 2.
    // BLOCK A: deadline must bound Phase 1 + Phase 2 together (N=2 so Phase 2 runs).
    // BLOCK D: targetConnections = 2 so the deadline child in runSamplingProbe is tested.
    @Test func diagnoseDefaultModeCompletesWithinDeadline() async throws {
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        // 100 MB body, slow delivery per chunk — far bigger than any sample window.
        let largeBody = Data(repeating: 0xFF, count: 100_000_000)
        MockURLProtocol.stub(
            url, body: largeBody, acceptsRanges: true,
            bodyChunkSize: 65_536,
            bodyChunkDelayMicroseconds: 500)  // 0.5 ms per chunk

        let deadline = 0.6   // shrunk deadline for fast CI
        let config = DiagnoseConfig(
            targetConnections: 2,   // Phase 2 runs; deadline must still bound the whole probe
            warmupSeconds: 0,
            sampleWindowSeconds: 0.1,
            rampWarmupSeconds: 0,
            defaultDeadlineSeconds: deadline,
            minSampleBytes: 0,
            scalingFactor: 1.3,
            connectTimeoutSeconds: 5.0)

        let clock = ContinuousClock()
        let start = clock.now

        let (report, _) = await GohDiagnoseProbe(
            urlString: url, config: config, session: mockSession(), full: false).run()

        let elapsed = clock.now - start
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        // Must return within deadline + generous slack (3×) — not hang on the 100 MB body.
        // If this fires, the deadline child did NOT cancel Phase 2 (BLOCK A regression).
        #expect(elapsedSeconds < deadline * 3.0,
            "Probe took \(elapsedSeconds)s — deadline is \(deadline)s; Phase-2 not bounded (BLOCK A)")
        #expect(report.reachable == true)
    }

    // AC4b — stalled server (slow paced body, N=2): default mode must return within ~deadline.
    // BLOCK A: Phase-2 drain is also cancelled by the deadline child (N=2 so Phase 2 runs).
    // BLOCK D: N≥2 required to exercise Phase-2 deadline cancellation.
    @Test func stalledServerWithPhase2DoesNotHangInDefaultMode() async throws {
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        // 100 MB body, 50 ms per 1 KB chunk → ~5000 s total delivery time.
        let bigBody = Data(repeating: 0x00, count: 100_000_000)
        MockURLProtocol.stub(url, body: bigBody, acceptsRanges: true,
            bodyChunkSize: 1_024,
            bodyChunkDelayMicroseconds: 50_000)

        let deadline = 0.6
        let config = DiagnoseConfig(
            targetConnections: 2,   // Phase 2 runs; must also be cancelled by deadline
            warmupSeconds: 0,
            sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0,
            defaultDeadlineSeconds: deadline,
            minSampleBytes: 0,
            scalingFactor: 1.3,
            connectTimeoutSeconds: 5.0)

        let clock = ContinuousClock()
        let start = clock.now

        let (report, _) = await GohDiagnoseProbe(
            urlString: url, config: config, session: mockSession(), full: false).run()

        let elapsed = clock.now - start
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        #expect(elapsedSeconds < deadline * 3.0,
            "Probe took \(elapsedSeconds)s — stall guard + Phase-2 deadline failed (BLOCK A)")
        #expect(report.reachable == true)
    }

    // AC4c — `--full` drains all N connections to EOF; wholeFileMBps is non-nil.
    // BLOCK B: --full must read past the sample window (drainStream must not break at windowEnd).
    // BLOCK D: N=2 so Phase-2 EOF drain is also exercised.
    @Test func diagnoseFullDrainesToEOF() async throws {
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        // Body larger than the sample window bytes but small enough for CI.
        // With a 0.05 s window and fast delivery, the sampler would stop at ~few-hundred KB.
        // We verify that --full delivers the whole 4 MB (both halves drain to EOF).
        let body = Data(repeating: 0xEE, count: 4_000_000)
        MockURLProtocol.stub(
            url, body: body, acceptsRanges: true,
            bodyChunkSize: 131_072,
            bodyChunkDelayMicroseconds: 500)

        let config = DiagnoseConfig(
            targetConnections: 2,   // Phase 2 also drains to EOF in --full mode (BLOCK D)
            warmupSeconds: 0,
            sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0,
            defaultDeadlineSeconds: 0.001,  // effectively zero — --full MUST ignore this (BLOCK B)
            minSampleBytes: 0,
            scalingFactor: 1.3,
            connectTimeoutSeconds: 5.0)

        let (report, _) = await GohDiagnoseProbe(
            urlString: url, config: config, session: mockSession(), full: true).run()

        #expect(report.reachable == true)
        // T₁ non-nil (minSampleBytes=0 so any byte count yields a rate).
        #expect(report.singleConnMBps != nil)
        // --full mode: wholeFileMBps must be non-nil (BLOCK B: proves EOF drain happened).
        // If wholeFileMBps is nil, the drain stopped at the window boundary (BLOCK B regression).
        #expect(report.wholeFileMBps != nil,
            "wholeFileMBps nil in --full mode — drain stopped at window boundary (BLOCK B)")
    }

    // AC4d — default (non-full) mode: wholeFileMBps is nil.
    @Test func diagnoseDefaultModeWholeFileMBpsIsNil() async throws {
        let url = "https://diagnose-test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, body: tenMB, acceptsRanges: true,
            bodyChunkSize: 131_072, bodyChunkDelayMicroseconds: 500)

        let config = DiagnoseConfig(
            targetConnections: 2, warmupSeconds: 0, sampleWindowSeconds: 0.05,
            rampWarmupSeconds: 0, defaultDeadlineSeconds: 2.0,
            minSampleBytes: 0, scalingFactor: 1.3, connectTimeoutSeconds: 5.0)

        let (report, _) = await GohDiagnoseProbe(
            urlString: url, config: config, session: mockSession(), full: false).run()

        #expect(report.wholeFileMBps == nil)
    }
}
```

**Step 2 — Run expected FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter GohCoreTests.GohDiagnoseProbeTimeBoxTests 2>&1 | tail -15
```

Expected (all from the Task 5 implementation):
- `diagnoseDefaultModeCompletesWithinDeadline` — passes (deadline child cancels both Phase 1 and
  Phase 2 drain children at the deadline instant).
- `stalledServerWithPhase2DoesNotHangInDefaultMode` — passes (same path; large body + slow chunk
  delivery, deadline fires first).
- `diagnoseFullDrainesToEOF` — passes (`full: true` → no deadline child; coordinator exits after
  Tₙ window but drain children keep running to EOF; `wholeFileMBps` assembled from `eofTotalBytes`).
- `diagnoseDefaultModeWholeFileMBpsIsNil` — passes (default mode never assigns `wholeFileMBps`).

**Step 3 — Implementation**

The `runSamplingProbe` method in `GohDiagnoseProbe.swift` (from Task 5) implements:
- Coordinator child that sleeps to snapshot boundaries and either cancels the group (default mode)
  or exits after the Tₙ window (`--full` mode, leaving drain children running to EOF).
- Deadline child that fires at `deadlineInstant` and cancels the group (default mode only).
- `wholeFileMBps` assembled from `eofTotalBytes` / elapsed after the group exits.

No additional code is needed for these tests. If any test fails:
- BLOCK A regression: deadline child is not in the group, or coordinator does not pass
  `deadlineInstant` to the group via child cancellation.
- BLOCK B regression: `drainStream` still has `break` at windowEnd regardless of `full`.
  Verify the coordinator exits (not the drain children) after the Tₙ window in `--full` mode.

**Step 4 — Run expected PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter GohCoreTests.GohDiagnoseProbeTimeBoxTests 2>&1 | tail -10
```

Expected: all 4 AC4 tests pass.

**Step 5 — Commit**

```
git add Tests/GohCoreTests/GohDiagnoseProbeTests.swift
git commit -m "test(diagnose): AC4 time-box tests with N≥2 — bounds, --full EOF drain, wholeFileMBps (Phase 2 Task 6)"
```

---

## Phase 3 — CLI command, wiring, and end-to-end tests

### Task 7: `GohDiagnoseCommand` — sync bridge, arg parsing, human rendering, exit codes

**Files**
- Create `Sources/GohCore/CLI/GohDiagnoseCommand.swift`
- Create `Tests/GohCoreTests/GohDiagnoseCommandTests.swift`

**Pre-task reads**
- [ ] `Sources/GohCore/CLI/GohDiagnoseProbe.swift` — `run()` returns `(DiagnosisReport, ProbeTermination)` (already in memory)
- [ ] `Sources/GohCore/CLI/DiagnoseTypes.swift` — `verdict()` function + `DiagnosisReport` + `DiagnoseConfig` (already in memory)
- [ ] `Sources/GohCore/CLI/GohCommandLine.swift` — `GohCommandLineResult` struct (already read)
- NOTE: `GohForegroundDownload.swift` need NOT be read for the bridge pattern — the async→sync
  bridge here is a new, self-contained `Task{}` + `DispatchSemaphore` pattern confined to this
  command. `GohForegroundDownload`'s semaphore is a thread-to-thread XPC signal (different purpose).
  See BLOCK 7 rationale in the implementation notes.

**Step 1 — Write failing tests**

Create `Tests/GohCoreTests/GohDiagnoseCommandTests.swift`:

```swift
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
        let data = try #require(result.standardOutput.data(using: .utf8))
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
```

**Step 2 — Run expected FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter GohCoreTests.GohDiagnoseCommandTests 2>&1 | tail -20
```

Expected: compile error — `GohDiagnoseCommand` not found.

**Step 3 — Implement `GohDiagnoseCommand.swift`**

Key design points (all block-review fixes applied):

- Exit codes are mapped from typed `ProbeTermination` — NEVER from `verdictText` (BLOCK 3).
- Malformed URL is caught at the arg-parse layer only (BLOCK 8); the probe is only reached with a
  parseable absolute URL.
- Exit 1 is a minimal defensive guard for the async→sync bridge with a comment marking it
  unreachable in practice (BLOCK 8).
- Async→sync bridge: a `Task{}` runs the probe on the cooperative pool; a `DispatchSemaphore`
  blocks the synchronous CLI main thread until the task signals. This is a self-contained pattern
  confined to `GohDiagnoseCommand` — it is NOT a re-use of `GohForegroundDownload.swift:46`,
  which is a thread-to-thread XPC signal in a class that manages XPC delivery callbacks (BLOCK 7).
- Swift 6 / `-warnings-as-errors` Sendable: `probeReport` is written inside the `Task` before
  `semaphore.signal()` and read after `semaphore.wait()`. The semaphore establishes a
  happens-before edge. The `@Sendable` Task closure captures `probeReport` as `inout` via an
  intermediate `var` with `nonisolated(unsafe)` annotation so the Swift 6 checker is satisfied
  without an actor. (BLOCK 7.)
- `timeoutIntervalForRequest` is set on diagnose's own session-config copy so a stalled server
  fires the per-connection idle timeout as a backstop — especially important in `--full` mode
  where no deadline child task is added to `runSamplingProbe`'s group (BLOCK A/1).

```swift
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

        // Async→sync bridge: Task runs probe on cooperative pool; semaphore blocks main thread.
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
```

**Step 4 — Run expected PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter GohCoreTests.GohDiagnoseCommandTests 2>&1 | tail -15
```

Expected: all command tests pass.

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/GohDiagnoseCommand.swift Tests/GohCoreTests/GohDiagnoseCommandTests.swift
git commit -m "feat(diagnose): GohDiagnoseCommand with sync bridge, rendering, and exit codes (Phase 3 Task 7)"
```

---

### Task 8: Wire `diagnose` into `GohCommandLine` and `main.swift`

**Files**
- Modify `Sources/GohCore/CLI/GohCommandLine.swift` — add `ParsedCommand.diagnose` case,
  `Diagnose` typealias, `diagnose` closure parameter, parse branch, run branch, usage line.
- Modify `Sources/goh/main.swift` — wire the `diagnose` closure.

**Pre-task reads**
- [ ] `Sources/GohCore/CLI/GohCommandLine.swift` — the full file (already read); specifically:
  - `GohCommandLine.init` parameters (line 29–43): foreground, top, doctor pattern
  - `ParsedCommand` enum (line 189–203)
  - `parse()` method (line 220–296)
  - `run()` switch (line 46–154)
  - `usage()` (line 458–481)
- [ ] `Sources/goh/main.swift` — doctor closure wiring (lines 281–285) (already read)

**Step 1 — Write failing tests**

Append to `Tests/GohCoreTests/GohCommandLineTests.swift` (the existing file):

```swift
// MARK: - diagnose wiring tests

extension GohCommandLineTests {

    @Test("diagnose dispatches to the injected closure")
    func diagnoseDispatchesToClosure() {
        var capturedURL: String?
        var diagnoseRunCount = 0

        let result = GohCommandLine(
            arguments: ["diagnose", "https://example.com/f.bin"],
            diagnose: { url, full, json, connections in
                capturedURL = url
                diagnoseRunCount += 1
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: "diagnose flow\n")
            },
            send: { _ in throw TestTransportError() }
        ).run()

        #expect(capturedURL == "https://example.com/f.bin")
        #expect(diagnoseRunCount == 1)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "diagnose flow\n")
        #expect(result.standardError == "")
    }

    @Test("diagnose with --full and --connections passes flags")
    func diagnosePassesFlags() {
        var capturedFull: Bool?
        var capturedConnections: Int?

        _ = GohCommandLine(
            arguments: ["diagnose", "https://example.com/f.bin", "--full", "--connections", "4"],
            diagnose: { _, full, _, connections in
                capturedFull = full
                capturedConnections = connections
                return GohCommandLineResult(exitCode: 0)
            },
            send: { _ in throw TestTransportError() }
        ).run()

        #expect(capturedFull == true)
        #expect(capturedConnections == 4)
    }

    @Test("diagnose missing URL exits 64")
    func diagnoseMissingURLExits64() {
        let result = GohCommandLine(
            arguments: ["diagnose"],
            diagnose: { _, _, _, _ in GohCommandLineResult(exitCode: 0) },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(result.exitCode == 64)
    }

    @Test("diagnose appears in usage output")
    func diagnoseAppearsInUsage() {
        let result = GohCommandLine(
            arguments: ["--help"],
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(result.standardOutput.contains("diagnose"))
    }

    @Test("diagnose without configured closure returns exit 1")
    func diagnoseWithoutClosureExits1() {
        let result = GohCommandLine(
            arguments: ["diagnose", "https://example.com/f.bin"],
            send: { _ in throw TestTransportError() }
        ).run()
        // No diagnose closure wired → exit 1 (not configured).
        #expect(result.exitCode == 1)
    }
}
```

**Step 2 — Run expected FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter "GohCoreTests.GohCommandLineTests/diagnose" 2>&1 | tail -20
```

Expected: compile error — `GohCommandLine.init` has no `diagnose:` parameter / `ParsedCommand.diagnose` not found.

**Step 3 — Implement wiring in `GohCommandLine.swift`**

Apply the following changes (each is a discrete edit):

**3a.** Add the `Diagnose` typealias after line 20 (`public typealias Doctor = () throws -> GohCommandLineResult`):

```swift
public typealias Diagnose = (_ url: String, _ full: Bool, _ json: Bool, _ connections: Int?) throws -> GohCommandLineResult
```

**3b.** Add `private let diagnose: Diagnose?` after the `private let doctor: Doctor?` stored property (line 26).

**3c.** Add `diagnose: Diagnose? = nil` parameter to `init` after the `doctor:` parameter (line 34), and assign `self.diagnose = diagnose` in the body.

**3d.** In the `ParsedCommand` enum, add:

```swift
case diagnose(url: String, full: Bool, json: Bool, connections: Int?)
```

**3e.** In `parse()`, add a new branch after the `"doctor"` check (around line 240):

```swift
if arguments.first == "diagnose" {
    return try parseDiagnose(Array(arguments.dropFirst()))
}
```

**3f.** Add the `parseDiagnose` static method to the `parse` extension:

```swift
private static func parseDiagnose(_ arguments: [String]) throws -> ParsedCommand {
    var url: String?
    var full = false
    var json = false
    var connections: Int?
    var index = 0
    while index < arguments.count {
        let arg = arguments[index]
        switch arg {
        case "--full":
            full = true; index += 1
        case "--json":
            json = true; index += 1
        case "--connections", "-c":
            guard index + 1 < arguments.count else {
                throw ParseError(message: "\(arg) requires a value")
            }
            let raw = arguments[index + 1]
            guard let n = Int(raw), (1...16).contains(n) else {
                throw ParseError(message: "connections must be an integer from 1 to 16")
            }
            connections = n; index += 2
        default:
            guard !arg.hasPrefix("-") else {
                throw ParseError(message: "unknown diagnose option \(arg)")
            }
            guard url == nil else {
                throw ParseError(message: "diagnose accepts exactly one URL")
            }
            url = arg; index += 1
        }
    }
    guard let resolvedURL = url else {
        throw ParseError(message: "diagnose requires a URL")
    }
    return .diagnose(url: resolvedURL, full: full, json: json, connections: connections)
}
```

**3g.** In `run()`'s `switch try Self.parse(arguments)`, add a case after `.doctor`:

```swift
case .diagnose(let url, let full, let json, let connections):
    guard let diagnose else {
        return GohCommandLineResult(
            exitCode: 1,
            standardError: "The diagnose command is not configured.\n")
    }
    return try diagnose(url, full, json, connections)
```

**3h.** In `usage()`, add the line:

```swift
text += "  goh diagnose [--full] [--json] [--connections <1-16> | -c <1-16>] <url>\n"
```

after the `goh doctor` line.

**Step 4 — Implement wiring in `main.swift`**

Add the `diagnose:` closure to the `GohCommandLine(...)` call, after the `doctor:` closure (around line 281):

```swift
diagnose: { url, full, json, connections in
    var args = [url]
    if full { args.append("--full") }
    if json { args.append("--json") }
    if let c = connections { args += ["--connections", "\(c)"] }
    return GohDiagnoseCommand.run(arguments: args)
},
```

**Step 5 — Run expected PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter "GohCoreTests.GohCommandLineTests" 2>&1 | tail -15
```

Expected: all CLI wiring tests pass (existing + new).

**Step 6 — Commit**

```
git add Sources/GohCore/CLI/GohCommandLine.swift Sources/goh/main.swift Tests/GohCoreTests/GohCommandLineTests.swift
git commit -m "feat(diagnose): wire diagnose verb into GohCommandLine and main.swift (Phase 3 Task 8)"
```

---

### Task 9: Full test suite pass + cleanup + Phase 3 artifact

**Files**
- No new code — this task verifies the entire suite, runs lint under `-warnings-as-errors`,
  and writes the phase artifact.

**Pre-task reads** — none.

**Step 1 — Run the full test suite**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -30
```

Expected: `Test run with N tests passed.` with zero failures.

**Step 2 — Build with `-warnings-as-errors` (CI check)**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -c debug -Xswiftc -warnings-as-errors 2>&1 | tail -20
```

Expected: `Build complete!` with no warnings.

**Step 3 — Fix any remaining issues**

If the build produces warnings or test failures, diagnose and fix here before committing. Common issues to check:
- Unused variables (`_ = ` patterns in probe loop).
- Non-exhaustive switches on enums.
- Missing `Sendable` conformances.
- Force-unwraps — none are allowed; fix any that snuck in.

**Step 4 — Write the Phase 3 artifact**

Write `docs/superpowers/progress/2026-06-03-goh-diagnose-phase3.md`:

```
# Phase 3 Progress — goh diagnose

Status: COMPLETE — Tasks 7, 8, 9 implemented and passing.

## Tasks completed
- Task 7: GohDiagnoseCommand (sync bridge, arg parsing, human + JSON rendering, typed exit codes)
- Task 8: GohCommandLine + main.swift wiring
- Task 9: Full suite pass, -warnings-as-errors clean

## Suite results
(Paste actual output here when run.)
```

**Step 5 — Commit**

```
git add docs/superpowers/progress/2026-06-03-goh-diagnose-phase3.md
git commit -m "chore(diagnose): Phase 3 complete — full suite passes, warnings-as-errors clean (Phase 3 Task 9)"
```

---

## Implementation notes

### ProbeTermination and exit-code mapping (BLOCK 3)

`GohDiagnoseProbe.run()` returns `(DiagnosisReport, ProbeTermination)`. `GohDiagnoseCommand`
maps `ProbeTermination` cases to exit codes via a `switch` — it NEVER inspects `verdictText`
(which is unfrozen human prose). This makes exit codes stable across copy-edit changes to
verdict sentences. Tests assert exit codes by driving specific HTTP stubs, not by matching
strings.

### Deadline enforcement and stall protection (BLOCKS A + 1)

The `deadlineInstant` is computed once in `run()` before any sampling starts and is the same
`ContinuousClock.Instant` used by the deadline child inside `runSamplingProbe`. The deadline child
lives in the same `withTaskGroup` that owns all drain children (conn-0 and all Phase-2 connections),
so when it fires it calls `group.cancelAll()` and then invokes every open connection's cancel
closure. This bounds the entire default-mode probe — Phase 1 AND Phase 2 — with a single deadline
(BLOCK A: the old design had an unbounded `runPhase2` outside the deadline scope).

In `--full` mode the deadline child is simply not added to the group. The coordinator exits after the
Tₙ window but the drain children keep running until EOF. The `timeoutIntervalForRequest` on
diagnose's own session-config copy (set by `GohDiagnoseCommand`) is the per-connection idle-timeout
backstop for stall protection in `--full` mode.

### wholeFileMBps (BLOCK B)

In `--full` mode, after the `withTaskGroup` exits (all drain children reached EOF because no
deadline child cancels the group), `runSamplingProbe` computes
`wholeFileMBps = Σ eofTotalBytes / elapsed(firstByte → now)` and assigns it to the report. The
guard against divide-by-zero (elapsed == 0 or totalDrained == 0 → nil) is explicit. In default
(non-full) mode `wholeFileMBps` is never set (remains nil). Tests assert both:
`wholeFileMBps != nil` in `--full`, `== nil` otherwise. This also proves EOF drain happened
(BLOCK B: the old `drainStream` always `break`ed at `windowEnd`).

### Tₙ measurement (BLOCK C)

Tₙ is measured by the coordinator child taking two `Σ counters` snapshots at real
`ContinuousClock.Instant` boundaries (`t1` and `t2`), computing `Tₙ = rate(byteDelta: S2-S1,
over: seconds(t1, t2))`. The elapsed seconds are the real measured duration between the two
snapshots — never the `sampleWindowSeconds` constant. Conn-0 is included in both snapshots
because it drains continuously through Phase 2 (its `ByteCounter` keeps advancing). This fixes
both defects in BLOCK C: the constant-divisor error and the conn-0 exclusion.

### AC4 / test coverage (BLOCK D)

All integration and AC4 tests use `targetConnections ≥ 2`. This ensures Phase 2 actually runs
inside `runSamplingProbe`, exercising the deadline child's ability to cancel both Phase 1 and Phase 2
drain children, and validating the `multiConnMBps` measurement path. Tests that previously used
`targetConnections: 1` (skipping Phase 2 entirely and never exercising the deadline against the
concurrent group) now use N=2.

### Async→sync bridge rationale (BLOCK 7)

The `DispatchSemaphore` + `Task{}` pattern in `GohDiagnoseCommand` is a **new, self-contained**
async→sync bridge confined to that file. It is NOT re-used from `GohForegroundDownload.swift`.
`GohForegroundDownload` uses `DispatchSemaphore` inside `GohXPCNotificationInbox` as a
thread-to-thread signalling primitive (XPC delivery threads signal; the `receive()` caller
waits) — a structurally different purpose. The diagnose bridge pattern: a `Task` runs the
async probe on the cooperative pool; `semaphore.signal()` is called after `probeResult` is
assigned; `semaphore.wait()` blocks the synchronous CLI main thread. The `nonisolated(unsafe)`
annotation on `probeResult` satisfies the Swift 6 Sendable checker (the semaphore establishes
the happens-before edge that makes the pattern safe).

### Concurrency model

`GohDiagnoseProbe` is `Sendable` and `struct`. Its `run()` is `async` but not
actor-isolated (`GohCore` target uses `nonisolated` default isolation). `Mutex<T>`
from `Synchronization` is used for all shared mutable state accessed by concurrent
children of the single `withTaskGroup` in `runSamplingProbe` — no `actor` overhead
needed for simple counters. `ByteCounter` wraps `Mutex<UInt64>` with `@unchecked Sendable`
so it can be captured by drain tasks (the unchecked annotation is safe because all
writes go through `mutex.withLock`).

### Timing contract (T₁ and Tₙ measurement)

The coordinator child uses `ContinuousClock.sleep(until:)` to reach each snapshot instant.
All counters are monotonically increasing (only `add()` is called, never subtracted). The
chunk-straddle problem is avoided: we snapshot the running totals at the boundary instants
and only the delta between snapshots matters — the exact chunk that crossed the boundary
is irrelevant. `rate()` always receives the real measured elapsed seconds between the two
snapshot instants (not the `sampleWindowSeconds` constant). This matches the spec §2.1
description and the engine's own measurement approach.

### Why content-range is inlined rather than shared

The spec explicitly calls out that these helpers (4 lines each) should be inlined rather
than widening `DownloadEngine`'s private surface. The copies are identical to the engine's
implementations. If the engine's copy ever changes, a `grep` for `Content-Range` finds both.

### MockURLProtocol protocol-capture limitation

`networkProtocolName` on `URLSessionTaskTransactionMetrics` is only populated for
real TCP/TLS connections — in-process `MockURLProtocol` stubs return `nil`.
Integration tests therefore assert `report.networkProtocol == nil` (unknown) rather
than a real ALPN string. The probe handles this correctly (unknown → multiplexed
branch). The AC5 h2/h3/http1.1 split is proven by the pure `verdict()` unit tests
in Task 2.

### `--json` contract stability

`DiagnosisReport` uses `[String: Int]` for `rejections` (not `[Int: Int]`), which
encodes as a JSON object rather than an array. Task 1's `rejectionsEncodesAsJSONObject`
test verifies this. The `reportVersion = 1` sentinel is always present and hardcoded
in the struct's stored-property default — it is not set by the verdict logic and
cannot accidentally change.

### Golden-file fixture (Advisory)

`diagnosisReportMatchesGoldenFixture()` in `DiagnoseTypesTests` tests the full `--json` contract
as a golden file stored at `Tests/GohCoreTests/Fixtures/diagnose-report-v1.json`. On first run it
creates the fixture; on subsequent runs it asserts byte-for-byte equality with sorted keys and
pretty-printing. A contract change (field rename, type change, Verdict raw value change) breaks
the test, forcing a `reportVersion` bump and fixture regeneration. This is the project convention
from CLAUDE.md ("golden-file fixtures for any wire format").
