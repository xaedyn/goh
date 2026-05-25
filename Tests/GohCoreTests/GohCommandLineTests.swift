import Foundation
import Testing
import XPC

import GohCore

@Suite("goh CLI command runner")
struct GohCommandLineTests {

    @Test("help shows the product catchphrase")
    func helpShowsCatchphrase() {
        let result = GohCommandLine(arguments: ["--help"]) { _ in
            throw TestTransportError()
        }.run()

        #expect(result.exitCode == 0)
        #expect(result.standardOutput.hasPrefix("Get over here!\n\nUsage:\n"))
        #expect(result.standardError == "")
    }

    @Test("add sends an add request and prints the queued job")
    func addSendsRequestAndPrintsQueuedJob() throws {
        let job = Self.makeJob(
            id: 42,
            url: "https://example.com/file.zip",
            destination: "/tmp/file.zip",
            state: .queued)
        var captured: Command?

        let result = GohCommandLine(arguments: ["add", "https://example.com/file.zip"]) { request in
            try request.withUnsafeUnderlyingDictionary { object in
                let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                captured = envelope.payload
                #expect(envelope.protocolVersion == CommandService.protocolVersion)
                #expect(envelope.messageType == .request)
                return try Self.reply(to: envelope, payload: job)
            }
        }.run()

        #expect(captured == .add(request: AddRequest(url: "https://example.com/file.zip")))
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "Added job 42 (queued): https://example.com/file.zip -> /tmp/file.zip\n")
        #expect(result.standardError == "")
    }

    @Test("bare URL runs the foreground download flow")
    func bareURLRunsForegroundDownloadFlow() {
        var captured: AddRequest?
        var oneShotSendCount = 0

        let result = GohCommandLine(
            arguments: ["https://example.com/file.zip"],
            foreground: { request in
                captured = request
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: "foreground flow\n")
            },
            send: { _ in
                oneShotSendCount += 1
                throw TestTransportError()
            }
        ).run()

        #expect(captured == AddRequest(url: "https://example.com/file.zip"))
        #expect(oneShotSendCount == 0)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "foreground flow\n")
        #expect(result.standardError == "")
    }

    @Test("top runs the live dashboard flow")
    func topRunsLiveDashboardFlow() {
        var topRunCount = 0
        var oneShotSendCount = 0

        let result = GohCommandLine(
            arguments: ["top"],
            top: {
                topRunCount += 1
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: "top flow\n")
            },
            send: { _ in
                oneShotSendCount += 1
                throw TestTransportError()
            }
        ).run()

        #expect(topRunCount == 1)
        #expect(oneShotSendCount == 0)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "top flow\n")
        #expect(result.standardError == "")
    }

    @Test("doctor runs the diagnostic flow without sending a one-shot command")
    func doctorRunsDiagnosticFlow() {
        var doctorRunCount = 0
        var oneShotSendCount = 0

        let result = GohCommandLine(
            arguments: ["doctor"],
            doctor: {
                doctorRunCount += 1
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: "doctor flow\n")
            },
            send: { _ in
                oneShotSendCount += 1
                throw TestTransportError()
            }
        ).run()

        #expect(doctorRunCount == 1)
        #expect(oneShotSendCount == 0)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "doctor flow\n")
        #expect(result.standardError == "")
    }

    @Test("add options populate the full add request")
    func addOptionsPopulateFullRequest() throws {
        let job = Self.makeJob(
            id: 43,
            url: "https://example.com/private.zip",
            destination: "/tmp/private.zip",
            state: .queued)
        var captured: Command?

        let result = GohCommandLine(arguments: [
            "add",
            "--output", "/tmp/private.zip",
            "--connections", "12",
            "--priority", "high",
            "--no-cookies",
            "https://example.com/private.zip",
        ]) { request in
            try request.withUnsafeUnderlyingDictionary { object in
                let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                captured = envelope.payload
                return try Self.reply(to: envelope, payload: job)
            }
        }.run()

        #expect(captured == .add(request: AddRequest(
            url: "https://example.com/private.zip",
            destination: "/tmp/private.zip",
            connectionCount: 12,
            useImportedCookies: false,
            priority: .high)))
        #expect(result.exitCode == 0)
        #expect(result.standardError == "")
    }

    @Test("ls sends an ls request and formats the job table")
    func lsFormatsJobTable() throws {
        let job = Self.makeJob(
            id: 7,
            url: "https://example.com/archive.tar",
            destination: "/tmp/archive.tar",
            state: .active,
            progress: JobProgress(
                bytesCompleted: 512,
                bytesTotal: 1024,
                bytesPerSecond: 2048),
            actualConnectionCount: 4)
        var captured: Command?

        let result = GohCommandLine(arguments: ["ls"]) { request in
            try request.withUnsafeUnderlyingDictionary { object in
                let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                captured = envelope.payload
                return try Self.reply(to: envelope, payload: LsReply(jobs: [job]))
            }
        }.run()

        #expect(captured == .ls)
        #expect(result.exitCode == 0)
        let lines = result.standardOutput.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first?.contains("ID") == true)
        #expect(lines.first?.contains("STATE") == true)
        #expect(lines.first?.contains("PROGRESS") == true)
        #expect(lines.first?.contains("SPEED") == true)
        #expect(result.standardOutput.contains("7"))
        #expect(result.standardOutput.contains("active"))
        #expect(result.standardOutput.contains("512 B/1 KB (50%)"))
        #expect(result.standardOutput.contains("2 KB/s"))
        #expect(result.standardOutput.contains("/tmp/archive.tar"))
        #expect(result.standardError == "")
    }

    @Test("ls json emits the existing LsReply shape")
    func lsJSONEmitsReplyShape() throws {
        let job = Self.makeJob(
            id: 8,
            url: "https://example.com/data.bin",
            destination: "/tmp/data.bin",
            state: .completed,
            progress: JobProgress(
                bytesCompleted: 4096,
                bytesTotal: 4096,
                bytesPerSecond: 0),
            actualConnectionCount: 4)

        let result = GohCommandLine(arguments: ["ls", "--json"]) { request in
            try request.withUnsafeUnderlyingDictionary { object in
                let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                #expect(envelope.payload == .ls)
                return try Self.reply(to: envelope, payload: LsReply(jobs: [job]))
            }
        }.run()

        let decoded = try CommandCoding.decoder.decode(
            LsReply.self,
            from: Data(result.standardOutput.utf8))
        #expect(decoded == LsReply(jobs: [job]))
        #expect(result.standardOutput.hasSuffix("\n"))
        #expect(result.standardError == "")
    }

    @Test("pause resume and rm send typed job-control commands")
    func jobControlCommandsSendTypedRequests() throws {
        let scenarios: [(arguments: [String], expected: Command, output: String)] = [
            (
                ["pause", "5"],
                .pause(jobID: 5),
                "Job 5 paused.\n"
            ),
            (
                ["resume", "6"],
                .resume(jobID: 6),
                "Job 6 queued.\n"
            ),
            (
                ["rm", "--keep", "7"],
                .rm(request: RmRequest(jobID: 7, keepPartialFile: true)),
                "Removed job 7.\n"
            ),
        ]

        for scenario in scenarios {
            var captured: Command?
            let result = GohCommandLine(arguments: scenario.arguments) { request in
                try request.withUnsafeUnderlyingDictionary { object in
                    let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                    captured = envelope.payload
                    switch scenario.expected {
                    case .pause:
                        return try Self.reply(
                            to: envelope,
                            payload: Self.makeJob(id: 5, state: .paused, pauseReason: .user))
                    case .resume:
                        return try Self.reply(
                            to: envelope,
                            payload: Self.makeJob(id: 6, state: .queued))
                    case .rm:
                        return try Self.reply(to: envelope, payload: RmReply(removedJobID: 7))
                    default:
                        Issue.record("unexpected scenario command")
                        return try Self.reply(
                            to: envelope,
                            payload: GohError(code: .invalidArgument),
                            messageType: .error)
                    }
                }
            }.run()

            #expect(captured == scenario.expected)
            #expect(result.exitCode == 0)
            #expect(result.standardOutput == scenario.output)
            #expect(result.standardError == "")
        }
    }

    @Test("invalid job IDs fail locally without sending XPC")
    func invalidJobIDFailsBeforeSending() {
        var sendCount = 0

        let result = GohCommandLine(arguments: ["pause", "not-a-number"]) { _ in
            sendCount += 1
            throw TestTransportError()
        }.run()

        #expect(sendCount == 0)
        #expect(result.exitCode == 64)
        #expect(result.standardOutput == "")
        #expect(result.standardError.contains("Usage:"))
        #expect(result.standardError.contains("job id must be an unsigned integer"))
    }

    @Test("daemon error replies are formatted as command failures")
    func daemonErrorsAreFormatted() throws {
        let result = GohCommandLine(arguments: ["pause", "99"]) { request in
            try request.withUnsafeUnderlyingDictionary { object in
                let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                return try Self.reply(
                    to: envelope,
                    payload: GohError(code: .jobNotFound, message: "no job 99"),
                    messageType: .error)
            }
        }.run()

        #expect(result.exitCode == 1)
        #expect(result.standardOutput == "")
        #expect(result.standardError == "gohd: no job 99\n")
    }

    @Test("transport failures show first-run daemon guidance")
    func transportFailuresShowDaemonGuidance() {
        let result = GohCommandLine(arguments: ["ls"]) { _ in
            throw TestTransportError()
        }.run()

        #expect(result.exitCode == 1)
        #expect(result.standardOutput == "")
        #expect(result.standardError.contains("Could not reach gohd."))
        #expect(result.standardError.contains("brew services start goh"))
        #expect(result.standardError.contains("test transport failure"))
        #expect(result.standardError.hasSuffix("\n"))
    }

    private static func makeJob(
        id: UInt64,
        url: String = "https://example.com/file",
        destination: String = "/tmp/file",
        state: JobState = .queued,
        progress: JobProgress = JobProgress(
            bytesCompleted: 0,
            bytesTotal: nil,
            bytesPerSecond: 0),
        actualConnectionCount: UInt8 = 0,
        pauseReason: PauseReason? = nil
    ) -> JobSummary {
        JobSummary(
            id: id,
            url: url,
            destination: destination,
            state: state,
            progress: progress,
            createdAt: Date(timeIntervalSince1970: 0),
            lastProgressAt: nil,
            requestedConnectionCount: 8,
            actualConnectionCount: actualConnectionCount,
            pauseReason: pauseReason)
    }

    private static func reply<Payload: Codable & Sendable>(
        to envelope: GohEnvelope<Command>,
        payload: Payload,
        messageType: MessageType = .reply
    ) throws -> XPCDictionary {
        try XPCDictionary(GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: envelope.requestID,
            messageType: messageType,
            payload: payload)
            .xpcDictionary())
    }

    private struct TestTransportError: Error, CustomStringConvertible {
        var description: String { "test transport failure" }
    }
}
