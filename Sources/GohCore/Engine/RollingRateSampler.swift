// Sources/GohCore/Engine/RollingRateSampler.swift
import Foundation
import Synchronization

/// Per-job rolling-rate sampler. Thread-safe: Mutex-guarded.
/// Crash-safe for concurrent ranged workers: monotonic guard drops
/// regressing bytesCompleted samples; saturating subtraction prevents
/// UInt64 underflow. No stored clock — each call site passes its own
/// clock.now so windowing is internally consistent.
final class RollingRateSampler: @unchecked Sendable {

    private struct Sample {
        let instant: ContinuousClock.Instant
        let bytesCompleted: UInt64
    }

    private struct State {
        var samples: [Sample] = []
        var lastStoredBytes: UInt64 = 0
    }

    private let state: Mutex<State>
    private let window: Duration
    private let warmupInterval: Duration

    init(
        window: Duration = .seconds(5),
        warmupInterval: Duration = .milliseconds(250)
    ) {
        self.state = Mutex(State())
        self.window = window
        self.warmupInterval = warmupInterval
    }

    /// Record the latest cumulative byte count at `now`; return the
    /// windowed rate (bytes/sec). Returns 0 during warm-up.
    func record(bytesCompleted: UInt64, now: ContinuousClock.Instant) -> UInt64 {
        state.withLock { s in
            // Append ONLY monotonic samples (drop regressing/out-of-order → crash-safe).
            if bytesCompleted > s.lastStoredBytes || s.samples.isEmpty {
                s.lastStoredBytes = bytesCompleted
                s.samples.append(Sample(instant: now, bytesCompleted: bytesCompleted))
            }
            // ALWAYS evict samples older than the window — on EVERY call, including a
            // stall where no new sample was appended. This is what makes the rate decay
            // toward 0 as the window empties.
            let cutoff = now - window
            s.samples.removeAll { $0.instant < cutoff }
            return rate(from: s, upTo: now)
        }
    }

    private func rate(from s: State, upTo now: ContinuousClock.Instant) -> UInt64 {
        guard s.samples.count >= 2 else { return 0 }
        let oldest = s.samples.first!
        let newest = s.samples.last!
        // Span from the oldest kept sample UP TO `now` (not to the newest sample), so a
        // stall — `now` advancing with no new bytes — decays the rate smoothly toward 0
        // (denominator grows while numerator is fixed) before the window fully empties.
        let span = oldest.instant.duration(to: now)
        guard span >= warmupInterval else { return 0 }
        // Saturating subtraction — never underflows (monotonic samples guarantee >=, but
        // keep the guard as defense-in-depth).
        let deltaBytes = newest.bytesCompleted >= oldest.bytesCompleted
            ? newest.bytesCompleted - oldest.bytesCompleted : 0
        let seconds = Double(span.components.seconds)
            + Double(span.components.attoseconds) / 1e18
        guard seconds > 0 else { return 0 }
        return UInt64(Double(deltaBytes) / seconds)
    }
}
