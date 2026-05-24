import Foundation

/// The progress subscription scope (`DESIGN.md` §Progress Subscription
/// Contract).
public enum SubscriptionScope: String, Codable, Sendable, Equatable {
    case job
    case all
}

/// The `subscribe` command's request payload.
public struct SubscribeRequest: Codable, Sendable, Equatable {
    public var scope: SubscriptionScope
    public var jobID: UInt64?

    public init(scope: SubscriptionScope, jobID: UInt64? = nil) {
        self.scope = scope
        self.jobID = jobID
    }
}

/// The `subscribe` command's immediate baseline reply.
public struct SubscribeReply: Codable, Sendable, Equatable {
    public var revision: UInt64
    public var snapshot: [ProgressSnapshot]

    public init(revision: UInt64, snapshot: [ProgressSnapshot]) {
        self.revision = revision
        self.snapshot = snapshot
    }
}

/// The progress notification payload sent after a successful subscription.
public struct ProgressEvent: Codable, Sendable, Equatable {
    public var sequence: UInt64
    public var revision: UInt64
    public var emittedAt: Date
    public var updateKind: ProgressUpdateKind
    public var snapshot: [ProgressSnapshot]

    public init(
        sequence: UInt64,
        revision: UInt64,
        emittedAt: Date,
        updateKind: ProgressUpdateKind,
        snapshot: [ProgressSnapshot]
    ) {
        self.sequence = sequence
        self.revision = revision
        self.emittedAt = emittedAt
        self.updateKind = updateKind
        self.snapshot = snapshot
    }
}

/// The v3 progress update kind. v3 accepts only full snapshots.
public enum ProgressUpdateKind: String, Codable, Sendable, Equatable {
    case fullSnapshot
}

/// A full progress snapshot for one job.
public struct ProgressSnapshot: Codable, Sendable, Equatable {
    public var job: JobSummary
    public var lanes: [TransferLaneProgress]

    public init(job: JobSummary, lanes: [TransferLaneProgress]) {
        self.job = job
        self.lanes = lanes
    }
}

/// Per-lane transfer state for a range/stream in the current engine attempt.
public struct TransferLaneProgress: Codable, Sendable, Equatable {
    public var index: UInt8
    public var state: TransferLaneState
    public var rangeStart: UInt64?
    public var rangeEnd: UInt64?
    public var bytesCompleted: UInt64
    public var bytesTotal: UInt64?
    public var bytesPerSecond: UInt64
    public var protocolName: String?
    public var updatedAt: Date?

    public init(
        index: UInt8,
        state: TransferLaneState,
        rangeStart: UInt64? = nil,
        rangeEnd: UInt64? = nil,
        bytesCompleted: UInt64,
        bytesTotal: UInt64? = nil,
        bytesPerSecond: UInt64,
        protocolName: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.index = index
        self.state = state
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.bytesCompleted = bytesCompleted
        self.bytesTotal = bytesTotal
        self.bytesPerSecond = bytesPerSecond
        self.protocolName = protocolName
        self.updatedAt = updatedAt
    }
}

/// The state of a transfer lane in the current engine attempt.
public enum TransferLaneState: String, Codable, Sendable, Equatable {
    case pending
    case active
    case completed
    case failed
}
