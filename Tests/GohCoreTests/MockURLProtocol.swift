import Foundation
import Synchronization

/// A `URLProtocol` that serves canned responses, so download-engine tests need
/// no network. Each test stubs a unique URL; stubs accumulate harmlessly across
/// a run, so there is no shared teardown to race on.
final class MockURLProtocol: URLProtocol {

    struct Stub: Sendable {
        var statusCode: Int = 200
        var body: Data = Data()
        var failure: URLError?
    }

    private static let stubs = Mutex<[String: Stub]>([:])

    /// Registers a successful response for `url`.
    static func stub(_ url: String, status: Int = 200, body: Data) {
        stubs.withLock { $0[url] = Stub(statusCode: status, body: body, failure: nil) }
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
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(stub.body.count)"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
