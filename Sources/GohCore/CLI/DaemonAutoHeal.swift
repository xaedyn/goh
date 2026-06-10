import Darwin   // getuid() — required; not implied by Foundation on all SDK configs (B5 fix)
import Foundation
import XPC

/// Shared auto-heal logic for commands scoped to detect and correct daemon skew.
///
/// Scoped to: `goh verify --all`, `goh verify --quick`, `goh doctor`.
/// NOT invoked by every verb — that would add a needless per-command round-trip.
///
/// Protocol:
/// 1. Send `.ls` to classify skew (`DaemonSkewCheck.evaluate`).
/// 2. `.staleIdle` → re-check idle (tighten TOCTOU window). If still idle,
///    call `restarter.kickstart()`. Poll `.ls` until `featureLevel >= current`
///    or budget exhausted. On timeout or kickstart failure → notice only.
/// 3. `.staleBusy` → notice only (no restart while downloads run).
/// 4. `.current` → no-op.
/// 5. All failures (XPC, kickstart, poll timeout) → notice only. Exit code unchanged.
public enum DaemonAutoHeal {

    /// Duration type used for the poll budget and interval.
    /// Using `Duration` (Swift 5.7+; always available on macOS 26.0 target).
    public typealias Budget = Duration

    /// Run the auto-heal check and return an optional notice string.
    ///
    /// - Parameters:
    ///   - send: XPC sender (the CLI's existing send closure).
    ///   - restarter: Injectable restart seam. Nil disables the kickstart step
    ///     (test-only: pass nil to assert no kickstart was attempted).
    ///   - uid: User ID for the launchctl target (default: `getuid()`).
    ///   - pollBudget: Maximum time to wait for the new daemon. Default 5s (spec §6).
    ///   - pollInterval: Interval between `.ls` polls. Default 250ms (spec §6).
    /// - Returns: A non-nil notice string when skew was detected but NOT resolved
    ///   (busy, kickstart failed, or poll timed out). `nil` means either current
    ///   or successfully healed.
    @discardableResult
    public static func runIfNeeded(
        send: @escaping GohCommandLine.Sender,
        restarter: (any DaemonRestarting)?,
        uid: Int = Int(Darwin.getuid()),
        pollBudget: Budget = .seconds(5),
        pollInterval: Budget = .milliseconds(250)
    ) -> String? {
        // Step 1: Initial .ls to classify.
        let reply: LsReply
        do {
            reply = try sendLs(send)
        } catch {
            return nil  // XPC unreachable — not our problem here (doctor handles that)
        }
        let activeCount = reply.jobs.filter { $0.state == .active }.count
        let skew = DaemonSkewCheck.evaluate(
            reported: reply.featureLevel,
            expected: GohFeatureLevel.current,
            activeDownloadCount: activeCount)

        switch skew {
        case .current:
            return nil

        case .staleBusy:
            fputs(
                "goh: background service is an older build — "
                + "it will update automatically when downloads finish "
                + "(or run: goh daemon restart --force)\n",
                stderr)
            return "stale daemon (busy)"

        case .staleIdle:
            // Step 2: Re-check idle to tighten the TOCTOU window.
            do {
                let recheck = try sendLs(send)
                let recheckActive = recheck.jobs.filter { $0.state == .active }.count
                if recheckActive > 0 {
                    // A download started in the window — treat as busy.
                    fputs(
                        "goh: background service is an older build — "
                        + "a download started before the restart window closed. "
                        + "It will update when downloads finish.\n",
                        stderr)
                    return "stale daemon (became busy)"
                }
            } catch {
                return nil  // XPC lost — let the command proceed
            }

            // Step 3: Kickstart.
            guard let restarter else {
                return "stale daemon (no restarter configured)"
            }
            do {
                try restarter.kickstart()
            } catch {
                fputs(
                    "goh: could not restart background service (\(error)) — "
                    + "run: goh daemon restart\n",
                    stderr)
                return "stale daemon (kickstart failed: \(error))"
            }

            // Step 4: Poll until featureLevel >= current or budget exhausted.
            let deadline = ContinuousClock.now.advanced(by: pollBudget)
            while ContinuousClock.now < deadline {
                // Busy-wait with Thread.sleep (synchronous CLI context).
                // Must include both .seconds and .attoseconds to avoid 0-sleep spin
                // for any interval ≥ 1s (B1 fix).
                let intervalSecs = Double(pollInterval.components.seconds)
                    + Double(pollInterval.components.attoseconds) / 1e18
                Thread.sleep(forTimeInterval: intervalSecs)
                do {
                    let polled = try sendLs(send)
                    if let level = polled.featureLevel, level >= GohFeatureLevel.current {
                        return nil  // Successfully healed.
                    }
                    // nil or < current → keep polling (old daemon may still be dying)
                } catch {
                    // XPC temporarily unavailable during restart — keep polling
                }
            }

            // Step 5: Timeout → notice only (best-effort).
            fputs(
                "goh: background service did not respond with the new version within 5s — "
                + "it may need a moment. Run: goh doctor\n",
                stderr)
            return "stale daemon (poll timeout)"
        }
    }

    private static func sendLs(_ send: @escaping GohCommandLine.Sender) throws -> LsReply {
        try GohCommandClient(send: send).send(.ls, expecting: LsReply.self)
    }
}
