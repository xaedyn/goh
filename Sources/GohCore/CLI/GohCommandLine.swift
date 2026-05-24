import Foundation
import XPC

public struct GohCommandLineResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct GohCommandLine {
    public typealias Sender = (XPCDictionary) throws -> XPCDictionary

    private let arguments: [String]
    private let homeDirectory: URL
    private let send: Sender

    public init(
        arguments: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        send: @escaping Sender
    ) {
        self.arguments = arguments
        self.homeDirectory = homeDirectory
        self.send = send
    }

    public func run() -> GohCommandLineResult {
        do {
            switch try Self.parse(arguments) {
            case .help:
                return GohCommandLineResult(exitCode: 0, standardOutput: Self.usage())

            case .authImportSafari:
                let result = AuthImportSafariCommand(
                    homeDirectory: homeDirectory,
                    send: send
                ).run()
                return GohCommandLineResult(
                    exitCode: result.exitCode,
                    standardOutput: result.standardOutput,
                    standardError: result.standardError)

            case .add(let url):
                let summary: JobSummary = try sendCommand(
                    .add(request: AddRequest(url: url)),
                    expecting: JobSummary.self)
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: Self.addedMessage(summary))

            case .ls:
                let reply: LsReply = try sendCommand(.ls, expecting: LsReply.self)
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: Self.table(for: reply.jobs))

            case .pause(let jobID):
                let summary: JobSummary = try sendCommand(
                    .pause(jobID: jobID),
                    expecting: JobSummary.self)
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: "Job \(summary.id) \(summary.state.rawValue).\n")

            case .resume(let jobID):
                let summary: JobSummary = try sendCommand(
                    .resume(jobID: jobID),
                    expecting: JobSummary.self)
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: "Job \(summary.id) \(summary.state.rawValue).\n")

            case .remove(let request):
                let reply: RmReply = try sendCommand(
                    .rm(request: request),
                    expecting: RmReply.self)
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: "Removed job \(reply.removedJobID).\n")
            }
        } catch let error as ParseError {
            return GohCommandLineResult(
                exitCode: 64,
                standardError: Self.usage(error: error.message))
        } catch let error as GohCommandLineError {
            return Self.failureResult(error)
        } catch {
            return Self.transportFailure(error)
        }
    }

    private func sendCommand<Reply: Codable & Sendable>(
        _ command: Command,
        expecting _: Reply.Type
    ) throws -> Reply {
        let requestID = UUID()
        let request = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .request,
            payload: command)
            .xpcDictionary()
        let response = try send(XPCDictionary(request))

        return try response.withUnsafeUnderlyingDictionary { object in
            if let reply = try? GohEnvelope<Reply>(xpcDictionary: object),
               reply.messageType == .reply
            {
                guard reply.requestID == requestID else {
                    throw GohCommandLineError.malformedReply(
                        "daemon reply requestID did not match the request")
                }
                return reply.payload
            }

            if let error = try? GohEnvelope<GohError>(xpcDictionary: object),
               error.messageType == .error
            {
                guard error.requestID == requestID else {
                    throw GohCommandLineError.malformedReply(
                        "daemon error requestID did not match the request")
                }
                throw GohCommandLineError.daemon(error.payload)
            }

            throw GohCommandLineError.malformedReply(
                "daemon returned an unrecognized reply")
        }
    }
}

private enum ParsedCommand: Equatable {
    case help
    case authImportSafari
    case add(String)
    case ls
    case pause(UInt64)
    case resume(UInt64)
    case remove(RmRequest)
}

private struct ParseError: Error, Equatable {
    var message: String
}

private enum GohCommandLineError: Error, Equatable {
    case daemon(GohError)
    case malformedReply(String)
}

