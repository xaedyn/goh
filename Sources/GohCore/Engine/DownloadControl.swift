import Dispatch
import Foundation
import Synchronization

/// The stop operation a command has requested of a running download.
public enum DownloadStopReason: Sendable, Equatable {
    case pause
    case remove(keepPartialFile: Bool)
}

/// How a running download answered a stop request.
public enum DownloadStopResult: Sendable, Equatable {
    case stopped
    case alreadyFinished
}

enum DownloadControlStop: Error, Sendable, Equatable {
    case pause
    case remove(keepPartialFile: Bool)

    init(reason: DownloadStopReason) {
        switch reason {
        case .pause:
            self = .pause
        case .remove(let keepPartialFile):
            self = .remove(keepPartialFile: keepPartialFile)
        }
    }
}

private final class PendingDownloadStop: @unchecked Sendable {
    let reason: DownloadStopReason
    private let semaphore = DispatchSemaphore(value: 0)
    private let result = Mutex<DownloadStopResult?>(nil)

    init(reason: DownloadStopReason) {
        self.reason = reason
    }

    func wait() -> DownloadStopResult {
        semaphore.wait()
        return result.withLock { $0 ?? .alreadyFinished }
    }

    func finish(_ value: DownloadStopResult) {
        let shouldSignal = result.withLock { result in
            guard result == nil else { return false }
            result = value
            return true
        }
        if shouldSignal {
            semaphore.signal()
        }
    }
}

/// Coordinates command-driven stops with the download engine.
///
/// `pause` and `rm --keep` must wait until the engine has written and
/// checkpointed its current piece. The command path records a stop request and
/// blocks on its waiter; the engine polls at checkpoint boundaries and signals
/// the waiter before unwinding.
public final class DownloadControl: Sendable {
    private struct State {
        var activeJobIDs: Set<UInt64> = []
        var pendingStops: [UInt64: PendingDownloadStop] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public func register(jobID: UInt64) {
        state.withLock { state in
            _ = state.activeJobIDs.insert(jobID)
        }
    }

    public func unregister(jobID: UInt64) {
        let pending = state.withLock { state in
            state.activeJobIDs.remove(jobID)
            return state.pendingStops.removeValue(forKey: jobID)
        }
        pending?.finish(.alreadyFinished)
    }

    public func requestStop(
        jobID: UInt64, reason: DownloadStopReason
    ) -> DownloadStopResult? {
        let pending: PendingDownloadStop? = state.withLock { state in
            guard state.activeJobIDs.contains(jobID) else { return nil }
            if let existing = state.pendingStops[jobID] {
                return existing
            }
            let created = PendingDownloadStop(reason: reason)
            state.pendingStops[jobID] = created
            return created
        }
        return pending?.wait()
    }

    func stopIfRequested(jobID: UInt64) throws {
        let pending = state.withLock { state in
            state.pendingStops.removeValue(forKey: jobID)
        }
        guard let pending else { return }
        pending.finish(.stopped)
        throw DownloadControlStop(reason: pending.reason)
    }
}
