import Foundation
import Synchronization

/// A `URLProtocol` that serves canned responses, so download-engine tests need
/// no network. It answers `HEAD` capability probes and `Range` requests, so the
/// range-parallel path is exercised end-to-end. Each test stubs a unique URL;
/// stubs accumulate harmlessly across a run, so there is no shared teardown.
final class MockURLProtocol: URLProtocol {

    struct Stub: Sendable {
        var statusCode: Int = 200
        var body: Data = Data()
        var failure: URLError?
        /// Whether `HEAD` advertises `Accept-Ranges` and range requests succeed.
        var acceptsRanges: Bool = true
        /// A range request beginning at this offset fails — for failure tests.
        var failRangeStartingAt: Int?
        /// A range request beginning at this offset returns a short successful body.
        var truncateRangeStartingAt: Int?
        /// A range request beginning at this offset returns this Content-Range header.
        var contentRangeOverride: [Int: String] = [:]
        /// Extra response headers, such as ETag or Last-Modified.
        var headers: [String: String] = [:]
        /// If set, non-HEAD requests must send this Cookie header or the stub
        /// returns 401, so engine tests can verify credential attachment.
        var requiredCookieHeader: String?
        /// If set, ranged requests must send this If-Range value or the stub
        /// returns a full `200` representation, matching HTTP's resume contract.
        var requiredIfRange: String?
        /// Test-only body pacing: when set, the response body is delivered in
        /// chunks with a delay between chunks so command tests can interrupt
        /// in-flight downloads deterministically.
        var bodyChunkSize: Int?
        var bodyChunkDelayMicroseconds: useconds_t = 0
        /// Test-only: when true, a successful ranged request delivers the 206
        /// headers (with a positive Content-Length) but then finishes WITHOUT
        /// delivering any body bytes — simulating a server that returns 206 then
        /// never sends a payload byte. Exercises the diagnose no-first-byte path.
        var emptyBodyOn206: Bool = false
        /// Test-only: when true, chunk delivery uses `DispatchQueue.asyncAfter`
        /// instead of blocking the URL loading thread with `usleep`. This frees
        /// the URL loading thread immediately so it can be reused by concurrent
        /// or sequential tests. Default `false` preserves existing behaviour;
        /// set `true` for tests that cancel mid-delivery and need the thread free.
        var asyncChunkDelivery: Bool = false
    }

    private static let stubs = Mutex<[String: Stub]>([:])
    private let stopped = Mutex(false)

    /// Registers a successful response for `url`.
    static func stub(
        _ url: String, status: Int = 200, body: Data,
        acceptsRanges: Bool = true, failRangeStartingAt: Int? = nil,
        truncateRangeStartingAt: Int? = nil,
        contentRangeOverride: [Int: String] = [:],
        headers: [String: String] = [:],
        requiredCookieHeader: String? = nil,
        requiredIfRange: String? = nil,
        bodyChunkSize: Int? = nil,
        bodyChunkDelayMicroseconds: useconds_t = 0,
        emptyBodyOn206: Bool = false,
        asyncChunkDelivery: Bool = false
    ) {
        stubs.withLock {
            $0[url] = Stub(
                statusCode: status, body: body, failure: nil,
                acceptsRanges: acceptsRanges, failRangeStartingAt: failRangeStartingAt,
                truncateRangeStartingAt: truncateRangeStartingAt,
                contentRangeOverride: contentRangeOverride,
                headers: headers, requiredCookieHeader: requiredCookieHeader,
                requiredIfRange: requiredIfRange,
                bodyChunkSize: bodyChunkSize,
                bodyChunkDelayMicroseconds: bodyChunkDelayMicroseconds,
                emptyBodyOn206: emptyBodyOn206,
                asyncChunkDelivery: asyncChunkDelivery)
        }
    }

