// Sources/GohCore/Engine/ChunkQueue.swift
import Synchronization

/// A byte interval: start offset + length. Isomorphic to ByteRange but named
/// separately to distinguish "a unit of work in the queue" from "a range spec."
public struct ByteInterval: Sendable, Equatable {
    public var start: UInt64
    public var length: UInt64

    public init(start: UInt64, length: UInt64) {
        self.start = start
        self.length = length
    }

    public init(from range: ByteRange) {
        self.start = range.start
        self.length = range.length
    }

    public var end: UInt64 { start + length }
}

/// A `Mutex`-guarded queue of remaining byte intervals for the dynamic chunk pool.
///
/// Workers pull one interval at a time; completed intervals are marked via
/// `markDone(_:)`. A dropped worker returns its un-started interval to the
/// front via `returnToFront(_:)`. Thread-safe.
public final class ChunkQueue: Sendable {

    private struct State: Sendable {
        var pending: [ByteInterval]      // sorted by start; front is next to pull
        var inFlight: Set<UInt64>        // starts of in-flight intervals
        var done: Set<UInt64>            // starts of completed intervals
        var totalIntervals: Int
    }

    private let state: Mutex<State>

    public init(intervals: [ByteInterval]) {
        let sorted = intervals.sorted { $0.start < $1.start }
        state = Mutex(State(
            pending: sorted,
            inFlight: [],
            done: [],
            totalIntervals: sorted.count))
    }

    /// Pulls the next pending interval. Returns nil when the queue is empty.
    public func pull() -> ByteInterval? {
        state.withLock { s -> ByteInterval? in
            guard !s.pending.isEmpty else { return nil }
            let interval = s.pending.removeFirst()
            s.inFlight.insert(interval.start)
            return interval
        }
    }

    /// Returns an interval to the front of the pending queue (dropped worker).
    public func returnToFront(_ interval: ByteInterval) {
        state.withLock { s in
            s.inFlight.remove(interval.start)
            s.pending.insert(interval, at: 0)
        }
    }

    /// Marks an interval as completed.
    public func markDone(_ interval: ByteInterval) {
        state.withLock { s in
            s.inFlight.remove(interval.start)
            s.done.insert(interval.start)
        }
    }

    /// Bytes still pending (not yet pulled). Used by the governor for the tiny-file guard.
    public var remainingBytes: UInt64 {
        state.withLock { s in
            s.pending.reduce(0) { $0 + $1.length }
        }
    }

    /// True when all intervals have been completed.
    public var isDone: Bool {
        state.withLock { s in
            s.done.count == s.totalIntervals && s.pending.isEmpty && s.inFlight.isEmpty
        }
    }
}
