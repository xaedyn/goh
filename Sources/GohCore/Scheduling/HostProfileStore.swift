import Darwin
import Foundation
import Synchronization

/// A failure writing the host-scheduling file to disk.
public enum HostProfileStoreError: Error {
    case fsyncOpenFailed(path: String, errno: Int32)
    case fsyncFailed(path: String, errno: Int32)
    case renameFailed(errno: Int32)
}

/// The outcome of loading the host-scheduling record.
public struct HostProfileLoadResult: Sendable {
    /// The loaded scheduling — empty when the file was missing or unreadable.
    public var scheduling: HostScheduling
    /// When the on-disk file was unreadable, the path the bytes were copied to
    /// before recovery; `nil` on a clean or first-run load.
    public var corruptionSidecar: URL?
}

/// Reads, writes, and maintains the in-memory host-scheduling state.
///
/// Concurrency: all mutable state is guarded by a `Mutex` — matching the
/// existing `Synchronization.Mutex` primitive used in `DownloadEngine` and
/// `RangeProgress`. The store is `Sendable`.
///
/// Saves are atomic and durable — identical pattern to `CatalogStore` and
/// `CheckpointStore` (temp→fsync→rename(2)→dir-fsync). The output file is
/// written at owner-only 0600 permissions because the file is daemon-internal
/// with no external reader.
///
/// The in-memory active-job index is NOT persisted; it is live daemon state
/// rebuilt from the active set on restart (D5/D7).
///
/// Persist failures in `recordObservation` are non-fatal (a failed optimization
/// write must not break the download) but are surfaced via the injected
/// `persistFailureReporter` so the daemon can log them via its existing
/// `warn()` channel. Pass `nil` only in tests that don't need the callback.
public final class HostProfileStore: Sendable {

    // MARK: — Tuning constants (non-frozen daemon constants per D3)

    /// 90-day TTL for evicting stale host profiles on load.
    public static let ttlSeconds: Double = 90 * 24 * 3600

    // MARK: — Private state

    private let fileURL: URL
    private let inner: Mutex<Inner>
    /// Called on a persist failure in `recordObservation`. Non-fatal — the
    /// in-memory state is already updated; only the write failed.
    private let persistFailureReporter: (@Sendable (String, any Error) -> Void)?

    private struct Inner: Sendable {
        var scheduling: HostScheduling
        /// Active job IDs per host key. Cleared when a host's set becomes empty.
        var activeJobs: [String: Set<UInt64>]
        /// Job IDs that were ever concurrent with a sibling. Cleared in end().
        var contended: Set<UInt64>
    }

    // MARK: — Init

