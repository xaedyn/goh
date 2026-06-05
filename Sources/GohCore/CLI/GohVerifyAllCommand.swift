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
    /// - Parameter provenanceStorePath: Absolute path to `provenance.plist`.
    ///   Resolved by the caller from `ProvenanceStoreLocation.defaultURL(create: false)`.
    public static func run(provenanceStorePath: String) -> GohCommandLineResult {
        let storeURL = URL(fileURLWithPath: provenanceStorePath)

        // ── Step 1: Read the ledger (read-only; never creates a sidecar or resets) ──
        guard FileManager.default.fileExists(atPath: provenanceStorePath) else {
            return GohCommandLineResult(
                exitCode: 0,
                standardOutput: "0 recorded entries\n")
        }

        guard let data = try? Data(contentsOf: storeURL) else {
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "provenance ledger unreadable\n")
        }

        let record: ProvenanceRecord
        do {
            record = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
        } catch {
            // CLI does NOT copy-to-sidecar or reset — the daemon owns recovery.
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "provenance ledger corrupt\n")
        }

        guard record.version == ProvenanceRecord.currentVersion else {
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
            return GohCommandLineResult(
                exitCode: 0,
                standardOutput: "0 recorded entries\n")
        }

        // ── Step 3: Re-hash each entry ────────────────────────────────────────
        var lines: [String] = []
        var hasMissing = false
        var hasFailed = false

        for entry in record.entries {
            let hash: String
            do {
                (hash, _) = try FileDigest.sha256WithSize(path: entry.destinationPath)
            } catch FileDigest.DigestError.cannotOpen {
                lines.append("MISSING \(entry.destinationPath) (expected \(entry.sha256))\n")
                hasMissing = true
                continue
            } catch {
                lines.append("MISSING \(entry.destinationPath) (expected \(entry.sha256))\n")
                hasMissing = true
                continue
            }

            if hash == entry.sha256 {
                lines.append("OK \(entry.destinationPath)\n")
            } else {
                lines.append(
                    "FAILED \(entry.destinationPath) expected \(entry.sha256) actual \(hash)\n")
                hasFailed = true
            }
        }

        // ── Step 4: Precedence 9 > 2 > 0 ─────────────────────────────────────
        let exitCode: Int32
        if hasMissing {
            exitCode = 9
        } else if hasFailed {
            exitCode = 2
        } else {
            exitCode = 0
        }

        return GohCommandLineResult(exitCode: exitCode, standardOutput: lines.joined())
    }
}
