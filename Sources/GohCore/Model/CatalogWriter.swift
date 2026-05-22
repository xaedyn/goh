import Dispatch
import Foundation
import Synchronization

/// Persists the job catalog asynchronously, coalescing rapid mutations into a
/// single write (`DESIGN.md` §2).
///
/// A mutation does not pay disk latency on the response path: it records the
/// latest catalog snapshot and, if no save is already scheduled, schedules one
/// after a short coalescing window. Several mutations inside the window collapse
/// to one save of the most recent snapshot. The trade is a small crash window —
/// the last few milliseconds of mutations can be lost on a daemon crash — which
/// is acceptable: a just-added job has not started downloading, and in-flight
/// progress is a separate mechanism.
public final class CatalogWriter: Sendable {
    private let store: CatalogStore
    private let window: TimeInterval
    private let queue = DispatchQueue(label: "dev.goh.catalog-writer")
    /// The latest snapshot awaiting a save; `nil` when no save is pending.
    private let pending = Mutex<JobCatalog?>(nil)

    /// Creates a writer saving to `store`, coalescing within `window` seconds.
    public init(store: CatalogStore, window: TimeInterval = 0.05) {
        self.store = store
        self.window = window
    }

    /// Records `catalog` as the latest state to persist, and schedules a save
    /// when one is not already pending.
    public func scheduleSave(_ catalog: JobCatalog) {
        let needsSchedule = pending.withLock { slot -> Bool in
            let wasIdle = (slot == nil)
            slot = catalog
            return wasIdle
        }
        guard needsSchedule else { return }
        queue.asyncAfter(deadline: .now() + window) { [self] in
            writePending()
        }
    }

    /// Synchronously writes any pending snapshot — for a graceful daemon
    /// shutdown, and for deterministic tests.
    public func flush() {
        queue.sync { self.writePending() }
    }

    private func writePending() {
        let snapshot = pending.withLock { slot -> JobCatalog? in
            let value = slot
            slot = nil
            return value
        }
        guard let snapshot else { return }
        do {
            try store.save(snapshot)
        } catch {
            FileHandle.standardError.write(
                Data("gohd: catalog save failed — \(error)\n".utf8))
        }
    }
}
