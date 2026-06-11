import Foundation

public struct SafariCookie: Sendable, Equatable {
    public let domain: String
    public let name: String
    public let path: String
    public let value: String
    public let flags: SafariCookieFlags
    public let expiresAt: Date
    public let createdAt: Date

    public init(
        domain: String,
        name: String,
        path: String,
        value: String,
        flags: SafariCookieFlags,
        expiresAt: Date,
        createdAt: Date
    ) {
        self.domain = domain
        self.name = name
        self.path = path
        self.value = value
        self.flags = flags
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }
}

public struct SafariCookieFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let secure = SafariCookieFlags(rawValue: 1 << 0)
    public static let httpOnly = SafariCookieFlags(rawValue: 1 << 2)
}

public struct SafariCookieJar: Sendable, Equatable {
    public let cookies: [SafariCookie]

    public init(cookies: [SafariCookie]) {
        self.cookies = cookies
    }

    public func matchingCookies(for url: URL, now: Date = Date()) -> [SafariCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let requestPath = Self.normalizedRequestPath(url.path)
        let isSecureRequest = url.scheme?.lowercased() == "https"

        return cookies.enumerated()
            .filter { _, cookie in
                cookie.expiresAt > now
                    && (isSecureRequest || !cookie.flags.contains(.secure))
                    && Self.domainMatches(cookieDomain: cookie.domain, requestHost: host)
                    && Self.pathMatches(cookiePath: cookie.path, requestPath: requestPath)
            }
            .sorted { lhs, rhs in
                if lhs.element.path.count != rhs.element.path.count {
                    return lhs.element.path.count > rhs.element.path.count
                }
                if lhs.element.createdAt != rhs.element.createdAt {
                    return lhs.element.createdAt < rhs.element.createdAt
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    public func cookieHeader(for url: URL, now: Date = Date()) -> String? {
        let pairs = matchingCookies(for: url, now: now).map { "\($0.name)=\($0.value)" }
        guard !pairs.isEmpty else { return nil }
        return pairs.joined(separator: "; ")
    }

    private static func domainMatches(cookieDomain: String, requestHost: String) -> Bool {
        let domain = cookieDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !domain.isEmpty else { return false }

        if domain.hasPrefix(".") {
            let suffix = String(domain.drop { $0 == "." })
            return requestHost == suffix || requestHost.hasSuffix(".\(suffix)")
        }

        return requestHost == domain
    }

    private static func pathMatches(cookiePath: String, requestPath: String) -> Bool {
        let path = normalizedCookiePath(cookiePath)
        if requestPath == path { return true }
        guard requestPath.hasPrefix(path) else { return false }
        if path.hasSuffix("/") { return true }
        let boundary = requestPath.index(requestPath.startIndex, offsetBy: path.count)
        return requestPath[boundary] == "/"
    }

    private static func normalizedRequestPath(_ path: String) -> String {
        path.isEmpty || !path.hasPrefix("/") ? "/" : path
    }

    private static func normalizedCookiePath(_ path: String) -> String {
        path.isEmpty || !path.hasPrefix("/") ? "/" : path
    }
}

public enum SafariBinaryCookiesError: Error, Equatable {
    case invalidMagic
    case truncated(context: String)
    case invalidPageSignature(pageIndex: Int)
    case invalidCookieOffset(pageIndex: Int, cookieIndex: Int, offset: UInt32)
    case invalidRecordSize(pageIndex: Int, cookieIndex: Int, size: UInt32)
    case invalidStringOffset(pageIndex: Int, cookieIndex: Int, field: String, offset: UInt32)
    case invalidUTF8(pageIndex: Int, cookieIndex: Int, field: String)
    case unterminatedString(pageIndex: Int, cookieIndex: Int, field: String)
}

public struct SafariBinaryCookiesParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> [SafariCookie] {
        var reader = BinaryCookieReader(bytes: Array(data))
        guard try reader.readBytes(count: 4, context: "file magic") == [0x63, 0x6f, 0x6f, 0x6b] else {
            throw SafariBinaryCookiesError.invalidMagic
        }

        let pageCount = Int(try reader.readUInt32BE(context: "page count"))
        // Cap before building the (0..<pageCount) loop: an attacker-supplied
        // count near UInt32.max would otherwise spin billions of iterations /
        // allocations before readBytes eventually throws. Real Safari cookie
        // files have at most a handful of pages; 65_536 is generous-but-bounded.
        guard pageCount <= Self.maxPageCount else {
            throw SafariBinaryCookiesError.truncated(context: "page count \(pageCount) exceeds cap \(Self.maxPageCount)")
        }
        let pageSizes = try (0..<pageCount).map { pageIndex in
            Int(try reader.readUInt32BE(context: "page \(pageIndex) size"))
        }

        var cookies: [SafariCookie] = []
        for (pageIndex, pageSize) in pageSizes.enumerated() {
            let page = try reader.readBytes(count: pageSize, context: "page \(pageIndex)")
            cookies += try Self.parsePage(page, pageIndex: pageIndex)
        }
        return cookies
    }

    private static func parsePage(_ page: [UInt8], pageIndex: Int) throws -> [SafariCookie] {
        var reader = BinaryCookieReader(bytes: page)
        guard try reader.readBytes(count: 4, context: "page \(pageIndex) magic") == [0, 0, 1, 0] else {
            throw SafariBinaryCookiesError.invalidPageSignature(pageIndex: pageIndex)
        }

        let cookieCount = Int(try reader.readUInt32LE(context: "page \(pageIndex) cookie count"))
        // Cap before the (0..<cookieCount) loop, same rationale as page count:
        // an absurd count would otherwise allocate/iterate before readBytes
        // throws. A single page holds far fewer than a million cookies; the
        // bound stays generous while keeping a crafted file from hanging us.
        guard cookieCount <= Self.maxCookieCountPerPage else {
            throw SafariBinaryCookiesError.truncated(
                context: "page \(pageIndex) cookie count \(cookieCount) exceeds cap \(Self.maxCookieCountPerPage)")
        }
        let offsets = try (0..<cookieCount).map { cookieIndex in
            try reader.readUInt32LE(context: "page \(pageIndex) cookie \(cookieIndex) offset")
        }
        _ = try reader.readUInt32LE(context: "page \(pageIndex) footer")

        var cookies: [SafariCookie] = []
        cookies.reserveCapacity(cookieCount)
        for (cookieIndex, rawOffset) in offsets.enumerated() {
            cookies.append(try parseCookie(
                page: page,
                pageIndex: pageIndex,
                cookieIndex: cookieIndex,
                rawOffset: rawOffset))
        }
        return cookies
    }

    private static func parseCookie(
        page: [UInt8],
        pageIndex: Int,
        cookieIndex: Int,
        rawOffset: UInt32
    ) throws -> SafariCookie {
        let offset = Int(rawOffset)
        guard offset >= 0, offset + 4 <= page.count else {
            throw SafariBinaryCookiesError.invalidCookieOffset(
                pageIndex: pageIndex, cookieIndex: cookieIndex, offset: rawOffset)
        }

        let recordSize = UInt32(littleEndianBytes: Array(page[offset..<offset + 4]))
        guard recordSize >= UInt32(Self.recordHeaderSize) else {
            throw SafariBinaryCookiesError.invalidRecordSize(
                pageIndex: pageIndex, cookieIndex: cookieIndex, size: recordSize)
        }

        let recordEnd = offset + Int(recordSize)
        guard recordEnd <= page.count else {
            throw SafariBinaryCookiesError.invalidRecordSize(
                pageIndex: pageIndex, cookieIndex: cookieIndex, size: recordSize)
        }

        let record = Array(page[offset..<recordEnd])
        var reader = BinaryCookieReader(bytes: record)
        _ = try reader.readUInt32LE(context: "cookie \(cookieIndex) size")
        _ = try reader.readUInt32LE(context: "cookie \(cookieIndex) unknown 1")
        let flags = SafariCookieFlags(rawValue: try reader.readUInt32LE(context: "cookie \(cookieIndex) flags"))
        _ = try reader.readUInt32LE(context: "cookie \(cookieIndex) unknown 2")

        let domainOffset = try reader.readUInt32LE(context: "cookie \(cookieIndex) domain offset")
        let nameOffset = try reader.readUInt32LE(context: "cookie \(cookieIndex) name offset")
        let pathOffset = try reader.readUInt32LE(context: "cookie \(cookieIndex) path offset")
        let valueOffset = try reader.readUInt32LE(context: "cookie \(cookieIndex) value offset")

        _ = try reader.readUInt64LE(context: "cookie \(cookieIndex) unknown 3")
        let expires = try reader.readDoubleLE(context: "cookie \(cookieIndex) expiration")
        let created = try reader.readDoubleLE(context: "cookie \(cookieIndex) creation")

        let domain = try string(
            in: record,
            at: domainOffset,
            field: "domain",
            pageIndex: pageIndex,
            cookieIndex: cookieIndex)
        let name = try string(
            in: record,
            at: nameOffset,
            field: "name",
            pageIndex: pageIndex,
            cookieIndex: cookieIndex)
        let path = try string(
            in: record,
            at: pathOffset,
            field: "path",
            pageIndex: pageIndex,
            cookieIndex: cookieIndex)
        let value = try string(
            in: record,
            at: valueOffset,
            field: "value",
            pageIndex: pageIndex,
            cookieIndex: cookieIndex)

        return SafariCookie(
            domain: domain,
            name: name,
            path: path,
            value: value,
            flags: flags,
            expiresAt: Date(timeIntervalSinceReferenceDate: expires),
            createdAt: Date(timeIntervalSinceReferenceDate: created))
    }

    private static func string(
        in record: [UInt8],
        at rawOffset: UInt32,
        field: String,
        pageIndex: Int,
        cookieIndex: Int
    ) throws -> String {
        let offset = Int(rawOffset)
        guard offset >= Self.recordHeaderSize, offset < record.count else {
            throw SafariBinaryCookiesError.invalidStringOffset(
                pageIndex: pageIndex,
                cookieIndex: cookieIndex,
                field: field,
                offset: rawOffset)
        }

        guard let terminator = record[offset...].firstIndex(of: 0) else {
            throw SafariBinaryCookiesError.unterminatedString(
                pageIndex: pageIndex,
                cookieIndex: cookieIndex,
                field: field)
        }

        let bytes = record[offset..<terminator]
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw SafariBinaryCookiesError.invalidUTF8(
                pageIndex: pageIndex,
                cookieIndex: cookieIndex,
                field: field)
        }
        return value
    }

    private static let recordHeaderSize = 56

    /// Upper bound on the file's page count — guards the page-size loop against
    /// a crafted count. Real Safari Cookies.binarycookies files have a handful.
    static let maxPageCount = 65_536

    /// Upper bound on a single page's cookie count — guards the offset loop.
    static let maxCookieCountPerPage = 1_000_000
}

private struct BinaryCookieReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readBytes(count: Int, context: String) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else {
            throw SafariBinaryCookiesError.truncated(context: context)
        }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func readUInt32BE(context: String) throws -> UInt32 {
        UInt32(bigEndianBytes: try readBytes(count: 4, context: context))
    }

