import Foundation

/// Streaming progress for a verify run.
///
/// `completed`   = number of files fully processed so far.
/// `total`       = total entries in the ledger at run start.
/// `currentPath` = the file currently being hashed (or just finished).
/// `bytesHashed` = cumulative bytes hashed across ALL files so far (monotonic).
/// `totalBytes`  = sum of all entries' recorded sizes (0 when progress is disabled).
///
/// `progress` now fires DURING hashing — at the start of each file, throttled
/// while a file streams, and once more when each file completes. `completed`
/// reaches `total` only on a full run; `bytesHashed` reaches `totalBytes` then too.
public struct VerifyProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let currentPath: String?
    public let bytesHashed: Int
    public let totalBytes: Int

    public init(
        completed: Int,
        total: Int,
        currentPath: String?,
        bytesHashed: Int = 0,
        totalBytes: Int = 0
    ) {
        self.completed = completed
        self.total = total
        self.currentPath = currentPath
        self.bytesHashed = bytesHashed
        self.totalBytes = totalBytes
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
/// - `progress` fires DURING hashing (start of each file, throttled mid-file, and on
///   completion); `isCancelled` is checked BETWEEN files AND mid-file (per chunk).
/// - Per-file digest errors → MISSING/FAILED; the run NEVER aborts on one bad file.
///   Mid-file cancellation stops the run and returns the partial report (no throw),
///   without counting the in-progress file.
///
/// **Concurrency:** this function is synchronous (no `async`). Callers that need
/// off-main execution MUST dispatch it via `DispatchQueue.global().async` (a real
/// OS thread, off the Swift cooperative pool) — NOT `Task.detached`, which remains
/// on the cooperative pool and would starve it during the blocking hash loop (#81).
public enum VerifyAllRunner {

    /// Re-hashes every recorded file and returns the structured report.
    ///
    /// - Parameters:
    ///   - provenanceStorePath: Absolute path to `provenance.plist`.
    ///   - generatedAt: Timestamp for `VerifyAllReport.generatedAt`.
    ///   - progress: Called during hashing — at the start of each file, throttled while a
    ///     file streams, and once on completion (may be nil; nil does zero extra work).
    ///   - isCancelled: Called before each file AND per chunk mid-file (may be nil).
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

        // Only sum sizes when someone is listening — keeps the CLI (progress == nil) path free.
        let totalBytes = progress == nil ? 0 : entries.reduce(0) { $0 + $1.size }
        var bytesHashedCumulative = 0

        for entry in entries {
            // Check cancellation BEFORE starting the next file.
            if isCancelled?() == true {
                break
            }

            // Emit a start-of-file update so currentPath advances immediately.
            progress?(VerifyProgress(
                completed: completed,
                total: total,
                currentPath: entry.destinationPath,
                bytesHashed: bytesHashedCumulative,
                totalBytes: totalBytes))

            let result: VerifyEntryResult
            let hashedBytes: Int
            do {
                (result, hashedBytes) = try hashEntry(
                    entry,
                    progress: progress,
                    isCancelled: isCancelled,
                    completed: completed,
                    total: total,
                    bytesHashedCumulative: bytesHashedCumulative,
                    totalBytes: totalBytes)
            } catch FileDigest.DigestError.cancelled {
                // Mid-file cancel: stop the run WITHOUT appending/counting the in-progress
                // file, then fall through to build the partial report (never throw).
                break
            } catch {
                // hashEntry only rethrows DigestError.cancelled; any other error is a
                // programming error. Defensively stop and return the partial report.
                break
            }

            results.append(result)
            bytesHashedCumulative += hashedBytes
            completed += 1

            // Final per-file update: completed incremented, cumulative bytes advanced.
            progress?(VerifyProgress(
                completed: completed,
                total: total,
                currentPath: entry.destinationPath,
                bytesHashed: bytesHashedCumulative,
                totalBytes: totalBytes))
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

    /// Throttle interval for mid-file progress: emit at most once per ~16 MiB hashed.
    private static let progressThrottleBytes = 16 << 20  // 16 MiB

    /// Hashes one entry, streaming throttled progress and honoring mid-file cancel.
    ///
    /// - Returns: `(result, bytesHashed)` — the classified result and the number of bytes
    ///   actually hashed (0 for a MISSING/unreadable file).
    /// - Throws: rethrows `DigestError.cancelled` (mid-file cancel) so the caller can stop
    ///   the run and return a partial report. A missing/unreadable file is NOT a
    ///   cancellation — it is caught and classified `.missing`.
    private static func hashEntry(
        _ entry: ProvenanceEntry,
        progress: (@Sendable (VerifyProgress) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?,
        completed: Int,
        total: Int,
        bytesHashedCumulative: Int,
        totalBytes: Int
    ) throws -> (VerifyEntryResult, Int) {
        let hash: String
        let size: Int
        do {
            // Local running counters for THIS file, used to throttle progress emission.
            var bytesIntoThisFile = 0
            var bytesSinceLastEmit = 0
            (hash, size) = try FileDigest.sha256WithSize(
                path: entry.destinationPath,
                onBytesHashed: { chunkBytes in
                    bytesIntoThisFile += chunkBytes
                    bytesSinceLastEmit += chunkBytes
                    if bytesSinceLastEmit >= progressThrottleBytes {
                        bytesSinceLastEmit = 0
                        progress?(VerifyProgress(
                            completed: completed,
                            total: total,
                            currentPath: entry.destinationPath,
                            bytesHashed: bytesHashedCumulative + bytesIntoThisFile,
                            totalBytes: totalBytes))
                    }
                },
                isCancelled: isCancelled)
        } catch FileDigest.DigestError.cancelled {
            throw FileDigest.DigestError.cancelled  // propagate — NOT a missing file
        } catch FileDigest.DigestError.cannotOpen {
            return (VerifyEntryResult(
                path: entry.destinationPath,
                url: entry.url,
                status: .missing,
                expectedSha256: entry.sha256,
                actualSha256: nil), 0)
        } catch {
            // Any other FileHandle error (I/O during read) → MISSING (file may be unreadable).
            return (VerifyEntryResult(
                path: entry.destinationPath,
                url: entry.url,
                status: .missing,
                expectedSha256: entry.sha256,
                actualSha256: nil), 0)
        }

        if hash == entry.sha256 {
            return (VerifyEntryResult(
                path: entry.destinationPath,
                url: entry.url,
                status: .ok,
                expectedSha256: entry.sha256,
                actualSha256: nil), size)
        } else {
            return (VerifyEntryResult(
                path: entry.destinationPath,
                url: entry.url,
                status: .failed,
                expectedSha256: entry.sha256,
                actualSha256: hash), size)
        }
    }
}
