import Foundation
import Testing

import GohCore

@Suite("Job model wire forms")
struct JobModelTests {

    private func wire<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try CommandCoding.encoder.encode(value), as: UTF8.self)
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try CommandCoding.decoder.decode(T.self, from: CommandCoding.encoder.encode(value))
    }

    @Test("JobState encodes to its frozen wire strings")
    func jobStateWire() throws {
        #expect(try wire(JobState.queued) == "\"queued\"")
        #expect(try wire(JobState.active) == "\"active\"")
        #expect(try wire(JobState.paused) == "\"paused\"")
        #expect(try wire(JobState.completed) == "\"completed\"")
        #expect(try wire(JobState.failed) == "\"failed\"")
    }

    @Test("PauseReason and Priority encode to their frozen wire strings")
    func pauseReasonAndPriorityWire() throws {
        #expect(try wire(PauseReason.user) == "\"user\"")
        #expect(try wire(PauseReason.network) == "\"network\"")
        #expect(try wire(Priority.low) == "\"low\"")
        #expect(try wire(Priority.normal) == "\"normal\"")
        #expect(try wire(Priority.high) == "\"high\"")
    }

    @Test("ErrorCode is exactly the fifteen frozen cases, in table order")
    func errorCodeCases() {
        #expect(ErrorCode.allCases.map(\.rawValue) == [
            "dnsResolutionFailed", "connectionFailed", "tlsFailure", "timedOut",
            "httpStatus", "diskFull", "destinationUnwritable",
            "destinationPermissionDenied", "checksumMismatch", "unauthorized",
            "unsupportedURL", "jobNotFound", "queueFull", "protocolVersionMismatch",
            "cancelled",
        ])
    }

    @Test("an unrecognised enum wire string is rejected, not crashed")
    func unknownEnumRejected() {
        #expect(throws: (any Error).self) {
            try CommandCoding.decoder.decode(JobState.self, from: Data("\"warped\"".utf8))
        }
    }

    @Test("GohError round-trips; httpStatusCode is omitted when absent")
    func gohErrorWire() throws {
        let bare = GohError(code: .jobNotFound)
        #expect(try roundTrip(bare) == bare)
        #expect(try wire(bare).contains("httpStatusCode") == false)

        let http = GohError(code: .httpStatus, message: "Not Found", httpStatusCode: 404)
        #expect(try roundTrip(http) == http)
        #expect(try wire(http).contains("\"httpStatusCode\":404"))
    }

    @Test("JobProgress round-trips; bytesTotal is present as null when unknown")
    func jobProgressWire() throws {
        let known = JobProgress(bytesCompleted: 512, bytesTotal: 2048, bytesPerSecond: 256)
        #expect(try roundTrip(known) == known)

        let unknown = JobProgress(bytesCompleted: 512, bytesTotal: nil, bytesPerSecond: 0)
        #expect(try roundTrip(unknown) == unknown)
        // The contract says bytesTotal is *always present*, null when unknown.
        #expect(try wire(unknown).contains("\"bytesTotal\":null"))
    }

    @Test("JobSummary round-trips with ISO-8601 dates and contract presence rules")
    func jobSummaryWire() throws {
        let queued = JobSummary(
            id: 3,
            url: "https://example.com/a.iso",
            destination: "/Users/me/Downloads/a.iso",
            state: .queued,
            progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastProgressAt: nil,
            requestedConnectionCount: 8,
            actualConnectionCount: 0)
        #expect(try roundTrip(queued) == queued)
        let queuedWire = try wire(queued)
        // createdAt is an ISO-8601 string, not a numeric timestamp.
        #expect(queuedWire.contains("\"createdAt\":\"2023-11-14T"))
        // lastProgressAt is always present, null when the job never progressed.
        #expect(queuedWire.contains("\"lastProgressAt\":null"))
        // The failed-only fields are absent on a non-failed job.
        #expect(queuedWire.contains("error") == false)
        #expect(queuedWire.contains("pauseReason") == false)
        #expect(queuedWire.contains("retryCount") == false)

        let failed = JobSummary(
            id: 4,
            url: "https://example.com/b.iso",
            destination: "/Users/me/Downloads/b.iso",
            state: .failed,
            progress: JobProgress(bytesCompleted: 100, bytesTotal: 1000, bytesPerSecond: 0),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastProgressAt: Date(timeIntervalSince1970: 1_700_000_500),
            requestedConnectionCount: 8,
            actualConnectionCount: 0,
            error: GohError(code: .timedOut, message: "timed out"),
            retryEligible: true,
            failedAt: Date(timeIntervalSince1970: 1_700_000_600),
            retryCount: 3)
        #expect(try roundTrip(failed) == failed)
        #expect(try wire(failed).contains("\"retryCount\":3"))
    }
}