    /// Registers a transport failure for `url`.
    static func stub(_ url: String, failure: URLError) {
        stubs.withLock { $0[url] = Stub(failure: failure) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    override func startLoading() {
        guard
            let url = request.url,
            let stub = Self.stubs.withLock({ $0[url.absoluteString] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        if request.httpMethod == "HEAD" {
            deliver(url: url, status: stub.statusCode, headers: headers(for: stub), body: nil, asyncDelivery: false)
            return
        }
        if let requiredCookieHeader = stub.requiredCookieHeader,
           request.value(forHTTPHeaderField: "Cookie") != requiredCookieHeader
        {
            deliver(url: url, status: 401, headers: headers(for: stub), body: nil, asyncDelivery: false)
            return
        }
        if let header = request.value(forHTTPHeaderField: "Range"),
           let (start, end) = Self.parseRange(header),
           stub.acceptsRanges, (200..<300).contains(stub.statusCode) {
            if stub.failRangeStartingAt == start {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            if let requiredIfRange = stub.requiredIfRange,
               request.value(forHTTPHeaderField: "If-Range") != requiredIfRange
            {
                deliver(
                    url: url, status: 200, headers: headers(for: stub), body: stub.body,
                    asyncDelivery: stub.asyncChunkDelivery)
                return
            }
            guard start >= 0, start < stub.body.count, end >= start else {
                deliver(url: url, status: 416, headers: [
                    "Content-Range": "bytes */\(stub.body.count)",
                ], body: nil, asyncDelivery: false)
                return
            }
            let upper = min(end, stub.body.count - 1)
            let actualUpper = stub.truncateRangeStartingAt == start
                ? min(upper, start + max(0, (upper - start) / 2)) : upper
            let slice = Data(stub.body[start...actualUpper])
            var headers = headers(for: stub)
            headers["Content-Range"] = stub.contentRangeOverride[start]
                ?? "bytes \(start)-\(upper)/\(stub.body.count)"
            if stub.emptyBodyOn206 {
                // Deliver 206 headers (advertising a positive size) but no body bytes,
                // then finish — simulating a server that 206s then never sends a payload.
                headers["Content-Length"] = "\(slice.count)"
                deliver(url: url, status: 206, headers: headers, body: nil, asyncDelivery: false)
                return
            }
            headers["Content-Length"] = "\(slice.count)"
            deliver(url: url, status: 206, headers: headers, body: slice,
                    asyncDelivery: stub.asyncChunkDelivery)
            return
        }
        deliver(url: url, status: stub.statusCode, headers: headers(for: stub), body: stub.body,
                asyncDelivery: stub.asyncChunkDelivery)
    }

    private func headers(for stub: Stub) -> [String: String] {
        var headers = stub.headers
        headers["Content-Length"] = "\(stub.body.count)"
        if let chunkSize = stub.bodyChunkSize {
            headers["X-Goh-Test-Chunk-Size"] = "\(chunkSize)"
            headers["X-Goh-Test-Chunk-Delay-Us"] = "\(stub.bodyChunkDelayMicroseconds)"
        }
        if stub.acceptsRanges { headers["Accept-Ranges"] = "bytes" }
        return headers
    }

    private func deliver(
        url: URL, status: Int, headers: [String: String], body: Data?,
        asyncDelivery: Bool
    ) {
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body, !body.isEmpty {
            if let chunkSize = stubChunkSize(headers: headers), chunkSize > 0 {
                let delay = stubDelay(headers: headers) ?? 0
                if asyncDelivery && delay > 0 {
                    // Async delivery: schedule chunks on a background queue WITHOUT blocking
                    // the URL loading system thread. This allows the thread to return
                    // immediately so it can be reused by concurrent or sequential tests.
                    // The `stopped` flag is checked before each chunk so `stopLoading()`
                    // cancels delivery within one chunk interval.
                    deliverChunksAsync(body: body, chunkSize: chunkSize, delayMicros: delay)
                    return  // startLoading returns; delivery continues on deliveryQueue
                } else {
                    // Synchronous delivery: block the URL loading thread with usleep (original path).
                    var offset = body.startIndex
                    while offset < body.endIndex {
                        guard !isStopped else { return }
                        let end = body.index(offset, offsetBy: chunkSize, limitedBy: body.endIndex)
                            ?? body.endIndex
                        client?.urlProtocol(self, didLoad: body[offset..<end])
                        offset = end
                        if delay > 0 {
                            usleep(delay)
                        }
                    }
                }
            } else {
                guard !isStopped else { return }
                client?.urlProtocol(self, didLoad: body)
            }
        }
        guard !isStopped else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Private serial queue for async chunk delivery. Keeps the URL loading thread free.
    /// Each MockURLProtocol instance creates its own queue so concurrent requests are
    /// independent.
    private lazy var deliveryQueue = DispatchQueue(
        label: "MockURLProtocol.delivery.\(ObjectIdentifier(self))",
        qos: .default)

    /// Delivers `body` in `chunkSize`-byte pieces with `delayMicros` µs between them,
    /// running entirely on `deliveryQueue`. The URL loading thread is freed immediately.
    private func deliverChunksAsync(body: Data, chunkSize: Int, delayMicros: useconds_t) {
        let delayNanos = UInt64(delayMicros) * 1_000
        scheduleNextChunk(body: body, chunkSize: chunkSize, delayNanos: delayNanos, offset: body.startIndex)
    }

    private func scheduleNextChunk(
        body: Data,
        chunkSize: Int,
        delayNanos: UInt64,
        offset: Data.Index
    ) {
        if isStopped { return }
        if offset >= body.endIndex {
            guard !isStopped else { return }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let end = body.index(offset, offsetBy: chunkSize, limitedBy: body.endIndex) ?? body.endIndex
        guard !isStopped else { return }
        client?.urlProtocol(self, didLoad: body[offset..<end])
        let nextOffset = end
        deliveryQueue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(delayNanos)),
            execute: { [weak self] in
                self?.scheduleNextChunk(
                    body: body, chunkSize: chunkSize,
                    delayNanos: delayNanos, offset: nextOffset)
            })
    }

    private var isStopped: Bool {
        stopped.withLock { $0 }
    }

    private func stubChunkSize(headers: [String: String]) -> Int? {
        headers["X-Goh-Test-Chunk-Size"].flatMap(Int.init)
    }

    private func stubDelay(headers: [String: String]) -> useconds_t? {
        headers["X-Goh-Test-Chunk-Delay-Us"].flatMap(useconds_t.init)
    }

    /// Parses `bytes=START-END` into integer offsets. The end may be omitted
    /// (`bytes=START-`) — the speculative ranged GET sends this open-ended
    /// form — in which case it is returned as `Int.max` and clamped to the
    /// body size by the caller.
    private static func parseRange(_ header: String) -> (start: Int, end: Int)? {
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst("bytes=".count)
            .split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]) else { return nil }
        let end: Int
        if parts[1].isEmpty {
            end = Int.max
        } else if let parsed = Int(parts[1]) {
            end = parsed
        } else {
            return nil
        }
        return (start, end)
    }
}