    mutating func readUInt32LE(context: String) throws -> UInt32 {
        UInt32(littleEndianBytes: try readBytes(count: 4, context: context))
    }

    mutating func readUInt64LE(context: String) throws -> UInt64 {
        UInt64(littleEndianBytes: try readBytes(count: 8, context: context))
    }

    mutating func readDoubleLE(context: String) throws -> Double {
        Double(bitPattern: try readUInt64LE(context: context))
    }
}

private extension UInt32 {
    init(bigEndianBytes bytes: [UInt8]) {
        precondition(bytes.count == 4)
        self =
            (UInt32(bytes[0]) << 24) |
            (UInt32(bytes[1]) << 16) |
            (UInt32(bytes[2]) << 8) |
            UInt32(bytes[3])
    }

    init(littleEndianBytes bytes: [UInt8]) {
        precondition(bytes.count == 4)
        self =
            UInt32(bytes[0]) |
            (UInt32(bytes[1]) << 8) |
            (UInt32(bytes[2]) << 16) |
            (UInt32(bytes[3]) << 24)
    }
}

private extension UInt64 {
    init(littleEndianBytes bytes: [UInt8]) {
        precondition(bytes.count == 8)
        self =
            UInt64(bytes[0]) |
            (UInt64(bytes[1]) << 8) |
            (UInt64(bytes[2]) << 16) |
            (UInt64(bytes[3]) << 24) |
            (UInt64(bytes[4]) << 32) |
            (UInt64(bytes[5]) << 40) |
            (UInt64(bytes[6]) << 48) |
            (UInt64(bytes[7]) << 56)
    }
}
