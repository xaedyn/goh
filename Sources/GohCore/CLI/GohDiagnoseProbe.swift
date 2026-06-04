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

// MARK: - ByteCounter

/// Per-connection running byte total. `Mutex<UInt64>` so drain tasks and the coordinator
/// can access it concurrently without data races (the engine's `ByteCounter` idiom).
private final class ByteCounter: @unchecked Sendable {
    private let mutex = Mutex<UInt64>(0)

    func add(_ n: Int) {
        mutex.withLock { $0 += UInt64(n) }
    }

    func snapshot() -> UInt64 {
        mutex.withLock { $0 }
    }
}

// MARK: - ChildOutcome

/// What a `withTaskGroup` child reports back to the parent so the PARENT (not a
/// child) can decide when to call `group.cancelAll()`. Capturing the non-Sendable
/// `TaskGroup` inside a child is not allowed under Swift 6 strict concurrency, so
/// teardown is parent-driven — mirroring `DownloadEngine`'s `group.next()` pattern.
private enum ChildOutcome: Sendable {
    /// A drain child reached EOF or was cancelled.
    case drainFinished
    /// The coordinator finished the T₁ (and Tₙ) windows.
    case coordinatorDone
    /// The deadline child's sleep completed — the global deadline fired (NORMAL termination).
    case deadlineFired
    /// The deadline child's sleep was cancelled because the coordinator finished first.
    case deadlineCancelled
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
///
/// `GohDiagnoseProbe` lives in `GohCore/CLI/` and therefore has access to the
/// module-internal `URLSession.streamingResponse(for:onMetrics:)`.
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
        cancelConn0: @escaping @Sendable () -> Void,
        clock: ContinuousClock,
        deadlineInstant: ContinuousClock.Instant,
        report: inout DiagnosisReport
    ) async {
        let n = config.targetConnections

        // Phase 2 runs ONLY when the file is genuinely large enough to (a) split into
        // `n` NON-EMPTY contiguous parts and (b) yield a meaningful parallel sample.
        // BLOCK 1: a small ranged file (totalBytes < n) gives partSize == 0, and the
        // non-last-part `end = start + partSize - 1` would underflow UInt64 and trap.
        // Such a file is also below minSampleBytes, so a parallel sample is meaningless.
        // Skipping Phase 2 here mirrors the rangeSupported-but-cannot-parallelize path:
        // a single-stream-only run whose tiny T₁ falls through to insufficientData.
        let canSplitIntoNParts: Bool = {
            guard let total = report.totalBytes, n >= 2 else { return false }
            return total / UInt64(n) > 0
        }()
        let largeEnoughForParallelSample = (report.totalBytes ?? 0) >= UInt64(config.minSampleBytes)
        let runPhase2 = report.rangeSupported
            && report.totalBytes != nil
            && n >= 2
            && canSplitIntoNParts
            && largeEnoughForParallelSample

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

        // Phase-2 open-attempt barrier: the coordinator must not start the Tₙ window until
        // every Phase-2 connection has finished its OPEN (recorded a 206 accept or a
        // rejection). Without this the Tₙ aggregate would race the opens and under-count
        // accepted connections when rampWarmupSeconds is small (the shrunk-config case).
        // Counts completed open *attempts* (accept OR reject), not bytes.
        let phase2OpensCompleted = Mutex<Int>(0)
        let expectedPhase2Opens = runPhase2 ? (n - 1) : 0

        // T₁ / Tₙ measurement results, written by the coordinator.
        let t1Result = Mutex<Double?>(nil)
        let tnResult = Mutex<Double?>(nil)

        // For --full: track first-byte instant and aggregate EOF bytes across all conns.
        let firstByteInstant = Mutex<ContinuousClock.Instant?>(nil)
        let eofTotalBytes = Mutex<UInt64>(0)

        // BLOCK 2: terminal-completion signal for conn-0. The coordinator's first-byte
        // wait loop (and the Phase-2 opens barrier) have NO deadline backstop in --full
        // mode (no deadline child is added). If conn-0 returns 206 but never delivers a
        // byte, its drain child reaches EOF (or throws) WITHOUT setting firstByteInstant,
        // and a `while firstByteInstant == nil` loop would spin forever. The drain child
        // sets this flag when it exits without ever recording a first byte; the wait loops
        // check it so they terminate cleanly with firstByteInstant still nil → treated as
        // no measurable sample (singleConnMBps == nil → insufficientData).
        let conn0Ended = Mutex<Bool>(false)

        // Part geometry for Phase 2. When runPhase2 is true the canSplitIntoNParts gate
        // above guarantees total / n > 0, so partSize >= 1 for every opened connection —
        // making the `start + partSize - 1` below underflow-proof. We still clamp to >= 1
        // defensively so no underflow is even arithmetically possible.
        let total = report.totalBytes ?? 0
        let partSize: UInt64 = runPhase2 ? max(1, total / UInt64(n)) : 0

        // Tear-down helper: cancels every open URLSession data task. Calling the
        // per-connection cancels is what actually unblocks the drain children's
        // suspended `for try await chunk in stream` (the data task finishing makes
        // the AsyncThrowingStream terminate). This closure is Sendable (reads the
        // cancel array under the Mutex) so any child may invoke it safely.
        let cancelAllConnections: @Sendable () -> Void = {
            let cancels = cancelClosures.withLock { $0 }
            for cancel in cancels { cancel() }
        }

        // Child outcome tag so the PARENT (not a child) can decide when to call
        // `group.cancelAll()` — capturing `group` inside a child is not Sendable-legal
        // (TaskGroup is non-Sendable). This mirrors DownloadEngine's pattern of driving
        // cancellation from the group body via `group.next()`.
        await withTaskGroup(of: ChildOutcome.self) { group in

            // (a) Conn-0 drain child.
            group.addTask { @Sendable in
                var localTotal: UInt64 = 0
                do {
                    for try await chunk in conn0Stream {
                        counters[0].add(chunk.count)
                        localTotal += UInt64(chunk.count)
                        // Record first-byte instant for --full wholeFileMBps and the
                        // coordinator's warmup start.
                        if firstByteInstant.withLock({ $0 }) == nil {
                            firstByteInstant.withLock { $0 = clock.now }
                        }
                    }
                } catch { }
                eofTotalBytes.withLock { $0 += localTotal }
                // BLOCK 2: if conn-0's drain ended (EOF / error / cancellation) WITHOUT
                // ever recording a first byte, signal terminal completion so the
                // coordinator's first-byte wait loop can exit instead of spinning forever
                // (no deadline child exists in --full mode).
                if firstByteInstant.withLock({ $0 }) == nil {
                    conn0Ended.withLock { $0 = true }
                }
                return .drainFinished
            }

            // (b) Phase-2 drain children (1..<n).
            if runPhase2 {
                for i in 1..<n {
                    let start = UInt64(i) * partSize
                    let end: UInt64 = i == n - 1 ? total - 1 : start + partSize - 1
                    let slotIndex = i

                    group.addTask { @Sendable in
                        var req = URLRequest(url: url)
                        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                        do {
                            let (resp, partStream, cancelPart) =
                                try await self.session.streamingResponse(for: req)
                            // Register cancel closure so the deadline child can tear down.
                            cancelClosures.withLock { $0.append(cancelPart) }

                            // Guard: if the deadline fired while this connection was opening
                            // (e.g., the URL loading thread was briefly contended), the cancel
                            // closure wasn't in `cancelClosures` when `cancelAllConnections()`
                            // ran. Detect that here and self-cancel so the drain doesn't escape
                            // the deadline. This is equivalent to a late-registered cancel.
                            guard !Task.isCancelled else {
                                cancelPart()
                                phase2OpensCompleted.withLock { $0 += 1 }
                                return .drainFinished
                            }

                            if resp.statusCode == 206 {
                                acceptedCount.withLock { $0 += 1 }
                                // Open succeeded — release the coordinator's Tₙ barrier now,
                                // BEFORE draining, so the Tₙ window sees this connection.
                                phase2OpensCompleted.withLock { $0 += 1 }
                                var localTotal: UInt64 = 0
                                do {
                                    for try await chunk in partStream {
                                        counters[slotIndex].add(chunk.count)
                                        localTotal += UInt64(chunk.count)
                                    }
                                } catch { }
                                eofTotalBytes.withLock { $0 += localTotal }
                                cancelPart()
                            } else {
                                // Non-206: record rejection; do NOT cancel the group (abort-free).
                                cancelPart()
                                let statusStr = "\(resp.statusCode)"
                                rejectionsMap.withLock { $0[statusStr, default: 0] += 1 }
                                phase2OpensCompleted.withLock { $0 += 1 }
                            }
                        } catch {
                            // Transport error — count as rejection; do NOT cancel the group.
                            rejectionsMap.withLock { $0["transport", default: 0] += 1 }
                            phase2OpensCompleted.withLock { $0 += 1 }
                        }
                        return .drainFinished
                    }
                }
            }

            // (c) Coordinator child — timed snapshots and termination logic.
            group.addTask { @Sendable in
                let warmup = Duration.seconds(self.config.warmupSeconds)
                let window = Duration.seconds(self.config.sampleWindowSeconds)
                let rampWarmup = Duration.seconds(self.config.rampWarmupSeconds)

                // Wait for conn-0's first byte before starting the warmup clock.
                // Poll with a short sleep to avoid a busy-wait; bail if the deadline fires
                // (the group is cancelled → Task.sleep throws CancellationError).
                // BLOCK 2: also bail if conn-0 ended with no bytes (the --full backstop —
                // no deadline child exists in --full mode, so this is the ONLY way out of
                // this loop when conn-0 delivers 206 headers but never a body byte).
                while firstByteInstant.withLock({ $0 }) == nil && !conn0Ended.withLock({ $0 }) {
                    do {
                        try await Task.sleep(for: .milliseconds(5))
                    } catch {
                        return .coordinatorDone  // group cancelled (deadline fired first)
                    }
                }

                // BLOCK 2: conn-0 produced no measurable sample (ended with no first byte).
                // Leave singleConnMBps nil (→ insufficientData), skip Phase 2 and the Tₙ
                // window, and terminate cleanly. In --full mode tear down any other open
                // connections so the group can exit instead of draining indefinitely.
                if firstByteInstant.withLock({ $0 }) == nil {
                    cancelAllConnections()
                    return .coordinatorDone
                }

                // --- T₁ measurement ---
                let warmupStart = clock.now
                let t1WindowStart = warmupStart.advanced(by: warmup)
                do {
                    try await clock.sleep(until: t1WindowStart, tolerance: nil)
                } catch { return .coordinatorDone }
                let s1Bytes = Int(counters[0].snapshot())
                let t1Start = clock.now

                let t1WindowEnd = t1Start.advanced(by: window)
                do { try await clock.sleep(until: t1WindowEnd, tolerance: nil) } catch {
                    // Deadline fired mid-window: record whatever we have (partial window → nil).
                    return .coordinatorDone
                }
                let s2Bytes = Int(counters[0].snapshot())
                let t1End = clock.now
                let t1Elapsed = Self.seconds(from: t1Start, to: t1End)
                let delta1 = s2Bytes - s1Bytes
                if delta1 >= self.config.minSampleBytes && t1Elapsed > 0 {
                    t1Result.withLock { $0 = rate(byteDelta: delta1, over: t1Elapsed) }
                }

                // --- Tₙ measurement (Phase 2 only) ---
                if runPhase2 {
                    // Barrier: wait until every Phase-2 connection has finished its OPEN
                    // (accepted or rejected) before measuring Tₙ, so the aggregate window
                    // never races the opens. Bail if the deadline cancels us mid-wait.
                    // BLOCK 2: also bail if conn-0 has ended — in --full mode there is no
                    // deadline child, so a Phase-2 open that never returns (server hangs at
                    // header time) would otherwise spin this barrier forever. conn-0 ending
                    // (EOF/error) is the --full backstop signal here too.
                    while phase2OpensCompleted.withLock({ $0 }) < expectedPhase2Opens
                        && !conn0Ended.withLock({ $0 }) {
                        do {
                            try await Task.sleep(for: .milliseconds(2))
                        } catch { return .coordinatorDone }
                    }

                    // Ramp warmup: let Phase-2 connections settle.
                    let tnWarmupEnd = clock.now.advanced(by: rampWarmup)
                    do {
                        try await clock.sleep(until: tnWarmupEnd, tolerance: nil)
                    } catch { return .coordinatorDone }

                    // Snapshot Σ all accepted counters at t_n1.
                    let tn1Snapshot = counters.reduce(0) { $0 + Int($1.snapshot()) }
                    let tn1 = clock.now

                    let tnWindowEnd = tn1.advanced(by: window)
                    do { try await clock.sleep(until: tnWindowEnd, tolerance: nil) } catch {
                        // Deadline fired mid-Tₙ window: leave tnResult nil.
                        return .coordinatorDone
                    }
                    let tn2Snapshot = counters.reduce(0) { $0 + Int($1.snapshot()) }
                    let tn2 = clock.now
                    let tnElapsed = Self.seconds(from: tn1, to: tn2)
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
                    // Default mode: cancel all open connections after the Tₙ window. This
                    // unblocks the suspended drain children (their streams finish), so they
                    // return promptly. The PARENT then calls `group.cancelAll()` to tear down
                    // the still-sleeping deadline child (see the `group.next()` loop below).
                    cancelAllConnections()
                }
                return .coordinatorDone
            }

            // (d) Deadline child — default mode only (BLOCK A: bounds Phase 1 AND Phase 2).
            if !full {
                group.addTask { @Sendable in
                    do {
                        try await clock.sleep(until: deadlineInstant, tolerance: nil)
                    } catch {
                        // Cancelled before deadline fired (coordinator finished first) — ok.
                        return .deadlineCancelled
                    }
                    // Deadline fired: cancel all open connections. This unblocks the drain
                    // children. The PARENT then calls `group.cancelAll()` to stop the
                    // coordinator's remaining sleeps. Treated as NORMAL termination, not an error.
                    cancelAllConnections()
                    return .deadlineFired
                }
            }

            // PARENT-driven cancellation (Sendable-safe — `group` is never captured by a
            // child). The moment either the coordinator finishes (default mode, post-Tₙ) or
            // the deadline fires, we cancel the whole group: this stops every remaining
            // sleeping timer child and propagates cancellation to any drain child still
            // suspended. `--full` has no deadline child and the coordinator does NOT tear
            // down, so the loop simply drains every child to natural EOF.
            for await outcome in group {
                switch outcome {
                case .coordinatorDone, .deadlineFired:
                    if !full {
                        // `cancelAllConnections()` was called by the finishing child (coordinator
                        // or deadline). Call it again here, BEFORE `group.cancelAll()`, to catch
                        // any Phase-2 connections that registered their cancel closure AFTER the
                        // first `cancelAllConnections()` ran (i.e., connections that were still
                        // in `streamingResponse` when the deadline fired and have since opened).
                        // This closes their streams so drain children's `for try await` exits.
                        cancelAllConnections()
                        // Cancel remaining tasks (sleeping timer children, any drain still in
                        // `streamingResponse` via its `withTaskCancellationHandler` onCancel).
                        group.cancelAll()
                    }
                case .deadlineCancelled, .drainFinished:
                    // Nothing to do: drains end on EOF/cancel; a cancelled deadline child is
                    // the normal "coordinator finished first" path.
                    break
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
            let elapsed = Self.seconds(from: fbt, to: now)
            let totalDrained = eofTotalBytes.withLock { $0 }
            if elapsed > 0 && totalDrained > 0 {
                report.wholeFileMBps = rate(byteDelta: Int(totalDrained), over: elapsed)
            }
        }
    }

    // MARK: - Inlined helpers (from DownloadEngine private surface — do NOT widen engine)

    /// Real elapsed seconds between two monotonic instants, as a `Double`.
    private static func seconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let d = end - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

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
