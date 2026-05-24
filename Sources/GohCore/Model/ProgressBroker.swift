import Foundation

/// A registered progress subscription and its sequence-0 baseline reply.
public struct ProgressBrokerSubscription: Sendable, Equatable {
    public var id: UUID
    public var reply: SubscribeReply

    public init(id: UUID, reply: SubscribeReply) {
        self.id = id
        self.reply = reply
    }
}

/// One progress event ready to send to a subscriber.
public struct ProgressBrokerDelivery: Sendable, Equatable {
    public var subscriptionID: UUID
    public var event: ProgressEvent

    public init(subscriptionID: UUID, event: ProgressEvent) {
        self.subscriptionID = subscriptionID
        self.event = event
    }
}

/// Daemon-local progress fan-out and coalescing.
public struct ProgressBroker: Sendable {
    private struct Subscriber: Sendable {
        var scope: SubscriptionScope
        var jobID: UInt64?
        var nextSequence: UInt64 = 1
        var lastEmittedAt: Date?
        var pendingRevision: UInt64?
        var pendingSnapshot: [ProgressSnapshot]?
    }

    private var revision: UInt64
    private var snapshots: [UInt64: ProgressSnapshot]
    private var subscribers: [UUID: Subscriber]
    private var subscriberOrder: [UUID]
    private let cadence: TimeInterval

    public init(cadence: TimeInterval = 0.100, initialSnapshots: [ProgressSnapshot] = []) {
        self.revision = 0
        self.snapshots = Dictionary(
            initialSnapshots.map { ($0.job.id, $0) },
            uniquingKeysWith: { _, latest in latest })
        self.subscribers = [:]
        self.subscriberOrder = []
        self.cadence = cadence
    }

    public mutating func subscribe(_ request: SubscribeRequest) throws -> ProgressBrokerSubscription {
        try validate(request)

        let id = UUID()
        subscribers[id] = Subscriber(scope: request.scope, jobID: request.jobID)
        subscriberOrder.append(id)
        return ProgressBrokerSubscription(
            id: id,
            reply: SubscribeReply(
                revision: revision,
                snapshot: snapshot(scope: request.scope, jobID: request.jobID)))
    }

    public mutating func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
        subscriberOrder.removeAll { $0 == id }
    }

    public mutating func publish(
        _ snapshot: ProgressSnapshot, at now: Date = Date()
    ) -> [ProgressBrokerDelivery] {
        snapshots[snapshot.job.id] = snapshot
        revision += 1
        return enqueueEvents(changedJobID: snapshot.job.id, terminal: false, at: now)
    }

    public mutating func remove(jobID: UInt64, at now: Date = Date()) -> [ProgressBrokerDelivery] {
        guard snapshots.removeValue(forKey: jobID) != nil else { return [] }
        revision += 1
        return enqueueEvents(changedJobID: jobID, terminal: true, at: now)
    }

    public mutating func flushDue(at now: Date = Date()) -> [ProgressBrokerDelivery] {
        var deliveries: [ProgressBrokerDelivery] = []
        for id in subscriberOrder {
            guard var subscriber = subscribers[id],
                  let pendingRevision = subscriber.pendingRevision,
                  let pendingSnapshot = subscriber.pendingSnapshot,
                  isDue(subscriber, at: now)
            else { continue }

            deliveries.append(delivery(
                id: id,
                subscriber: &subscriber,
                revision: pendingRevision,
                snapshot: pendingSnapshot,
                at: now))
            subscriber.pendingRevision = nil
            subscriber.pendingSnapshot = nil
            subscribers[id] = subscriber
        }
        return deliveries
    }

    private func validate(_ request: SubscribeRequest) throws {
        switch request.scope {
        case .job:
            guard let jobID = request.jobID else {
                throw GohError(
                    code: .invalidArgument,
                    message: "job-scoped progress subscriptions require jobID")
            }
            guard snapshots[jobID] != nil else {
                throw GohError(code: .jobNotFound, message: "no job with id \(jobID)")
            }
        case .all:
            guard request.jobID == nil else {
                throw GohError(
                    code: .invalidArgument,
                    message: "all-jobs progress subscriptions must not include jobID")
            }
        }
    }

    private mutating func enqueueEvents(
        changedJobID: UInt64, terminal: Bool, at now: Date
    ) -> [ProgressBrokerDelivery] {
        var deliveries: [ProgressBrokerDelivery] = []
        for id in subscriberOrder {
            guard var subscriber = subscribers[id],
                  includes(subscriber, changedJobID: changedJobID)
            else { continue }

            let scopedSnapshot = snapshot(scope: subscriber.scope, jobID: subscriber.jobID)
            if terminal || isDue(subscriber, at: now) {
                deliveries.append(delivery(
                    id: id,
                    subscriber: &subscriber,
                    revision: revision,
                    snapshot: scopedSnapshot,
                    at: now))
                subscriber.pendingRevision = nil
                subscriber.pendingSnapshot = nil
            } else {
                subscriber.pendingRevision = revision
                subscriber.pendingSnapshot = scopedSnapshot
            }
            subscribers[id] = subscriber
        }
        return deliveries
    }

    private func includes(_ subscriber: Subscriber, changedJobID: UInt64) -> Bool {
        switch subscriber.scope {
        case .all:
            return true
        case .job:
            return subscriber.jobID == changedJobID
        }
    }

    private func isDue(_ subscriber: Subscriber, at now: Date) -> Bool {
        guard let lastEmittedAt = subscriber.lastEmittedAt else { return true }
        return now.timeIntervalSince(lastEmittedAt) >= cadence
    }

    private mutating func delivery(
        id: UUID,
        subscriber: inout Subscriber,
        revision: UInt64,
        snapshot: [ProgressSnapshot],
        at now: Date
    ) -> ProgressBrokerDelivery {
        let event = ProgressEvent(
            sequence: subscriber.nextSequence,
            revision: revision,
            emittedAt: now,
            updateKind: .fullSnapshot,
            snapshot: snapshot)
        subscriber.nextSequence += 1
        subscriber.lastEmittedAt = now
        return ProgressBrokerDelivery(subscriptionID: id, event: event)
    }

    private func snapshot(scope: SubscriptionScope, jobID: UInt64?) -> [ProgressSnapshot] {
        switch scope {
        case .all:
            return snapshots.values.sorted { $0.job.id < $1.job.id }
        case .job:
            guard let jobID, let snapshot = snapshots[jobID] else { return [] }
            return [snapshot]
        }
    }
}
