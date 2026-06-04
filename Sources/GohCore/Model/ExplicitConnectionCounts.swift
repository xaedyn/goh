// Sources/GohCore/Model/ExplicitConnectionCounts.swift
import Synchronization

/// Daemon-internal map of `jobID → user-supplied connection count`.
///
/// This is the explicit-`--connections` "governor-off" channel: when a job is
/// admitted with a user-supplied count, the dispatcher records it here; the
/// scheduler consumes it to run that job with the in-flight parallelism governor
/// turned OFF (the connection count is statically pinned). It is NEVER on the
/// wire — not part of `JobSummary`, carries no `protocolVersion`.
///
/// A `Sendable` reference type wrapping a `Mutex` (a bare `Mutex` is noncopyable
/// and cannot be a struct stored property or shared across the daemon's closures).
public final class ExplicitConnectionCounts: Sendable {
    private let table: Mutex<[UInt64: UInt8]>

    public init() { table = Mutex([:]) }

    /// Records `jobID`'s explicit connection count (admission time).
    public func set(jobID: UInt64, count: UInt8) {
        table.withLock { $0[jobID] = count }
    }

    /// Removes and returns `jobID`'s explicit count, or nil if none was set
    /// (the governor may run for that job). Consumed by the scheduler.
    public func consume(jobID: UInt64) -> UInt8? {
        table.withLock { $0.removeValue(forKey: jobID) }
    }
}
