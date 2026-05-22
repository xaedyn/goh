/// A typed command-failure category (`DESIGN.md` §2.4). The CLI branches on the
/// code without parsing prose; each case has a remedy path in the contract.
public enum ErrorCode: String, Codable, Sendable, CaseIterable {
    case dnsResolutionFailed
    case connectionFailed
    case tlsFailure
    case timedOut
    case httpStatus
    case diskFull
    case destinationUnwritable
    case destinationPermissionDenied
    case checksumMismatch
    case unauthorized
    case unsupportedURL
    case jobNotFound
    case queueFull
    case protocolVersionMismatch
    case cancelled
    case invalidArgument
}

/// A structured command failure (`DESIGN.md` §2.4). Travels the §1.2 error
/// channel as a reply's `.failure`, and records a job's failure in the
/// `failed`-state fields of ``JobSummary``.
public struct GohError: Codable, Sendable, Equatable, Error {
    /// The error category.
    public var code: ErrorCode
    /// Human-readable detail; the reason phrase for an `httpStatus` failure.
    public var message: String?
    /// The numeric HTTP status — set only when `code` is `httpStatus`.
    public var httpStatusCode: Int?

    public init(code: ErrorCode, message: String? = nil, httpStatusCode: Int? = nil) {
        self.code = code
        self.message = message
        self.httpStatusCode = httpStatusCode
    }
}
