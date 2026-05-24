import Foundation
import Testing

import GohCore

@Suite("Safari binary cookies parser")
struct SafariBinaryCookiesTests {

    @Test("parses a cookie record from a binarycookies page")
    func parseSingleCookie() throws {
        let fixture = BinaryCookiesFixture(
            cookies: [
                .init(
                    domain: ".example.com",
                    name: "session",
                    path: "/account",
                    value: "abc123",
                    flags: [.secure, .httpOnly],
                    expires: 3_600,
                    created: 60),
            ]
        ).data()

        let cookies = try SafariBinaryCookiesParser().parse(fixture)

        let cookie = try #require(cookies.first)
        #expect(cookies.count == 1)
        #expect(cookie.domain == ".example.com")
        #expect(cookie.name == "session")
        #expect(cookie.path == "/account")
        #expect(cookie.value == "abc123")
        #expect(cookie.flags.contains(.secure))
        #expect(cookie.flags.contains(.httpOnly))
        #expect(cookie.expiresAt == Date(timeIntervalSinceReferenceDate: 3_600))
        #expect(cookie.createdAt == Date(timeIntervalSinceReferenceDate: 60))
    }

    @Test("uses cookie string offsets instead of assuming packed string order")
    func parseStringsByOffset() throws {
        let fixture = BinaryCookiesFixture(
            cookies: [
                .init(
                    domain: "downloads.example.com",
                    name: "token",
                    path: "/files",
                    value: "offset-value",
                    flags: [],
                    expires: 7_200,
                    created: 120,
                    stringPacking: [.value, .path, .name, .domain]),
            ]
        ).data()

        let cookie = try #require(SafariBinaryCookiesParser().parse(fixture).first)

        #expect(cookie.domain == "downloads.example.com")
        #expect(cookie.name == "token")
        #expect(cookie.path == "/files")
        #expect(cookie.value == "offset-value")
    }

    @Test("parses multiple pages and ignores trailing footer bytes")
    func parseMultiplePages() throws {
        let fixture = BinaryCookiesFixture(
            pages: [
                [
                    .init(
                        domain: ".example.com",
                        name: "a",
                        path: "/",
                        value: "1",
                        flags: [.secure],
                        expires: 1,
                        created: 1),
                ],
                [
                    .init(
                        domain: ".swift.org",
                        name: "b",
                        path: "/download",
                        value: "2",
                        flags: [.httpOnly],
                        expires: 2,
                        created: 2),
                ],
            ],
            trailingBytes: Data([0, 0, 0, 0, 7, 23, 32, 5, 0, 0, 0, 0])
        ).data()

        let cookies = try SafariBinaryCookiesParser().parse(fixture)

        #expect(cookies.map(\.name) == ["a", "b"])
        #expect(cookies[0].flags.contains(.secure))
        #expect(cookies[1].flags.contains(.httpOnly))
    }

