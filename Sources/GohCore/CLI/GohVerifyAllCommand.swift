import Foundation

/// CLI-local integrity verifier for `goh verify --all`.
///
/// Re-hashes each entry in the provenance ledger against the file on disk and
/// reports OK / FAILED / MISSING. No daemon or XPC connection required — works
/// with the daemon stopped.
///
/// This is a SEPARATE runner from `GohVerifyCommand` (which is frozen). The
/// frozen `verify` surface is untouched; `--all` parses to a distinct case and
/// dispatches here.
///
/// Exit code contract (mirrors `GohVerifyCommand`'s vocabulary for the codes that
/// apply to the global ledger):
///   0  — all entries OK (or zero / absent entries)
///   2  — at least one hash MISMATCH (FAILED)
///   6  — ledger unreadable / unknown version (corrupt) — CLI does NOT copy a
///         sidecar and does NOT reset the store (only the daemon's load() does)
///   9  — at least one recorded file MISSING on disk
///
/// Precedence: 9 > 2 > 0.
public enum GohVerifyAllCommand {

    /// Runs `goh verify --all` and returns a result suitable for the CLI runner.
    ///
    /// - Parameters:
    ///   - provenanceStorePath: Absolute path to `provenance.plist`.
    ///     Resolved by the caller from `ProvenanceStoreLocation.defaultURL(create: false)`.
    ///   - json: When `true`, render output as JSON (`VerifyAllReport` or `VerifyErrorReport`).
    ///     Defaults to `false` so existing callers and tests compile unchanged.
    ///   - generatedAt: The timestamp to embed in the JSON `generatedAt` field.
    ///     Defaults to `Date()` (current time) in production; inject a fixed instant in tests
    ///     and for the golden-fixture encode-equals test. Ignored when `json` is false.
    public static func run(
        provenanceStorePath: String,
        json: Bool = false,
        generatedAt: Date = Date()
    ) -> GohCommandLineResult {

        // ── Step 1: Classify ledger ────────────────────────────────────────────
        let outcome = ProvenanceLedgerReader.read(at: provenanceStorePath)

        switch outcome {
        case .absent, .entries([]):
            // Absent file OR empty entries array → exit 0, 0 recorded entries
            if json {
                return jsonResult(exitCode: 0, report: emptyReport(generatedAt: generatedAt))
            }
            return GohCommandLineResult(exitCode: 0, standardOutput: "0 recorded entries\n")

        case .unreadable(.io):
            if json { return jsonErrorResult(.ledgerUnreadable) }
            return GohCommandLineResult(exitCode: 6, standardOutput: "provenance ledger unreadable\n")

        case .unreadable(.corrupt):
            if json { return jsonErrorResult(.ledgerCorrupt) }
            return GohCommandLineResult(exitCode: 6, standardOutput: "provenance ledger corrupt\n")

        case .unreadable(.versionUnknown(let found)):
            if json { return jsonErrorResult(.ledgerVersionUnknown) }
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "provenance ledger version \(found) is unknown\n")

        case .entries:
            break  // fall through to re-hash
        }

        // ── Step 2: Re-hash via runner ────────────────────────────────────────
        // VerifyAllRunner.verifyAll throws only on .unreadable — already handled above.
        // The catch here is a defensive guard (should never trigger given the switch above).
        let report: VerifyAllReport
        do {
            report = try VerifyAllRunner.verifyAll(
                provenanceStorePath: provenanceStorePath,
                generatedAt: generatedAt,
                progress: nil,
                isCancelled: nil)
        } catch {
            if json { return jsonErrorResult(.ledgerUnreadable) }
            return GohCommandLineResult(exitCode: 6, standardOutput: "provenance ledger unreadable\n")
        }

        // ── Step 3: Derive exit code ──────────────────────────────────────────
        let exitCode: Int32
        if report.summary.missing > 0 {
            exitCode = 9
        } else if report.summary.failed > 0 {
            exitCode = 2
        } else {
            exitCode = 0
        }

        // ── Step 4: Render ────────────────────────────────────────────────────
        if json {
            return jsonResult(exitCode: exitCode, report: report)
        }

        // Human: reconstruct lines[] from report.entries[] in order.
        let lines = report.entries.map { entry -> String in
            switch entry.status {
            case .ok:
                return "OK \(entry.path)\n"
            case .failed:
                let actual = entry.actualSha256 ?? ""
                return "FAILED \(entry.path) expected \(entry.expectedSha256) actual \(actual)\n"
            case .missing:
                return "MISSING \(entry.path) (expected \(entry.expectedSha256))\n"
            }
        }
        return GohCommandLineResult(exitCode: exitCode, standardOutput: lines.joined())
    }

    // MARK: - Private helpers

    /// Returns the canonical payload bytes for a `VerifyAllReport` — the encoder output
    /// with NO trailing newline.
    ///
    /// **Crypto-critical (B1):** this is `payload_bytes` for `goh attest`'s signing input.
    /// It is byte-identical to the golden `verify-all-report-v1.json` fixture.
    /// The `--json` stdout path appends `"\n"` AFTER this; never sign the stdout bytes.
    ///
    /// Throws if `CommandCoding.encoder.encode` fails (a programming error — encoding a
    /// value type should never fail in practice, but the error is propagated fail-closed
    /// rather than silently producing nil / empty bytes).
    public static func payloadBytes(for report: VerifyAllReport) throws -> Data {
        try CommandCoding.encoder.encode(report)
    }

    // MARK: - Private helpers

    private static func emptyReport(generatedAt: Date) -> VerifyAllReport {
        VerifyAllReport(
            reportVersion: 1,
            generatedAt: generatedAt,
            summary: VerifySummary(total: 0, ok: 0, failed: 0, missing: 0),
            entries: [])
    }

    private static func jsonResult(exitCode: Int32, report: VerifyAllReport) -> GohCommandLineResult {
        let data: Data
        do {
            data = try payloadBytes(for: report)
        } catch {
            // Fail-closed: encoding failure → exit 6 (ledger error class) with no JSON output.
            // Never emit blank stdout + success exit on an encode failure.
            return GohCommandLineResult(
                exitCode: 6,
                standardError: "verify --all: failed to encode JSON report\n")
        }
        return GohCommandLineResult(
            exitCode: exitCode,
            standardOutput: String(decoding: data, as: UTF8.self) + "\n")
    }

    private static func jsonErrorResult(_ code: VerifyErrorCode) -> GohCommandLineResult {
        let envelope = VerifyErrorReport(reportVersion: 1, error: code)
        guard let data = try? CommandCoding.encoder.encode(envelope) else {
            return GohCommandLineResult(exitCode: 6, standardOutput: "")
        }
        return GohCommandLineResult(
            exitCode: 6,
            standardOutput: String(decoding: data, as: UTF8.self) + "\n")
    }
}
