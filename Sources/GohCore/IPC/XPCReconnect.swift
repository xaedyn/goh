import Foundation

/// A bounded reconnection attempt for a foreground client whose `gohd` session
/// dropped — for example when the daemon crashed and `launchd` is relaunching it
/// (see `DESIGN.md` §2.2).
public enum XPCReconnect {

    /// The outcome of `attempt(within:pollInterval:connect:)`.
    public enum Outcome: Sendable, Equatable {
        /// `connect` succeeded within the window.
        case reconnected
        /// The window elapsed without a successful `connect`.
        case gaveUp
    }

    /// Retries `connect` until it succeeds or `window` elapses, pausing
    /// `pollInterval` between tries. `connect` is invoked once immediately, then
    /// after each pause.
    ///
    /// A `launchd`-relaunched daemon is not instantly back — it must restart,
    /// re-read its state, and re-register its listener — so a single instant
    /// retry fires too early; the window gives it time to return. This is *one
    /// bounded attempt*: no exponential backoff, no attempt cap beyond the
    /// window itself. `connect` re-resolves the Mach service and re-validates
    /// the daemon's audit token by construction (it builds a fresh validated
    /// session); a foreground caller re-subscribes to its job on success.
    public static func attempt(
        within window: Duration,
        pollInterval: Duration,
        connect: () -> Bool
    ) -> Outcome {
        let clock = ContinuousClock()
        let deadline = clock.now + window
        while true {
            if connect() { return .reconnected }
            if clock.now >= deadline { return .gaveUp }
            Thread.sleep(forTimeInterval: pollInterval.timeIntervalValue)
        }
    }
}

extension Duration {
    /// This duration expressed as a `TimeInterval` (seconds).
    fileprivate var timeIntervalValue: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
