import Foundation

/// CLI-local fast-check verifier for `goh verify --quick`.
///
/// Runs `FastCheckRunner.checkAll` (lstat-only — no file content reads) against
/// all entries in the provenance ledger. Does not require the daemon.
///
/// Exit code contract:
///   0  — all entries unchanged or notBaselined (0 or absent entries → 0)
///   2  — at least one CHANGED
///   9  — at least one MISSING
///   11 — at least one INDETERMINATE (unreadable-but-present)
///   6  — ledger unreadable / corrupt / unknown version
///
/// Precedence: 9 > 2 > 11 > 0.
///
/// Output format (human-readable, one line per entry):
///   OK        <path>
///   CHANGED   <path>  (size | modified | replaced)
///   MISSING   <path>
///   UNKNOWN   <path>  (unreadable)
///   BASELINE? <path>  (no baseline recorded)
public enum GohVerifyQuickCommand {

    /// Runs the fast check and returns a CLI result.
    ///
    /// - Parameters:
    ///   - provenanceStorePath: Absolute path to `provenance.plist`.
    ///   - probe: Injectable probe (default `LiveFileStatProbe()`).
    public static func run(
        provenanceStorePath: String,
        probe: any FileStatProbing = LiveFileStatProbe()
    ) -> GohCommandLineResult {
        let outcome = ProvenanceLedgerReader.read(at: provenanceStorePath)

        switch outcome {
        case .absent, .entries([]):
            return GohCommandLineResult(exitCode: 0, standardOutput: "0 recorded entries\n")

        case .unreadable(.io):
            return GohCommandLineResult(exitCode: 6, standardOutput: "provenance ledger unreadable\n")

        case .unreadable(.corrupt):
            return GohCommandLineResult(exitCode: 6, standardOutput: "provenance ledger corrupt\n")

        case .unreadable(.versionUnknown(let found)):
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "provenance ledger version \(found) is unknown\n")

        case .entries(let entries):
            return check(entries: entries, probe: probe)
        }
    }

    // MARK: - Private

    private static func check(
        entries: [ProvenanceEntry],
        probe: any FileStatProbing
    ) -> GohCommandLineResult {
        let results = FastCheckRunner.checkAll(entries, probe: probe)

        var hasMissing      = false
        var hasChanged      = false
        var hasIndeterminate = false
        var lines: [String] = []

        for (entry, status) in results {
            let path = entry.destinationPath
            switch status {
            case .unchanged:
                lines.append("OK        \(path)\n")
            case .changed(let reason):
                hasChanged = true
                let note: String
                switch reason {
                case .size:     note = "size"
                case .mtime:    note = "modified"
                case .identity: note = "replaced"
                }
                lines.append("CHANGED   \(path)  (\(note))\n")
            case .missing:
                hasMissing = true
                lines.append("MISSING   \(path)\n")
            case .indeterminate:
                hasIndeterminate = true
                lines.append("UNKNOWN   \(path)  (unreadable)\n")
            case .notBaselined:
                lines.append("BASELINE? \(path)  (no baseline — re-download to enable)\n")
            }
        }

        // Append caveat for any unchanged entries.
        if results.contains(where: { $0.1 == .unchanged }) {
            lines.append(
                "\n"
                + "Note: 'OK' means size, mtime, and inode match the recorded baseline — "
                + "not a full integrity check.\n"
                + "Run 'goh verify --all' to detect bit-rot or tampering that preserves "
                + "size & timestamp.\n")
        }

        let exitCode: Int32
        if hasMissing {
            exitCode = 9
        } else if hasChanged {
            exitCode = 2
        } else if hasIndeterminate {
            exitCode = 11
        } else {
            exitCode = 0
        }

        return GohCommandLineResult(exitCode: exitCode, standardOutput: lines.joined())
    }
}
