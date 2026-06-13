import Foundation
import Synchronization
import GohCore

/// Collects VerifiedBaseline values from the @Sendable onVerified closure.
/// Reference-type box so the @Sendable closure can capture a reference (not a mutable var).
nonisolated private final class BaselineCollectionBox: @unchecked Sendable {
    private let mutex = Mutex<[VerifiedBaseline]>([])
    nonisolated func append(_ b: VerifiedBaseline) { mutex.withLock { $0.append(b) } }
    nonisolated func drain() -> [VerifiedBaseline] { mutex.withLock { let v = $0; $0 = []; return v } }
}

/// Wraps a weak reference in a Sendable box for safe capture in @Sendable closures.
/// A @Sendable closure cannot capture a `weak var` directly — this box is captured
/// by value (the box is the strong reference; `value` is the weak back-reference).
private final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// Boxes a `Mutex<Bool>` in a reference type so the cancel flag can be captured
/// by value in a @Sendable closure on the worker thread. (`Mutex`/`Atomic` are
/// `~Copyable` and cannot be captured directly into an escaping @Sendable closure.)
/// Pattern mirrors `GohMenuProgressSubscriptionCancellation`.
///
/// `nonisolated` so `isCancelled()` is callable from off-main worker closures
/// without actor-hop overhead. The Mutex guarantees thread safety.
nonisolated private final class CancellationBox: @unchecked Sendable {
    private let flag = Mutex(false)

    nonisolated func cancel() { flag.withLock { $0 = true } }
    nonisolated func isCancelled() -> Bool { flag.withLock { $0 } }
}

/// The verify run state for the Trust window.
nonisolated public enum TrustRunState: Sendable, Equatable {
    case idle
    case running(VerifyProgress)
    case finished(VerifyAllReport)
    case cancelled(VerifyAllReport)   // partial report
    case failed(String)               // plain-English error message
}

/// Display statistics computed from a live `VerifyProgress` snapshot.
public struct VerifyLiveStats: Equatable {
    /// 0...1 overall fraction (bytesHashed / totalBytes); 0 when totalBytes == 0.
    public let fraction: Double
    /// e.g. "53.1 GB / 68.0 GB"; empty when totalBytes == 0.
    public let byteText: String
    /// e.g. "ETA 1m 12s"; nil during warm-up, when totalBytes == 0, or when rate == 0.
    public let etaText: String?
}

/// @MainActor view model for the Trust window.
///
/// Responsibilities:
/// - Loads trust overview + rows off-main on init (via the injected ProvenanceReading).
/// - Drives the background verify run (VerifyAllRunner on a dedicated OS thread).
/// - Publishes overview, rows, and runState to SwiftUI.
@MainActor
public final class TrustWindowViewModel: ObservableObject {

    @Published public private(set) var overview: GohTrustOverview = .empty
    @Published public private(set) var rows: [GohTrustEntryRow] = []
    @Published public private(set) var runState: TrustRunState = .idle

    /// Fast-check statuses keyed by `destinationPath`. Populated immediately
    /// after `loadOverview()` reads the ledger — before the view re-renders.
    @Published public private(set) var fastStatuses: [String: FastCheckStatus] = [:]

    /// On-disk SHA-256 of a CHANGED file, keyed by `destinationPath`, computed on
    /// demand when its row is selected. Powers the inspector's recorded-vs-current
    /// byte-diff. Empty until the selected changed file's hash completes.
    @Published public private(set) var currentHashes: [String: String] = [:]
    /// The path whose on-disk hash is currently being computed (for the
    /// "Computing on-disk hash…" inspector state); nil when idle.
    @Published public private(set) var hashingPath: String?

    private let reader: any ProvenanceReading
    private let provenanceStorePath: String
    private let presenter: GohTrustPresenter
    /// Injected probe for fast-check calls. `LiveFileStatProbe` in production;
    /// a stub in tests.
    private let probe: any FileStatProbing
    private var cancellationBox: CancellationBox?
    /// Cancellation for the in-flight on-demand hash (separate from verify).
    private var hashCancellationBox: CancellationBox?
    /// Injected client for best-effort baseline sends after a verify run.
    /// Nil in test contexts that do not exercise backfill.
    private let menuClient: (any GohMenuClient)?

    /// Wall-clock timestamp at which the current verify run started.
    /// Set when transitioning to `.running`; cleared on run end and `reset()`.
    /// Exposed as `internal` so unit tests can inject a fixed start time.
    internal var verifyStartedAt: Date?

    public init(
        reader: any ProvenanceReading,
        provenanceStorePath: String,
        presenter: GohTrustPresenter = GohTrustPresenter(),
        probe: any FileStatProbing = LiveFileStatProbe(),
        client: (any GohMenuClient)? = nil
    ) {
        self.reader = reader
        self.provenanceStorePath = provenanceStorePath
        self.presenter = presenter
        self.probe = probe
        self.menuClient = client
    }

    // MARK: - Load overview (off-main)

