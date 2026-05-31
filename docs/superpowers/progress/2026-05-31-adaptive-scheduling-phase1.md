# Adaptive Scheduling — Phase 1 Artifact

## WHAT WAS BUILT

Phase 1 establishes the pure value layer that everything else depends on:

1. **Host-key normalizer** (`HostKey.swift`) — `URLComponents`-based normalization
   producing `"{scheme}://{lowercased-host}:{port}"` strings per D1. Strips
   credentials, returns nil on nil-host, uses bracketed IPv6 and ASCII/punycode
   host form, makes default ports explicit (`:443` / `:80`).

2. **Codable on-disk types** (`HostScheduling.swift`) — `HostScheduling`,
   `HostProfile`, `ConnObservation` per D3. All `Codable`, `Sendable`, `Equatable`.
   Format `version == 1`.

3. **Golden round-trip corpus** — committed binary plist fixture
   `Tests/GohCoreTests/Fixtures/host-scheduling-v1.plist` encoding a known
   `HostScheduling` value, plus a CI round-trip guard test asserting the fixture
   decodes to the expected value and re-encodes byte-for-byte (fulfilling the
   trust-core post-mortem requirement).

## CURRENT STATE OF MODIFIED / CREATED FILES

### `Sources/GohCore/Scheduling/HostKey.swift` (Create)

```swift
import Foundation

/// D1 — Normalizes a URL string to its scheme+host+port key.
/// Returns nil when the host is absent (nil host → skip, never bucket).
public func hostKey(for urlString: String) -> String? { ... }
```

### `Sources/GohCore/Scheduling/HostScheduling.swift` (Create)

```swift
public struct HostScheduling: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var hosts: [HostProfile]
}

public struct HostProfile: Codable, Sendable, Equatable {
    public var host: String          // D1-normalized key
    public var arms: [ConnObservation]
    public var updatedAt: Date
}

public struct ConnObservation: Codable, Sendable, Equatable {
    public var connectionCount: UInt8
    public var throughputEWMA: Double  // bytes/sec
    public var sampleCount: UInt32
    public var updatedAt: Date
}
```

### `Tests/GohCoreTests/HostSchedulingTests.swift` (Create)

All tests pass. Tests cover: hostKey normalization (credentials stripped, nil
host → nil, IPv6 bracketed, punycode/ASCII stability, default ports explicit,
unknown ports preserved, scheme-case lowercased), HostScheduling Codable
round-trip, golden-fixture round-trip, corrupt-fixture detection.

### `Tests/GohCoreTests/Fixtures/host-scheduling-v1.plist` (Create)

Binary plist encoding a known `HostScheduling` v1 value (two host profiles,
multiple arms). Used by the golden round-trip guard.

## CONTRACTS ESTABLISHED

- `hostKey(for:) -> String?` is the sole D1 normalization entry point; callers
  never produce keys themselves.
- `HostScheduling.currentVersion == 1`; this constant is the load-time guard.
- `ConnObservation` stores **only raw measurements** — no selection knobs — per the
  D3 frozen-surface principle.
- The golden fixture is committed; its byte content is the reference encoding for
  `HostScheduling` v1. Any accidental format change breaks the guard test.

## OPEN ITEMS

None blocking Phase 2. The fixture's exact byte content is determined by the
`PropertyListEncoder(.binary)` output produced during task execution and committed
verbatim.
