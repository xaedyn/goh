import Synchronization

/// Daemon-global per-host active-connection budget (spec §8). Across all concurrent downloads to one
/// host key, at most `maxPerHost` connections are open at once. The control loop requests a slot before
/// spawning a worker; a denied request holds N. Thread-safe.
public final class ConnectionBudget: Sendable {
    private let maxPerHost: Int
    private let active: Mutex<[String: Int]>

    public init(maxPerHost: Int = 16) {
        self.maxPerHost = maxPerHost
        self.active = Mutex([:])
    }

    /// Reserves `slots` for `hostKey`. Returns true iff granted (current + slots <= maxPerHost).
    public func request(slots: Int, hostKey: String) -> Bool {
        active.withLock { dict in
            let current = dict[hostKey, default: 0]
            guard current + slots <= maxPerHost else { return false }
            dict[hostKey] = current + slots
            return true
        }
    }

    /// Releases `slots` for `hostKey`.
    public func release(slots: Int, hostKey: String) {
        active.withLock { dict in
            let after = max(0, dict[hostKey, default: 0] - slots)
            if after == 0 { dict.removeValue(forKey: hostKey) } else { dict[hostKey] = after }
        }
    }

    /// Current usage for `hostKey` (diagnostics).
    public func usage(hostKey: String) -> Int { active.withLock { $0[hostKey, default: 0] } }
}