    /// Load the trust overview from the ledger. Call from `.task {}` on the Trust window.
    public func loadOverview() async {
        let capturedProbe = probe
        let (outcome, statuses) = await Task.detached(priority: .userInitiated) { [reader] in
            let outcome = reader.read()
            // Run the fast-check synchronously off-main with the injected probe.
            let entries: [ProvenanceEntry]
            if case .entries(let e) = outcome { entries = e } else { entries = [] }
            let fastResults = FastCheckRunner.checkAll(entries, probe: capturedProbe)
            // uniquingKeysWith (not uniqueKeysWithValues) so a hand-corrupted ledger with
            // duplicate destinationPaths can't trap the tray; last entry wins.
            let statuses = Dictionary(
                fastResults.map { ($0.destinationPath, $1) },
                uniquingKeysWith: { _, last in last })
            return (outcome, statuses)
        }.value
        let (ov, rs) = presenter.present(outcome)
        overview = ov
        rows = rs
        fastStatuses = statuses
    }

    // MARK: - On-demand current hash (the changed-file byte-diff)

    /// Computes the on-disk SHA-256 of a changed file on demand, so the inspector
    /// can show the real recorded-vs-current byte-diff. Idempotent per path (cached
    /// once computed); cancels any other in-flight hash. Runs on a real GCD thread
    /// (NOT `Task.detached`, which would stay on the cooperative pool and could
    /// starve it on a multi-GB file — same hazard the verify path avoids).
    ///
    /// Best-effort: a read failure (or cancellation) leaves the path unhashed and
    /// the inspector falls back to "Run Verify All to compute the on-disk hash."
    public func computeCurrentHash(forPath path: String) {
        if currentHashes[path] != nil || hashingPath == path { return }
        hashCancellationBox?.cancel()
        let box = CancellationBox()
        hashCancellationBox = box
        hashingPath = path

        let weakSelf = WeakRef(self)
        DispatchQueue.global(qos: .userInitiated).async { [box, path] in
            let hash = try? FileDigest.sha256WithSize(path: path, isCancelled: { box.isCancelled() }).0
            Task { @MainActor in
                guard let vm = weakSelf.value else { return }
                // Apply only if this is still the path we were hashing and not cancelled.
                guard vm.hashingPath == path, !box.isCancelled() else { return }
                vm.hashingPath = nil
                if let hash { vm.currentHashes[path] = hash }
            }
        }
    }

    /// Cancels any in-flight on-demand hash (e.g. selection changed / window closed).
    public func cancelHashing() {
        hashCancellationBox?.cancel()
        hashCancellationBox = nil
        hashingPath = nil
    }

    // MARK: - Forget (AC5)

    /// Whether a row's file is currently MISSING on disk (ENOENT), making its
    /// provenance entry eligible for a one-click Forget. Keys off the fast-check
    /// truth (`fastStatuses`), NOT the composite display status: a file that was
    /// verified and later deleted carries `verifiedAt != nil`, so its `displayStatus`
    /// is `.verified(at:)` even though its file is gone — gating on display status
    /// would hide Forget on exactly that common case. `FastCheckStatus.missing` is
    /// strictly ENOENT, so a present-but-unreadable file is NOT forgettable.
    public func isForgettable(path: String) -> Bool {
        fastStatuses[path] == .missing
    }

    /// A user-facing message when a Forget did not take effect — a daemon error, or
    /// the record was not removed (e.g. an installed daemon too old to support the
    /// Forget command). Shown as an alert; cleared on dismiss. Unlike the
    /// best-effort baseline send, Forget is an explicit user action, so its failure
    /// must NOT be silent.
    @Published public private(set) var forgetError: String?

    public func clearForgetError() { forgetError = nil }

    /// Removes the given path's provenance entry via the daemon, then refreshes the
    /// overview so the row disappears. Surfaces a message if the daemon errors or if
    /// the row is still present after the refresh (the command matched nothing —
    /// most often a daemon that predates Forget).
    public func forgetRow(path: String) async {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard let menuClient else {
            forgetError = "Forget is unavailable — there is no connection to the goh daemon."
            return
        }
        do {
            try await menuClient.forget(paths: [path])
        } catch {
            forgetError = "Couldn’t forget “\(name)”: \(GohMenuErrorMapper.map(error).userFacingMessage)"
            return
        }
        await loadOverview()
        if rows.contains(where: { $0.displayPath == path }) {
            forgetError = "“\(name)” couldn’t be removed. Your goh daemon may be an older version without Forget support — restart it (use Restart Daemon in the menu, or run `goh daemon restart`) and try again."
        }
    }

    // MARK: - Verify now

