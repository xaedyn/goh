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
    }

    private static let stubs = Mutex<[String: Stub]>([:])

    /// Registers a successful response for `url`.
    static func stub(
        _ url: String, status: Int = 200, body: Data,
        acceptsRanges: Bool = true, failRangeStartingAt: Int? = nil,
        truncateRangeStartingAt: Int? = nil,
        contentRangeOverride: [Int: String] = [:]
    ) {
        stubs.withLock {
            $0[url] = Stub(
                statusCode: status, body: body, failure: nil,
                acceptsRanges: acceptsRanges, failRangeStartingAt: failRangeStartingAt,
                truncateRangeStartingAt: truncateRangeStartingAt,
                contentRangeOverride: contentRangeOverride)
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
        if let header = request.value(forHTTPHeaderField: "Range"),
           let (start, end) = Self.parseRange(header),
           stub.acceptsRanges, (200..<300).contains(stub.statusCode) {
            if stub.failRangeStartingAt == start {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            let upper = min(end, stub.body.count - 1)
            let actualUpper = stub.truncateRangeStartingAt == start
                ? min(upper, start + max(0, (upper - start) / 2)) : upper
            let slice = Data(stub.body[start...actualUpper])
            deliver(url: url, status: 206, headers: [
                "Content-Length": "\(slice.count)",
                "Content-Range": stub.contentRangeOverride[start]
                    ?? "bytes \(start)-\(upper)/\(stub.body.count)",
            ], body: slice)
            return
        }
        deliver(url: url, status: stub.statusCode, headers: headers(for: stub), body: stub.body)
    }

    private func headers(for stub: Stub) -> [String: String] {
        var headers = ["Content-Length": "\(stub.body.count)"]
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
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
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
