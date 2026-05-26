import Darwin
import Foundation
import XPC

public struct AuthImportSafariCommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct AuthImportSafariCommand {
    public typealias Sender = (XPCDictionary) throws -> XPCDictionary

    private let homeDirectory: URL
    private let send: Sender

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        send: @escaping Sender
    ) {
        self.homeDirectory = homeDirectory
        self.send = send
    }

    public func run() -> AuthImportSafariCommandResult {
        let candidates = SafariCookieFileLocator.candidateURLs(homeDirectory: homeDirectory)
        guard let opened = Self.openFirstReadableCandidate(candidates) else {
            return AuthImportSafariCommandResult(
                exitCode: 1,
                standardError: Self.fullDiskAccessMessage(candidates: candidates))
        }
        defer { close(opened.fileDescriptor) }

        do {
            let request = try Self.requestDictionary(fileDescriptor: opened.fileDescriptor)
            let response = try send(XPCDictionary(request))
            return try Self.result(from: response)
        } catch {
            return AuthImportSafariCommandResult(
                exitCode: 1,
                standardError: "Safari cookie import failed: \(error)\n")
        }
    }

    private static func openFirstReadableCandidate(
        _ candidates: [URL]
    ) -> (url: URL, fileDescriptor: Int32)? {
        for candidate in candidates {
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory),
                !isDirectory.boolValue
            else {
                continue
            }

            let fd = open(candidate.path, O_RDONLY | O_CLOEXEC)
            if fd >= 0 {
                return (candidate, fd)
            }
        }
        return nil
    }

    private static func requestDictionary(fileDescriptor: Int32) throws -> xpc_object_t {
        let request = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: UUID(),
            messageType: .request,
            payload: Command.authImportSafari(request: AuthImportSafariRequest()))
            .xpcDictionary()
        XPCEnvelope.setFileDescriptor(
            fileDescriptor,
            forKey: XPCEnvelope.authSafariCookieFileKey,
            in: request)
        return request
    }

    private static func result(from response: XPCDictionary) throws -> AuthImportSafariCommandResult {
        switch response.decodeGohReply(as: AuthImportSafariReply.self) {
        case .reply(_, let payload):
            let noun = payload.importedCookieCount == 1 ? "cookie" : "cookies"
            return AuthImportSafariCommandResult(
                exitCode: 0,
                standardOutput: "Imported \(payload.importedCookieCount) Safari \(noun).\n")
        case .daemonError(_, let error):
            return AuthImportSafariCommandResult(
                exitCode: 1,
                standardError: Self.daemonErrorMessage(error))
        case .malformed:
            throw GohError(
                code: .invalidArgument,
                message: "daemon returned an unrecognized auth import reply")
        }
    }

    private static func daemonErrorMessage(_ error: GohError) -> String {
        if let message = error.message, !message.isEmpty {
            return "Safari cookie import failed: \(message)\n"
        }
        return "Safari cookie import failed: \(error.code.rawValue)\n"
    }

    private static func fullDiskAccessMessage(candidates: [URL]) -> String {
        var message = "Could not open Safari's Cookies.binarycookies file.\n\n"
        message += "Checked:\n"
        for candidate in candidates {
            message += "  \(candidate.path)\n"
        }
        message += "\nGrant Full Disk Access to your terminal app "
        message += "(or to goh when installed as a standalone binary), "
        message += "then rerun `goh auth import safari`.\n"
        return message
    }
}
