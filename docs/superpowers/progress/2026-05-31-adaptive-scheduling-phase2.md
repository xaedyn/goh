# Adaptive Scheduling — Phase 2 Artifact

## WHAT WAS BUILT

Phase 2 adds persistence and selection on top of the Phase 1 value types:

1. **`HostProfileStore`** — atomic versioned-plist persistence (temp→fsync→rename(2)→dir-fsync),
   matching `CatalogStore`/`CheckpointStore` exactly. Writes `host-scheduling.plist`
   at 0600 permissions. On load: version check → TTL eviction (90-day default, non-frozen
   constant) → return `HostScheduling`. Corrupt → discard + `.corrupt-<timestamp>` sidecar.
   Owns the in-memory `[hostKey: activeCount]` index (D5/D7); not persisted.

2. **Epsilon-greedy bandit selector** (`BanditSelector.swift`) — pure, synchronous,
   seeded-deterministic (accepts an injected `RandomNumberGenerator`). Given a `HostProfile`
   and tuning constants, returns `(chosenN: UInt8, reason: SelectionReason)`. Implements
   exploration when any arm has fewer than `minSamples`, otherwise ε-greedy. Returns
   `(8, .cold)` when no profile exists.

3. **EWMA fold** — `ConnObservation.foldingIn(throughput:alpha:) -> ConnObservation` pure
   method. New arm initialization uses the observed throughput as the seed EWMA.

4. **In-memory active-count index** — `HostProfileStore.incrementActiveCount(hostKey:)` /
   `decrementActiveCount(hostKey:)`. Not persisted; rebuilt from the active job set on restart.

## CURRENT STATE OF MODIFIED / CREATED FILES

### `Sources/GohCore/Scheduling/HostProfileStore.swift` (Create)

```swift
import Darwin
import Foundation
import Synchronization

public enum HostProfileStoreError: Error {
    case fsyncOpenFailed(path: String, errno: Int32)
    case fsyncFailed(path: String, errno: Int32)
    case renameFailed(errno: Int32)
}

public struct HostProfileLoadResult: Sendable {
    public var scheduling: HostScheduling
    public var corruptionSidecar: URL?
}

public final class HostProfileStore: Sendable {
    // Tuning constants — non-frozen daemon constants per D3.
    public static let ttlSeconds: Double = 90 * 24 * 3600  // 90 days

    private let fileURL: URL
    private let state: Mutex<StoreState>

    public init(fileURL: URL, now: Date = Date()) { ... }

    public func load(now: Date = Date()) -> HostProfileLoadResult { ... }
    public func save() throws { ... }  // saves current in-memory state

    // D5/D7 active-count index — not persisted
    public func incrementActiveCount(hostKey: String) { ... }
    public func decrementActiveCount(hostKey: String) { ... }
    public func activeCount(hostKey: String) -> Int { ... }

    // Observation recording — called on download completion
    public func recordObservation(
        hostKey: String,
        connectionCount: UInt8,
        totalBytes: UInt64,
        transferDuration: Duration,
        alpha: Double = 0.3
    ) { ... }

    // Selection — returns (N, reason); never throws
    public func selectN(
        hostKey: String?,
        selector: BanditSelector = .init()
    ) -> (n: UInt8, reason: SelectionReason) { ... }
}

private struct StoreState: Sendable {
    var scheduling: HostScheduling
    var activeCount: [String: Int]
}
```

### `Sources/GohCore/Scheduling/BanditSelector.swift` (Create)

```swift
public enum SelectionReason: Sendable, Equatable {
    case cold           // no profile or all arms cold
    case exploit        // best-EWMA arm, minSamples met
    case explore        // epsilon draw or under-sampled arm
}

public struct BanditSelector: Sendable {
    public static let candidateSet: [UInt8] = [2, 4, 8, 16]
    public static let epsilon: Double = 0.15
    public static let minSamples: UInt32 = 2
    public static let defaultN: UInt8 = 8

    public func select(
        profile: HostProfile?,
        rng: inout some RandomNumberGenerator
    ) -> (n: UInt8, reason: SelectionReason) { ... }
}
```

### `Sources/GohCore/Scheduling/HostScheduling.swift` (Modify — add EWMA fold)

```swift
extension ConnObservation {
    public func foldingIn(throughput: Double, alpha: Double) -> ConnObservation { ... }
}
```

### `Tests/GohCoreTests/HostProfileStoreTests.swift` (Create)

All tests pass. Covers: save/load round-trip, missing file → empty, corrupt →
sidecar recovery, no temp file left behind, TTL eviction on load, 0600 file
permissions on save, activeCount increment/decrement, observation recording
(EWMA update, new arm creation).

### `Tests/GohCoreTests/BanditSelectorTests.swift` (Create)

All tests pass. Covers: cold profile → default 8, exploit selects best-EWMA
arm when all arms have ≥ minSamples, epsilon draw triggers exploration,
under-sampled arm forces explore, seeded determinism, candidate set respected.

## CONTRACTS ESTABLISHED

- `HostProfileStore` is the sole writer of `host-scheduling.plist`; no external
  tool reads it (owner-only 0600).
- `BanditSelector.candidateSet`, `.epsilon`, `.minSamples`, `.defaultN` are public
  constants but **not persisted** — they are tuning knobs, not part of the frozen format.
- `recordObservation` is the only code path that mutates `HostScheduling` state;
  it validates gates internally (duration, bytes floor) but does NOT check activeCount
  itself — the caller (Phase 3 engine wiring) is responsible for the activeCount==1 gate.
- `selectN(hostKey: nil, ...)` always returns `(8, .cold)` — the nil-host skip per D1.
- The `save()` method is called only on observation commit, not on reads.

## OPEN ITEMS

None blocking Phase 3. Tuning values (ε = 0.15, α = 0.3, minSamples = 2,
TTL = 90 days, candidate set {2,4,8,16}) are non-frozen constants settled here
for the initial implementation; empirical tuning against the benchmark suite is
post-Phase-3 work.
