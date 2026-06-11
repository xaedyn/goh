import Foundation

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
    case recordVerifiedProvenance(request: RecordVerifiedProvenanceRequest)
    case forgetProvenance(request: ForgetProvenanceRequest)
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

/// The `recordVerifiedProvenance` command's request payload.
/// Carries all sync-verified-skip entries for one `goh sync` run as a single batch.
/// `sha256` values carry the ALREADY-"sha256:"-prefixed form from `FileDigest.sha256WithSize`.
/// The daemon stores them verbatim — it must NOT add the "sha256:" prefix again.
public struct RecordVerifiedProvenanceRequest: Codable, Sendable, Equatable {
    public var entries: [VerifiedProvenanceEntry]
    public init(entries: [VerifiedProvenanceEntry]) { self.entries = entries }
}

/// The `forgetProvenance` command's request payload.
/// Removes the ledger entries whose canonical `destinationPath` matches one of
/// `paths`. The daemon canonicalizes each path via
/// `URL(fileURLWithPath:).standardizedFileURL.path` before matching (the
/// `recordVerifiedProvenance` precedent). A path matching no entry is a no-op.
/// `forgetProvenance` NEVER touches the file at any path — it removes ledger
/// entries only. Reply is `ForgetProvenanceReply`, carrying the count actually
/// removed (`forgotCount`).
public struct ForgetProvenanceRequest: Codable, Sendable, Equatable {
    public var paths: [String]
    public init(paths: [String]) { self.paths = paths }
}

/// One entry in a `recordVerifiedProvenance` batch.
public struct VerifiedProvenanceEntry: Codable, Sendable, Equatable {
    public var url: String
    /// ALREADY "sha256:"-prefixed — exactly as `FileDigest.sha256WithSize` returns it.
    /// The daemon stores this verbatim. Never re-prefix.
    public var sha256: String
    public var size: Int
    /// Raw destination path (CLI-resolved); the daemon canonicalizes via
    /// `URL(fileURLWithPath:).standardizedFileURL.path`.
    public var destinationPath: String
    public var verifiedAt: Date

    // Additive-optional baseline fields (all-or-nothing: any nil → write none).
    // Sourced from FileDigest.sha256WithSizeAndStat FileStat, NOT the streaming byte count.
    // B1: recordedStatSize is ALWAYS stat.size (fstat st_size), NEVER hashedByteCount.
    public var recordedStatSize: Int64?           // st_size (off_t)
    public var recordedMtimeSeconds: Int64?       // st_mtimespec.tv_sec
    public var recordedMtimeNanoseconds: Int64?   // st_mtimespec.tv_nsec
    public var recordedInode: UInt64?             // st_ino
    public var recordedDevice: Int64?             // st_dev widened to Int64

    public init(
        url: String,
        sha256: String,
        size: Int,
        destinationPath: String,
        verifiedAt: Date,
        recordedStatSize: Int64? = nil,
        recordedMtimeSeconds: Int64? = nil,
        recordedMtimeNanoseconds: Int64? = nil,
        recordedInode: UInt64? = nil,
        recordedDevice: Int64? = nil
    ) {
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.destinationPath = destinationPath
        self.verifiedAt = verifiedAt
        self.recordedStatSize = recordedStatSize
        self.recordedMtimeSeconds = recordedMtimeSeconds
        self.recordedMtimeNanoseconds = recordedMtimeNanoseconds
        self.recordedInode = recordedInode
        self.recordedDevice = recordedDevice
    }
}
