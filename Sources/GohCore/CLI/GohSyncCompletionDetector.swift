import Foundation

/// Polls the daemon's job list to detect when a `goh sync` download finishes
/// (spec §9.1, T6.3).
///
/// After `add` returns a job id, the CLI polls `ls`, finds that id, and decides:
///   - `completed` → done (the caller re-hashes the file).
///   - `failed` → exit-contribution 8, EXCEPT `symlinkComponentRefused` → 5.
///   - id ABSENT from a *successful* `ls` → the job vanished → exit-contribution 8.
///   - `ls` THROWS → transient transport: bounded retry, then exit 1 (distinct
///     from 8 — a thrown `ls` is never classified as "disappeared").
///   - No state transition or byte advance for `watchdogSeconds` → exit 8
///     (`timed out (no progress)`); the watchdog resets on any progress.
///
/// Determinism: the watchdog is driven by the injected `watchdogSeconds` and the
/// `ls` replies, so tests pass a tiny value (~0.05) and a fake `ls` that keeps
/// returning `active` to exercise the timeout without sleeping 120 s.
struct CompletionDetector {
    let send: GohCommandLine.Sender
    let watchdogSeconds: TimeInterval

    /// Per-poll pause. 250 ms matches the rest of the codebase's poll cadence
    /// (`DaemonAutoHeal`, spec §6); a full `ls` — which deserializes the entire
    /// job list — every 10 ms cost up to ~12,000 XPC round-trips per asset. Kept
    /// as a `var` so a caller or test can override it.
    var pollInterval: TimeInterval = 0.25
    /// Max consecutive thrown `ls` calls before declaring a transport failure.
    var maxLsRetries = 3

    enum Result: Equatable {
        case completed
        /// A terminal failure with its exit contribution and a message.
        case failed(contribution: Int32, message: String)
        /// A transport failure (thrown `ls` past the retry budget).
        case transport(message: String)
    }

    func awaitCompletion(jobID: UInt64) -> Result {
        var lastProgressTick = Date()
        var lastObservedState: JobState?
        var lastObservedBytes: UInt64?
        var consecutiveThrows = 0

        let client = GohCommandClient(send: send)

        while true {
            // Poll ls.
            let jobs: [JobSummary]
            do {
                let reply = try client.send(.ls, expecting: LsReply.self)
                jobs = reply.jobs
                consecutiveThrows = 0
            } catch {
                consecutiveThrows += 1
                if consecutiveThrows >= maxLsRetries {
                    return .transport(
                        message: "lost contact with gohd while polling (\(error))")
                }
                Thread.sleep(forTimeInterval: pollInterval)
                continue
            }

            // Find the job by id in a SUCCESSFUL reply.
            guard let job = jobs.first(where: { $0.id == jobID }) else {
                // Absent from a successful ls → it disappeared.
                return .failed(contribution: 8, message: "job disappeared")
            }

            switch job.state {
            case .completed:
                return .completed
            case .failed:
                if job.error?.code == .symlinkComponentRefused {
                    return .failed(
                        contribution: 5,
                        message: "download refused (symlink component): \(job.error?.message ?? "")")
                }
                let detail = job.error?.message.map { ": \($0)" } ?? ""
                return .failed(contribution: 8, message: "download failed\(detail)")
            case .queued, .active, .paused:
                break
            }

            // Watchdog: any state transition or byte advance resets the clock.
            let bytes = job.progress.bytesCompleted
            let progressed = (lastObservedState != job.state) || (lastObservedBytes != bytes)
            if progressed {
                lastProgressTick = Date()
                lastObservedState = job.state
                lastObservedBytes = bytes
            } else if Date().timeIntervalSince(lastProgressTick) >= watchdogSeconds {
                return .failed(contribution: 8, message: "timed out (no progress)")
            }

            Thread.sleep(forTimeInterval: pollInterval)
        }
    }
}