    @Test("rejects a file with the wrong magic")
    func rejectInvalidMagic() {
        #expect(throws: SafariBinaryCookiesError.invalidMagic) {
            try SafariBinaryCookiesParser().parse(Data("nope".utf8))
        }
    }

    @Test("rejects a page whose cookie offset points outside the page")
    func rejectInvalidCookieOffset() {
        var page = Data([0, 0, 1, 0])
        page.appendUInt32LE(1)
        page.appendUInt32LE(9_999)
        page.appendUInt32LE(0)

        var file = Data("cook".utf8)
        file.appendUInt32BE(1)
        file.appendUInt32BE(UInt32(page.count))
        file.append(page)
        file.appendUInt64BE(0)

        #expect(throws: SafariBinaryCookiesError.self) {
            try SafariBinaryCookiesParser().parse(file)
        }
    }

    @Test("cookie header includes only domain, path, secure, and expiry matches")
    func cookieHeaderFiltersMatches() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let jar = SafariCookieJar(cookies: [
            cookie(
                domain: ".example.com", name: "root", path: "/", value: "1",
                expiresAt: now.addingTimeInterval(100), createdAt: now),
            cookie(
                domain: ".example.com", name: "deep", path: "/files", value: "2",
                expiresAt: now.addingTimeInterval(100),
                createdAt: now.addingTimeInterval(10)),
            cookie(
                domain: ".example.com", name: "secure", path: "/", value: "3",
                flags: [.secure],
                expiresAt: now.addingTimeInterval(100),
                createdAt: now.addingTimeInterval(20)),
            cookie(
                domain: ".example.com", name: "expired", path: "/", value: "4",
                expiresAt: now.addingTimeInterval(-1), createdAt: now),
            cookie(
                domain: ".other.example", name: "other", path: "/", value: "5",
                expiresAt: now.addingTimeInterval(100), createdAt: now),
            cookie(
                domain: ".example.com", name: "wrongPath", path: "/private", value: "6",
                expiresAt: now.addingTimeInterval(100), createdAt: now),
        ])

        let httpsHeader = try #require(jar.cookieHeader(
            for: URL(string: "https://downloads.example.com/files/archive.zip")!,
            now: now))
        let httpHeader = try #require(jar.cookieHeader(
            for: URL(string: "http://downloads.example.com/files/archive.zip")!,
            now: now))

        #expect(httpsHeader == "deep=2; root=1; secure=3")
        #expect(httpHeader == "deep=2; root=1")
    }

    @Test("cookie header respects exact host domains and path segment boundaries")
    func cookieHeaderRespectsHostAndPathBoundaries() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let jar = SafariCookieJar(cookies: [
            cookie(
                domain: "example.com", name: "host", path: "/", value: "1",
                expiresAt: now.addingTimeInterval(100), createdAt: now),
            cookie(
                domain: ".example.com", name: "domain", path: "/download", value: "2",
                expiresAt: now.addingTimeInterval(100), createdAt: now),
        ])

        let exactHostHeader = try #require(jar.cookieHeader(
            for: URL(string: "https://example.com/download/file")!,
            now: now))
        let subdomainHeader = try #require(jar.cookieHeader(
            for: URL(string: "https://cdn.example.com/download/file")!,
            now: now))

        #expect(exactHostHeader == "domain=2; host=1")
        #expect(subdomainHeader == "domain=2")
        #expect(jar.cookieHeader(
            for: URL(string: "https://cdn.example.com/downloaded/file")!,
            now: now) == nil)
    }

    private func cookie(
        domain: String,
        name: String,
        path: String,
        value: String,
        flags: SafariCookieFlags = [],
        expiresAt: Date,
        createdAt: Date
    ) -> SafariCookie {
        SafariCookie(
            domain: domain,
            name: name,
            path: path,
            value: value,
            flags: flags,
            expiresAt: expiresAt,
            createdAt: createdAt)
    }
}

private struct BinaryCookiesFixture {
    var pages: [[Cookie]]
    var trailingBytes: Data

    init(cookies: [Cookie]) {
        self.pages = [cookies]
        self.trailingBytes = Data(repeating: 0, count: 8)
    }

    init(pages: [[Cookie]], trailingBytes: Data = Data(repeating: 0, count: 8)) {
        self.pages = pages
        self.trailingBytes = trailingBytes
    }

    func data() -> Data {
        let pageData = pages.map { Self.page(cookies: $0) }
        var data = Data("cook".utf8)
        data.appendUInt32BE(UInt32(pageData.count))
        for page in pageData {
            data.appendUInt32BE(UInt32(page.count))
        }
        for page in pageData {
            data.append(page)
        }
        data.append(trailingBytes)
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

        var offsets: [StringField: UInt32] = [:]
        for field in cookie.stringPacking {
            offsets[field] = UInt32(record.count)
            record.appendCString(cookie.value(for: field))
        }

        record.setUInt32LE(UInt32(record.count), at: 0)
        record.setUInt32LE(offsets[.domain]!, at: domainOffsetIndex)
        record.setUInt32LE(offsets[.name]!, at: nameOffsetIndex)
        record.setUInt32LE(offsets[.path]!, at: pathOffsetIndex)
        record.setUInt32LE(offsets[.value]!, at: valueOffsetIndex)
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
        var stringPacking: [StringField]

        init(
            domain: String,
            name: String,
            path: String,
            value: String,
            flags: SafariCookieFlags,
            expires: TimeInterval,
            created: TimeInterval,
            stringPacking: [StringField] = [.domain, .name, .path, .value]
        ) {
            self.domain = domain
            self.name = name
            self.path = path
            self.value = value
            self.flags = flags
            self.expires = expires
            self.created = created
            self.stringPacking = stringPacking
        }

        func value(for field: StringField) -> String {
            switch field {
            case .domain:
                domain
            case .name:
                name
            case .path:
                path
            case .value:
                value
            }
        }
    }

    enum StringField {
        case domain
        case name
        case path
        case value
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
