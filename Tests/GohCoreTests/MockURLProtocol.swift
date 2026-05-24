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
    }

    private static let stubs = Mutex<[String: Stub]>([:])

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
        bodyChunkDelayMicroseconds: useconds_t = 0
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
                bodyChunkDelayMicroseconds: bodyChunkDelayMicroseconds)
        }
    }

    /// Registers a transport failure for `url`.
    static func stub(_ url: String, failure: URLError) {
        stubs.withLock { $0[url] = Stub(failure: failure) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

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
            deliver(url: url, status: stub.statusCode, headers: headers(for: stub), body: nil)
            return
        }
        if let requiredCookieHeader = stub.requiredCookieHeader,
           request.value(forHTTPHeaderField: "Cookie") != requiredCookieHeader
        {
            deliver(url: url, status: 401, headers: headers(for: stub), body: nil)
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
                    url: url, status: 200, headers: headers(for: stub), body: stub.body)
                return
            }
            guard start >= 0, start < stub.body.count, end >= start else {
                deliver(url: url, status: 416, headers: [
                    "Content-Range": "bytes */\(stub.body.count)",
                ], body: nil)
                return
            }
            let upper = min(end, stub.body.count - 1)
            let actualUpper = stub.truncateRangeStartingAt == start
                ? min(upper, start + max(0, (upper - start) / 2)) : upper
            let slice = Data(stub.body[start...actualUpper])
            var headers = headers(for: stub)
            headers["Content-Length"] = "\(slice.count)"
            headers["Content-Range"] = stub.contentRangeOverride[start]
                ?? "bytes \(start)-\(upper)/\(stub.body.count)"
            deliver(url: url, status: 206, headers: headers, body: slice)
            return
        }
        deliver(url: url, status: stub.statusCode, headers: headers(for: stub), body: stub.body)
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

    private func deliver(url: URL, status: Int, headers: [String: String], body: Data?) {
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body, !body.isEmpty {
            if let chunkSize = stubChunkSize(headers: headers), chunkSize > 0 {
                var offset = body.startIndex
                while offset < body.endIndex {
                    let end = body.index(offset, offsetBy: chunkSize, limitedBy: body.endIndex)
                        ?? body.endIndex
                    client?.urlProtocol(self, didLoad: body[offset..<end])
                    offset = end
                    if let delay = stubDelay(headers: headers), delay > 0 {
                        usleep(delay)
                    }
                }
            } else {
                client?.urlProtocol(self, didLoad: body)
            }
        }
        client?.urlProtocolDidFinishLoading(self)
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