    /// Start a background verify run. Disabled while already running.
    /// Dispatches the blocking re-hash on a real OS thread (NOT the cooperative pool).
    public func startVerify() {
        guard case .idle = runState else { return }
        guard !rows.isEmpty else { return }

        let box = CancellationBox()
        cancellationBox = box
        let now = Date()
        verifyStartedAt = now
        runState = .running(VerifyProgress(completed: 0, total: rows.count, currentPath: nil))

        let path = provenanceStorePath

        // Capture self weakly before the @Sendable dispatch.
        // A @Sendable closure cannot capture a weak var by reference — we capture
        // the weak reference as a Sendable reference-type box instead.
        let weakSelf = WeakRef(self)
        let collectionBox = BaselineCollectionBox()
        // Check whether a client is wired before leaving MainActor; store a Bool
        // (Sendable) rather than the client itself (not Sendable across the thread boundary).
        let hasClient = menuClient != nil

        DispatchQueue.global(qos: .userInitiated).async { [box] in
            do {
                let report = try VerifyAllRunner.verifyAll(
                    provenanceStorePath: path,
                    generatedAt: now,
                    progress: { progress in
                        Task { @MainActor in
                            guard let vm = weakSelf.value else { return }
                            if case .running = vm.runState {
                                vm.runState = .running(progress)
                            }
                        }
                    },
                    isCancelled: { box.isCancelled() },
                    onVerified: { baseline in collectionBox.append(baseline) })

                // Send collected baselines best-effort — BEFORE updating runState,
                // so AC9 (cancelled run backfills) works for both .finished and .cancelled.
                // Access the @MainActor-isolated client via weakSelf on the MainActor Task.
                let baselines = collectionBox.drain()
                if hasClient, !baselines.isEmpty {
                    let entries = baselines.map { b in
                        VerifiedProvenanceEntry(
                            url: b.url,
                            sha256: b.sha256,
                            size: b.hashedByteCount,         // display/download byte count
                            destinationPath: b.destinationPath,
                            verifiedAt: now,
                            recordedStatSize: b.stat.size,   // B1: ALWAYS stat.size
                            recordedMtimeSeconds: b.stat.mtimeSeconds,
                            recordedMtimeNanoseconds: b.stat.mtimeNanoseconds,
                            recordedInode: b.stat.inode,
                            recordedDevice: b.stat.device)
                    }
                    Task { @MainActor [weakSelf] in
                        // Best-effort: error is swallowed — never block or error the UI.
                        guard let vm = weakSelf.value else { return }
                        try? await vm.menuClient?.recordVerifiedProvenance(entries)
                    }
                }

                Task { @MainActor in
                    guard let vm = weakSelf.value else { return }
                    if box.isCancelled() {
                        vm.runState = .cancelled(report)
                    } else {
                        vm.runState = .finished(report)
                    }
                    vm.cancellationBox = nil
                    vm.verifyStartedAt = nil
                }
            } catch let VerifyAllRunnerError.ledgerUnreadable(reason) {
                let message: String
                switch reason {
                case .io:       message = "provenance ledger unreadable"
                case .corrupt:  message = "provenance ledger corrupt"
                case .versionUnknown(let n): message = "provenance ledger version \(n) is unknown"
                }
                Task { @MainActor in
                    weakSelf.value?.runState = .failed(message)
                    weakSelf.value?.cancellationBox = nil
                    weakSelf.value?.verifyStartedAt = nil
                }
            } catch {
                Task { @MainActor in
                    weakSelf.value?.runState = .failed("verify failed: \(error)")
                    weakSelf.value?.cancellationBox = nil
                    weakSelf.value?.verifyStartedAt = nil
                }
            }
        }
    }

    /// Cancel the in-flight verify run. No-op if not running.
    public func cancelVerify() {
        cancellationBox?.cancel()
    }

    /// Reset to idle (called when the Trust window closes, if desired).
    public func reset() {
        cancellationBox?.cancel()
        cancellationBox = nil
        cancelHashing()
        verifyStartedAt = nil
        runState = .idle
    }

    // MARK: - Live stats

    /// Compute display statistics from a live `VerifyProgress` snapshot.
    /// Uses wall-clock elapsed since `verifyStartedAt` for the ETA calculation.
    public func liveStats(for p: VerifyProgress) -> VerifyLiveStats {
        liveStats(for: p, now: Date())
    }

    /// Testable overload — accepts an injected `now` so tests can pin the clock.
    internal func liveStats(for p: VerifyProgress, now: Date) -> VerifyLiveStats {
        guard p.totalBytes > 0 else {
            return VerifyLiveStats(fraction: 0, byteText: "", etaText: nil)
        }
        let fraction = min(1.0, Double(p.bytesHashed) / Double(p.totalBytes))
        let byteText = JobDisplayFormatter.formatBytes(UInt64(max(0, p.bytesHashed)))
            + " / " + JobDisplayFormatter.formatBytes(UInt64(max(0, p.totalBytes)))

        var etaText: String? = nil
        if let started = verifyStartedAt {
            let elapsed = now.timeIntervalSince(started)
            // Warm-up guard: need at least 0.5s elapsed and some bytes for a sane rate.
            if elapsed >= 0.5, p.bytesHashed > 0 {
                let rate = Double(p.bytesHashed) / elapsed   // bytes/sec
                if rate > 0 {
                    let remaining = Double(max(0, p.totalBytes - p.bytesHashed))
                    let secs = remaining / rate
                    etaText = "ETA " + JobDisplayFormatter.durationText(
                        seconds: UInt64(max(0, secs.rounded())))
                }
            }
        }
        return VerifyLiveStats(fraction: fraction, byteText: byteText, etaText: etaText)
    }

}
