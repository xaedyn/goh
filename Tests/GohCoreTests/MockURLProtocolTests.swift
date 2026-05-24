import Foundation
import Testing

@testable import GohCore

@Suite("Mock URL protocol")
struct MockURLProtocolTests {

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("an out-of-bounds range returns 416 instead of trapping")
    func outOfBoundsRangeReturns416() async throws {
        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data([0xaa, 0xbb, 0xcc])
        MockURLProtocol.stub(url, body: payload)

        var request = URLRequest(url: try #require(URL(string: url)))
        request.setValue("bytes=9-12", forHTTPHeaderField: "Range")
        let (response, stream) = try await mockSession().streamingResponse(for: request)

        var body = Data()
        for try await chunk in stream {
            body.append(chunk)
        }

        #expect(response.statusCode == 416)
        #expect(response.value(forHTTPHeaderField: "Content-Range") == "bytes */\(payload.count)")
        #expect(body.isEmpty)
    }
}
