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

    private let reader: any ProvenanceReading
    private let provenanceStorePath: String
    private let presenter: GohTrustPresenter
    private var cancellationBox: CancellationBox?

    public init(
        reader: any ProvenanceReading,
        provenanceStorePath: String,
        presenter: GohTrustPresenter = GohTrustPresenter()
    ) {
        self.reader = reader
        self.provenanceStorePath = provenanceStorePath
        self.presenter = presenter
    }

    // MARK: - Load overview (off-main)

    /// Load the trust overview from the ledger. Call from `.task {}` on the Trust window.
    public func loadOverview() async {
        let outcome = await Task.detached(priority: .userInitiated) { [reader] in
            reader.read()
        }.value
        let (ov, rs) = presenter.present(outcome)
        overview = ov
        rows = rs
    }

    // MARK: - Verify now

    /// Start a background verify run. Disabled while already running.
    /// Dispatches the blocking re-hash on a real OS thread (NOT the cooperative pool).
    public func startVerify() {
        guard case .idle = runState else { return }
        guard !rows.isEmpty else { return }

        let box = CancellationBox()
        cancellationBox = box
        runState = .running(VerifyProgress(completed: 0, total: rows.count, currentPath: nil))

        let path = provenanceStorePath
        let now = Date()

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
                }
            } catch {
                Task { @MainActor in
                    weakSelf.value?.runState = .failed("verify failed: \(error)")
                    weakSelf.value?.cancellationBox = nil
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
        runState = .idle
    }
}
