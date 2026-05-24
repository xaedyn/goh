import Darwin
import Foundation
import Testing
import XPC

import GohCore

@Suite("auth import safari CLI command")
struct AuthImportSafariCommandTests {

    @Test("unopenable Safari cookie candidates print FDA guidance without sending XPC")
    func unopenableCandidatesDoNotSendXPC() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "goh-auth-import-cli-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var sendCount = 0

        let result = AuthImportSafariCommand(homeDirectory: home) { _ in
            sendCount += 1
            Issue.record("command should not send XPC when no Safari cookie file opens")
            throw GohError(code: .invalidArgument)
        }.run()

        #expect(result.exitCode != 0)
        #expect(result.standardOutput == "")
        #expect(result.standardError.contains("Full Disk Access"))
        for candidate in SafariCookieFileLocator.candidateURLs(homeDirectory: home) {
            #expect(result.standardError.contains(candidate.path))
        }
        #expect(sendCount == 0)
    }

    @Test("open Safari cookie file is sent as auth.safariCookieFile fd sibling")
    func openCookieFileIsSentAsFileDescriptorSibling() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "goh-auth-import-cli-success-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let cookieFile = SafariCookieFileLocator.candidateURLs(homeDirectory: home)[0]
        try FileManager.default.createDirectory(
            at: cookieFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let cookieBytes = Array("cookie-bytes".utf8)
        try Data(cookieBytes).write(to: cookieFile)

        var sendCount = 0
        let result = AuthImportSafariCommand(homeDirectory: home) { request in
            sendCount += 1
            return try request.withUnsafeUnderlyingDictionary { object in
                let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                #expect(envelope.protocolVersion == 2)
                #expect(envelope.messageType == .request)
                #expect(envelope.payload == .authImportSafari(request: AuthImportSafariRequest()))

                let fd = try XPCEnvelope.fileDescriptor(
                    object, XPCEnvelope.authSafariCookieFileKey)
                defer { close(fd) }
                var buffer = [UInt8](repeating: 0, count: cookieBytes.count)
                let bytesRead = read(fd, &buffer, buffer.count)
                #expect(bytesRead == cookieBytes.count)
                #expect(buffer == cookieBytes)

                let reply = try GohEnvelope(
                    protocolVersion: 2,
                    requestID: envelope.requestID,
                    messageType: .reply,
                    payload: AuthImportSafariReply(importedCookieCount: 7))
                    .xpcDictionary()
                return XPCDictionary(reply)
            }
        }.run()

        #expect(sendCount == 1)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "Imported 7 Safari cookies.\n")
        #expect(result.standardError == "")
    }

    @Test("directory candidates are skipped before falling back to the legacy cookie file")
    func directoryCandidateFallsBackToLegacyFile() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "goh-auth-import-cli-directory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let candidates = SafariCookieFileLocator.candidateURLs(homeDirectory: home)
        try FileManager.default.createDirectory(
            at: candidates[0],
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: candidates[1].deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let legacyBytes = Array("legacy-cookie-bytes".utf8)
        try Data(legacyBytes).write(to: candidates[1])

        var sentBytes: [UInt8] = []
        let result = AuthImportSafariCommand(homeDirectory: home) { request in
            return try request.withUnsafeUnderlyingDictionary { object in
                let envelope = try GohEnvelope<Command>(xpcDictionary: object)
                let fd = try XPCEnvelope.fileDescriptor(
                    object, XPCEnvelope.authSafariCookieFileKey)
                defer { close(fd) }
                var buffer = [UInt8](repeating: 0, count: legacyBytes.count)
                let bytesRead = read(fd, &buffer, buffer.count)
                #expect(bytesRead == legacyBytes.count)
                sentBytes = buffer

                let reply = try GohEnvelope(
                    protocolVersion: 2,
                    requestID: envelope.requestID,
                    messageType: .reply,
                    payload: AuthImportSafariReply(importedCookieCount: 1))
                    .xpcDictionary()
                return XPCDictionary(reply)
            }
        }.run()

        #expect(result.exitCode == 0)
        #expect(sentBytes == legacyBytes)
    }
}
