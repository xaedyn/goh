import Darwin
import Foundation

public enum SafariAuthImportError: Error, Equatable {
    case readFailed(errnoCode: Int32)
    case tooManyCookies(Int)
    case fileTooLarge(bytes: Int)
}

public struct SafariAuthImporter: Sendable {
    /// Default hard cap on the cookie file we will buffer. Real Safari
    /// Cookies.binarycookies files are kilobytes; 64 MiB is generous-but-bounded
    /// and stops a crafted/huge fd from exhausting memory before parsing.
    public static let defaultMaxFileSize = 64 * 1024 * 1024

    private let parser: SafariBinaryCookiesParser
    private let maxFileSize: Int

    public init(
        parser: SafariBinaryCookiesParser = SafariBinaryCookiesParser(),
        maxFileSize: Int = SafariAuthImporter.defaultMaxFileSize
    ) {
        self.parser = parser
        self.maxFileSize = maxFileSize
    }

    public func importCookies(
        fromFileDescriptor fileDescriptor: Int32,
        into importedCookies: ImportedCookieStore
    ) throws -> AuthImportSafariReply {
        let data = try readAll(from: fileDescriptor)
        let cookies = try parser.parse(data)
        guard cookies.count <= Int(UInt32.max) else {
            throw SafariAuthImportError.tooManyCookies(cookies.count)
        }

        importedCookies.replaceCookies(cookies)
        return AuthImportSafariReply(importedCookieCount: UInt32(cookies.count))
    }

    private func readAll(from fileDescriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }

            if bytesRead > 0 {
                data.append(contentsOf: buffer.prefix(bytesRead))
                guard data.count <= maxFileSize else {
                    throw SafariAuthImportError.fileTooLarge(bytes: data.count)
                }
            } else if bytesRead == 0 {
                return data
            } else if errno != EINTR {
                throw SafariAuthImportError.readFailed(errnoCode: errno)
            }
        }
    }
}

public struct SafariAuthImportHandler: Sendable {
    private let importedCookies: ImportedCookieStore
    private let importer: SafariAuthImporter

    public init(
        importedCookies: ImportedCookieStore,
        importer: SafariAuthImporter = SafariAuthImporter()
    ) {
        self.importedCookies = importedCookies
        self.importer = importer
    }

    public func reply(fileDescriptor: Int32) -> CommandOutcome {
        do {
            let reply = try importer.importCookies(
                fromFileDescriptor: fileDescriptor,
                into: importedCookies)
            return .authImported(reply)
        } catch {
            return .failure(GohError(
                code: .invalidArgument,
                message: Self.failureMessage(for: error)))
        }
    }

    private static func failureMessage(for error: any Error) -> String {
        switch error {
        case SafariAuthImportError.readFailed(let errnoCode):
            "could not read Safari cookie file: errno \(errnoCode)"
        case SafariAuthImportError.tooManyCookies(let count):
            "Safari cookie file contains too many cookies: \(count)"
        case SafariAuthImportError.fileTooLarge(let bytes):
            "Safari cookie file is too large: \(bytes) bytes"
        case is SafariBinaryCookiesError:
            "malformed Safari cookie file: \(error)"
        default:
            "could not import Safari cookies: \(error)"
        }
    }
}
