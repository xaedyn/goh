import Foundation
import Synchronization

/// Per-download diagnostic trace for the range-parallel engine.
///
/// Off unless `GOH_ENGINE_TRACE=1` in the environment (override-able via the
/// `enabled:` initializer for tests). When off, every method is a cheap
/// short-circuit. When on, timestamped events go to standard error so they
/// ride alongside `goh-bench`'s stdout result line without polluting it.
///
/// Built to diagnose one download at a time — the engine creates one instance
/// per `run(jobID:in:)` and threads it through the range tasks. The trace
/// records:
///
/// - Per-range start, first-byte, and completion timestamps (the user can
///   eyeball them to see whether the 8 ranges actually started concurrently).
/// - Peak number of concurrent range tasks (verifies the connection cap
///   isn't throttling).
/// - Per-range critical-section time, split between the `pwrite`+fsync phase
///   (`.write`) and the assembler/progress/store mutex phase (`.report`).
final class EngineDiagnostics: Sendable {

    /// Reads the `GOH_ENGINE_TRACE` env var once; cached for the process.
    static let defaultEnabled: Bool =
        ProcessInfo.processInfo.environment["GOH_ENGINE_TRACE"] != nil

    /// The two critical sections inside a flush.
    enum CriticalSection: String, Sendable {
        /// `DownloadFile.write` — a `pwrite`, plus an `fsync` every 1 MiB.
        case write
        /// `assembler.advance` + `progress.report` + `store.recordProgress`,
        /// each of which acquires its own mutex.
        case report
    }

    private struct ActiveTally: Sendable {
        var current: Int = 0
        var peak: Int = 0
    }

    private struct PerRangeTotals: Sendable {
        var writeNanos: UInt64 = 0
        var reportNanos: UInt64 = 0
        var flushes: Int = 0
    }

    private let enabled: Bool
    private let clock: ContinuousClock
    private let started: ContinuousClock.Instant
    private let active: Mutex<ActiveTally>
    private let totals: Mutex<[Int: PerRangeTotals]>

    init(enabled: Bool = EngineDiagnostics.defaultEnabled) {
        self.enabled = enabled
        self.clock = ContinuousClock()
        self.started = clock.now
        self.active = Mutex(ActiveTally())
        self.totals = Mutex([:])
    }

    /// Records that the range task with `index` has started, with `bytes` the
    /// range's expected length. Updates the peak-concurrency tally.
    func rangeStarted(_ index: Int, bytes: UInt64) {
        guard enabled else { return }
        let peak = active.withLock { tally -> Int in
            tally.current += 1
            tally.peak = max(tally.peak, tally.current)
            return tally.peak
        }
        emit("range \(index) start       bytes=\(bytes)  active=\(peak)")
    }

    /// Records the first byte arriving on the range — answers
    /// "did all 8 ranges actually start at once?".
    func rangeFirstByte(_ index: Int) {
        guard enabled else { return }
        emit("range \(index) first-byte")
    }

    /// Records the range's completion, with `bytes` the total written. Emits
    /// the per-range critical-section totals on the way out.
    func rangeFinished(_ index: Int, bytes: UInt64) {
        guard enabled else { return }
        active.withLock { $0.current -= 1 }
        let row = totals.withLock { $0[index] ?? PerRangeTotals() }
        emit("""
            range \(index) done        bytes=\(bytes)  flushes=\(row.flushes)  \
            writeMs=\(Self.formatNanos(row.writeNanos))  \
            reportMs=\(Self.formatNanos(row.reportNanos))
            """)
    }

    /// Times the body and credits it to `index`'s `section` total. One flush
    /// calls `.write` then `.report`, in that order, so `.report`'s `flushes`
    /// count is the per-range flush count.
    func timed<T>(
        _ index: Int, _ section: CriticalSection, _ body: () throws -> T
    ) rethrows -> T {
        guard enabled else { return try body() }
        let before = clock.now
        let result = try body()
        let nanos = Self.nanoseconds(from: before, to: clock.now)
        totals.withLock { dict in
            var row = dict[index] ?? PerRangeTotals()
            switch section {
            case .write: row.writeNanos += nanos
            case .report:
                row.reportNanos += nanos
                row.flushes += 1
            }
            dict[index] = row
        }
        return result
    }

    /// Emits the download-level summary line — the peak concurrent range count
    /// reached over the lifetime of the download.
    func summary() {
        guard enabled else { return }
        let peak = active.withLock { $0.peak }
        emit("download complete   peak-active=\(peak)")
    }

    /// Current peak active-range count. For tests — in disabled mode this
    /// stays at zero regardless of `rangeStarted` calls.
    var peakActive: Int { active.withLock { $0.peak } }

    private func emit(_ message: String) {
        let elapsed = clock.now - started
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let line = "[goh-trace t=\(String(format: "%7.3f", seconds))s] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func nanoseconds(
        from before: ContinuousClock.Instant, to after: ContinuousClock.Instant
    ) -> UInt64 {
        let duration = after - before
        let seconds = max(0, duration.components.seconds)
        let attoseconds = max(0, duration.components.attoseconds)
        return UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    }

    private static func formatNanos(_ nanos: UInt64) -> String {
        String(format: "%.1f", Double(nanos) / 1_000_000)
    }
}
