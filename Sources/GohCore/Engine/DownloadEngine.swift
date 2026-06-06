import Darwin
import Foundation
import Synchronization

/// A shared, monotonic byte counter for the dynamic worker pool. Every worker
/// adds its per-flush byte delta and reads back the running cumulative total
/// across ALL workers — independent of how many chunks or workers produced the
/// bytes. A `Sendable` reference type so the worker tasks share one instance
/// (a bare `Mutex` is noncopyable and cannot be captured by the sending task
/// closures). Replaces the per-range-index `RangeProgress`.
private final class ByteCounter: Sendable {
    private let total: Mutex<UInt64>

    init() { total = Mutex(0) }

    /// Adds `delta` to the running total and returns the new cumulative value.
    func add(_ delta: UInt64) -> UInt64 {
        total.withLock { $0 += delta; return $0 }
    }

    /// The current cumulative total across all workers. The control loop reads
    /// this at each reap to derive the aggregate delivery rate for the governor.
    var value: UInt64 {
        total.withLock { $0 }
    }
}

/// Runs an HTTP download (`DESIGN.md` §Transport).
///
/// The engine claims a queued job, sends a *speculative* ranged GET
/// (`Range: bytes=0-`) as the first request, and routes from the response: a
/// `206` reveals the total via `Content-Range` and the engine splits across N
/// concurrent ranges with range 0 reusing the in-flight stream; a `200` means
/// the server doesn't honour `Range`, so the engine consumes that stream as a
/// single connection. Either way it streams bytes into a ``DownloadFile``,
/// hashes through a ``ChunkAssembler``, reports progress, and drives the job
/// to `completed` or `failed`.
///
/// Skipping the `HEAD` probe saves one round-trip on every download (we learn
/// `Content-Length` from `Content-Range` *while* range 0's bytes are already
/// arriving, instead of paying a separate `HEAD`-then-`GET` sequence).
///
/// HTTP/3 enablement is *not* set per-request — a first attempt to opt in via
/// `URLRequest.assumesHTTP3Capable = true` produced a regression on the
/// saturated workload (run-to-run variance, dl.google.com appeared to throttle
/// h3 traffic more aggressively than h2 from this network path). Reverted; see
/// DESIGN.md §Transport for the discussion.
public struct DownloadEngine: Sendable {

    /// The buffer-flush granularity — bytes accumulate to here before a write.
    /// 1 MiB matches the cumulative-fsync checkpoint, so each flush is roughly
    /// one `pwrite` followed by an `fsync`, instead of 16 small `pwrite`s
    /// against the same checkpoint interval.
    private static let bufferSize = 1 << 20

    /// No range is split below this; smaller files download over one connection.
    private static let minChunk: UInt64 = 1 << 20

    /// The largest server-declared content length the engine will accept. A 206
    /// `Content-Range` total beyond this is treated as a hostile/malformed
    /// response and fails the job closed, rather than planning a chunk array of
    /// `total / chunkSize` entries — at `total` near `UInt64.max` that array
    /// would exhaust memory (audit M2). 8 TiB is far above any real asset goh
    /// targets (model weights, datasets) while bounding the chunk count.
    static let maxDeclaredTotal: UInt64 = 1 << 43

    /// Daemon kill-switch for the in-flight parallelism governor (spec §10).
    /// When `false`, `fetchRanged` falls back to a static N (the requested
    /// connection count) and never runs the governor. Defaults to `true`.
    static let governorEnabled = true

    /// Minimum wall-clock window over which the control loop measures one
    /// aggregate delivery-rate sample for the governor. Per-reap intervals are
    /// far too short (tens of ms) and produce a jitter-swamped rate estimate;
    /// averaging over ≥0.25 s yields a stable signal the governor can detect a
    /// modest throughput gain against.
    static let minGovernorSampleSeconds = 0.25

    /// Reports a `JobStore` mutation failure other than the expected
    /// `.jobNotFound` (which the engine ignores because it means the job was
    /// removed under it). The reporter receives the `jobID`, the operation
    /// name (`"recordProgress"`, `"fail"`), and the raw error. The daemon
    /// wires this to its stderr `warn(...)` channel so an otherwise-silent
    /// persistence failure becomes diagnosable.
    public typealias UnexpectedStoreErrorReporter = @Sendable (UInt64, String, any Error) -> Void

    /// Fixed chunk granularity for the dynamic worker pool. Workers pull
    /// `chunkSize`-byte intervals one at a time (the last takes the remainder),
    /// so there is always spare unclaimed work for the governor (Task 12) to
    /// hand a freshly-added worker. Independent of the requested connection
    /// count `N`. Defaults to 8 MiB; injectable so tests can force many small
    /// chunks. Must be ≥ `bufferSize`.
    private let chunkSize: UInt64

