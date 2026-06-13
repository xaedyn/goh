import Foundation
import GohCore

// MARK: - Shared enums / value types (nonisolated Sendable per GohMenuBar convention)

nonisolated public enum GohNotificationAuthorization: Sendable {
    case authorized
    case denied
    case undetermined
}

nonisolated public struct GohNotificationContent: Sendable, Equatable {
    /// Short title, e.g. "Download Complete" or "Download Failed".
    public let title: String
    /// Secondary line — the file name (filename only; never a full path, per the
    /// §5 PII rule).
    public let subtitle: String
    /// Body line — outcome + size for completes ("Verified · 6.94 GB"), or the
    /// failure reason for failures.
    public let body: String

    public nonisolated init(title: String, subtitle: String = "", body: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

// MARK: - Service protocol (implemented by live UNUserNotificationCenter in goh-menu; stubbed in tests)

public protocol GohMenuNotificationService: Sendable {
    /// Returns the current authorization status without prompting.
    func authorizationStatus() async -> GohNotificationAuthorization
    /// Requests authorization once. Idempotent; errors are swallowed (best-effort).
    func requestAuthorization() async
    /// Posts a notification. Best-effort: errors are swallowed; view never sees raw errors.
    func post(_ content: GohNotificationContent) async
}

// MARK: - Pure transition detector (no framework, fully unit-tested)

/// Stateless mapper: given the previous per-job state map and the current snapshot batch,
/// returns the notifications to post and the updated state map.
///
/// Contract (spec §7.2):
/// - previous == nil (seed): suppress all notifications; return current states as `next`.
/// - previous != nil: emit one GohNotificationContent for each job whose state went
///   non-terminal → terminal. Jobs absent from snapshots are dropped from `next`.
nonisolated public struct GohNotificationTransitionDetector: Sendable {
    public nonisolated init() {}

    public nonisolated func evaluate(
        previous: [UInt64: JobState]?,
        snapshots: [ProgressSnapshot]
    ) -> (toPost: [GohNotificationContent], next: [UInt64: JobState]) {
        // Build the current map from the snapshot batch.
        var next: [UInt64: JobState] = [:]
        for snapshot in snapshots {
            next[snapshot.job.id] = snapshot.job.state
        }

        // Seed path: suppress all notifications; just seed the map.
        guard let previous else {
            return (toPost: [], next: next)
        }

        // Transition path: emit one notification per non-terminal → terminal edge.
        var toPost: [GohNotificationContent] = []
        for snapshot in snapshots {
            let job = snapshot.job
            let currentState = job.state
            guard currentState.isTerminal else { continue }

            let previousState = previous[job.id]
            // Only fire on the transition edge: was not terminal (or absent = new job appearing terminal).
            // A new job appearing directly terminal in the first post-seed update should fire.
            // A job already recorded terminal should not re-fire.
            if let prev = previousState, prev.isTerminal {
                // Already terminal — no edge, no notification.
                continue
            }

            let fileName = URL(filePath: job.destination).lastPathComponent
            // Filename only — never fall back to the full local path (keeps the
            // redaction discipline: no path leakage in user-facing notifications).
            let displayName = fileName.isEmpty ? "your download" : fileName

            let content: GohNotificationContent
            switch currentState {
            case .completed:
                // The bytes were SHA-256-hashed in-flight and recorded to the
                // ledger at completion, so "Verified" is the origin-trust claim.
                let sizeSuffix = job.progress.bytesTotal.map { " · \(JobDisplayFormatter.formatBytes($0))" } ?? ""
                content = GohNotificationContent(
                    title: "Download Complete",
                    subtitle: displayName,
                    body: "Verified\(sizeSuffix)")
            case .failed:
                content = GohNotificationContent(
                    title: "Download Failed",
                    subtitle: displayName,
                    body: job.error?.message ?? "The download couldn't be completed.")
            default:
                // Should not reach here due to isTerminal guard above.
                continue
            }
            toPost.append(content)
        }

        return (toPost: toPost, next: next)
    }
}

// MARK: - JobState terminal helper

private extension JobState {
    nonisolated var isTerminal: Bool {
        switch self {
        case .completed, .failed: true
        case .queued, .active, .paused: false
        }
    }
}
