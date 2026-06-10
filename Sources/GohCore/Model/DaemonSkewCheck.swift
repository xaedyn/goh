/// The daemon's feature-level skew classification relative to the client's.
///
/// `staleIdle` / `staleBusy` mean the running daemon is older than the client;
/// `current` means the daemon is at or ahead of the client's expected level.
public enum DaemonSkew: Sendable, Equatable {
    /// Daemon is current (reported >= expected). No action needed.
    case current
    /// Daemon is stale and no downloads are active — safe to auto-restart.
    case staleIdle
    /// Daemon is stale but downloads are active — emit notice, do not restart.
    case staleBusy
}

/// Pure skew classifier. No I/O. Injectable in tests via `evaluate(...)`.
public enum DaemonSkewCheck {

    /// Classifies the daemon's reported featureLevel against the client's expectation.
    ///
    /// - Parameters:
    ///   - reported: The `LsReply.featureLevel` from the running daemon.
    ///     `nil` means the daemon pre-dates featureLevel (= stale).
    ///   - expected: The client's `GohFeatureLevel.current`.
    ///   - activeDownloadCount: Number of `.active` jobs from the same `LsReply`.
    /// - Returns: `.current`, `.staleIdle`, or `.staleBusy`.
    public static func evaluate(
        reported: Int?,
        expected: Int,
        activeDownloadCount: Int
    ) -> DaemonSkew {
        guard let reported, reported >= expected else {
            return activeDownloadCount == 0 ? .staleIdle : .staleBusy
        }
        return .current
    }
}