    private let session: URLSession
    private let checkpointStore: CheckpointStore?
    private let control: DownloadControl?
    private let cookieHeaderProvider: (@Sendable (UInt64, URL) -> String?)?
    private let sleepAssertionController: SleepAssertionController?
    private let completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome) -> Void)?
    private let unexpectedStoreError: UnexpectedStoreErrorReporter?
    private let hostProfileStore: HostProfileStore?
    private let connectionBudget: ConnectionBudget?

    public init(
        session: URLSession,
        chunkSize: UInt64 = 8 << 20,
        checkpointStore: CheckpointStore? = nil,
        control: DownloadControl? = nil,
        cookieHeaderProvider: (@Sendable (UInt64, URL) -> String?)? = nil,
        sleepAssertionController: SleepAssertionController? = nil,
        completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome) -> Void)? = nil,
        unexpectedStoreError: UnexpectedStoreErrorReporter? = nil,
        hostProfileStore: HostProfileStore? = nil,
        connectionBudget: ConnectionBudget? = nil
    ) {
        self.chunkSize = chunkSize
        self.session = session
        self.checkpointStore = checkpointStore
        self.control = control
        self.cookieHeaderProvider = cookieHeaderProvider
        self.sleepAssertionController = sleepAssertionController
        self.completedDownloadHandler = completedDownloadHandler
        self.unexpectedStoreError = unexpectedStoreError
        self.hostProfileStore = hostProfileStore
        self.connectionBudget = connectionBudget
    }

    /// Routes a `JobStore` mutation error to the reporter, silently dropping
    /// `.jobNotFound` (which means the job was removed under the engine).
    private func reportStoreError(
        jobID: UInt64, operation: String, _ error: any Error
    ) {
        if let gohError = error as? GohError, gohError.code == .jobNotFound {
            return
        }
        unexpectedStoreError?(jobID, operation, error)
    }

    /// `JobStore.recordProgress`, tolerating the expected `.jobNotFound`
    /// (the job was removed under the engine) and reporting any other
    /// failure via `unexpectedStoreError`.
    private func recordProgress(
        store: JobStore, jobID: UInt64, _ progress: JobProgress
    ) {
        do {
            _ = try store.recordProgress(id: jobID, progress)
        } catch {
            reportStoreError(jobID: jobID, operation: "recordProgress", error)
        }
    }

    /// `JobStore.fail`, tolerating the expected `.jobNotFound` (the job was
    /// removed under the engine while it was unwinding) and reporting any
    /// other failure via `unexpectedStoreError`.
    private func recordFail(
        store: JobStore, jobID: UInt64, error: GohError, retryEligible: Bool
    ) {
        do {
            _ = try store.fail(id: jobID, error: error, retryEligible: retryEligible)
        } catch {
            reportStoreError(jobID: jobID, operation: "fail", error)
        }
    }

    /// Downloads the job with `jobID`, driving it to a terminal state. Never
    /// throws — every failure is recorded on the job as a ``GohError``.
    public func run(
        jobID: UInt64, in store: JobStore,
        explicitConnectionCount: UInt8? = nil
    ) async {
        guard store.job(id: jobID) != nil else { return }
        control?.register(jobID: jobID)
        defer { control?.unregister(jobID: jobID) }
        // Claim the job atomically; only proceed if this call won the claim.
        guard (try? store.start(id: jobID)) == true else { return }
        // Active-job bracket (D5/D7) — placed AFTER the atomic start claim so only
        // the winning runner touches the per-host active index; a losing duplicate
        // run() for the same jobID bails at the claim above and never begin()/end()s
        // (which would otherwise remove the winner's entry, since the set keys on
        // jobID). begin() marks the job active and flags any concurrent siblings
        // contended. end() is in a defer so it fires on every exit path (throw,
        // pause, cancel, success) — cannot leak regardless of how run() terminates.
        // The defer runs when run() EXITS, i.e. AFTER complete()'s handler has
        // returned, so wasSolo(jobID:) at handler time still sees the whole-duration
        // answer.
        let jobHostKey = store.job(id: jobID).flatMap { hostKey(for: $0.url) }
        if let key = jobHostKey {
            hostProfileStore?.begin(jobID: jobID, hostKey: key)
        }
        defer {
            if let key = jobHostKey {
                hostProfileStore?.end(jobID: jobID, hostKey: key)
            }
        }
        sleepAssertionController?.downloadStarted()
        defer { sleepAssertionController?.downloadFinished() }
        guard let job = store.job(id: jobID) else { return }
        do {
            if let checkpointStore,
               let checkpoint = checkpointStore.load(jobID: jobID).checkpoint
            {
                try await resume(
                    job: job, checkpoint: checkpoint, checkpointStore: checkpointStore,
                    store: store, trace: EngineDiagnostics())
            } else {
                try await download(
                    job: job, store: store, trace: EngineDiagnostics(),
                    explicitConnectionCount: explicitConnectionCount)
            }
            try? checkpointStore?.delete(jobID: jobID)
        } catch let stop as DownloadControlStop {
            handle(stop: stop, job: job)
        } catch let error as GohError {
            recordFail(
                store: store, jobID: jobID, error: error,
                retryEligible: Self.retryEligible(for: error))
        } catch {
            let mapped = Self.mapError(error)
            recordFail(
                store: store, jobID: jobID, error: mapped,
                retryEligible: Self.retryEligible(for: mapped))
        }
    }

    private func handle(stop: DownloadControlStop, job: JobSummary) {
        switch stop.reason {
        case .pause:
            return
        case .remove(let keepPartialFile):
            guard !keepPartialFile else { return }
            try? checkpointStore?.delete(jobID: job.id)
            try? FileManager.default.removeItem(atPath: job.destination)
        }
    }

    private func download(
        job: JobSummary, store: JobStore, trace: EngineDiagnostics,
        explicitConnectionCount: UInt8? = nil
    ) async throws {
        guard let url = URL(string: job.url) else {
            throw GohError(code: .unsupportedURL, message: "could not parse URL: \(job.url)")
        }
        // Speculative ranged GET. `Range: bytes=0-` asks for everything from
        // byte zero; a server that honours ranges replies `206` with a
        // `Content-Range` header that carries the total, and range 0's bytes
        // start streaming in the same round-trip. A server that doesn't honour
        // ranges replies `200` with the full body — this stream is then the
        // whole file and the engine consumes it as a single connection.
        var request = request(for: url, job: job)
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        let (response, stream, cancelStream) = try await session.streamingResponse(
            for: request,
            onMetrics: { @Sendable [trace] metrics in
                trace.recordProtocol(0, networkProtocolName: metrics.networkProtocolName)
            })
        defer { cancelStream() }
        switch response.statusCode {
        case 206:
            guard let contentRange = Self.contentRange(response),
                  contentRange.start == 0,
                  contentRange.end == contentRange.total - 1
            else {
                throw GohError(
                    code: .connectionFailed,
                    message: "the initial 206 response did not carry a full Content-Range")
            }
            let total = contentRange.total
            // Reject an implausibly large declared length before it drives chunk
            // planning / preallocation (audit M2).
            guard total <= Self.maxDeclaredTotal else {
                throw GohError(
                    code: .connectionFailed,
                    message: "the server declared an implausibly large content length (\(total) bytes)")
            }
            try await fetchRanged(
                job: job, store: store, url: url, total: total, initialResponse: response,
                firstRangeStream: stream, cancelFirstRangeStream: cancelStream, trace: trace,
                explicitConnectionCount: explicitConnectionCount)
        case 200..<300:
            try await fetchSingle(
                job: job, store: store,
                initialResponse: response, initialStream: stream,
                cancelInitialStream: cancelStream)
        default:
            throw Self.httpFailure(statusCode: response.statusCode)
        }
    }

    private struct ContentRange: Sendable, Equatable {
        var start: UInt64
        var end: UInt64
        var total: UInt64
    }

    /// Parses `Content-Range: bytes START-END/TOTAL`. Returns `nil` for
    /// unparseable, missing, empty, or internally inconsistent values.
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

    private static func validateContentRange(
        _ response: HTTPURLResponse, matches range: ByteRange, total: UInt64
    ) throws {
        guard let contentRange = contentRange(response),
              contentRange.start == range.start,
              contentRange.end == range.start + range.length - 1,
              contentRange.total == total
        else {
            throw GohError(
                code: .connectionFailed,
                message: "the server returned a mismatched Content-Range")
        }
    }

    private static func strongETag(_ response: HTTPURLResponse) -> String? {
        guard let etag = response.value(forHTTPHeaderField: "ETag")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !etag.isEmpty,
              !etag.lowercased().hasPrefix("w/")
        else { return nil }
        return etag
    }

    private static func lastModified(_ response: HTTPURLResponse) -> String? {
        guard let lastModified = response.value(forHTTPHeaderField: "Last-Modified")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !lastModified.isEmpty
        else { return nil }
        return lastModified
    }

    // MARK: Resume

    private func resume(
        job: JobSummary, checkpoint: DownloadCheckpoint, checkpointStore: CheckpointStore,
        store: JobStore, trace: EngineDiagnostics
    ) async throws {
        guard checkpoint.startupResumeProgress(for: job) != nil,
              let total = checkpoint.totalBytes,
              let validator = checkpoint.ifRangeValidator,
              let missingRanges = checkpoint.missingByteRanges,
              var completed = checkpoint.durableBytesCompleted,
              let url = URL(string: job.url)
        else {
            throw GohError(
                code: .connectionFailed,
                message: "resume metadata was unavailable or unsafe")
        }

        _ = try store.setActualConnectionCount(id: job.id, 1)
        let file = try DownloadFile(path: job.destination, expectedSize: total, truncate: false)
        let recorder = DownloadCheckpointRecorder(store: checkpointStore, checkpoint: checkpoint)
        let clock = ContinuousClock()
        let started = clock.now

        let resumeDigest: String
        do {
            for range in missingRanges {
                completed += try await downloadResumeRange(
                    range: range, url: url, file: file, recorder: recorder,
                    validator: validator, job: job, store: store, total: total,
                    completedBeforeRange: completed, clock: clock, started: started)
            }

            resumeDigest = try await verifyHash(file: file, total: total)
            try file.finish()
        } catch {
            try? file.finish()
            throw error
        }
        _ = try store.recordProgress(
            id: job.id,
            Self.progress(completed: total, total: total, elapsed: clock.now - started))
        try complete(
            jobID: job.id, in: store,
            transferDuration: clock.now - started, isResume: true,
            sha256: resumeDigest)
        trace.summary()
    }

    private func downloadResumeRange(
        range: ByteRange, url: URL, file: DownloadFile,
        recorder: DownloadCheckpointRecorder, validator: String,
        job: JobSummary, store: JobStore, total: UInt64,
        completedBeforeRange: UInt64,
        clock: ContinuousClock, started: ContinuousClock.Instant
    ) async throws -> UInt64 {
        var request = request(for: url, job: job)
        let last = range.start + range.length - 1
        request.setValue("bytes=\(range.start)-\(last)", forHTTPHeaderField: "Range")
        request.setValue(validator, forHTTPHeaderField: "If-Range")
        let (http, stream, cancelStream) = try await session.streamingResponse(for: request)
        defer { cancelStream() }
        guard http.statusCode == 206 else {
            if (200..<300).contains(http.statusCode) {
                throw GohError(
                    code: .connectionFailed,
                    message: "the server returned a full representation instead of resuming")
            }
            throw Self.httpFailure(statusCode: http.statusCode)
        }
        try Self.validateContentRange(http, matches: range, total: total)

        var buffer = Data()
        buffer.reserveCapacity(Self.bufferSize)
        var written: UInt64 = 0

        func flush() throws {
            guard !buffer.isEmpty else { return }
            let pieceStart = range.start + written
            let pieceLength = UInt64(buffer.count)
            try file.write(buffer, at: pieceStart)
            try file.sync()
            try recorder.recordCompletedPiece(start: pieceStart, length: pieceLength)
            written += pieceLength
            buffer.removeAll(keepingCapacity: true)
            recordProgress(
                store: store, jobID: job.id,
                Self.progress(
                    completed: completedBeforeRange + written,
                    total: total,
                    elapsed: clock.now - started))
            try control?.stopIfRequested(jobID: job.id)
        }

        for try await chunk in stream {
            let alreadyHave = written + UInt64(buffer.count)
            let remaining: UInt64 =
                alreadyHave >= range.length ? 0 : range.length - alreadyHave
            let toAppend: Data =
                UInt64(chunk.count) <= remaining ? chunk : chunk.prefix(Int(remaining))
            buffer.append(toAppend)
            if buffer.count >= Self.bufferSize { try flush() }
            if written + UInt64(buffer.count) >= range.length { break }
        }
        try flush()
        guard written == range.length else {
            throw GohError(
                code: .connectionFailed,
                message: "resume range ended after \(written) of \(range.length) expected bytes")
        }
        return written
    }

    private func verifyHash(file: DownloadFile, total: UInt64) async throws -> String {
        let assembler = ChunkAssembler(file: file, totalBytes: total)
        async let assembled = assembler.hashToCompletion()
        assembler.complete(interval: ByteInterval(start: 0, length: total))
        assembler.finish()
        let outcome = await assembled                              // the ONE await
        guard case .digest(let hex) = outcome else {
            guard case .failed(let err) = outcome else {
                fatalError("unreachable: ChunkAssemblerResult has only .digest/.failed")
            }
            throw err
        }
        return hex
    }

    // MARK: Single connection

    private func fetchSingle(
        job: JobSummary, store: JobStore,
        initialResponse: HTTPURLResponse,
        initialStream: AsyncThrowingStream<Data, Error>,
        cancelInitialStream: @escaping @Sendable () -> Void
    ) async throws {
        defer { cancelInitialStream() }
        guard (200..<300).contains(initialResponse.statusCode) else {
            throw Self.httpFailure(statusCode: initialResponse.statusCode)
        }

        // `expectedContentLength` is `Int64`; the unknown sentinel is
        // `NSURLResponseUnknownLength` (-1). `>= 0` admits `Content-Length: 0`
        // (a real empty body) as a known total of 0; only `-1` maps to nil.
        let total: UInt64? = initialResponse.expectedContentLength >= 0
            ? UInt64(initialResponse.expectedContentLength) : nil
        let file = try DownloadFile(path: job.destination, expectedSize: total)
        let assembler = ChunkAssembler(file: file, totalBytes: total)
        async let assembled = assembler.hashToCompletion()

        let clock = ContinuousClock()
        let started = clock.now
        var buffer = Data()
        buffer.reserveCapacity(Self.bufferSize)
        var completed: UInt64 = 0

        func flush() throws {
            guard !buffer.isEmpty else { return }
            let writeStart = completed
            let writeLength = UInt64(buffer.count)
            try file.write(buffer, at: writeStart)
            completed += writeLength
            buffer.removeAll(keepingCapacity: true)
            assembler.complete(interval: ByteInterval(start: writeStart, length: writeLength))
            try control?.stopIfRequested(jobID: job.id)
        }

        do {
            for try await chunk in initialStream {
                buffer.append(chunk)
                if buffer.count >= Self.bufferSize {
                    try flush()
                    _ = try store.recordProgress(
                        id: job.id,
                        Self.progress(completed: completed, total: total,
                                      elapsed: clock.now - started))
                }
            }
            try flush()
        } catch {
            assembler.recordFailure(Self.mapError(error))
            _ = await assembled
            try? file.finish()
            throw error
        }

        assembler.finish()
        let assemblerOutcome = await assembled                         // the ONE await
        if case .failed(let assemblerError) = assemblerOutcome {
            try? file.finish()
            throw assemblerError
        }
        // assemblerOutcome is .digest(hex) — extract the hex for provenance recording.
        let fetchSingleDigest: String?
        if case .digest(let hex) = assemblerOutcome {
            fetchSingleDigest = hex
        } else {
            fatalError("unreachable: ChunkAssemblerResult has only .digest/.failed")
        }
        try file.finish()
        _ = try store.recordProgress(
            id: job.id,
            Self.progress(completed: completed, total: total, elapsed: clock.now - started))
        try complete(
            jobID: job.id, in: store,
            transferDuration: clock.now - started, isResume: false,
            sha256: fetchSingleDigest)
    }

    // MARK: Range-parallel

    private func fetchRanged(
        job: JobSummary, store: JobStore, url: URL, total: UInt64,
        initialResponse: HTTPURLResponse,
        firstRangeStream: AsyncThrowingStream<Data, Error>,
        cancelFirstRangeStream: @escaping @Sendable () -> Void,
        trace: EngineDiagnostics,
        explicitConnectionCount: UInt8? = nil,
        clock: ContinuousClock = ContinuousClock()   // injected; default keeps callers unchanged
    ) async throws {
        let file = try DownloadFile(path: job.destination, expectedSize: total)
        let assembler = ChunkAssembler(file: file, totalBytes: total)
        async let assembled = assembler.hashToCompletion()
        let checkpointRecorder = makeCheckpointRecorder(
            job: job, total: total, response: initialResponse)

        // Byte-based progress: a single shared counter accumulating every
        // worker's per-flush delta. Monotonic and N-agnostic — the sum of all
        // per-flush `pieceLength`s equals total bytes written, regardless of how
        // many chunks or workers produced them. Replaces the per-range-index
        // `RangeProgress` (which assumed a fixed range count).
        let bytesWritten = ByteCounter()
        let started = clock.now

        // Seed the dynamic chunk pool with FIXED-size chunks (spec §6.1): a
        // daemon constant independent of N. The last chunk takes the remainder.
        // Because there are many more chunks than N (for total > chunkSize), the
        // queue always holds spare unclaimed work — that is what lets the
        // governor (Task 12) add a worker live. The first chunk (start 0)
        // reuses the speculative firstRangeStream; all others open a fresh GET.
        var chunks: [ByteInterval] = []
        var offset: UInt64 = 0
        while offset < total {
            let len = min(chunkSize, total - offset)
            chunks.append(ByteInterval(start: offset, length: len))
            offset += len
        }
        let queue = ChunkQueue(intervals: chunks)

        // Governor runs only when no explicit --connections was given AND the
        // daemon kill-switch is on. An explicit count pins targetN (no probing).
        let governorEnabled = explicitConnectionCount == nil && Self.governorEnabled
        // Clamp the seed/pin target to [1, 16]. The slot set is 0..<16, so
        // targetN must never exceed 16 (closes the 11A advisory).
        var targetN = min(max(Int(explicitConnectionCount ?? job.requestedConnectionCount), 1), 16)
        // The governor is a value type mutated ONLY in the synchronous control
        // loop below (record/decide). Workers never touch it. The sample sink is
        // the sole worker→control-loop channel (a Mutex).
        var governor = ParallelismGovernor(config: .default, rng: SystemRandomNumberGenerator())

        // Per-host connection budget gate (spec §8). Computed once; nil when the
        // host key is unparseable — in that case the gate is skipped entirely.
        // `connectionBudget` itself may be nil (no enforcement; existing tests
        // pass no budget and are completely unaffected).
        let budgetHostKey: String? = connectionBudget != nil ? hostKey(for: job.url) : nil

        do {
            // The group element is the connection SLOT the worker held, returned
            // on completion so the control loop can free it. Slots are a stable
            // index in 0..<liveWorkers (NOT the unbounded chunk index) so Task
            // 12's governor can tag each rate sample with a per-worker identity.
            try await withThrowingTaskGroup(of: Int.self) { group in
                var liveWorkers = 0
                var peakWorkers = 0
                // 16 = the hard worker cap (the governor may grow targetN to 16
                // in Task 12). The lowest free slot is allocated on spawn and
                // returned to the set on reap; at fixed targetN ≤ 16 only the low
                // slots are ever used.
                var availableSlots = Set(0..<16)

                // The control loop is the SOLE caller of group.addTask. A worker
                // downloads one captured chunk (the first chunk reuses the
                // speculative firstRangeStream; others open a fresh ranged GET
                // via downloadRange) and returns its slot id. Workers never call
                // addTask and never touch the slot set.
                //
                // `spawn` is only called after the budget slot has already been
                // granted by `fillToTarget` — the worker's defer unconditionally
                // releases 1 slot on exit (normal return, throw, or cancel).
                // Capture `budgetHostKey` by value so the closure is independent
                // of any outer mutation.
                func spawn(_ chunk: ByteInterval) {
                    // Crash-proof slot allocation: if somehow no slot is free,
                    // don't spawn — hold (targetN is clamped ≤ 16, so this should
                    // never trip, but a force-unwrap here would be a hard crash).
                    guard let slot = availableSlots.min() else {
                        // Budget was pre-granted but spawn can't proceed; release it.
                        if let budget = connectionBudget, let hk = budgetHostKey {
                            budget.release(slots: 1, hostKey: hk)
                        }
                        return
                    }
                    availableSlots.remove(slot)
                    let range = ByteRange(start: chunk.start, length: chunk.length)
                    // Capture budget and key by value for the worker's defer so
                    // the release is leak-proof on normal return, throw, and cancel.
                    let capturedBudget = connectionBudget
                    let capturedBudgetHostKey = budgetHostKey
                    if chunk.start == 0 {
                        group.addTask {
                            defer {
                                if let budget = capturedBudget, let hk = capturedBudgetHostKey {
                                    budget.release(slots: 1, hostKey: hk)
                                }
                            }
                            try await consumeRange(
                                index: slot, range: range, file: file,
                                assembler: assembler, bytesWritten: bytesWritten,
                                checkpointRecorder: checkpointRecorder,
                                job: job, store: store, total: total,
                                clock: clock, started: started, trace: trace,
                                stream: firstRangeStream, cancelStream: cancelFirstRangeStream)
                            return slot
                        }
                    } else {
                        group.addTask {
                            defer {
                                if let budget = capturedBudget, let hk = capturedBudgetHostKey {
                                    budget.release(slots: 1, hostKey: hk)
                                }
                            }
                            try await downloadRange(
                                index: slot, range: range, url: url, file: file,
                                assembler: assembler, bytesWritten: bytesWritten,
                                checkpointRecorder: checkpointRecorder,
                                job: job, store: store, total: total,
                                clock: clock, started: started, trace: trace)
                            return slot
                        }
                    }
                    liveWorkers += 1
                    peakWorkers = max(peakWorkers, liveWorkers)
                }

                // Admit workers up to the target while the queue has work and the
                // per-host budget allows. Budget is requested here, before spawn,
                // so the worker's defer owns the paired release — no double-release
                // is possible (the control loop never releases; only workers do).
                // On budget denial the chunk is returned to the front of the queue
                // and the fill breaks (hold-N), waiting for the next reap to try
                // again. Returns whether at least one worker was admitted.
                @discardableResult
                func fillToTarget(_ target: Int) -> Bool {
                    var admitted = false
                    while liveWorkers < target, let chunk = queue.pull() {
                        if let budget = connectionBudget, let hk = budgetHostKey {
                            guard budget.request(slots: 1, hostKey: hk) else {
                                // Budget full — return the chunk and stop filling.
                                queue.returnToFront(chunk)
                                break
                            }
                        }
                        spawn(chunk)
                        admitted = true
                    }
                    return admitted
                }

                // Seed fill. If budget denial blocked ALL workers (liveWorkers == 0
                // after the fill) yet there's still work queued, force-admit one
                // worker unconditionally — this guarantees the download always makes
                // progress even when the global budget is fully consumed by sibling
                // downloads. Without this safeguard the outer `while liveWorkers > 0`
                // loop would exit immediately, leaving chunks in the queue.
                func forceOneIfStalled() {
                    guard liveWorkers == 0, let chunk = queue.pull() else { return }
                    // Force: request budget (will be denied if full) but spawn anyway.
                    // The budget is requested first so the worker's defer can release
                    // it; if denied, the budget is not incremented so no phantom
                    // release happens. We DON'T increment the budget here when denied
                    // — we just skip the request and spawn without a budget slot.
                    // The worker's defer only releases when budget+key were captured
                    // as non-nil, so it's safe to capture nil when forcing.
                    if let budget = connectionBudget, let hk = budgetHostKey {
                        // Try a normal request first (may succeed if another download
                        // released between the fill attempt and now).
                        if !budget.request(slots: 1, hostKey: hk) {
                            // Denied; spawn without incrementing the budget counter
                            // so the forced worker will NOT release on exit.
                            let slot: Int
                            guard let s = availableSlots.min() else { return }
                            slot = s
                            availableSlots.remove(slot)
                            let range = ByteRange(start: chunk.start, length: chunk.length)
                            if chunk.start == 0 {
                                group.addTask {
                                    // No defer release — this is the un-budgeted forced slot.
                                    try await consumeRange(
                                        index: slot, range: range, file: file,
                                        assembler: assembler, bytesWritten: bytesWritten,
                                        checkpointRecorder: checkpointRecorder,
                                        job: job, store: store, total: total,
                                        clock: clock, started: started, trace: trace,
                                        stream: firstRangeStream, cancelStream: cancelFirstRangeStream)
                                    return slot
                                }
                            } else {
                                group.addTask {
                                    // No defer release — this is the un-budgeted forced slot.
                                    try await downloadRange(
                                        index: slot, range: range, url: url, file: file,
                                        assembler: assembler, bytesWritten: bytesWritten,
                                        checkpointRecorder: checkpointRecorder,
                                        job: job, store: store, total: total,
                                        clock: clock, started: started, trace: trace)
                                    return slot
                                }
                            }
                            liveWorkers += 1
                            peakWorkers = max(peakWorkers, liveWorkers)
                            return
                        }
                    }
                    // Budget either nil (no enforcement), key nil (no enforcement),
                    // or request succeeded — normal spawn path.
                    spawn(chunk)
                }

                fillToTarget(targetN)
                forceOneIfStalled()
                // Record peak concurrent workers (== min(targetN, chunkCount) at
                // fixed N) for goh top / ls.
                _ = try store.setActualConnectionCount(id: job.id, UInt8(peakWorkers))

                // Aggregate delivery-rate sampling for the governor: at each reap
                // we measure total bytes/sec across ALL connections over the
                // interval since the last reap. This is the BBR-style signal the
                // governor hill-climbs on — robust to the per-connection jitter
                // that made the old per-worker steady-state detector inert.
                var lastSampledTotal: UInt64 = 0
                var lastSampledAt = started

                while liveWorkers > 0 {
                    let freedSlot: Int?
                    do {
                        freedSlot = try await group.next()
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                    liveWorkers -= 1
                    if let s = freedSlot { availableSlots.insert(s) }

                    // Governor step (governor-on only). Measure the aggregate
                    // delivery rate over the interval since the last reap (total
                    // bytes across ALL connections), feed it to the governor, ask
                    // for a decision, and apply it to the OPERATING target N (not
                    // the just-decremented liveWorkers — the governor reasons
                    // about the intended connection count). Mutating `governor`
                    // here is safe — this is the sole synchronous mutator.
                    if governorEnabled {
                        let nowTotal = bytesWritten.value
                        let nowInstant = clock.now
                        let interval = nowInstant - lastSampledAt
                        let dSeconds = Double(interval.components.seconds)
                            + Double(interval.components.attoseconds) / 1e18
                        // Only record once the window is long enough to be a
                        // low-noise rate estimate; otherwise keep accumulating.
                        if dSeconds >= Self.minGovernorSampleSeconds {
                            let bps = Double(nowTotal - lastSampledTotal) / dSeconds
                            governor.record(aggregateBytesPerSecond: bps)
                            lastSampledTotal = nowTotal
                            lastSampledAt = nowInstant
                        }
                        let decision = governor.decide(
                            operatingN: targetN, remainingBytes: queue.remainingBytes)
                        let decisionLabel: String
                        switch decision {
                        case .hold: decisionLabel = "hold"
                        case .addWorkers(let k): targetN = min(targetN + k, 16); decisionLabel = "addWorkers(\(k))"
                        case .dropWorkers(let k): targetN = max(targetN - k, 1); decisionLabel = "dropWorkers(\(k))"
                        case .commit(let n): targetN = min(max(n, 1), 16); decisionLabel = "commit(\(n))"
                        case .backOffPinLow: targetN = 1; decisionLabel = "backOffPinLow"
                        }
                        trace.recordGovernorDecision(
                            phase: governor.phaseLabel, decision: decisionLabel,
                            currentN: targetN, hostKey: hostKey(for: job.url))
                    }

                    // Re-admit chunk(s) up to the (possibly governor-updated)
                    // target onto freed slots. When targetN dropped, this simply
                    // doesn't re-admit — running workers finish their current
                    // chunk and aren't replaced (cooperative drop, no cancel).
                    fillToTarget(targetN)
                    // No need to call forceOneIfStalled here: liveWorkers was > 0
                    // when we entered this iteration (the while condition), so
                    // after decrement it may be 0. But if it's 0 and budget denied
                    // the fill, the while condition fails and we exit. However we
                    // JUST reaped a worker whose defer released a budget slot, so
                    // another download's released slot also means budget may now be
                    // free. Re-check: if liveWorkers == 0 after fill, force one.
                    forceOneIfStalled()
                    // The governor may have grown N — re-record the peak. The
                    // store method is peak-max, so repeated calls keep the
                    // high-water mark.
                    _ = try store.setActualConnectionCount(id: job.id, UInt8(peakWorkers))
                }
            }
        } catch {
            // A failed or stopped range cancels its siblings; record the failure
            // so the assembler aborts rather than hangs.
            assembler.recordFailure(Self.mapError(error))
            _ = await assembled
            try? file.finish()
            throw error
        }

        assembler.finish()
        let rangedOutcome = await assembled                            // the ONE await
        if case .failed(let assemblerError) = rangedOutcome {
            try? file.finish()
            throw assemblerError
        }
        let fetchRangedDigest: String?
        if case .digest(let hex) = rangedOutcome {
            fetchRangedDigest = hex
        } else {
            fatalError("unreachable: ChunkAssemblerResult has only .digest/.failed")
        }
        try file.finish()
        _ = try store.recordProgress(
            id: job.id,
            Self.progress(completed: total, total: total, elapsed: clock.now - started))
        let governorOutcome = governorEnabled ? governor.outcome : .governorOff
        try complete(
            jobID: job.id, in: store,
            transferDuration: clock.now - started, isResume: false,
            sha256: fetchRangedDigest,
            governorOutcome: governorOutcome)
        trace.summary()
    }

    private func complete(
        jobID: UInt64, in store: JobStore,
        transferDuration: Duration, isResume: Bool,
        sha256: String?,                          // lowercase hex, no prefix; nil if unavailable
        governorOutcome: GovernorOutcome = .governorOff
    ) throws {
        let completed = try store.complete(id: jobID)
        completedDownloadHandler?(completed, transferDuration, isResume, sha256, governorOutcome)
    }

    /// Issues a fresh ranged `GET` for `range` and feeds its body into
    /// ``consumeRange``. Used for ranges 1..N-1; range 0 is consumed from the
    /// open-ended stream that ``download(job:store:trace:)`` already started.
    private func downloadRange(
        index: Int, range: ByteRange, url: URL, file: DownloadFile,
        assembler: ChunkAssembler, bytesWritten: ByteCounter,
        checkpointRecorder: DownloadCheckpointRecorder?,
        job: JobSummary, store: JobStore, total: UInt64,
        clock: ContinuousClock, started: ContinuousClock.Instant,
        trace: EngineDiagnostics
    ) async throws {
        var request = request(for: url, job: job)
        let last = range.start + range.length - 1
        request.setValue("bytes=\(range.start)-\(last)", forHTTPHeaderField: "Range")
        let (http, stream, cancelStream) = try await session.streamingResponse(
            for: request,
            onMetrics: { @Sendable [trace] metrics in
                trace.recordProtocol(index, networkProtocolName: metrics.networkProtocolName)
            })
        defer { cancelStream() }
        guard http.statusCode == 206 else {
            throw Self.httpFailure(statusCode: http.statusCode)
        }
        try Self.validateContentRange(http, matches: range, total: total)
        try await consumeRange(
            index: index, range: range, file: file,
            assembler: assembler, bytesWritten: bytesWritten,
            checkpointRecorder: checkpointRecorder,
            job: job, store: store, total: total,
            clock: clock, started: started, trace: trace,
            stream: stream, cancelStream: cancelStream)
    }

    /// Consumes `range`'s bytes from `stream` into `file`. Stops reading once
    /// `range.length` bytes have arrived — the speculative range 0 stream is
    /// open-ended and would otherwise spill into the next range's territory;
    /// the per-range precise streams naturally end at this boundary, so the
    /// break is benign for them.
    private func consumeRange(
        index: Int, range: ByteRange, file: DownloadFile,
        assembler: ChunkAssembler, bytesWritten: ByteCounter,
        checkpointRecorder: DownloadCheckpointRecorder?,
        job: JobSummary, store: JobStore, total: UInt64,
        clock: ContinuousClock, started: ContinuousClock.Instant,
        trace: EngineDiagnostics,
        stream: AsyncThrowingStream<Data, Error>,
        cancelStream: @escaping @Sendable () -> Void
    ) async throws {
        defer { cancelStream() }
        trace.rangeStarted(index, bytes: range.length)
        var buffer = Data()
        buffer.reserveCapacity(Self.bufferSize)
        var written: UInt64 = 0

        func flush() throws {
            guard !buffer.isEmpty else { return }
            let pieceStart = range.start + written
            let pieceLength = UInt64(buffer.count)
            try trace.timed(index, .write) {
                try file.write(buffer, at: pieceStart)
                if checkpointRecorder != nil { try file.sync() }
            }
            if let checkpointRecorder {
                try checkpointRecorder.recordCompletedPiece(
                    start: pieceStart, length: pieceLength)
            }
            written += pieceLength
            buffer.removeAll(keepingCapacity: true)
            trace.timed(index, .report) {
                assembler.complete(interval: ByteInterval(start: pieceStart, length: pieceLength))
                // Add this flush's byte delta to the shared cumulative counter;
                // `overall` is the running total across ALL workers — monotonic
                // and independent of chunk/worker count.
                let overall = bytesWritten.add(pieceLength)
                recordProgress(
                    store: store, jobID: job.id,
                    Self.progress(completed: overall, total: total,
                                  elapsed: clock.now - started))
            }
            try control?.stopIfRequested(jobID: job.id)
        }

        var firstByteSeen = false
        for try await chunk in stream {
            try Task.checkCancellation()
            if !firstByteSeen {
                firstByteSeen = true
                trace.rangeFirstByte(index)
            }
            // Truncate so we never write past this range's allotted slice.
            let alreadyHave = written + UInt64(buffer.count)
            let remaining: UInt64 =
                alreadyHave >= range.length ? 0 : range.length - alreadyHave
            let toAppend: Data =
                UInt64(chunk.count) <= remaining ? chunk : chunk.prefix(Int(remaining))
            buffer.append(toAppend)
            if buffer.count >= Self.bufferSize { try flush() }
            if written + UInt64(buffer.count) >= range.length {
                // Allotted bytes received; break so the stream's onTermination
                // cancels the in-flight task and frees the connection slot.
                break
            }
        }
        try flush()
        guard written == range.length else {
            throw GohError(
                code: .connectionFailed,
                message: "range \(index) ended after \(written) of \(range.length) expected bytes")
        }
        trace.rangeFinished(index, bytes: written)
    }

    private func makeCheckpointRecorder(
        job: JobSummary, total: UInt64, response: HTTPURLResponse
    ) -> DownloadCheckpointRecorder? {
        guard let checkpointStore else { return nil }
        let checkpoint = DownloadCheckpoint(
            jobID: job.id,
            url: job.url,
            destination: job.destination,
            partialFileSize: 0,
            totalBytes: total,
            strongETag: Self.strongETag(response),
            lastModified: Self.lastModified(response))
        return DownloadCheckpointRecorder(store: checkpointStore, checkpoint: checkpoint)
    }

    private func request(for url: URL, job: JobSummary) -> URLRequest {
        var request = URLRequest(url: url)
        if let cookieHeader = cookieHeaderProvider?(job.id, url), !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private static func progress(
        completed: UInt64, total: UInt64?, elapsed: Duration
    ) -> JobProgress {
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let rate = seconds > 0 ? UInt64(Double(completed) / seconds) : 0
        return JobProgress(bytesCompleted: completed, bytesTotal: total, bytesPerSecond: rate)
    }

    /// Maps a transport or disk error to a ``GohError``; retry eligibility is
    /// decided separately by ``retryEligible(for:)``.
    static func mapError(_ error: any Error) -> GohError {
        if let gohError = error as? GohError { return gohError }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                return GohError(code: .dnsResolutionFailed, message: urlError.localizedDescription)
            case .cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost:
                return GohError(code: .connectionFailed, message: urlError.localizedDescription)
            case .timedOut:
                return GohError(code: .timedOut, message: urlError.localizedDescription)
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid:
                return GohError(code: .tlsFailure, message: urlError.localizedDescription)
            case .unsupportedURL, .badURL:
                return GohError(code: .unsupportedURL, message: urlError.localizedDescription)
            case .cancelled:
                return GohError(code: .cancelled, message: urlError.localizedDescription)
            default:
                return GohError(code: .connectionFailed, message: urlError.localizedDescription)
            }
        }
        if let fileError = error as? DownloadFileError {
            if case .writeFailed(let code) = fileError, code == ENOSPC {
                return GohError(code: .diskFull, message: "no space on the destination volume")
            }
            return GohError(code: .destinationUnwritable, message: fileError.redactedDescription)
        }
        return GohError(code: .connectionFailed, message: "\(error)")
    }

    private static func httpFailure(statusCode: Int) -> GohError {
        let message = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        switch statusCode {
        case 401, 403:
            return GohError(code: .unauthorized, message: message)
        default:
            return GohError(
                code: .httpStatus, message: message, httpStatusCode: statusCode)
        }
    }

    /// Whether a fresh attempt could plausibly succeed — advisory (`DESIGN.md`
    /// §2.2 Retry boundary).
    static func retryEligible(for error: GohError) -> Bool {
        switch error.code {
        case .connectionFailed, .timedOut, .dnsResolutionFailed, .diskFull, .queueFull:
            return true
        case .httpStatus:
            switch error.httpStatusCode {
            case 408, 425, 429:
                return true
            case let status?:
                return status >= 500
            case nil:
                return false
            }
        case .checksumMismatch:
            return true
        case .tlsFailure, .unsupportedURL, .destinationUnwritable,
             .destinationPermissionDenied, .unauthorized, .jobNotFound,
             .protocolVersionMismatch, .cancelled, .invalidArgument,
             .symlinkComponentRefused:
            // A symlinked path component is a deterministic confinement
            // refusal — the same path will be refused again, so no retry.
            return false
        }
    }
}