extension GohCommandLine {
    private static func parse(_ arguments: [String]) throws -> ParsedCommand {
        if arguments == ["--help"] || arguments == ["help"] {
            return .help
        }
        if arguments == ["auth", "import", "safari"] {
            return .authImportSafari
        }
        if arguments.count == 2, arguments[0] == "add" {
            return .add(arguments[1])
        }
        if arguments == ["ls"] {
            return .ls
        }
        if arguments.count == 2, arguments[0] == "pause" {
            return .pause(try parseJobID(arguments[1]))
        }
        if arguments.count == 2, arguments[0] == "resume" {
            return .resume(try parseJobID(arguments[1]))
        }
        if arguments.count == 2, arguments[0] == "rm" {
            return .remove(RmRequest(jobID: try parseJobID(arguments[1])))
        }
        if arguments.count == 3, arguments[0] == "rm", arguments[1] == "--keep" {
            return .remove(
                RmRequest(jobID: try parseJobID(arguments[2]), keepPartialFile: true))
        }
        if arguments.count == 3, arguments[0] == "rm", arguments[2] == "--keep" {
            return .remove(
                RmRequest(jobID: try parseJobID(arguments[1]), keepPartialFile: true))
        }

        throw ParseError(message: "unknown or incomplete command")
    }

    private static func parseJobID(_ raw: String) throws -> UInt64 {
        guard let id = UInt64(raw) else {
            throw ParseError(message: "job id must be an unsigned integer")
        }
        return id
    }
}

extension GohCommandLine {
    private static func addedMessage(_ summary: JobSummary) -> String {
        "Added job \(summary.id) (\(summary.state.rawValue)): \(summary.url) -> \(summary.destination)\n"
    }

    private static func table(for jobs: [JobSummary]) -> String {
        guard !jobs.isEmpty else {
            return "No downloads.\n"
        }

        let headers = ["ID", "STATE", "PROGRESS", "SPEED", "DESTINATION"]
        let rows = jobs.map { job in
            [
                "\(job.id)",
                job.state.rawValue,
                progressText(job.progress),
                "\(formatBytes(job.progress.bytesPerSecond))/s",
                job.destination,
            ]
        }
        let widths = (0..<headers.count).map { index in
            ([headers[index]] + rows.map { $0[index] })
                .map(\.count)
                .max() ?? headers[index].count
        }

        let header = padded(headers, widths: widths)
        let body = rows.map { padded($0, widths: widths) }.joined(separator: "\n")
        return "\(header)\n\(body)\n"
    }

    private static func padded(_ columns: [String], widths: [Int]) -> String {
        columns.enumerated().map { index, column in
            if index == columns.count - 1 {
                return column
            }
            return column.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }

    private static func progressText(_ progress: JobProgress) -> String {
        guard let total = progress.bytesTotal else {
            return "\(formatBytes(progress.bytesCompleted))/?"
        }
        let percent = total == 0
            ? 100
            : Int((Double(progress.bytesCompleted) / Double(total) * 100).rounded())
        return "\(formatBytes(progress.bytesCompleted))/\(formatBytes(total)) (\(percent)%)"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        guard bytes >= 1024 else {
            return "\(bytes) B"
        }

        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            return "\(Int(rounded)) \(units[unitIndex])"
        }
        return String(
            format: "%.1f %@",
            locale: Locale(identifier: "en_US_POSIX"),
            value,
            units[unitIndex])
    }
}

extension GohCommandLine {
    private static func usage(error: String? = nil) -> String {
        var text = ""
        if let error {
            text += "Error: \(error)\n\n"
        }
        text += """
        Usage:
          goh add <url>
          goh ls
          goh pause <id>
          goh resume <id>
          goh rm [--keep] <id>
          goh auth import safari

        """
        return text
    }

    private static func failureResult(_ error: GohCommandLineError) -> GohCommandLineResult {
        switch error {
        case .daemon(let daemonError):
            return GohCommandLineResult(
                exitCode: 1,
                standardError: daemonErrorMessage(daemonError))
        case .malformedReply(let message):
            return GohCommandLineResult(
                exitCode: 1,
                standardError: "gohd returned an invalid reply: \(message)\n")
        }
    }

    private static func daemonErrorMessage(_ error: GohError) -> String {
        if error.code == .protocolVersionMismatch {
            let detail = error.message?.isEmpty == false
                ? error.message!
                : error.code.rawValue
            return "gohd: \(detail)\nRestart the daemon with: brew services restart goh\n"
        }

        if let message = error.message, !message.isEmpty {
            return "gohd: \(message)\n"
        }
        return "gohd: \(error.code.rawValue)\n"
    }

    private static func transportFailure(_ error: any Error) -> GohCommandLineResult {
        GohCommandLineResult(
            exitCode: 1,
            standardError: "Could not reach gohd.\nStart the daemon with: brew services start goh\n\n\(error)\n")
    }
}
