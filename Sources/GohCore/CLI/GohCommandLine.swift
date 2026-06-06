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

extension GohCommandLineResult {
    /// Emits `value` as a JSON line with `successExitCode`, or **fails closed**
    /// with exit 6 and `failureMessage` on stderr when encoding throws.
    ///
    /// Security-critical verify commands must never emit blank stdout alongside a
    /// success exit code on an encode failure — otherwise
    /// `goh verify-attestation --json && deploy` could deploy on a swallowed
    /// error. Routing those commands through this helper guarantees the
    /// fail-closed contract (audit `docs/security-audit-2026-06.md` finding H3).
    /// The `encode` seam defaults to the shared `CommandCoding.encoder`; tests
    /// inject a throwing closure to exercise the failure path.
    public static func jsonOrFailClosed<Value: Encodable>(
        _ value: Value,
        successExitCode: Int32,
        failureMessage: String,
        encode: (Value) throws -> Data = { try CommandCoding.encoder.encode($0) }
    ) -> GohCommandLineResult {
        do {
            let data = try encode(value)
            return GohCommandLineResult(
                exitCode: successExitCode,
                standardOutput: String(decoding: data, as: UTF8.self) + "\n")
        } catch {
            return GohCommandLineResult(exitCode: 6, standardError: failureMessage)
        }
    }
}

public struct GohCommandLine {
    public typealias Sender = (XPCDictionary) throws -> XPCDictionary
    public typealias Foreground = (AddRequest) throws -> GohCommandLineResult
    public typealias Top = () throws -> GohCommandLineResult
    public typealias Doctor = () throws -> GohCommandLineResult
    public typealias Diagnose = (_ url: String, _ full: Bool, _ json: Bool, _ connections: Int?) throws -> GohCommandLineResult
    public typealias ProvenanceStorePathResolver = () -> String?

    /// Resolves the attest key store locations (handle + keys.json URLs).
    /// Returns nil if the directory cannot be resolved (treated as "use default").
    public typealias AttestKeyLocationResolver = () -> (handleURL: URL, keysJSONURL: URL)?

    /// Test-only injection seam for the attest signer. PRODUCTION DEFAULT IS NIL (no override).
    /// When nil, the real SE signer is used via SecureEnclaveSigner.createOrOpen.
    /// Must NEVER be used as a production software-key fallback — that defeats hardware attestation.
    public typealias AttestSignerResolver = () -> GohAttestCommand.SignerOverride?

    private let arguments: [String]
    private let homeDirectory: URL
    private let foreground: Foreground?
    private let top: Top?
    private let doctor: Doctor?
    private let diagnose: Diagnose?
    private let provenanceStorePathResolver: ProvenanceStorePathResolver
    private let attestKeyLocationResolver: AttestKeyLocationResolver
    private let attestSignerResolver: AttestSignerResolver
    private let send: Sender

