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

    /// Mutable box for collecting baselines from the @Sendable onVerified closure.
    /// A @Sendable closure cannot capture a mutable var by reference under -warnings-as-errors;
    /// the box is a reference captured by value (the class IS the reference).
    private final class BaselineCollector: @unchecked Sendable {
        var baselines: [VerifiedBaseline] = []
    }

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
    ///   - send: Optional XPC sender for best-effort baseline backfill. Nil when called from
    ///     `goh attest` (keeps attest read-only, AC5). When non-nil, `.ok` baselines are
    ///     sent via `GohCommandClient` after the run — best-effort: a send failure never
    ///     changes the exit code or report (AC7).
    public static func run(
        provenanceStorePath: String,
        json: Bool = false,
        generatedAt: Date = Date(),
        send: GohCommandLine.Sender? = nil
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
        // AC5: collector is nil when send is nil → no baseline collection overhead.
        let collector: BaselineCollector? = send != nil ? BaselineCollector() : nil
        let onVerified: (@Sendable (VerifiedBaseline) -> Void)?
        if let box = collector {
            onVerified = { baseline in box.baselines.append(baseline) }
        } else {
            onVerified = nil
        }
        let report: VerifyAllReport
        do {
            report = try VerifyAllRunner.verifyAll(
                provenanceStorePath: provenanceStorePath,
                generatedAt: generatedAt,
                progress: nil,
                isCancelled: nil,
                onVerified: onVerified)
        } catch {
            if json { return jsonErrorResult(.ledgerUnreadable) }
            return GohCommandLineResult(exitCode: 6, standardOutput: "provenance ledger unreadable\n")
        }

        // ── Step 2.5: Best-effort backfill send ──────────────────────────────────────
        // AC7: send failure never changes exit code or report. AC5: send is nil for attest.
        // Uses GohCommandClient (mirrors GohSyncCommand's pattern).
        if let send, let baselines = collector?.baselines, !baselines.isEmpty {
            let entries = baselines.map { b in
                VerifiedProvenanceEntry(
                    url: b.url,
                    sha256: b.sha256,
                    size: b.hashedByteCount,               // display/download byte count
                    destinationPath: b.destinationPath,
                    verifiedAt: generatedAt,
                    recordedStatSize: b.stat.size,          // B1: ALWAYS stat.size (non-optional on VerifiedBaseline)
                    recordedMtimeSeconds: b.stat.mtimeSeconds,
                    recordedMtimeNanoseconds: b.stat.mtimeNanoseconds,
                    recordedInode: b.stat.inode,
                    recordedDevice: b.stat.device)
            }
            do {
                let client = GohCommandClient(send: send)
                _ = try client.send(
                    .recordVerifiedProvenance(
                        request: RecordVerifiedProvenanceRequest(entries: entries)),
                    expecting: AckReply.self)
            } catch {
                // AC7: best-effort. Log warning to stderr; never change exit code.
                fputs("goh verify --all: provenance backfill failed (daemon may be stopped): \(error)\n",
                      stderr)
            }
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
