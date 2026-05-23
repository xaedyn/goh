import Darwin
import Foundation
import Synchronization

/// Aggregates per-range byte counts so a job's reported progress reflects every
/// connection. A reference type, so the range tasks share one instance.
private final class RangeProgress: Sendable {
    private let counts: Mutex<[UInt64]>

    init(rangeCount: Int) {
        counts = Mutex(Array(repeating: 0, count: rangeCount))
    }

    /// Records range `index`'s byte count, returning the new overall total.
    func report(index: Int, written: UInt64) -> UInt64 {
        counts.withLock { counts in
            counts[index] = written
            return counts.reduce(0, +)
        }
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

    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    /// Downloads the job with `jobID`, driving it to a terminal state. Never
    /// throws — every failure is recorded on the job as a ``GohError``.
    public func run(jobID: UInt64, in store: JobStore) async {
        guard store.job(id: jobID) != nil else { return }
        // Claim the job atomically; only proceed if this call won the claim.
        guard (try? store.start(id: jobID)) == true else { return }
        guard let job = store.job(id: jobID) else { return }
        do {
            try await download(job: job, store: store, trace: EngineDiagnostics())
        } catch let error as GohError {
            _ = try? store.fail(
                id: jobID, error: error, retryEligible: Self.retryEligible(for: error))
        } catch {
            let mapped = Self.mapError(error)
            _ = try? store.fail(
                id: jobID, error: mapped, retryEligible: Self.retryEligible(for: mapped))
        }
    }

    private func download(
        job: JobSummary, store: JobStore, trace: EngineDiagnostics
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
        var request = URLRequest(url: url)
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        let (response, stream) = try await session.streamingResponse(
            for: request,
            onMetrics: { @Sendable [trace] metrics in
                trace.recordProtocol(0, networkProtocolName: metrics.networkProtocolName)
            })
        switch response.statusCode {
        case 206:
            guard let contentRange = Self.contentRange(response),
                  contentRange.start == 0
            else {
                throw GohError(
                    code: .connectionFailed,
                    message: "the 206 response did not carry a usable Content-Range")
            }
            let total = contentRange.total
            try await fetchRanged(
                job: job, store: store, url: url, total: total,
                firstRangeStream: stream, trace: trace)
        case 200..<300:
            try await fetchSingle(
                job: job, store: store,
                initialResponse: response, initialStream: stream)
        default:
            throw GohError(
                code: .httpStatus,
                message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                httpStatusCode: response.statusCode)
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

    // MARK: Single connection

    private func fetchSingle(
        job: JobSummary, store: JobStore,
        initialResponse: HTTPURLResponse,
        initialStream: AsyncThrowingStream<Data, Error>
    ) async throws {
        guard (200..<300).contains(initialResponse.statusCode) else {
            throw GohError(
                code: .httpStatus,
                message: HTTPURLResponse.localizedString(
                    forStatusCode: initialResponse.statusCode),
                httpStatusCode: initialResponse.statusCode)
        }

        let total: UInt64? = initialResponse.expectedContentLength > 0
            ? UInt64(initialResponse.expectedContentLength) : nil
        let file = try DownloadFile(path: job.destination, expectedSize: total)
        let assembler = ChunkAssembler(
            file: file, ranges: [ByteRange(start: 0, length: total ?? UInt64.max)])
        async let assembled = assembler.hashToCompletion()

        let clock = ContinuousClock()
        let started = clock.now
        var buffer = Data()
        buffer.reserveCapacity(Self.bufferSize)
        var completed: UInt64 = 0

        func flush() throws {
            guard !buffer.isEmpty else { return }
            try file.write(buffer, at: completed)
            completed += UInt64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            assembler.advance(range: 0, writtenBytes: completed)
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
        if case .failed(let assemblerError) = await assembled {
            try? file.finish()
            throw assemblerError
        }
        try file.finish()
        _ = try store.recordProgress(
            id: job.id,
            Self.progress(completed: completed, total: total, elapsed: clock.now - started))
        _ = try store.complete(id: job.id)
    }

    // MARK: Range-parallel

    private func fetchRanged(
        job: JobSummary, store: JobStore, url: URL, total: UInt64,
        firstRangeStream: AsyncThrowingStream<Data, Error>,
        trace: EngineDiagnostics
    ) async throws {
        let ranges = ByteRange.split(
            total: total, requested: job.requestedConnectionCount, minChunk: Self.minChunk)
        _ = try store.setActualConnectionCount(id: job.id, UInt8(ranges.count))

        let file = try DownloadFile(path: job.destination, expectedSize: total)
        let assembler = ChunkAssembler(file: file, ranges: ranges)
        async let assembled = assembler.hashToCompletion()

        let progress = RangeProgress(rangeCount: ranges.count)
        let clock = ContinuousClock()
        let started = clock.now

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Range 0 reuses the open-ended stream that download() already
                // started; consumeRange truncates it at ranges[0].length.
                group.addTask {
                    try await consumeRange(
                        index: 0, range: ranges[0], file: file,
                        assembler: assembler, progress: progress,
                        job: job, store: store, total: total,
                        clock: clock, started: started, trace: trace,
                        stream: firstRangeStream)
                }
                for (index, range) in ranges.enumerated().dropFirst() {
                    group.addTask {
                        try await downloadRange(
                            index: index, range: range, url: url, file: file,
                            assembler: assembler, progress: progress,
                            job: job, store: store, total: total,
                            clock: clock, started: started, trace: trace)
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            // A failed range cancels its siblings (the group unwinds); record
            // the failure so the assembler aborts rather than hangs.
            assembler.recordFailure(Self.mapError(error))
            _ = await assembled
            try? file.finish()
            throw error
        }

        assembler.finish()
        if case .failed(let assemblerError) = await assembled {
            try? file.finish()
            throw assemblerError
        }
        try file.finish()
        _ = try store.recordProgress(
            id: job.id,
            Self.progress(completed: total, total: total, elapsed: clock.now - started))
        _ = try store.complete(id: job.id)
        trace.summary()
    }

    /// Issues a fresh ranged `GET` for `range` and feeds its body into
    /// ``consumeRange``. Used for ranges 1..N-1; range 0 is consumed from the
    /// open-ended stream that ``download(job:store:trace:)`` already started.
    private func downloadRange(
        index: Int, range: ByteRange, url: URL, file: DownloadFile,
        assembler: ChunkAssembler, progress: RangeProgress,
        job: JobSummary, store: JobStore, total: UInt64,
        clock: ContinuousClock, started: ContinuousClock.Instant,
        trace: EngineDiagnostics
    ) async throws {
        var request = URLRequest(url: url)
        let last = range.start + range.length - 1
        request.setValue("bytes=\(range.start)-\(last)", forHTTPHeaderField: "Range")
        let (http, stream) = try await session.streamingResponse(
            for: request,
            onMetrics: { @Sendable [trace] metrics in
                trace.recordProtocol(index, networkProtocolName: metrics.networkProtocolName)
            })
        guard http.statusCode == 206 else {
            throw GohError(
                code: .httpStatus,
                message: "the server did not honour the range request",
                httpStatusCode: http.statusCode)
        }
        try Self.validateContentRange(http, matches: range, total: total)
        try await consumeRange(
            index: index, range: range, file: file,
            assembler: assembler, progress: progress,
            job: job, store: store, total: total,
            clock: clock, started: started, trace: trace,
            stream: stream)
    }

    /// Consumes `range`'s bytes from `stream` into `file`. Stops reading once
    /// `range.length` bytes have arrived — the speculative range 0 stream is
    /// open-ended and would otherwise spill into the next range's territory;
    /// the per-range precise streams naturally end at this boundary, so the
    /// break is benign for them.
    private func consumeRange(
        index: Int, range: ByteRange, file: DownloadFile,
        assembler: ChunkAssembler, progress: RangeProgress,
        job: JobSummary, store: JobStore, total: UInt64,
        clock: ContinuousClock, started: ContinuousClock.Instant,
        trace: EngineDiagnostics,
        stream: AsyncThrowingStream<Data, Error>
    ) async throws {
        trace.rangeStarted(index, bytes: range.length)
        var buffer = Data()
        buffer.reserveCapacity(Self.bufferSize)
        var written: UInt64 = 0

        func flush() throws {
            guard !buffer.isEmpty else { return }
            try trace.timed(index, .write) {
                try file.write(buffer, at: range.start + written)
            }
            written += UInt64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            trace.timed(index, .report) {
                assembler.advance(range: index, writtenBytes: written)
                let overall = progress.report(index: index, written: written)
                _ = try? store.recordProgress(
                    id: job.id,
                    Self.progress(completed: overall, total: total,
                                  elapsed: clock.now - started))
            }
        }

        var firstByteSeen = false
        for try await chunk in stream {
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

    private static func progress(
        completed: UInt64, total: UInt64?, elapsed: Duration
    ) -> JobProgress {
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let rate = seconds > 0 ? UInt64(Double(completed) / seconds) : 0
        return JobProgress(bytesCompleted: completed, bytesTotal: total, bytesPerSecond: rate)
    }

    /// Maps a transport or disk error to a ``GohError``. The retry policy itself
    /// is slice 3c; this mapping is the minimum needed to record a failure.
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
            return GohError(code: .destinationUnwritable, message: "\(fileError)")
        }
        return GohError(code: .connectionFailed, message: "\(error)")
    }

    /// Whether a fresh attempt could plausibly succeed — advisory (`DESIGN.md`
    /// §2.2 Retry boundary).
    static func retryEligible(for error: GohError) -> Bool {
        switch error.code {
        case .connectionFailed, .timedOut, .dnsResolutionFailed, .diskFull, .queueFull:
            return true
        case .httpStatus:
            return (error.httpStatusCode ?? 0) >= 500
        case .tlsFailure, .unsupportedURL, .checksumMismatch, .destinationUnwritable,
             .destinationPermissionDenied, .unauthorized, .jobNotFound,
             .protocolVersionMismatch, .cancelled, .invalidArgument:
            return false
        }
    }
}