    public init(
        fileURL: URL,
        persistFailureReporter: (@Sendable (String, any Error) -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.persistFailureReporter = persistFailureReporter
        self.inner = Mutex(Inner(scheduling: .empty, activeJobs: [:], contended: []))
    }

    // MARK: — Load / Save

    /// Loads from disk, evicting profiles older than `ttlSeconds`, and updates
    /// the in-memory state. Call once at daemon startup.
    @discardableResult
    public func load(now: Date = Date()) -> HostProfileLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return HostProfileLoadResult(scheduling: .empty, corruptionSidecar: nil)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            var scheduling = try PropertyListDecoder().decode(HostScheduling.self, from: data)
            guard scheduling.version == HostScheduling.currentVersion else {
                return recoverToEmpty()
            }
            // D9: evict profiles whose updatedAt is older than ttlSeconds.
            scheduling.hosts = scheduling.hosts.filter { profile in
                now.timeIntervalSince(profile.updatedAt) < Self.ttlSeconds
            }
            inner.withLock { $0.scheduling = scheduling }
            return HostProfileLoadResult(scheduling: scheduling, corruptionSidecar: nil)
        } catch {
            return recoverToEmpty()
        }
    }

    /// Atomically and durably persists `scheduling`, updating the in-memory state.
    /// Use for direct saves (e.g., tests, migration). In production the daemon
    /// calls `recordObservation` which persists automatically.
    public func save(_ scheduling: HostScheduling) throws {
        inner.withLock { $0.scheduling = scheduling }
        try writeAtomically(scheduling)
    }

    // MARK: — Per-host active-job index (D5/D7 — not persisted)

    /// Records that jobID has started on hostKey.
    /// If any other job is already active on hostKey, marks ALL of them (including
    /// this one and any pre-existing siblings) contended.
    public func begin(jobID: UInt64, hostKey: String) {
        inner.withLock { inner in
            inner.activeJobs[hostKey, default: []].insert(jobID)
            if inner.activeJobs[hostKey]!.count > 1 {
                for id in inner.activeJobs[hostKey]! {
                    inner.contended.insert(id)
                }
            }
        }
    }

    /// Returns true iff jobID was never concurrent with a sibling on its host.
    /// Call BEFORE end(jobID:hostKey:) — once end() removes the job, wasSolo
    /// always returns false for it.
    public func wasSolo(jobID: UInt64) -> Bool {
        inner.withLock { !$0.contended.contains(jobID) }
    }

    /// Records that jobID has finished on hostKey.
    /// Removes the job from both the active set and the contended set.
    public func end(jobID: UInt64, hostKey: String) {
        inner.withLock { inner in
            inner.activeJobs[hostKey]?.remove(jobID)
            if inner.activeJobs[hostKey]?.isEmpty == true {
                inner.activeJobs.removeValue(forKey: hostKey)
            }
            inner.contended.remove(jobID)
        }
    }

    // MARK: — Observation recording (D5, D7)

    /// Folds a completed-download observation into the matching arm's EWMA and
    /// persists the updated state.
    ///
    /// The D5 gates (duration ≥ 10 s, bytes ≥ 8 MiB, `wasSolo(jobID)` true,
    /// actualConnectionCount == requestedConnectionCount, not a resume) are
    /// checked by the CALLER (the `completedDownloadHandler` in `gohd/main.swift`).
    /// This method receives only observations that have already passed the gates.
    ///
    /// A persist failure is non-fatal — the in-memory EWMA is updated regardless.
    /// Failures are surfaced via the `persistFailureReporter` injected at init so
    /// the daemon can log them via its existing `warn()` channel.
    public func recordObservation(
        hostKey: String,
        connectionCount: UInt8,
        totalBytes: UInt64,
        transferDuration: Duration,
        alpha: Double = 0.3
    ) {
        let seconds =
            Double(transferDuration.components.seconds)
            + Double(transferDuration.components.attoseconds) / 1e18
        guard seconds > 0 else { return }
        let throughput = Double(totalBytes) / seconds
        let now = Date()

        inner.withLock { inner in
            if let idx = inner.scheduling.hosts.firstIndex(where: { $0.host == hostKey }) {
                if let armIdx = inner.scheduling.hosts[idx].arms
                    .firstIndex(where: { $0.connectionCount == connectionCount }) {
                    inner.scheduling.hosts[idx].arms[armIdx] =
                        inner.scheduling.hosts[idx].arms[armIdx]
                        .foldingIn(throughput: throughput, alpha: alpha)
                } else {
                    inner.scheduling.hosts[idx].arms.append(
                        ConnObservation(
                            connectionCount: connectionCount,
                            throughputEWMA: throughput,
                            sampleCount: 1,
                            updatedAt: now))
                }
                inner.scheduling.hosts[idx].updatedAt = now
            } else {
                inner.scheduling.hosts.append(HostProfile(
                    host: hostKey,
                    arms: [ConnObservation(
                        connectionCount: connectionCount,
                        throughputEWMA: throughput,
                        sampleCount: 1,
                        updatedAt: now)],
                    updatedAt: now))
            }
        }

        let snapshot = inner.withLock { $0.scheduling }
        do {
            try writeAtomically(snapshot)
        } catch {
            persistFailureReporter?("host-profile persist hostKey=\(hostKey)", error)
        }
    }

    // MARK: — Observation gate (D5, D8)

    /// D5/D8 gate — whether a completed download qualifies as a clean per-host
    /// throughput observation. Pure and side-effect-free so it can be unit-tested
    /// in isolation; the daemon's completion handler calls this to decide whether
    /// to call `recordObservation`.
    ///
    /// Records IFF: not a resume (D8); transfer phase ran at least `minTransferDuration`;
    /// at least `minBytes` were transferred; the download was solo for its whole
    /// duration (`wasSolo`); and the engine actually used the requested connection
    /// count (a server that ignored Range and fell back to 1 connection must not
    /// pollute the arm for the requested N).
    public static func shouldRecordObservation(
        isResume: Bool,
        transferDuration: Duration,
        bytesCompleted: UInt64,
        wasSolo: Bool,
        actualConnectionCount: UInt8,
        requestedConnectionCount: UInt8,
        minTransferDuration: Duration = .seconds(10),
        minBytes: UInt64 = 8 * 1024 * 1024
    ) -> Bool {
        guard !isResume else { return false }
        return transferDuration >= minTransferDuration
            && bytesCompleted >= minBytes
            && wasSolo
            && actualConnectionCount == requestedConnectionCount
    }

    // MARK: — Selection (D4, D6)

    /// Returns the bandit's chosen N and the reason.
    ///
    /// When `hostKey` is nil (D1: nil-host skip), always returns `(defaultN, .cold)`.
    public func selectN(
        hostKey: String?,
        selector: BanditSelector = BanditSelector()
    ) -> (n: UInt8, reason: SelectionReason) {
        guard let key = hostKey else {
            return (BanditSelector.defaultN, .cold)
        }
        let profile = inner.withLock { inner in
            inner.scheduling.hosts.first { $0.host == key }
        }
        var rng = SystemRandomNumberGenerator()
        return selector.select(profile: profile, rng: &rng)
    }

    // MARK: — Snapshot accessors (for tests and diagnostics)

    /// Returns the current in-memory scheduling (for test assertions).
    public func currentScheduling() -> HostScheduling {
        inner.withLock { $0.scheduling }
    }

    /// Returns the current in-memory profile for `hostKey`, or nil if not found.
    /// Used by `CommandDispatcher` to read arm EWMAs for the AC12 trace.
    public func profile(hostKey: String) -> HostProfile? {
        inner.withLock { $0.scheduling.hosts.first { $0.host == hostKey } }
    }

    // MARK: — Private helpers

    private func recoverToEmpty() -> HostProfileLoadResult {
        let timestamp = Int(Date().timeIntervalSince1970)
        let sidecar = fileURL.deletingLastPathComponent()
            .appending(path: "\(fileURL.lastPathComponent).corrupt-\(timestamp)")
        try? FileManager.default.copyItem(at: fileURL, to: sidecar)
        let sidecarExists = FileManager.default.fileExists(atPath: sidecar.path)
        inner.withLock { $0.scheduling = .empty }
        return HostProfileLoadResult(
            scheduling: .empty,
            corruptionSidecar: sidecarExists ? sidecar : nil)
    }

    private func writeAtomically(_ scheduling: HostScheduling) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(scheduling)

        let directory = fileURL.deletingLastPathComponent()
        let temporaryURL = directory.appending(
            path: ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")

        do {
            try data.write(to: temporaryURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            try Self.fsync(path: temporaryURL.path)
            guard rename(temporaryURL.path, fileURL.path) == 0 else {
                throw HostProfileStoreError.renameFailed(errno: errno)
            }
            try Self.fsync(path: directory.path)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func fsync(path: String) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw HostProfileStoreError.fsyncOpenFailed(path: path, errno: errno)
        }
        defer { close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw HostProfileStoreError.fsyncFailed(path: path, errno: errno)
        }
    }
}
