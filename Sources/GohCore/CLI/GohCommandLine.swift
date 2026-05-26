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
    public typealias Foreground = (AddRequest) throws -> GohCommandLineResult
    public typealias Top = () throws -> GohCommandLineResult
    public typealias Doctor = () throws -> GohCommandLineResult

    private let arguments: [String]
    private let homeDirectory: URL
    private let foreground: Foreground?
    private let top: Top?
    private let doctor: Doctor?
    private let send: Sender

    public init(
        arguments: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        foreground: Foreground? = nil,
        top: Top? = nil,
        doctor: Doctor? = nil,
        send: @escaping Sender
    ) {
        self.arguments = arguments
        self.homeDirectory = homeDirectory
        self.foreground = foreground
        self.top = top
        self.doctor = doctor
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

            case .add(let request):
                let summary: JobSummary = try sendCommand(
                    .add(request: request),
                    expecting: JobSummary.self)
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: Self.addedMessage(summary))

            case .foreground(let request):
                guard let foreground else {
                    return GohCommandLineResult(
                        exitCode: 1,
                        standardError: "Foreground downloads are not configured.\n")
                }
                return try foreground(request)

            case .top:
                guard let top else {
                    return GohCommandLineResult(
                        exitCode: 1,
                        standardError: "The top dashboard is not configured.\n")
                }
                return try top()

            case .doctor:
                guard let doctor else {
                    return GohCommandLineResult(
                        exitCode: 1,
                        standardError: "The doctor diagnostic is not configured.\n")
                }
                return try doctor()

            case .ls(.table):
                let reply: LsReply = try sendCommand(.ls, expecting: LsReply.self)
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: Self.table(for: reply.jobs))

            case .ls(.json):
                let reply: LsReply = try sendCommand(.ls, expecting: LsReply.self)
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: try Self.json(reply))

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

        switch response.decodeGohReply(as: Reply.self) {
        case .reply(let id, let payload):
            guard id == requestID else {
                throw GohCommandLineError.malformedReply(
                    "daemon reply requestID did not match the request")
            }
            return payload
        case .daemonError(let id, let error):
            guard id == requestID else {
                throw GohCommandLineError.malformedReply(
                    "daemon error requestID did not match the request")
            }
            throw GohCommandLineError.daemon(error)
        case .malformed:
            throw GohCommandLineError.malformedReply(
                "daemon returned an unrecognized reply")
        }
    }
}

private enum ParsedCommand: Equatable {
    case help
    case authImportSafari
    case add(AddRequest)
    case foreground(AddRequest)
    case top
    case doctor
    case ls(OutputFormat)
    case pause(UInt64)
    case resume(UInt64)
    case remove(RmRequest)
}

private enum OutputFormat: Equatable {
    case table
    case json
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
        if arguments.first == "add" {
            return .add(try parseAdd(Array(arguments.dropFirst())))
        }
        if arguments == ["ls"] {
            return .ls(.table)
        }
        if arguments == ["ls", "--json"] {
            return .ls(.json)
        }
        if arguments == ["top"] {
            return .top
        }
        if arguments == ["doctor"] {
            return .doctor
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
        if arguments.count == 1, let url = arguments.first, !url.hasPrefix("-") {
            return .foreground(AddRequest(url: url))
        }

        throw ParseError(message: "unknown or incomplete command")
    }

    private static func parseAdd(_ arguments: [String]) throws -> AddRequest {
        var url: String?
        var destination: String?
        var connectionCount: UInt8?
        var useImportedCookies: Bool?
        var priority: Priority?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--output", "-o":
                destination = try value(after: argument, in: arguments, at: &index)
            case "--connections":
                let raw = try value(after: argument, in: arguments, at: &index)
                guard let parsed = UInt8(raw), (1...16).contains(parsed) else {
                    throw ParseError(message: "connections must be an integer from 1 to 16")
                }
                connectionCount = parsed
            case "--priority":
                let raw = try value(after: argument, in: arguments, at: &index)
                guard let parsed = Priority(rawValue: raw) else {
                    throw ParseError(message: "priority must be low, normal, or high")
                }
                priority = parsed
            case "--no-cookies":
                useImportedCookies = false
                index += 1
            default:
                guard !argument.hasPrefix("-") else {
                    throw ParseError(message: "unknown add option \(argument)")
                }
                guard url == nil else {
                    throw ParseError(message: "add accepts exactly one URL")
                }
                url = argument
                index += 1
            }
        }

        guard let url else {
            throw ParseError(message: "add requires a URL")
        }
        return AddRequest(
            url: url,
            destination: destination,
            connectionCount: connectionCount,
            useImportedCookies: useImportedCookies,
            priority: priority)
    }

    private static func value(
        after option: String,
        in arguments: [String],
        at index: inout Int
    ) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw ParseError(message: "\(option) requires a value")
        }
        index += 2
        return arguments[valueIndex]
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

    private static func json<Payload: Encodable>(_ payload: Payload) throws -> String {
        let data: Data
        do {
            data = try CommandCoding.encoder.encode(payload)
        } catch {
            throw GohCommandLineError.malformedReply(
                "failed to encode JSON output: \(error)")
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

extension GohCommandLine {
    private static func usage(error: String? = nil) -> String {
        var text = ""
        if let error {
            text += "Error: \(error)\n\n"
        }
        text += "Get over here!\n\n"
        text += """
        Usage:
          goh <url>
          goh add [--output <path>] [--connections <1-16>] [--priority low|normal|high] [--no-cookies] <url>
          goh ls [--json]
          goh top
          goh doctor
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
