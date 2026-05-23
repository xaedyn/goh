import Foundation
import Synchronization

extension URLSession {

    /// Issues `request` and returns the HTTP response together with an
    /// `AsyncThrowingStream<Data, Error>` that yields the response body's
    /// `Data` chunks as `URLSession` delivers them.
    ///
    /// Unlike `URLSession.bytes(for:)`, which exposes the body as an
    /// `AsyncSequence<UInt8>` (one async iteration per *byte* — a notorious
    /// performance trap on multi-MiB responses, since every byte pays full
    /// async/await machinery cost), this routes `URLSession`'s delegate
    /// `urlSession(_:dataTask:didReceive data:)` callbacks straight into the
    /// stream. The caller pays one suspension per *network read* — typically
    /// 16-64 KiB or larger — not per byte.
    ///
    /// The returned response is the *final* response — `URLSession` follows
    /// redirects automatically. The stream finishes when the body is complete,
    /// or throws on transport failure. Cancelling the consuming task cancels
    /// the underlying data task.
    func streamingResponse(
        for request: URLRequest,
        onMetrics: (@Sendable (URLSessionTaskTransactionMetrics) -> Void)? = nil
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error>(
            bufferingPolicy: .unbounded
        ) { continuation in
            streamContinuation = continuation
        }

        let response = try await withCheckedThrowingContinuation {
            (responseContinuation: CheckedContinuation<HTTPURLResponse, Error>) in
            let delegate = StreamingDataTaskDelegate(
                onResponse: responseContinuation,
                onChunk: streamContinuation,
                onMetrics: onMetrics)
            let task = self.dataTask(with: request)
            task.delegate = delegate
            streamContinuation.onTermination = { @Sendable [weak task] _ in
                task?.cancel()
            }
            task.resume()
        }
        return (response, stream)
    }
}

/// Bridges `URLSession` delegate callbacks to async/await: resolves the
/// response continuation when the response headers arrive, then forwards each
/// `Data` chunk to the stream continuation. Held alive by the data task while
/// the task is running; released when the task completes.
private final class StreamingDataTaskDelegate:
    NSObject, URLSessionDataDelegate, @unchecked Sendable
{
    private struct State: Sendable {
        var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    }

    private let state: Mutex<State>
    private let streamContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let onMetrics: (@Sendable (URLSessionTaskTransactionMetrics) -> Void)?

    init(
        onResponse: CheckedContinuation<HTTPURLResponse, Error>,
        onChunk: AsyncThrowingStream<Data, Error>.Continuation,
        onMetrics: (@Sendable (URLSessionTaskTransactionMetrics) -> Void)?
    ) {
        self.state = Mutex(State(responseContinuation: onResponse))
        self.streamContinuation = onChunk
        self.onMetrics = onMetrics
        super.init()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let cont = state.withLock { state -> CheckedContinuation<HTTPURLResponse, Error>? in
            let captured = state.responseContinuation
            state.responseContinuation = nil
            return captured
        }
        if let cont {
            if let http = response as? HTTPURLResponse {
                cont.resume(returning: http)
            } else {
                cont.resume(throwing: URLError(.badServerResponse))
            }
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        streamContinuation.yield(data)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        let responseCont = state.withLock { state -> CheckedContinuation<HTTPURLResponse, Error>? in
            let captured = state.responseContinuation
            state.responseContinuation = nil
            return captured
        }
        if let error {
            responseCont?.resume(throwing: error)
            streamContinuation.finish(throwing: error)
        } else {
            streamContinuation.finish()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        // Multiple transactionMetrics on redirects; the last is the response
        // that actually delivered the body.
        guard let callback = onMetrics,
              let final = metrics.transactionMetrics.last
        else { return }
        callback(final)
    }
}
