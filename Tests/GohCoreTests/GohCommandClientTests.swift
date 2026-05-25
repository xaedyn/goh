import Foundation
import Testing
import XPC

@testable import GohCore

@Suite("GohCommandClient")
struct GohCommandClientTests {
    @Test func decodesSuccessfulReply() throws {
        let expected = JobSummary(
            id: 42,
            url: "https://example.com/file.iso",
            destination: "/tmp/file.iso",
            state: .queued,
            progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
            createdAt: Date(timeIntervalSince1970: 1),
            lastProgressAt: nil,
            requestedConnectionCount: 8,
            actualConnectionCount: 0)

        let client = GohCommandClient { request in
            let requestID = try request.withUnsafeUnderlyingDictionary { object in
                try GohEnvelope<Command>(xpcDictionary: object).requestID
            }
            let reply = try GohEnvelope(
                protocolVersion: CommandService.protocolVersion,
                requestID: requestID,
                messageType: .reply,
                payload: expected)
                .xpcDictionary()
            return XPCDictionary(reply)
        }

        let actual: JobSummary = try client.send(
            .add(request: AddRequest(url: expected.url)),
            expecting: JobSummary.self)

        #expect(actual == expected)
    }

    @Test func throwsDaemonErrorReply() throws {
        let daemonError = GohError(
            code: .protocolVersionMismatch,
            message: "client and daemon builds differ")
        let client = GohCommandClient { request in
            let requestID = try request.withUnsafeUnderlyingDictionary { object in
                try GohEnvelope<Command>(xpcDictionary: object).requestID
            }
            let reply = try GohEnvelope(
                protocolVersion: CommandService.protocolVersion,
                requestID: requestID,
                messageType: .error,
                payload: daemonError)
                .xpcDictionary()
            return XPCDictionary(reply)
        }

        #expect(throws: GohCommandClientError.daemon(daemonError)) {
            let _: LsReply = try client.send(.ls, expecting: LsReply.self)
        }
    }

    @Test func rejectsMismatchedRequestID() throws {
        let client = GohCommandClient { _ in
            let reply = try GohEnvelope(
                protocolVersion: CommandService.protocolVersion,
                requestID: UUID(),
                messageType: .reply,
                payload: LsReply(jobs: []))
                .xpcDictionary()
            return XPCDictionary(reply)
        }

        #expect(throws: GohCommandClientError.malformedReply("daemon reply requestID did not match the request")) {
            let _: LsReply = try client.send(.ls, expecting: LsReply.self)
        }
    }
}
