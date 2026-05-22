import Foundation

/// The public surface of a download job (`DESIGN.md` §1) — the shape every
/// job-bearing reply returns.
///
/// State-specific fields are present on the wire only in the state they belong
/// to: `pauseReason` when `paused`, `completedAt` when `completed`, and `error` /
/// `retryEligible` / `failedAt` / `retryCount` when `failed`. The wire schema
/// permits other combinations; the daemon enforces the invariant and never emits
/// one (§2.2).
public struct JobSummary: Codable, Sendable, Equatable {
    public var id: UInt64
    public var url: String
    public var destination: String
    public var state: JobState
    public var progress: JobProgress
    /// When `add` created the job.
    public var createdAt: Date
    /// When `progress` last advanced; always present, `null` if it never has.
    public var lastProgressAt: Date?
    /// The connection count `add` was given (`1`–`16`).
    public var requestedConnectionCount: UInt8
    /// Connections currently in use; `0` when not downloading, below
    /// `requestedConnectionCount` on a single-connection fallback.
    public var actualConnectionCount: UInt8
    /// Present iff `state == paused`.
    public var pauseReason: PauseReason?
    /// Present iff `state == completed`.
    public var completedAt: Date?
    /// Present iff `state == failed`.
    public var error: GohError?
    /// Present iff `state == failed` — the daemon's judgement that a retry could
    /// succeed (advisory; see §2.2 "Retry boundary").
    public var retryEligible: Bool?
    /// Present iff `state == failed`.
    public var failedAt: Date?
    /// Present iff `state == failed`.
    public var retryCount: UInt32?

    public init(
        id: UInt64,
        url: String,
        destination: String,
        state: JobState,
        progress: JobProgress,
        createdAt: Date,
        lastProgressAt: Date?,
        requestedConnectionCount: UInt8,
        actualConnectionCount: UInt8,
        pauseReason: PauseReason? = nil,
        completedAt: Date? = nil,
        error: GohError? = nil,
        retryEligible: Bool? = nil,
        failedAt: Date? = nil,
        retryCount: UInt32? = nil
    ) {
        self.id = id
        self.url = url
        self.destination = destination
        self.state = state
        self.progress = progress
        self.createdAt = createdAt
        self.lastProgressAt = lastProgressAt
        self.requestedConnectionCount = requestedConnectionCount
        self.actualConnectionCount = actualConnectionCount
        self.pauseReason = pauseReason
        self.completedAt = completedAt
        self.error = error
        self.retryEligible = retryEligible
        self.failedAt = failedAt
        self.retryCount = retryCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, destination, state, progress, createdAt, lastProgressAt
        case requestedConnectionCount, actualConnectionCount
        case pauseReason, completedAt, error, retryEligible, failedAt, retryCount
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt64.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        destination = try c.decode(String.self, forKey: .destination)
        state = try c.decode(JobState.self, forKey: .state)
        progress = try c.decode(JobProgress.self, forKey: .progress)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastProgressAt = try c.decodeIfPresent(Date.self, forKey: .lastProgressAt)
        requestedConnectionCount = try c.decode(UInt8.self, forKey: .requestedConnectionCount)
        actualConnectionCount = try c.decode(UInt8.self, forKey: .actualConnectionCount)
        pauseReason = try c.decodeIfPresent(PauseReason.self, forKey: .pauseReason)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        error = try c.decodeIfPresent(GohError.self, forKey: .error)
        retryEligible = try c.decodeIfPresent(Bool.self, forKey: .retryEligible)
        failedAt = try c.decodeIfPresent(Date.self, forKey: .failedAt)
        retryCount = try c.decodeIfPresent(UInt32.self, forKey: .retryCount)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(destination, forKey: .destination)
        try c.encode(state, forKey: .state)
        try c.encode(progress, forKey: .progress)
        try c.encode(createdAt, forKey: .createdAt)
        // Always present — `null` when the job has never progressed.
        try c.encode(lastProgressAt, forKey: .lastProgressAt)
        try c.encode(requestedConnectionCount, forKey: .requestedConnectionCount)
        try c.encode(actualConnectionCount, forKey: .actualConnectionCount)
        // State-specific — emitted only in the state each belongs to.
        try c.encodeIfPresent(pauseReason, forKey: .pauseReason)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(retryEligible, forKey: .retryEligible)
        try c.encodeIfPresent(failedAt, forKey: .failedAt)
        try c.encodeIfPresent(retryCount, forKey: .retryCount)
    }
}
