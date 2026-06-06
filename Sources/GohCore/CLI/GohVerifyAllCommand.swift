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
        let storeURL = URL(fileURLWithPath: provenanceStorePath)

        // ── Step 1: Read the ledger (read-only; never creates a sidecar or resets) ──
        guard FileManager.default.fileExists(atPath: provenanceStorePath) else {
            if json {
                return jsonResult(
                    exitCode: 0,
                    report: emptyReport(generatedAt: generatedAt))
            }
            return GohCommandLineResult(
                exitCode: 0,
                standardOutput: "0 recorded entries\n")
        }

        guard let data = try? Data(contentsOf: storeURL) else {
            if json {
                return jsonErrorResult(.ledgerUnreadable)
            }
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "provenance ledger unreadable\n")
        }

        let record: ProvenanceRecord
        do {
            record = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
        } catch {
            // CLI does NOT copy-to-sidecar or reset — the daemon owns recovery.
            if json {
                return jsonErrorResult(.ledgerCorrupt)
            }
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "provenance ledger corrupt\n")
        }

        guard record.version == ProvenanceRecord.currentVersion else {
            if json {
                return jsonErrorResult(.ledgerVersionUnknown)
            }
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "provenance ledger version \(record.version) is unknown\n")
        }

        // A4 — corruption boundary is "decodable + version-matched". A plist that decodes
        // cleanly with version == currentVersion is treated as VALID even if individual
        // entries are semantically odd (e.g. a malformed sha256 string or a nonsense path).
        // Such entries enter the re-hash loop below and report FAILED/MISSING — NOT exit 6.
        // Exit 6 is reserved for an unreadable/undecodable/unknown-version file. This is the
        // accepted boundary for verify-only: structural decodability gates corruption.

        // ── Step 2: Empty store ────────────────────────────────────────────────
        if record.entries.isEmpty {
            if json {
                return jsonResult(
                    exitCode: 0,
                    report: emptyReport(generatedAt: generatedAt))
            }
            return GohCommandLineResult(
                exitCode: 0,
                standardOutput: "0 recorded entries\n")
        }

        // ── Step 3: Re-hash each entry — compute ONCE into [VerifyEntryResult] ─
        //
        // Bet: deriving both renderings from one result model keeps the JSON and
        // human verdicts + exit codes consistent at zero ongoing cost; the existing
        // byte-exact regression tests prove the human output stayed identical after
        // the refactor.
        var entries: [VerifyEntryResult] = []
        var lines: [String] = []
        var hasMissing = false
        var hasFailed = false

        for entry in record.entries {
            let hash: String
            do {
                (hash, _) = try FileDigest.sha256WithSize(path: entry.destinationPath)
            } catch FileDigest.DigestError.cannotOpen {
                entries.append(VerifyEntryResult(
                    path: entry.destinationPath,
                    url: entry.url,
                    status: .missing,
                    expectedSha256: entry.sha256,
                    actualSha256: nil))
                lines.append("MISSING \(entry.destinationPath) (expected \(entry.sha256))\n")
                hasMissing = true
                continue
            } catch {
                entries.append(VerifyEntryResult(
                    path: entry.destinationPath,
                    url: entry.url,
                    status: .missing,
                    expectedSha256: entry.sha256,
                    actualSha256: nil))
                lines.append("MISSING \(entry.destinationPath) (expected \(entry.sha256))\n")
                hasMissing = true
                continue
            }

            if hash == entry.sha256 {
                entries.append(VerifyEntryResult(
                    path: entry.destinationPath,
                    url: entry.url,
                    status: .ok,
                    expectedSha256: entry.sha256,
                    actualSha256: nil))
                lines.append("OK \(entry.destinationPath)\n")
            } else {
                entries.append(VerifyEntryResult(
                    path: entry.destinationPath,
                    url: entry.url,
                    status: .failed,
                    expectedSha256: entry.sha256,
                    actualSha256: hash))
                lines.append(
                    "FAILED \(entry.destinationPath) expected \(entry.sha256) actual \(hash)\n")
                hasFailed = true
            }
        }

        // ── Step 4: Derive exit code from the SAME entries[] array ────────────
        // (hasMissing/hasFailed booleans mirror entries[] — they are in sync by construction.)
        let exitCode: Int32
        if hasMissing {
            exitCode = 9
        } else if hasFailed {
            exitCode = 2
        } else {
            exitCode = 0
        }

        // ── Step 5: Render — JSON or human ────────────────────────────────────
        if json {
            // Summary is DERIVED by folding over the final entries[] array.
            // This is the single source of truth — no parallel tally that could drift.
            let summary = VerifySummary(
                total: entries.count,
                ok: entries.filter { $0.status == .ok }.count,
                failed: entries.filter { $0.status == .failed }.count,
                missing: entries.filter { $0.status == .missing }.count)
            let report = VerifyAllReport(
                reportVersion: 1,
                generatedAt: generatedAt,
                summary: summary,
                entries: entries)
            return jsonResult(exitCode: exitCode, report: report)
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
    /// Returns `nil` only if `CommandCoding.encoder.encode` fails (a programming error —
    /// encoding a value type should never fail in practice).
    public static func payloadBytes(for report: VerifyAllReport) -> Data? {
        try? CommandCoding.encoder.encode(report)
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
        guard let data = payloadBytes(for: report) else {
            // Defensive: encoding a value type should never fail.
            return GohCommandLineResult(exitCode: exitCode, standardOutput: "")
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
