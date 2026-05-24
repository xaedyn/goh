import Foundation
import Synchronization

/// Thread-safe owner for the daemon-local ``ProgressBroker`` and its delivery
/// sinks.
public final class ProgressBrokerHub: Sendable {
    public typealias EventSink = @Sendable (ProgressEvent) throws -> Void

    private struct State {
        var broker: ProgressBroker
        var sinks: [UUID: EventSink] = [:]
    }

    private struct PendingDelivery: Sendable {
        var subscriptionID: UUID
        var event: ProgressEvent
        var sink: EventSink
    }

    private let state: Mutex<State>

    public init(cadence: TimeInterval = 0.100, initialSnapshots: [ProgressSnapshot] = []) {
        self.state = Mutex(State(
            broker: ProgressBroker(
                cadence: cadence,
                initialSnapshots: initialSnapshots)))
    }

    /// Registers a progress subscription and returns its sequence-0 baseline.
    public func subscribe(
        _ request: SubscribeRequest,
        eventSink: @escaping EventSink
    ) throws -> SubscribeReply {
        try state.withLock { state in
            let subscription = try state.broker.subscribe(request)
            state.sinks[subscription.id] = eventSink
            return subscription.reply
        }
    }

    /// Publishes a fresh snapshot and sends any due notifications.
    public func publish(_ snapshot: ProgressSnapshot, at now: Date = Date()) {
        deliver(state.withLock { state in
            state.broker.publish(snapshot, at: now).compactMap { delivery in
                guard let sink = state.sinks[delivery.subscriptionID] else { return nil }
                return PendingDelivery(
                    subscriptionID: delivery.subscriptionID,
                    event: delivery.event,
                    sink: sink)
            }
        })
    }

    /// Removes a job from the visible progress model and sends terminal
    /// notifications immediately.
    public func remove(jobID: UInt64, at now: Date = Date()) {
        deliver(state.withLock { state in
            state.broker.remove(jobID: jobID, at: now).compactMap { delivery in
                guard let sink = state.sinks[delivery.subscriptionID] else { return nil }
                return PendingDelivery(
                    subscriptionID: delivery.subscriptionID,
                    event: delivery.event,
                    sink: sink)
            }
        })
    }

    /// Flushes coalesced notifications whose cadence has elapsed.
    public func flushDue(at now: Date = Date()) {
        deliver(state.withLock { state in
            state.broker.flushDue(at: now).compactMap { delivery in
                guard let sink = state.sinks[delivery.subscriptionID] else { return nil }
                return PendingDelivery(
                    subscriptionID: delivery.subscriptionID,
                    event: delivery.event,
                    sink: sink)
            }
        })
    }

    private func deliver(_ deliveries: [PendingDelivery]) {
        var failedIDs: [UUID] = []
        for delivery in deliveries {
            do {
                try delivery.sink(delivery.event)
            } catch {
                failedIDs.append(delivery.subscriptionID)
            }
        }
        guard !failedIDs.isEmpty else { return }
        state.withLock { state in
            for id in failedIDs {
                state.sinks.removeValue(forKey: id)
                state.broker.unsubscribe(id)
            }
        }
    }
}
