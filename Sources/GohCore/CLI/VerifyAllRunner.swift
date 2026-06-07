import Foundation

/// Progress after one file finishes hashing.
///
/// `completed` = number of files fully processed so far.
/// `total`     = total entries in the ledger at run start.
/// `currentPath` = the file just completed (for display; nil after cancel completes a file).
///
/// `progress` fires AFTER each file, so `completed` reaches `total` only on a full run.
public struct VerifyProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let currentPath: String?

    public init(completed: Int, total: Int, currentPath: String?) {
        self.completed = completed
        self.total = total
        self.currentPath = currentPath
    }
}

/// Errors thrown by `VerifyAllRunner.verifyAll(...)`.
public enum VerifyAllRunnerError: Error {
    /// The ledger could not be read/decoded. Maps to exit 6 in the CLI.
    case ledgerUnreadable(LedgerUnreadableReason)
}

/// Pure, testable verify runner shared by `GohVerifyAllCommand` (CLI) and
/// `TrustWindowViewModel` (tray).
///
/// CONTRACT:
/// - Throws ONLY on a ledger-level read failure (`ProvenanceReadOutcome.unreadable`).
/// - Does NOT throw on cancel — returns a partial `VerifyAllReport`.
/// - `.absent` / `.entries([])` → returns an empty report (exit-0 analog); no throw.
/// - Entry ORDER and summary fold match the current CLI exactly (golden fixture unchanged).
/// - `progress` fires AFTER each file; `isCancelled` is checked BETWEEN files.
/// - Per-file digest errors → MISSING/FAILED; the run NEVER aborts on one bad file.
///
/// **Concurrency:** this function is synchronous (no `async`). Callers that need
/// off-main execution MUST dispatch it on `Thread.detachNewThread` or
/// `DispatchQueue.global().async` — NOT `Task.detached`, which runs on the
/// cooperative pool and would starve it during the blocking hash loop (#81).
public enum VerifyAllRunner {

    /// Re-hashes every recorded file and returns the structured report.
    ///
    /// - Parameters:
    ///   - provenanceStorePath: Absolute path to `provenance.plist`.
    ///   - generatedAt: Timestamp for `VerifyAllReport.generatedAt`.
    ///   - progress: Called after each file completes (may be nil).
    ///   - isCancelled: Called before starting each file (may be nil).
    ///     Return `true` to stop; the partial report is returned (no throw).
    /// - Throws: `VerifyAllRunnerError.ledgerUnreadable` on ledger read failure.
    public static func verifyAll(
        provenanceStorePath: String,
        generatedAt: Date,
        progress: (@Sendable (VerifyProgress) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> VerifyAllReport {
        let outcome = ProvenanceLedgerReader.read(at: provenanceStorePath)

        switch outcome {
        case .unreadable(let reason):
            throw VerifyAllRunnerError.ledgerUnreadable(reason)

        case .absent, .entries([]):
            return VerifyAllReport(
                reportVersion: 1,
                generatedAt: generatedAt,
                summary: VerifySummary(total: 0, ok: 0, failed: 0, missing: 0),
                entries: [])

        case .entries(let ledgerEntries):
            return rehash(
                entries: ledgerEntries,
                generatedAt: generatedAt,
                progress: progress,
                isCancelled: isCancelled)
        }
    }

    // MARK: - Private

    private static func rehash(
        entries: [ProvenanceEntry],
        generatedAt: Date,
        progress: (@Sendable (VerifyProgress) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) -> VerifyAllReport {
        let total = entries.count
        var results: [VerifyEntryResult] = []
        var completed = 0

        for entry in entries {
            // Check cancellation BEFORE starting the next file.
            if isCancelled?() == true {
                break
            }

            let result = hashEntry(entry)
            results.append(result)
            completed += 1

            progress?(VerifyProgress(
                completed: completed,
                total: total,
                currentPath: entry.destinationPath))
        }

        // Summary folded from results[] — never a parallel tally (matches CLI exactly).
        let summary = VerifySummary(
            total: results.count,
            ok: results.filter { $0.status == .ok }.count,
            failed: results.filter { $0.status == .failed }.count,
            missing: results.filter { $0.status == .missing }.count)

        return VerifyAllReport(
            reportVersion: 1,
            generatedAt: generatedAt,
            summary: summary,
            entries: results)
    }

    private static func hashEntry(_ entry: ProvenanceEntry) -> VerifyEntryResult {
        let hash: String
        do {
            (hash, _) = try FileDigest.sha256WithSize(path: entry.destinationPath)
        } catch FileDigest.DigestError.cannotOpen {
            return VerifyEntryResult(
                path: entry.destinationPath,
                url: entry.url,
                status: .missing,
                expectedSha256: entry.sha256,
                actualSha256: nil)
        } catch {
            // Any other FileHandle error (I/O during read) → MISSING (file may be unreadable).
            return VerifyEntryResult(
                path: entry.destinationPath,
                url: entry.url,
                status: .missing,
                expectedSha256: entry.sha256,
                actualSha256: nil)
        }

        if hash == entry.sha256 {
            return VerifyEntryResult(
                path: entry.destinationPath,
                url: entry.url,
                status: .ok,
                expectedSha256: entry.sha256,
                actualSha256: nil)
        } else {
            return VerifyEntryResult(
                path: entry.destinationPath,
                url: entry.url,
                status: .failed,
                expectedSha256: entry.sha256,
                actualSha256: hash)
        }
    }
}
