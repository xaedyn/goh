/// A request from `goh` to `gohd` — the payload of a `request`-kind envelope
/// (`DESIGN.md` §3). The daemon decodes a `Command` and routes it to the job
/// model.
public enum Command: Codable, Sendable, Equatable {
    case add(request: AddRequest)
    case ls
    case pause(jobID: UInt64)
    case resume(jobID: UInt64)
    case rm(request: RmRequest)
    case authImportSafari(request: AuthImportSafariRequest)
    case subscribe(request: SubscribeRequest)
}

/// The `add` command's request payload (`DESIGN.md` §3.1).
///
/// An absent optional field takes its frozen default (§4): `destination` is
/// derived from the URL, `connectionCount` is 8, `useImportedCookies` is true,
/// `priority` is `normal`.
public struct AddRequest: Codable, Sendable, Equatable {
    public var url: String
    public var destination: String?
    public var connectionCount: UInt8?
    public var useImportedCookies: Bool?
    public var priority: Priority?

    public init(
        url: String,
        destination: String? = nil,
        connectionCount: UInt8? = nil,
        useImportedCookies: Bool? = nil,
        priority: Priority? = nil
    ) {
        self.url = url
        self.destination = destination
        self.connectionCount = connectionCount
        self.useImportedCookies = useImportedCookies
        self.priority = priority
    }
}

/// The `rm` command's request payload (`DESIGN.md` §3.5). `keepPartialFile`
/// defaults to false.
public struct RmRequest: Codable, Sendable, Equatable {
    public var jobID: UInt64
    public var keepPartialFile: Bool?

    public init(jobID: UInt64, keepPartialFile: Bool? = nil) {
        self.jobID = jobID
        self.keepPartialFile = keepPartialFile
    }
}

/// The `authImportSafari` command's request payload (`DESIGN.md` §Auth).
///
/// The Safari cookie file itself is carried as a native XPC fd sibling named
/// `auth.safariCookieFile`, never inside this JSON payload.
public struct AuthImportSafariRequest: Codable, Sendable, Equatable {
    public init() {}
}

/// The `authImportSafari` command's success reply payload (`DESIGN.md` §Auth).
public struct AuthImportSafariReply: Codable, Sendable, Equatable {
    public var importedCookieCount: UInt32

    public init(importedCookieCount: UInt32) {
        self.importedCookieCount = importedCookieCount
    }
}