    public init(
        arguments: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        foreground: Foreground? = nil,
        top: Top? = nil,
        doctor: Doctor? = nil,
        diagnose: Diagnose? = nil,
        provenanceStorePathResolver: @escaping ProvenanceStorePathResolver = {
            try? ProvenanceStoreLocation.defaultURL(create: false).path
        },
        // attestKeyLocationResolver and attestSignerResolver MUST be placed BEFORE send:
        // so that main.swift's trailing-closure call site (send: as trailing closure) compiles.
        attestKeyLocationResolver: @escaping AttestKeyLocationResolver = {
            guard let handleURL = try? AttestKeyLocation.signingKeyHandleURL(create: false),
                  let keysURL = try? AttestKeyLocation.keysJSONURL(create: false) else { return nil }
            return (handleURL, keysURL)
        },
        attestSignerResolver: @escaping AttestSignerResolver = { nil },
        send: @escaping Sender
    ) {
        self.arguments = arguments
        self.homeDirectory = homeDirectory
        self.foreground = foreground
        self.top = top
        self.doctor = doctor
        self.diagnose = diagnose
        self.provenanceStorePathResolver = provenanceStorePathResolver
        self.attestKeyLocationResolver = attestKeyLocationResolver
        self.attestSignerResolver = attestSignerResolver
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

            case .diagnose(let url, let full, let json, let connections):
                guard let diagnose else {
                    return GohCommandLineResult(
                        exitCode: 1,
                        standardError: "The diagnose command is not configured.\n")
                }
                return try diagnose(url, full, json, connections)

            case .which(let path):
                let lockPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("gohfile.lock")
                    .path
                // BLOCK-1: same resolver seam as verifyAll. Production resolves the real
                // default read-only (create:false — never creates the dir); a nil/missing
                // path resolves to nil → ledger branch skipped silently. Tests inject a temp path.
                let provenanceStorePath = provenanceStorePathResolver()
                return GohWhichCommand.run(
                    filePath: path, lockPath: lockPath,
                    provenanceStorePath: provenanceStorePath)

            case .verify(let lockPath, let strictUntracked):
                return GohVerifyCommand.run(lockPath: lockPath, strictUntracked: strictUntracked)

            case .verifyAll(let json):
                // BLOCK-1: resolve at dispatch via the injected resolver (create:false in production).
                return GohVerifyAllCommand.run(
                    provenanceStorePath: provenanceStorePathResolver() ?? "",
                    json: json)

            case .attest(let outputPath):
                let storePathOrEmpty = provenanceStorePathResolver() ?? ""
                let locations = attestKeyLocationResolver()
                // attestKeyLocationResolver uses create:false (read path default).
                // GohAttestCommand.run calls create:true internally for the SE key.
                let handleURL = locations?.handleURL
                    ?? (try? AttestKeyLocation.signingKeyHandleURL(create: false))
                    ?? URL(fileURLWithPath: "")
                let keysURL = locations?.keysJSONURL
                    ?? (try? AttestKeyLocation.keysJSONURL(create: false))
                    ?? URL(fileURLWithPath: "")
                // Thread the injected signer override (test-only; nil in production).
                let signerOverride = attestSignerResolver()
                return GohAttestCommand.run(
                    provenanceStorePath: storePathOrEmpty,
                    outputPath: outputPath,
                    attestKeyHandleURL: handleURL,
                    attestKeysJSONURL: keysURL,
                    signerOverride: signerOverride)

            case .verifyAttestation(let artifactPath, let expectKey, let allowUntrustedKey, let json):
                return GohVerifyAttestationCommand.run(
                    artifactPath: artifactPath,
                    expectKey: expectKey,
                    allowUntrustedKey: allowUntrustedKey,
                    json: json)

            case .sync(let manifestPath, let base, let acceptChanged):
                return GohSyncCommand.run(
                    manifestPath: manifestPath,
                    base: base,
                    acceptChanged: acceptChanged,
                    send: send)

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
    case diagnose(url: String, full: Bool, json: Bool, connections: Int?)
    case which(path: String)
    case verify(lockPath: String, strictUntracked: Bool)
    case verifyAll(json: Bool)
    case attest(outputPath: String?)
    case verifyAttestation(
        artifactPath: String,
        expectKey: String?,
        allowUntrustedKey: Bool,
        json: Bool)
    case sync(manifestPath: String, base: String?, acceptChanged: Bool)
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
        if arguments.first == "diagnose" {
            return try parseDiagnose(Array(arguments.dropFirst()))
        }
        if arguments.first == "which" {
            let rest = Array(arguments.dropFirst())
            guard rest.count == 1, !rest[0].hasPrefix("-") else {
                throw ParseError(message: "usage: goh which <path>")
            }
            return .which(path: rest[0])
        }
        if arguments.first == "verify" {
            let rest = Array(arguments.dropFirst())

            // --all is parsed to a distinct case; it is incompatible with --strict-untracked
            // and a positional lockfile path (which are lock-directory concepts with no
            // analogue for the global ledger).
            if rest.first == "--all" {
                // Accepted grammar: `verify --all` or `verify --all --json` only.
                // Any other remainder (--strict-untracked, a positional, --json twice,
                // or an unknown flag) is rejected → exit 64.
                let after = Array(rest.dropFirst())
                let jsonFlag: Bool
                if after.isEmpty {
                    jsonFlag = false
                } else if after == ["--json"] {
                    jsonFlag = true
                } else {
                    throw ParseError(
                        message: "--all is incompatible with \(after.joined(separator: " "))")
                }
                // BLOCK-1: do NOT resolve the store path here. `parse()` is static and the
                // resolver is not in scope; resolving the real default at parse time would make
                // every parse test read the user's real provenance ledger. The path is resolved
                // at DISPATCH (run()) via the injected `provenanceStorePathResolver`.
                return .verifyAll(json: jsonFlag)
            }

            // Frozen path: --all is not present; parse exactly as before.
            var lockPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("gohfile.lock")
                .path
            var strictUntracked = false
            var sawPositional = false
            for arg in rest {
                if arg == "--strict-untracked" {
                    strictUntracked = true
                } else if arg.hasPrefix("-") {
                    throw ParseError(message: "unknown verify option \(arg)")
                } else {
                    guard !sawPositional else {
                        throw ParseError(message: "verify accepts at most one lockfile path")
                    }
                    sawPositional = true
                    lockPath = arg
                }
            }
            return .verify(lockPath: lockPath, strictUntracked: strictUntracked)
        }
        if arguments.first == "sync" {
            return try parseSync(Array(arguments.dropFirst()))
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
        // attest [--output <file>]
        // NOTE: must be checked BEFORE the single-arg foreground fallback (attest is a known verb)
        if arguments.first == "attest" {
            var outputPath: String?
            var index = 1
            while index < arguments.count {
                let arg = arguments[index]
                switch arg {
                case "--output", "-o":
                    outputPath = try value(after: arg, in: arguments, at: &index)
                default:
                    guard !arg.hasPrefix("-") else {
                        throw ParseError(message: "unknown attest option \(arg)")
                    }
                    throw ParseError(message: "attest: unexpected argument \(arg)")
                }
            }
            return .attest(outputPath: outputPath)
        }

        // verify-attestation <file> [--expect-key <kid|pubkey>] [--allow-untrusted-key] [--json]
        // NOTE: must be checked BEFORE the single-arg foreground fallback
        if arguments.first == "verify-attestation" {
            let rest = Array(arguments.dropFirst())
            guard !rest.isEmpty, let artifactPath = rest.first, !artifactPath.hasPrefix("-") else {
                throw ParseError(message: "verify-attestation requires an artifact file path")
            }
            var expectKey: String?
            var allowUntrustedKey = false
            var json = false
            var index = 1
            while index < rest.count {
                let arg = rest[index]
                switch arg {
                case "--expect-key":
                    expectKey = try value(after: arg, in: rest, at: &index)
                case "--allow-untrusted-key":
                    allowUntrustedKey = true
                    index += 1
                case "--json":
                    json = true
                    index += 1
                default:
                    guard !arg.hasPrefix("-") else {
                        throw ParseError(message: "unknown verify-attestation option \(arg)")
                    }
                    throw ParseError(message: "verify-attestation: unexpected argument \(arg)")
                }
            }
            return .verifyAttestation(
                artifactPath: artifactPath,
                expectKey: expectKey,
                allowUntrustedKey: allowUntrustedKey,
                json: json)
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

    private static func parseSync(_ arguments: [String]) throws -> ParsedCommand {
        var manifest: String?
        var base: String?
        var acceptChanged = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--base":
                base = try value(after: argument, in: arguments, at: &index)
            case "--accept-changed":
                acceptChanged = true
                index += 1
            default:
                guard !argument.hasPrefix("-") else {
                    throw ParseError(message: "unknown sync option \(argument)")
                }
                guard manifest == nil else {
                    throw ParseError(message: "sync accepts at most one manifest path")
                }
                manifest = argument
                index += 1
            }
        }

        // Optional positional manifest defaults to ./gohfile.toml in cwd.
        let manifestPath = manifest ?? URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("gohfile.toml")
            .path
        return .sync(manifestPath: manifestPath, base: base, acceptChanged: acceptChanged)
    }

    private static func parseDiagnose(_ arguments: [String]) throws -> ParsedCommand {
        var url: String?
        var full = false
        var json = false
        var connections: Int?
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--full":
                full = true; index += 1
            case "--json":
                json = true; index += 1
            case "--connections", "-c":
                guard index + 1 < arguments.count else {
                    throw ParseError(message: "\(arg) requires a value")
                }
                let raw = arguments[index + 1]
                guard let n = Int(raw), (1...16).contains(n) else {
                    throw ParseError(message: "connections must be an integer from 1 to 16")
                }
                connections = n; index += 2
            default:
                guard !arg.hasPrefix("-") else {
                    throw ParseError(message: "unknown diagnose option \(arg)")
                }
                guard url == nil else {
                    throw ParseError(message: "diagnose accepts exactly one URL")
                }
                url = arg; index += 1
            }
        }
        guard let resolvedURL = url else {
            throw ParseError(message: "diagnose requires a URL")
        }
        return .diagnose(url: resolvedURL, full: full, json: json, connections: connections)
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
                JobDisplayFormatter.progressText(job.progress),
                "\(JobDisplayFormatter.formatBytes(job.progress.bytesPerSecond))/s",
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
        text += "goh - terminal download manager\n\n"
        text += """
        Usage:
          goh <url>
          goh add [--output <path>] [--connections <1-16>] [--priority low|normal|high] [--no-cookies] <url>
          goh ls [--json]
          goh top
          goh doctor
          goh diagnose [--full] [--json] [--connections <1-16> | -c <1-16>] <url>
          goh which <path>
          goh sync [<manifest>] [--base <dir>] [--accept-changed]   (--base is cwd-relative)
          goh verify [<path-to-gohfile.lock>] [--strict-untracked]
          goh verify --all [--json]   (exit: 0 ok · 2 changed · 9 missing · 6 ledger error)
          goh attest [--output <file>]   (exit: 0 ok · 2 changed · 9 missing · 5 attest-failed · 6 ledger-error)
          goh verify-attestation <file> [--expect-key <full-pubkey|sha256-fingerprint>] [--allow-untrusted-key] [--json]
            (exit: 0 valid+trusted · 1 valid-unverified · 2 invalid · 3 key-mismatch · 6 malformed · 64 usage)
            --expect-key accepts a full base64url x963 public key or its full 64-hex SHA-256 fingerprint.
            kid (8-hex) is display-only and is rejected as --expect-key (exit 64).
            Note: attest and verify-attestation use DIFFERENT exit-code vocabularies — not interchangeable.
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
