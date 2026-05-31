import Foundation

/// The root on-disk type for the adaptive host-scheduling record
/// (`host-scheduling.plist`).
///
/// Format is a binary property list, version 1.
/// Only raw measurements are persisted here; all selection knobs
/// (candidate set, ε, α, minSamples, TTL, etc.) are non-frozen
/// daemon constants — per the D3 frozen-surface principle.
public struct HostScheduling: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// One entry per host that has been observed, keyed by the D1 normalized
    /// `"{scheme}://{host}:{port}"` string (credentials always stripped).
    public var hosts: [HostProfile]

    public init(version: Int = currentVersion, hosts: [HostProfile] = []) {
        self.version = version
        self.hosts = hosts
    }

    public static var empty: HostScheduling {
        HostScheduling(version: currentVersion, hosts: [])
    }
}

/// Per-host aggregate of bandit arm observations.
public struct HostProfile: Codable, Sendable, Equatable {
    /// The D1-normalized host key (credentials stripped).
    public var host: String
    /// One entry per connection count tried; bounded to the candidate set.
    public var arms: [ConnObservation]
    /// Last time any arm was updated.
    public var updatedAt: Date

    public init(host: String, arms: [ConnObservation], updatedAt: Date) {
        self.host = host
        self.arms = arms
        self.updatedAt = updatedAt
    }
}

/// One bandit arm — the per-connection-count throughput record.
public struct ConnObservation: Codable, Sendable, Equatable {
    /// The connection count this arm represents (always in the candidate set).
    public var connectionCount: UInt8
    /// Exponentially-weighted moving average throughput, bytes/sec.
    /// Computed as `Double(totalBytes)/seconds` and EWMA-folded.
    /// NOT read from `JobProgress.bytesPerSecond`.
    public var throughputEWMA: Double
    /// How many completed downloads contributed to this EWMA.
    public var sampleCount: UInt32
    /// When this arm was last updated.
    public var updatedAt: Date

    public init(
        connectionCount: UInt8,
        throughputEWMA: Double,
        sampleCount: UInt32,
        updatedAt: Date
    ) {
        self.connectionCount = connectionCount
        self.throughputEWMA = throughputEWMA
        self.sampleCount = sampleCount
        self.updatedAt = updatedAt
    }

    /// Returns a new observation with `throughput` folded into the EWMA and
    /// `sampleCount` incremented. When `sampleCount` is 0, seeds the EWMA
    /// directly with `throughput`.
    public func foldingIn(throughput: Double, alpha: Double) -> ConnObservation {
        let newEWMA: Double
        if sampleCount == 0 {
            newEWMA = throughput
        } else {
            newEWMA = alpha * throughput + (1 - alpha) * throughputEWMA
        }
        return ConnObservation(
            connectionCount: connectionCount,
            throughputEWMA: newEWMA,
            sampleCount: sampleCount + 1,
            updatedAt: Date())
    }
}
