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
/// The engine claims a queued job, probes whether the server supports range
/// requests, and either splits the file across N concurrent connections or
/// downloads it over one. Either way it streams bytes into a ``DownloadFile``,
/// hashes through a ``ChunkAssembler``, reports progress, and drives the job to
/// `completed` or `failed`.
public struct DownloadEngine: Sendable {

    /// The buffer-flush granularity — bytes accumulate to here before a write.
    private static let bufferSize = 1 << 16

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

    private enum ProbeOutcome {
        case ranged(total: UInt64)
        case single
    }

    private func download(
        job: JobSummary, store: JobStore, trace: EngineDiagnostics
    ) async throws {
        guard let url = URL(string: job.url) else {
            throw GohError(code: .unsupportedURL, message: "could not parse URL: \(job.url)")
        }
        switch await probe(url) {
        case .ranged(let total):
            try await fetchRanged(
                job: job, store: store, url: url, total: total, trace: trace)
        case .single:
            // The single-connection fallback is untouched in this round; the
            // diagnostics target the range-parallel path the benchmarks hit.
            try await fetchSingle(job: job, store: store, url: url)
        }
    }

    /// A `HEAD` capability probe. Anything inconclusive — a non-2xx status, no
    /// `Accept-Ranges: bytes`, no `Content-Length` — falls back to a single
    /// connection; the real download then surfaces any genuine error.
    private func probe(_ url: URL) async -> ProbeOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard
            let (_, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "")
                .lowercased().contains("bytes"),
            http.expectedContentLength > 0
        else {
            return .single
        }
        return .ranged(total: UInt64(http.expectedContentLength))
    }

    // MARK: Single connection

    private func fetchSingle(job: JobSummary, store: JobStore, url: URL) async throws {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw GohError(code: .connectionFailed, message: "the response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GohError(
                code: .httpStatus,
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                httpStatusCode: http.statusCode)
        }

        let total: UInt64? = http.expectedContentLength > 0
            ? UInt64(http.expectedContentLength) : nil
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
            for try await byte in bytes {
                buffer.append(byte)
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
                for (index, range) in ranges.enumerated() {
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

    private func downloadRange(
        index: Int, range: ByteRange, url: URL, file: DownloadFile,
        assembler: ChunkAssembler, progress: RangeProgress,
        job: JobSummary, store: JobStore, total: UInt64,
        clock: ContinuousClock, started: ContinuousClock.Instant,
        trace: EngineDiagnostics
    ) async throws {
        trace.rangeStarted(index, bytes: range.length)
        var request = URLRequest(url: url)
        let last = range.start + range.length - 1
        request.setValue("bytes=\(range.start)-\(last)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GohError(code: .connectionFailed, message: "the response was not HTTP")
        }
        guard http.statusCode == 206 else {
            throw GohError(
                code: .httpStatus,
                message: "the server did not honour the range request",
                httpStatusCode: http.statusCode)
        }

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
                    Self.progress(completed: overall, total: total, elapsed: clock.now - started))
            }
        }

        var firstByteSeen = false
        for try await byte in bytes {
            if !firstByteSeen {
                firstByteSeen = true
                trace.rangeFirstByte(index)
            }
            buffer.append(byte)
            if buffer.count >= Self.bufferSize { try flush() }
        }
        try flush()
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
