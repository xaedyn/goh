import Darwin
import Foundation

/// Runs a single-connection HTTP download (`DESIGN.md` §Transport).
///
/// Given a queued job, the engine marks it `active`, fetches the URL over
/// `URLSession`, streams the body into a ``DownloadFile``, reports progress, and
/// drives the job to `completed` or `failed`. Single-connection in this slice;
/// range-parallel orchestration is slice 3b.
public struct DownloadEngine: Sendable {

    /// The buffer-flush granularity — bytes accumulate to here before a write.
    private static let bufferSize = 1 << 16

    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    /// Downloads the job with `jobID`, driving it to a terminal state. Never
    /// throws — every failure is recorded on the job as a ``GohError``.
    public func run(jobID: UInt64, in store: JobStore) async {
        guard let job = store.job(id: jobID) else { return }
        // start() is a no-op unless the job is queued; only proceed if it took.
        guard (try? store.start(id: jobID))?.state == .active else { return }
        do {
            try await fetch(job: job, store: store)
        } catch let error as GohError {
            _ = try? store.fail(
                id: jobID, error: error, retryEligible: Self.retryEligible(for: error))
        } catch {
            let mapped = Self.mapError(error)
            _ = try? store.fail(
                id: jobID, error: mapped, retryEligible: Self.retryEligible(for: mapped))
        }
    }

    private func fetch(job: JobSummary, store: JobStore) async throws {
        guard let url = URL(string: job.url) else {
            throw GohError(code: .unsupportedURL, message: "could not parse URL: \(job.url)")
        }
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
        let clock = ContinuousClock()
        let started = clock.now

        var buffer = Data()
        buffer.reserveCapacity(Self.bufferSize)
        var completed: UInt64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= Self.bufferSize {
                try file.append(buffer)
                completed += UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                _ = try store.recordProgress(
                    id: job.id,
                    Self.progress(completed: completed, total: total,
                                  elapsed: clock.now - started))
            }
        }
        if !buffer.isEmpty {
            try file.append(buffer)
            completed += UInt64(buffer.count)
        }
        // 3a computes the SHA-256; it has no JobSummary field yet (see the PR).
        _ = try file.finalize()
        _ = try store.recordProgress(
            id: job.id,
            Self.progress(completed: completed, total: total, elapsed: clock.now - started))
        _ = try store.complete(id: job.id)
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
    /// is slice 3c; this mapping is the minimum 3a needs to record a failure.
    static func mapError(_ error: any Error) -> GohError {
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
