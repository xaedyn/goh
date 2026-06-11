/// Shared, module-internal CLI user-facing message builders.
///
/// Exists to keep a SINGLE implementation of the daemon-error → stderr mapping.
/// Previously three call sites (`goh` dispatch, foreground download, `goh top`)
/// each carried their own near-identical copy, and only the dispatch copy knew
/// to add the "restart the daemon" hint on a protocol-version mismatch. Routing
/// all three through `daemonError(_:)` unifies that behavior — the foreground and
/// top paths now also surface the restart hint on a mismatch.
enum CLIMessages {

    /// Maps a `GohError` to the canonical `gohd: …\n` stderr line.
    ///
    /// On `.protocolVersionMismatch` it appends the restart hint, because a
    /// version skew between the client and the running daemon is only resolved by
    /// restarting the daemon — no other remedy applies.
    static func daemonError(_ error: GohError) -> String {
        if error.code == .protocolVersionMismatch {
            let detail = error.message?.isEmpty == false
                ? error.message!
                : error.code.rawValue
            return "gohd: \(detail)\nRestart the daemon with: brew services restart goh\n"
        }

        if let message = error.message, !message.isEmpty {
            return "gohd: \(message)\n"
        }
        return "gohd: \(error.code.rawValue)\n"
    }
}
