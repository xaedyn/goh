import Foundation
import Synchronization
import GohCore

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

    private let reader: any ProvenanceReading
    private let provenanceStorePath: String
    private let presenter: GohTrustPresenter
    /// Injected probe for fast-check calls. `LiveFileStatProbe` in production;
    /// a stub in tests.
    private let probe: any FileStatProbing
    private var cancellationBox: CancellationBox?

    /// Wall-clock timestamp at which the current verify run started.
    /// Set when transitioning to `.running`; cleared on run end and `reset()`.
    /// Exposed as `internal` so unit tests can inject a fixed start time.
    internal var verifyStartedAt: Date?

    public init(
        reader: any ProvenanceReading,
        provenanceStorePath: String,
        presenter: GohTrustPresenter = GohTrustPresenter(),
        probe: any FileStatProbing = LiveFileStatProbe()
    ) {
        self.reader = reader
        self.provenanceStorePath = provenanceStorePath
        self.presenter = presenter
        self.probe = probe
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
                    isCancelled: { box.isCancelled() })

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
                    etaText = "ETA " + Self.formatDuration(secs)
                }
            }
        }
        return VerifyLiveStats(fraction: fraction, byteText: byteText, etaText: etaText)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
