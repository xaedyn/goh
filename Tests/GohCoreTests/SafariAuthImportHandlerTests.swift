import Darwin
import Foundation
import Testing

import GohCore

@Suite("Safari auth import handler")
struct SafariAuthImportHandlerTests {

    @Test("imports cookies from an open binarycookies fd and replaces the jar")
    func importCookiesFromFileDescriptor() throws {
        let store = ImportedCookieStore(cookies: [
            cookie(domain: ".example.com", name: "old", value: "stale"),
        ])
        let fileURL = try temporaryCookieFile(
            contents: BinaryCookiesFixture(cookies: [
                .init(
                    domain: ".example.com",
                    name: "session",
                    path: "/files",
                    value: "abc123",
                    flags: [.secure],
                    expires: 3_600,
                    created: 60),
            ]).data())
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let fd = open(fileURL.path, O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }

        let outcome = SafariAuthImportHandler(importedCookies: store)
            .reply(fileDescriptor: fd)

        #expect(outcome == .authImported(AuthImportSafariReply(importedCookieCount: 1)))
        #expect(store.snapshotHeader(
            forJobID: 1,
            url: URL(string: "https://cdn.example.com/files/archive.zip")!,
            now: Date(timeIntervalSinceReferenceDate: 120)
        ) == "session=abc123")
    }

    @Test("malformed binarycookies input fails without replacing existing cookies")
    func malformedInputDoesNotReplaceExistingCookies() throws {
        let store = ImportedCookieStore(cookies: [
            cookie(domain: ".example.com", name: "old", value: "still-here"),
        ])
        let fileURL = try temporaryCookieFile(contents: Data("not-a-cookie-file".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let fd = open(fileURL.path, O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }

        let outcome = SafariAuthImportHandler(importedCookies: store)
            .reply(fileDescriptor: fd)

        guard case .failure(let error) = outcome else {
            Issue.record("expected malformed input to fail")
            return
        }
        #expect(error.code == .invalidArgument)
        #expect(store.snapshotHeader(
            forJobID: 2,
            url: URL(string: "https://downloads.example.com/archive.zip")!,
            now: Date(timeIntervalSinceReferenceDate: 120)
        ) == "old=still-here")
    }

    private func temporaryCookieFile(contents: Data) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "goh-auth-import-handler-\(UUID().uuidString)")
        try contents.write(to: fileURL)
        return fileURL
    }

    private func cookie(
        domain: String,
        name: String,
        path: String = "/",
        value: String
    ) -> SafariCookie {
        SafariCookie(
            domain: domain,
            name: name,
            path: path,
            value: value,
            flags: [],
            expiresAt: Date(timeIntervalSinceReferenceDate: 3_600),
            createdAt: Date(timeIntervalSinceReferenceDate: 0))
    }
}

private struct BinaryCookiesFixture {
    var cookies: [Cookie]

    func data() -> Data {
        let page = Self.page(cookies: cookies)
        var data = Data("cook".utf8)
        data.appendUInt32BE(1)
        data.appendUInt32BE(UInt32(page.count))
        data.append(page)
        data.appendUInt64BE(0)
        return data
    }

    private static func page(cookies: [Cookie]) -> Data {
        let records = cookies.map(Self.record(cookie:))
        let headerSize = 4 + 4 + (4 * records.count) + 4
        var page = Data([0, 0, 1, 0])
        page.appendUInt32LE(UInt32(records.count))

        var nextOffset = UInt32(headerSize)
        for record in records {
            page.appendUInt32LE(nextOffset)
            nextOffset += UInt32(record.count)
        }

        page.appendUInt32LE(0)
        for record in records {
            page.append(record)
        }
        return page
    }

    private static func record(cookie: Cookie) -> Data {
        var record = Data()
        record.appendUInt32LE(0)
        record.appendUInt32LE(0)
        record.appendUInt32LE(cookie.flags.rawValue)
        record.appendUInt32LE(0)

        let domainOffsetIndex = record.count
        record.appendUInt32LE(0)
        let nameOffsetIndex = record.count
        record.appendUInt32LE(0)
        let pathOffsetIndex = record.count
        record.appendUInt32LE(0)
        let valueOffsetIndex = record.count
        record.appendUInt32LE(0)

        record.appendUInt64LE(0)
        record.appendDoubleLE(cookie.expires)
        record.appendDoubleLE(cookie.created)

        let domainOffset = UInt32(record.count)
        record.appendCString(cookie.domain)
        let nameOffset = UInt32(record.count)
        record.appendCString(cookie.name)
        let pathOffset = UInt32(record.count)
        record.appendCString(cookie.path)
        let valueOffset = UInt32(record.count)
        record.appendCString(cookie.value)

        record.setUInt32LE(UInt32(record.count), at: 0)
        record.setUInt32LE(domainOffset, at: domainOffsetIndex)
        record.setUInt32LE(nameOffset, at: nameOffsetIndex)
        record.setUInt32LE(pathOffset, at: pathOffsetIndex)
        record.setUInt32LE(valueOffset, at: valueOffsetIndex)
        return record
    }

    struct Cookie {
        var domain: String
        var name: String
        var path: String
        var value: String
        var flags: SafariCookieFlags
        var expires: TimeInterval
        var created: TimeInterval
    }
}

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        append(contentsOf: [
            UInt8((value >> 56) & 0xff),
            UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff),
            UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 32) & 0xff),
            UInt8((value >> 40) & 0xff),
            UInt8((value >> 48) & 0xff),
            UInt8((value >> 56) & 0xff),
        ])
    }

    mutating func appendDoubleLE(_ value: Double) {
        appendUInt64LE(value.bitPattern)
    }

    mutating func appendCString(_ value: String) {
        append(contentsOf: value.utf8)
        append(0)
    }

    mutating func setUInt32LE(_ value: UInt32, at index: Int) {
        replaceSubrange(index..<index + 4, with: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }
}
