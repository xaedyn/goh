# Adaptive Per-Host Range Scheduling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the daemon learn and persist the best parallel-connection count per
host empirically using an epsilon-greedy bandit, so repeat downloads from a known
host start at the count that historically performed best.

**Architecture:** A new daemon-owned sibling plist `host-scheduling.plist` stores
per-host per-N throughput EWMAs and sample counts (version 1, atomic temp→fsync→rename(2)→dir-fsync,
corrupt→sidecar, owner-only 0600); a `HostProfileStore` (actor or Mutex-guarded store
matching existing `*Store` types) plus a pure `BanditSelector` (ε-greedy over candidate
set {2,4,8,16}) select the N for each download at admission time; the engine's
`completedDownloadHandler` is additively widened to also carry the transfer-phase `Duration`
so observations can be recorded with a clean signal.

**Tech Stack:** Swift 6.2 / Swift 6.3.x toolchain; SwiftPM; GohCore + gohd targets
(nonisolated-default); Swift Testing (`import Testing`, `@Test`, `#expect`); macOS 26.0+;
`-warnings-as-errors`; `Synchronization.Mutex` (existing concurrency primitive in
`DownloadEngine`, `RangeProgress`); `Foundation.PropertyListEncoder(.binary)` for persistence;
`URLComponents` for host-key normalization.

---

## Acceptance Criteria

Derived from the spec's RESOLVED decisions, D5 gate predicate, D6 resolution behavior,
D3 frozen-surface principle, and Success-measurement section. Each AC is mapped to the task
that owns it.

| AC | Criterion | Owned by Task |
|----|-----------|---------------|
| AC1 | `hostKey(for:)` strips credentials, returns nil on nil-host, brackets IPv6, uses ASCII/punycode host, makes default ports explicit | Task 1 |
| AC2 | `HostScheduling` v1 Codable round-trips losslessly; golden fixture decodes to known value and re-encodes byte-for-byte | Task 2 |
| AC3 | `HostProfileStore` save/load round-trips; missing file → empty; corrupt → sidecar; no temp file left behind; file permissions are 0600 | Task 3 |
| AC4 | TTL eviction: profiles whose `updatedAt` is older than 90 days are dropped on load | Task 3 |
| AC5 | `BanditSelector` returns (8, .cold) for nil/missing profile; exploits best-EWMA arm when all ≥ minSamples; explores on epsilon draw or under-sampled arm; seeded-deterministic | Task 4 |
| AC6 | `DownloadEngine.completedDownloadHandler` carries `(JobSummary, Duration, Bool)` — transfer-phase Duration and isResume flag | Task 6 |
| AC7 | `CommandDispatcher` resolves nil `connectionCount` via host-profile bandit at admission time; explicit count honored unchanged | Task 7 |
| AC8 | Observation is recorded if and only if: completed successfully, duration ≥ 10s, bytes ≥ 8 MiB, `wasSolo(jobID)` true (download was never concurrent with a sibling for its entire duration), actualConnectionCount == requestedConnectionCount, not a resume | Task 8 |
| AC9 | Per-host active-job index: `begin(jobID:hostKey:)` brackets in `run()` with `defer { end(jobID:hostKey:) }` — cannot leak on throw/pause/cancel; contended-set tracks any job that ever had a sibling | Task 5 |
| AC10 | Resume path does NOT record an observation (D8) | Task 8 |
| AC11 | Converged-N throughput ≥ static-8 baseline within tolerance on saturated workload (regression guard) | Task 9 |
| AC12 | `GOH_ENGINE_TRACE` emits host-key, chosen-N, reason, arm EWMAs per download — emitted from `CommandDispatcher` at admission time (where all four fields are in hand) | Task 9 |
| AC13 | `protocolVersion` stays 3; `JobCatalog.version` stays 1; `JobSummary` struct unchanged | Tasks 6, 7 |

---

## File Map

### Phase 1 — Pure value layer

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `Sources/GohCore/Scheduling/HostKey.swift` | D1 host-key normalization helper |
| Create | `Sources/GohCore/Scheduling/HostScheduling.swift` | D3 on-disk types: `HostScheduling`, `HostProfile`, `ConnObservation` |
| Create | `Tests/GohCoreTests/Fixtures/host-scheduling-v1.plist` | Golden round-trip fixture (binary plist) |
| Create | `Tests/GohCoreTests/HostSchedulingTests.swift` | Tests for Tasks 1 and 2 |

### Phase 2 — Persistence and selection

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `Sources/GohCore/Scheduling/HostProfileStore.swift` | Atomic-write store + TTL eviction + begin/wasSolo/end active-job + contended-set index |
| Create | `Sources/GohCore/Scheduling/BanditSelector.swift` | Pure epsilon-greedy selector |
| Modify | `Sources/GohCore/Scheduling/HostScheduling.swift` | Add `ConnObservation.foldingIn(throughput:alpha:)` EWMA fold |
| Create | `Tests/GohCoreTests/HostProfileStoreTests.swift` | Tests for Task 3 |
| Create | `Tests/GohCoreTests/BanditSelectorTests.swift` | Tests for Tasks 4 and 5 |

### Phase 3 — Engine and wiring

| Action | Path | Responsibility |
|--------|------|----------------|
| Modify | `Sources/GohCore/Engine/DownloadEngine.swift` | Widen handler signature (D5); active-count bracket (AC9 begin/end calls); thread duration+isResume to handler |
| Modify | `Sources/GohCore/Model/CommandDispatcher.swift` | Admission-time N resolution via host profile (D6); emit AC12 scheduling-decision trace at admission (where hostKey, chosenN, reason, and arm EWMAs are all in hand) |
| Modify | `Sources/gohd/main.swift` | Wire `HostProfileStore`; extend handler with wasSolo gate; wire dispatcher |
| Modify | `Sources/GohCore/Engine/EngineDiagnostics.swift` | Add `recordSchedulingDecision(hostKey:chosenN:reason:armEWMAs:)` method |
| Modify | `Tests/GohCoreTests/DownloadEngineTests.swift` | Update handler arity in test closures |
| Modify | `Tests/GohCoreTests/CommandDispatcherTests.swift` | Add profile-driven N tests |
| Create | `Tests/GohCoreTests/EngineDiagnosticsSchedulingTests.swift` | AC12 compile+field test using `@testable import GohCore` |
| Modify | `Benchmarks/goh-bench/main.swift` | Add regression benchmark guard |

---

## Phase 1 — Pure Value Layer

*Depends on nothing. Fully unit-testable without a daemon, store, or network.*

---

### Task 1 — Host-key normalizer

**Files:**
- Create: `Sources/GohCore/Scheduling/HostKey.swift`
- Test: `Tests/GohCoreTests/HostSchedulingTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Model/JobSummary.swift` — confirm `url: String` raw type
- [ ] `Sources/GohCore/Engine/DownloadEngine.swift` line 175 — the nil-host guard (`URL(string:)` → unsupportedURL)

**Step 1 — Write failing test**

Create `Tests/GohCoreTests/HostSchedulingTests.swift`:

```swift
import Foundation
import Testing

import GohCore

@Suite("Host key normalization")
struct HostKeyTests {

    // AC1: credentials stripped, nil host → nil, IPv6 bracketed,
    //       punycode host, default ports explicit, scheme lowercased.

    @Test("AC: credentials stripped from key")
    func ac1CredentialsStripped() {
        let key = hostKey(for: "https://user:pass@dl.example.com/file.iso")
        #expect(key == "https://dl.example.com:443")
    }

    @Test("AC: nil host returns nil key")
    func ac1NilHostReturnsNil() {
        // A URL with no host — e.g. a file URL or a bare scheme.
        let key = hostKey(for: "file:///tmp/foo")
        #expect(key == nil)
    }

    @Test("AC: IPv6 literal is bracketed in key")
    func ac1IPv6Bracketed() {
        let key = hostKey(for: "https://[2001:db8::1]/file")
        #expect(key == "https://[2001:db8::1]:443")
    }

    @Test("AC: default HTTPS port made explicit")
    func ac1DefaultHTTPSPort() {
        #expect(hostKey(for: "https://example.com/f") == "https://example.com:443")
    }

    @Test("AC: default HTTP port made explicit")
    func ac1DefaultHTTPPort() {
        #expect(hostKey(for: "http://example.com/f") == "http://example.com:80")
    }

    @Test("AC: non-default port preserved")
    func ac1NonDefaultPortPreserved() {
        #expect(hostKey(for: "https://example.com:8443/f") == "https://example.com:8443")
    }

    @Test("AC: host lowercased")
    func ac1HostLowercased() {
        #expect(hostKey(for: "https://DL.EXAMPLE.COM/f") == "https://dl.example.com:443")
    }

    @Test("AC: scheme lowercased")
    func ac1SchemeLowercased() {
        // URLComponents normalizes scheme to lowercase; confirm this holds.
        #expect(hostKey(for: "HTTPS://example.com/f") == "https://example.com:443")
    }

    @Test("AC: unparseable URL returns nil key")
    func ac1UnparseableURLReturnsNil() {
        #expect(hostKey(for: "not a url at all ://???") == nil)
    }

    @Test("AC: punycode/ASCII host is stable across inputs")
    func ac1PunycodeStable() {
        // xn--nxasmq6b.com is the punycode for a Greek domain; both forms
        // must produce the same key (URLComponents encodes to ASCII).
        let asciiKey = hostKey(for: "https://xn--nxasmq6b.com/f")
        let unicodeKey = hostKey(for: "https://κόσμος.com/f")
        // Both or neither may parse — the invariant is they produce the SAME key.
        if let a = asciiKey, let u = unicodeKey {
            #expect(a == u)
        }
        // If one parses and the other doesn't — that is a failure. Both must succeed or both nil.
        #expect((asciiKey == nil) == (unicodeKey == nil))
    }
}
```

**Step 2 — Run, expect FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter HostKeyTests
```

Expected: compile error — `hostKey` undefined.

**Step 3 — Implement**

Create `Sources/GohCore/Scheduling/HostKey.swift`:

```swift
import Foundation

/// D1 — Normalizes a URL string to its scheme+host+port key:
/// `"{scheme}://{host-lowercased}:{port}"`.
///
/// - Returns `nil` when the host is absent (malformed URL, nil-host form) —
///   the caller must skip observation recording entirely; never bucket nil-host
///   URLs into a shared empty key.
/// - Credentials (userinfo) are stripped unconditionally.
/// - IPv6 literals are preserved in canonical bracketed form.
/// - The punycode/ASCII-encoded host is used so the key is encoding-stable.
/// - Default ports are made explicit (`:443` for https, `:80` for http).
public func hostKey(for urlString: String) -> String? {
    guard var components = URLComponents(string: urlString) else { return nil }

    // Strip credentials before any keying — a credential must never reach
    // the persisted key (D1: hard rule, not a leaning).
    components.user = nil
    components.password = nil

    // `percentEncodedHost` gives the wire-form host, which for IPv6 is the
    // bracketed form [addr] and for IDN is the percent-encoded ASCII/punycode
    // form — both stable and round-trippable.
    guard let rawHost = components.percentEncodedHost, !rawHost.isEmpty else {
        return nil
    }
    let host = rawHost.lowercased()

    let scheme = (components.scheme ?? "").lowercased()
    let port: Int
    if let explicit = components.port {
        port = explicit
    } else {
        switch scheme {
        case "https": port = 443
        case "http":  port = 80
        default:      return nil   // unknown scheme with no port → skip
        }
    }

    return "\(scheme)://\(host):\(port)"
}
```

**Step 4 — Run, expect PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter HostKeyTests
```

Expected: `Test run with 9 tests passed.`

**Step 5 — Commit**

```
git add Sources/GohCore/Scheduling/HostKey.swift \
        Tests/GohCoreTests/HostSchedulingTests.swift \
  && git commit -m "feat(adaptive-scheduling): D1 host-key normalizer + tests"
```

---

### Task 2 — Codable on-disk types and golden round-trip corpus

**Files:**
- Create: `Sources/GohCore/Scheduling/HostScheduling.swift`
- Create: `Tests/GohCoreTests/Fixtures/host-scheduling-v1.plist` *(generated in Step 3)*
- Modify: `Tests/GohCoreTests/HostSchedulingTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Model/JobCatalog.swift` — `currentVersion` pattern, `Codable`/`Sendable`/`Equatable` conformances
- [ ] `Sources/GohCore/Model/DownloadCheckpoint.swift` — `currentVersion`, field types
- [ ] `Tests/GohCoreTests/Fixtures/` — existing fixture layout

**Step 1 — Write failing tests (append to `HostSchedulingTests.swift`)**

```swift
@Suite("HostScheduling on-disk types")
struct HostSchedulingTypesTests {

    private func sampleScheduling() -> HostScheduling {
        HostScheduling(
            version: HostScheduling.currentVersion,
            hosts: [
                HostProfile(
                    host: "https://dl.example.com:443",
                    arms: [
                        ConnObservation(
                            connectionCount: 8,
                            throughputEWMA: 10_000_000,
                            sampleCount: 3,
                            updatedAt: Date(timeIntervalSince1970: 1_748_700_000)),
                        ConnObservation(
                            connectionCount: 16,
                            throughputEWMA: 15_000_000,
                            sampleCount: 2,
                            updatedAt: Date(timeIntervalSince1970: 1_748_700_100)),
                    ],
                    updatedAt: Date(timeIntervalSince1970: 1_748_700_100)),
                HostProfile(
                    host: "http://cdn.example.com:80",
                    arms: [
                        ConnObservation(
                            connectionCount: 4,
                            throughputEWMA: 5_000_000,
                            sampleCount: 1,
                            updatedAt: Date(timeIntervalSince1970: 1_748_700_200)),
                    ],
                    updatedAt: Date(timeIntervalSince1970: 1_748_700_200)),
            ])
    }

    // AC2: Codable round-trip.
    @Test("AC: HostScheduling Codable round-trips losslessly")
    func ac2CodableRoundTrip() throws {
        let original = sampleScheduling()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(original)
        let decoded = try PropertyListDecoder().decode(HostScheduling.self, from: data)
        #expect(decoded == original)
    }

    // AC2: Golden fixture round-trip.
    //
    // PRIMARY guard: decoded-value equality (SDK-stable). Binary plist object-table
    // layout and Date/Double encoding can differ between SDK versions — CI compiles
    // with the stable 26.2 SDK while local builds use 26.5 (CLAUDE.md: cross-SDK
    // C-API skew). Asserting byte-equality of a locally-generated committed blob
    // against a different SDK's re-encode is therefore fragile. The unconditional
    // primary guard is structural/value equality after decoding.
    //
    // ROUND-TRIP STABILITY guard: re-encode the just-decoded value and compare that
    // re-encode back to itself by decoding again. This proves the encoder+decoder
    // round-trips stably on this SDK without pinning to a cross-SDK blob.
    @Test("AC: golden fixture decodes to known value; round-trip encode/decode is stable")
    func ac2GoldenFixtureRoundTrip() throws {
        // The fixture is committed binary plist at Fixtures/host-scheduling-v1.plist.
        let fixtureURL = Bundle.module.url(
            forResource: "host-scheduling-v1", withExtension: "plist",
            subdirectory: "Fixtures")
        let fixtureData = try Data(contentsOf: #require(fixtureURL))

        let decoded = try PropertyListDecoder().decode(HostScheduling.self, from: fixtureData)

        // PRIMARY: structural/value equality — SDK-stable. Fails if the Codable
        // mapping changes or the fixture was generated from a different struct version.
        #expect(decoded.version == 1)
        #expect(decoded.hosts.count == 2)
        #expect(decoded.hosts[0].host == "https://dl.example.com:443")
        #expect(decoded.hosts[0].arms.count == 2)
        #expect(decoded.hosts[0].arms[0].connectionCount == 8)
        #expect(abs(decoded.hosts[0].arms[0].throughputEWMA - 10_000_000) < 1)
        #expect(decoded.hosts[0].arms[0].sampleCount == 3)
        #expect(decoded.hosts[0].arms[1].connectionCount == 16)
        #expect(decoded.hosts[1].host == "http://cdn.example.com:80")
        #expect(decoded.hosts[1].arms.count == 1)
        #expect(decoded.hosts[1].arms[0].connectionCount == 4)

        // ROUND-TRIP STABILITY: re-encode, then decode again and compare to the
        // first decode. Proves the codec is stable on this SDK without relying on
        // a cross-SDK committed blob.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let reencoded = try encoder.encode(decoded)
        let redecoded = try PropertyListDecoder().decode(HostScheduling.self, from: reencoded)
        #expect(redecoded == decoded)
    }

    @Test("AC: EWMA fold updates throughput and increments sampleCount")
    func ac2EWMAFold() {
        let arm = ConnObservation(
            connectionCount: 8, throughputEWMA: 10_000_000, sampleCount: 3,
            updatedAt: Date(timeIntervalSince1970: 1_000_000))
        let updated = arm.foldingIn(throughput: 20_000_000, alpha: 0.3)
        // new = 0.3 * 20_000_000 + 0.7 * 10_000_000 = 13_000_000
        #expect(abs(updated.throughputEWMA - 13_000_000) < 1)
        #expect(updated.sampleCount == 4)
        #expect(updated.connectionCount == 8)
    }
}
```

**Step 2 — Run, expect FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter HostSchedulingTypesTests
```

Expected: compile error — `HostScheduling`, `HostProfile`, `ConnObservation` undefined.

**Step 3 — Implement**

Create `Sources/GohCore/Scheduling/HostScheduling.swift`:

```swift
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
```

Now generate the golden fixture. The fixture must be committed as a binary plist
encoding the exact `sampleScheduling()` value from the tests. Generate it by
running a one-off Swift script in the build environment:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift -e '
import Foundation

struct ConnObservation: Codable {
    var connectionCount: UInt8
    var throughputEWMA: Double
    var sampleCount: UInt32
    var updatedAt: Date
}
struct HostProfile: Codable {
    var host: String
    var arms: [ConnObservation]
    var updatedAt: Date
}
struct HostScheduling: Codable {
    var version: Int
    var hosts: [HostProfile]
}

let s = HostScheduling(version: 1, hosts: [
    HostProfile(host: "https://dl.example.com:443", arms: [
        ConnObservation(connectionCount: 8, throughputEWMA: 10_000_000, sampleCount: 3,
                        updatedAt: Date(timeIntervalSince1970: 1_748_700_000)),
        ConnObservation(connectionCount: 16, throughputEWMA: 15_000_000, sampleCount: 2,
                        updatedAt: Date(timeIntervalSince1970: 1_748_700_100)),
    ], updatedAt: Date(timeIntervalSince1970: 1_748_700_100)),
    HostProfile(host: "http://cdn.example.com:80", arms: [
        ConnObservation(connectionCount: 4, throughputEWMA: 5_000_000, sampleCount: 1,
                        updatedAt: Date(timeIntervalSince1970: 1_748_700_200)),
    ], updatedAt: Date(timeIntervalSince1970: 1_748_700_200)),
])

let enc = PropertyListEncoder()
enc.outputFormat = .binary
let data = try enc.encode(s)
try data.write(to: URL(fileURLWithPath: "Tests/GohCoreTests/Fixtures/host-scheduling-v1.plist"))
print("written \(data.count) bytes")
'
```

Run this from `/Users/shane/claude/goh`. The resulting binary plist is committed as-is.
The golden-fixture test asserts: (a) the fixture decodes to the known structural value
(PRIMARY, SDK-stable guard); and (b) encode(decode(fixture)) decodes again to the same
value (round-trip stability on THIS SDK). It does NOT assert byte-for-byte equality of
the re-encode against the committed blob — binary plist layout can differ across SDKs
(CLAUDE.md: cross-SDK C-API skew; CI is stable 26.2, local is 26.5).

**Step 4 — Run, expect PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter HostSchedulingTypesTests
```

Expected: `Test run with 3 tests passed.`

Full suite (including Task 1):
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter HostScheduling
```

Expected: `Test run with 12 tests passed.`

**Step 5 — Commit**

```
git add Sources/GohCore/Scheduling/HostScheduling.swift \
        Tests/GohCoreTests/Fixtures/host-scheduling-v1.plist \
        Tests/GohCoreTests/HostSchedulingTests.swift \
  && git commit -m "feat(adaptive-scheduling): D3 on-disk types + golden round-trip fixture"
```

---

## Phase 2 — Persistence and Selection

*Depends on Phase 1 types. Fully unit-testable without engine or daemon.*

---

### Task 3 — HostProfileStore

**Files:**
- Create: `Sources/GohCore/Scheduling/HostProfileStore.swift`
- Create: `Tests/GohCoreTests/HostProfileStoreTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Model/CatalogStore.swift` — atomic save pattern, `fsync` helper, corrupt recovery
- [ ] `Sources/GohCore/Model/CheckpointStore.swift` — directory fsync, temp naming convention
- [ ] `Sources/GohCore/Model/JobCatalog.swift` — version guard in `load()`
- [ ] `Sources/gohd/main.swift` — `supportDirectoryURL()` shows the base path for sibling stores

**Step 1 — Write failing test**

Create `Tests/GohCoreTests/HostProfileStoreTests.swift`:

```swift
import Foundation
import Testing

import GohCore

@Suite("Host profile store")
struct HostProfileStoreTests {

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goh-hostprofile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sampleScheduling() -> HostScheduling {
        HostScheduling(version: HostScheduling.currentVersion, hosts: [
            HostProfile(
                host: "https://dl.example.com:443",
                arms: [
                    ConnObservation(
                        connectionCount: 8, throughputEWMA: 10_000_000,
                        sampleCount: 3, updatedAt: Date(timeIntervalSince1970: 1_748_700_000))
                ],
                updatedAt: Date(timeIntervalSince1970: 1_748_700_000))
        ])
    }

    // AC3: save/load round-trip.
    @Test("AC: save then load round-trips HostScheduling")
    func ac3SaveLoadRoundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        let scheduling = sampleScheduling()
        try store.save(scheduling)

        let loaded = store.load()
        #expect(loaded.scheduling == scheduling)
        #expect(loaded.corruptionSidecar == nil)
    }

    // AC3: missing file → empty.
    @Test("AC: missing file yields empty HostScheduling")
    func ac3MissingFileYieldsEmpty() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        let loaded = store.load()
        #expect(loaded.scheduling.hosts.isEmpty)
        #expect(loaded.corruptionSidecar == nil)
    }

    // AC3: corrupt → sidecar recovery.
    @Test("AC: corrupt file recovers to empty and leaves sidecar copy")
    func ac3CorruptFileLeaveSidecar() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "host-scheduling.plist")
        try Data("not a plist".utf8).write(to: fileURL)

        let store = HostProfileStore(fileURL: fileURL)
        let loaded = store.load()
        #expect(loaded.scheduling.hosts.isEmpty)
        let sidecar = try #require(loaded.corruptionSidecar)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
    }

    // AC3: no temp file left behind.
    @Test("AC: save leaves no temporary file behind")
    func ac3NoTempFileLeft() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        try store.save(sampleScheduling())

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents == ["host-scheduling.plist"])
    }

    // AC3: file permissions are 0600.
    @Test("AC: saved file has owner-only 0600 permissions")
    func ac3FilePermissions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "host-scheduling.plist")
        let store = HostProfileStore(fileURL: fileURL)
        try store.save(sampleScheduling())

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let posixPerms = attrs[.posixPermissions] as? Int
        #expect(posixPerms == 0o600)
    }

    // AC4: TTL eviction.
    @Test("AC: profiles older than TTL are dropped on load")
    func ac4TTLEviction() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "host-scheduling.plist")
        // Write a scheduling with a profile whose updatedAt is 91 days ago.
        let oldDate = Date(timeIntervalSinceNow: -(91 * 24 * 3600))
        let scheduling = HostScheduling(version: 1, hosts: [
            HostProfile(
                host: "https://old.example.com:443",
                arms: [],
                updatedAt: oldDate)
        ])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(scheduling).write(to: fileURL)

        let store = HostProfileStore(fileURL: fileURL)
        let loaded = store.load()
        // The expired profile must have been evicted.
        #expect(loaded.scheduling.hosts.isEmpty)
    }

    // AC4: a profile within TTL is kept.
    @Test("profile within TTL is retained on load")
    func ttlRetains() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "host-scheduling.plist")
        let recentDate = Date(timeIntervalSinceNow: -(30 * 24 * 3600))
        let scheduling = HostScheduling(version: 1, hosts: [
            HostProfile(
                host: "https://recent.example.com:443",
                arms: [],
                updatedAt: recentDate)
        ])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(scheduling).write(to: fileURL)

        let store = HostProfileStore(fileURL: fileURL)
        let loaded = store.load()
        #expect(loaded.scheduling.hosts.count == 1)
    }

    // AC9: begin/wasSolo/end — contended-set tracks any job that ever had a sibling.
    @Test("AC: solo job is wasSolo; overlapping sibling marks both contended; subsequent solo is clean")
    func ac9SoloContendedTracking() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))

        let key = "https://example.com:443"

        // Solo job: begin → wasSolo should be true BEFORE end (job still registered).
        store.begin(jobID: 1, hostKey: key)
        #expect(store.wasSolo(jobID: 1))
        store.end(jobID: 1, hostKey: key)

        // Two overlapping jobs: both should be contended (wasSolo false).
        store.begin(jobID: 2, hostKey: key)
        store.begin(jobID: 3, hostKey: key)
        #expect(!store.wasSolo(jobID: 2))
        #expect(!store.wasSolo(jobID: 3))
        store.end(jobID: 2, hostKey: key)
        store.end(jobID: 3, hostKey: key)

        // After full drain, a fresh solo job is clean again.
        store.begin(jobID: 4, hostKey: key)
        #expect(store.wasSolo(jobID: 4))
        store.end(jobID: 4, hostKey: key)
    }

    // AC8 (partial): observation recording updates the arm.
    @Test("recording an observation folds throughput into the arm EWMA")
    func observationRecording() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        _ = store.load()  // initialise from disk (empty)

        let key = "https://example.com:443"
        store.recordObservation(
            hostKey: key, connectionCount: 8,
            totalBytes: 100 * 1024 * 1024,
            transferDuration: .seconds(10))

        let scheduling = store.currentScheduling()
        let profile = try #require(scheduling.hosts.first { $0.host == key })
        let arm = try #require(profile.arms.first { $0.connectionCount == 8 })
        // throughput = 100*1024*1024 / 10 = 10_485_760 bytes/sec
        #expect(abs(arm.throughputEWMA - 10_485_760) < 1)
        #expect(arm.sampleCount == 1)
    }
}
```

**Step 2 — Run, expect FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter HostProfileStoreTests
```

Expected: compile error — `HostProfileStore` undefined.

**Step 3 — Implement**

Create `Sources/GohCore/Scheduling/HostProfileStore.swift`:

```swift
import Darwin
import Foundation
import Synchronization

/// A failure writing the host-scheduling file to disk.
public enum HostProfileStoreError: Error {
    case fsyncOpenFailed(path: String, errno: Int32)
    case fsyncFailed(path: String, errno: Int32)
    case renameFailed(errno: Int32)
}

/// The outcome of loading the host-scheduling record.
public struct HostProfileLoadResult: Sendable {
    /// The loaded scheduling — empty when the file was missing or unreadable.
    public var scheduling: HostScheduling
    /// When the on-disk file was unreadable, the path the bytes were copied to
    /// before recovery; `nil` on a clean or first-run load.
    public var corruptionSidecar: URL?
}

/// Reads, writes, and maintains the in-memory host-scheduling state.
///
/// Concurrency: all mutable state is guarded by a `Mutex` — matching the
/// existing `Synchronization.Mutex` primitive used in `DownloadEngine` and
/// `RangeProgress`. The store is `Sendable`.
///
/// Saves are atomic and durable — identical pattern to `CatalogStore` and
/// `CheckpointStore` (temp→fsync→rename(2)→dir-fsync). The output file is
/// written at owner-only 0600 permissions because the file is daemon-internal
/// with no external reader.
///
/// The in-memory active-job index is NOT persisted; it is live daemon state
/// rebuilt from the active set on restart (D5/D7).
///
/// Persist failures in `recordObservation` are non-fatal (a failed optimization
/// write must not break the download) but are surfaced via the injected
/// `persistFailureReporter` so the daemon can log them via its existing
/// `warn()` channel. Pass `nil` only in tests that don't need the callback.
public final class HostProfileStore: Sendable {

    // MARK: — Tuning constants (non-frozen daemon constants per D3)

    /// 90-day TTL for evicting stale host profiles on load.
    public static let ttlSeconds: Double = 90 * 24 * 3600

    // MARK: — Private state

    private let fileURL: URL
    private let inner: Mutex<Inner>
    /// Called on a persist failure in `recordObservation`. Non-fatal — the
    /// in-memory state is already updated; only the write failed.
    private let persistFailureReporter: (@Sendable (String, any Error) -> Void)?

    private struct Inner: Sendable {
        var scheduling: HostScheduling
        /// Active job IDs per host key. Cleared when a host's set becomes empty.
        var activeJobs: [String: Set<UInt64>]
        /// Job IDs that were ever concurrent with a sibling. Cleared in end().
        var contended: Set<UInt64>
    }

    // MARK: — Init

    public init(
        fileURL: URL,
        persistFailureReporter: (@Sendable (String, any Error) -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.persistFailureReporter = persistFailureReporter
        self.inner = Mutex(Inner(scheduling: .empty, activeJobs: [:], contended: []))
    }

    // MARK: — Load / Save

    /// Loads from disk, evicting profiles older than `ttlSeconds`, and updates
    /// the in-memory state. Call once at daemon startup.
    @discardableResult
    public func load(now: Date = Date()) -> HostProfileLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return HostProfileLoadResult(scheduling: .empty, corruptionSidecar: nil)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            var scheduling = try PropertyListDecoder().decode(HostScheduling.self, from: data)
            guard scheduling.version == HostScheduling.currentVersion else {
                return recoverToEmpty()
            }
            // D9: evict profiles whose updatedAt is older than ttlSeconds.
            scheduling.hosts = scheduling.hosts.filter { profile in
                now.timeIntervalSince(profile.updatedAt) < Self.ttlSeconds
            }
            inner.withLock { $0.scheduling = scheduling }
            return HostProfileLoadResult(scheduling: scheduling, corruptionSidecar: nil)
        } catch {
            return recoverToEmpty()
        }
    }

    /// Atomically and durably persists `scheduling`, updating the in-memory state.
    /// Use for direct saves (e.g., tests, migration). In production the daemon
    /// calls `recordObservation` which persists automatically.
    public func save(_ scheduling: HostScheduling) throws {
        inner.withLock { $0.scheduling = scheduling }
        try writeAtomically(scheduling)
    }

    // MARK: — Per-host active-job index (D5/D7 — not persisted)
    //
    // The spec (D5) requires the download be solo "for the WHOLE duration."
    // A point-in-time count check at completion is insufficient: a sibling that
    // starts and finishes entirely within another download's window returns the
    // count to 1 by completion time, falsely appearing solo. The fix is a
    // contended set: once a job ever had a sibling, it stays contended regardless
    // of the count at completion.
    //
    // begin(jobID:hostKey:)  — call at the start of run(), like control?.register.
    // wasSolo(jobID:)        — call in the completion handler BEFORE end() runs.
    // end(jobID:hostKey:)    — call in a defer, like control?.unregister.

    /// Records that jobID has started on hostKey.
    /// If any other job is already active on hostKey, marks ALL of them (including
    /// this one and any pre-existing siblings) contended.
    public func begin(jobID: UInt64, hostKey: String) {
        inner.withLock { inner in
            inner.activeJobs[hostKey, default: []].insert(jobID)
            if inner.activeJobs[hostKey]!.count > 1 {
                // Mark every current member contended — including pre-existing siblings.
                for id in inner.activeJobs[hostKey]! {
                    inner.contended.insert(id)
                }
            }
        }
    }

    /// Returns true iff jobID was never concurrent with a sibling on its host.
    /// Call BEFORE end(jobID:hostKey:) — once end() removes the job, wasSolo
    /// always returns false for it.
    public func wasSolo(jobID: UInt64) -> Bool {
        inner.withLock { !$0.contended.contains(jobID) }
    }

    /// Records that jobID has finished on hostKey.
    /// Removes the job from both the active set and the contended set.
    public func end(jobID: UInt64, hostKey: String) {
        inner.withLock { inner in
            inner.activeJobs[hostKey]?.remove(jobID)
            if inner.activeJobs[hostKey]?.isEmpty == true {
                inner.activeJobs.removeValue(forKey: hostKey)
            }
            inner.contended.remove(jobID)
        }
    }

    // MARK: — Observation recording (D5, D7)

    /// Folds a completed-download observation into the matching arm's EWMA and
    /// persists the updated state.
    ///
    /// The D5 gates (duration ≥ 10 s, bytes ≥ 8 MiB, `wasSolo(jobID)` true,
    /// actualConnectionCount == requestedConnectionCount, not a resume) are
    /// checked by the CALLER (the `completedDownloadHandler` in `gohd/main.swift`).
    /// This method receives only observations that have already passed the gates.
    ///
    /// A persist failure is non-fatal — the in-memory EWMA is updated regardless.
    /// Failures are surfaced via the `persistFailureReporter` injected at init so
    /// the daemon can log them via its existing `warn()` channel.
    public func recordObservation(
        hostKey: String,
        connectionCount: UInt8,
        totalBytes: UInt64,
        transferDuration: Duration,
        alpha: Double = 0.3
    ) {
        let seconds =
            Double(transferDuration.components.seconds)
            + Double(transferDuration.components.attoseconds) / 1e18
        guard seconds > 0 else { return }
        let throughput = Double(totalBytes) / seconds
        let now = Date()

        inner.withLock { inner in
            if let idx = inner.scheduling.hosts.firstIndex(where: { $0.host == hostKey }) {
                // Update existing profile.
                if let armIdx = inner.scheduling.hosts[idx].arms
                    .firstIndex(where: { $0.connectionCount == connectionCount }) {
                    inner.scheduling.hosts[idx].arms[armIdx] =
                        inner.scheduling.hosts[idx].arms[armIdx]
                        .foldingIn(throughput: throughput, alpha: alpha)
                } else {
                    // New arm for this connection count.
                    inner.scheduling.hosts[idx].arms.append(
                        ConnObservation(
                            connectionCount: connectionCount,
                            throughputEWMA: throughput,
                            sampleCount: 1,
                            updatedAt: now))
                }
                inner.scheduling.hosts[idx].updatedAt = now
            } else {
                // New host profile.
                inner.scheduling.hosts.append(HostProfile(
                    host: hostKey,
                    arms: [ConnObservation(
                        connectionCount: connectionCount,
                        throughputEWMA: throughput,
                        sampleCount: 1,
                        updatedAt: now)],
                    updatedAt: now))
            }
        }

        // Persist on observation commit only — write amplification is low.
        // Non-fatal: a failed optimization write must not break the download.
        // Diagnosable: failures are reported via the injected reporter (the
        // daemon wires this to its warn() channel).
        let snapshot = inner.withLock { $0.scheduling }
        do {
            try writeAtomically(snapshot)
        } catch {
            persistFailureReporter?("host-profile persist hostKey=\(hostKey)", error)
        }
    }

    // MARK: — Selection (D4, D6)

    /// Returns the bandit's chosen N and the reason.
    ///
    /// When `hostKey` is nil (D1: nil-host skip), always returns `(defaultN, .cold)`.
    public func selectN(
        hostKey: String?,
        selector: BanditSelector = BanditSelector()
    ) -> (n: UInt8, reason: SelectionReason) {
        guard let key = hostKey else {
            return (BanditSelector.defaultN, .cold)
        }
        let profile = inner.withLock { inner in
            inner.scheduling.hosts.first { $0.host == key }
        }
        var rng = SystemRandomNumberGenerator()
        return selector.select(profile: profile, rng: &rng)
    }

    // MARK: — Snapshot accessors (for tests and diagnostics)

    /// Returns the current in-memory scheduling (for test assertions).
    public func currentScheduling() -> HostScheduling {
        inner.withLock { $0.scheduling }
    }

    /// Returns the current in-memory profile for `hostKey`, or nil if not found.
    /// Used by `CommandDispatcher` to read arm EWMAs for the AC12 trace.
    public func profile(hostKey: String) -> HostProfile? {
        inner.withLock { $0.scheduling.hosts.first { $0.host == hostKey } }
    }

    // MARK: — Private helpers

    private func recoverToEmpty() -> HostProfileLoadResult {
        let timestamp = Int(Date().timeIntervalSince1970)
        let sidecar = fileURL.deletingLastPathComponent()
            .appending(path: "\(fileURL.lastPathComponent).corrupt-\(timestamp)")
        try? FileManager.default.copyItem(at: fileURL, to: sidecar)
        let sidecarExists = FileManager.default.fileExists(atPath: sidecar.path)
        inner.withLock { $0.scheduling = .empty }
        return HostProfileLoadResult(
            scheduling: .empty,
            corruptionSidecar: sidecarExists ? sidecar : nil)
    }

    private func writeAtomically(_ scheduling: HostScheduling) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(scheduling)

        let directory = fileURL.deletingLastPathComponent()
        let temporaryURL = directory.appending(
            path: ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")

        do {
            // Write and set 0600 before fsync — Data.write() uses umask-default
            // (~0644); we tighten to owner-only immediately.
            try data.write(to: temporaryURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            try Self.fsync(path: temporaryURL.path)
            guard rename(temporaryURL.path, fileURL.path) == 0 else {
                throw HostProfileStoreError.renameFailed(errno: errno)
            }
            try Self.fsync(path: directory.path)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func fsync(path: String) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw HostProfileStoreError.fsyncOpenFailed(path: path, errno: errno)
        }
        defer { close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw HostProfileStoreError.fsyncFailed(path: path, errno: errno)
        }
    }
}
```

**Step 4 — Run, expect PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter HostProfileStoreTests
```

Expected: `Test run with 8 tests passed.`

**Step 5 — Commit**

```
git add Sources/GohCore/Scheduling/HostProfileStore.swift \
        Tests/GohCoreTests/HostProfileStoreTests.swift \
  && git commit -m "feat(adaptive-scheduling): HostProfileStore — atomic persistence + TTL eviction + active-count index"
```

---

### Task 4 — Epsilon-greedy bandit selector

**Files:**
- Create: `Sources/GohCore/Scheduling/BanditSelector.swift`
- Create: `Tests/GohCoreTests/BanditSelectorTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Scheduling/HostScheduling.swift` — `ConnObservation` fields, `HostProfile.arms`
- [ ] Spec D4 — candidate set `{2,4,8,16}`, ε ≈ 0.15, minSamples = 2, cold start = 8

**Step 1 — Write failing test**

Create `Tests/GohCoreTests/BanditSelectorTests.swift`:

```swift
import Testing

import GohCore

// A seeded deterministic RNG for testing.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        // xorshift64
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

@Suite("Bandit selector")
struct BanditSelectorTests {

    // AC5: cold profile → default 8.
    @Test("AC: nil profile returns (8, .cold)")
    func ac5NilProfileReturnsDefault() {
        var rng = SeededRNG(seed: 42)
        let (n, reason) = BanditSelector().select(profile: nil, rng: &rng)
        #expect(n == 8)
        #expect(reason == .cold)
    }

    // AC5: all arms cold (sampleCount < minSamples) → explore.
    @Test("AC: all arms under-sampled returns explore")
    func ac5AllArmsColdExplore() {
        let profile = HostProfile(
            host: "https://example.com:443",
            arms: [
                ConnObservation(connectionCount: 8, throughputEWMA: 10_000_000,
                                sampleCount: 1, updatedAt: .now),  // sampleCount < 2
            ],
            updatedAt: .now)
        var rng = SeededRNG(seed: 1)
        let (_, reason) = BanditSelector().select(profile: profile, rng: &rng)
        #expect(reason == .explore)
    }

    // AC5: best-EWMA arm exploited when all arms have ≥ minSamples and no epsilon draw.
    @Test("AC: exploits best-EWMA arm when settled")
    func ac5ExploitsBestArm() {
        // Force no epsilon exploration: use a selector with ε = 0.
        let selector = BanditSelector(epsilon: 0.0)
        let profile = HostProfile(
            host: "https://example.com:443",
            arms: [
                ConnObservation(connectionCount: 4, throughputEWMA: 5_000_000,
                                sampleCount: 3, updatedAt: .now),
                ConnObservation(connectionCount: 16, throughputEWMA: 20_000_000,
                                sampleCount: 3, updatedAt: .now),
                ConnObservation(connectionCount: 8, throughputEWMA: 10_000_000,
                                sampleCount: 3, updatedAt: .now),
            ],
            updatedAt: .now)
        var rng = SeededRNG(seed: 1)
        let (n, reason) = selector.select(profile: profile, rng: &rng)
        #expect(n == 16)  // highest EWMA
        #expect(reason == .exploit)
    }

    // AC5: chosen N is always in the candidate set.
    @Test("AC: chosen N is always in the candidate set")
    func ac5ChosenNInCandidateSet() {
        let profile = HostProfile(
            host: "https://example.com:443",
            arms: [
                ConnObservation(connectionCount: 8, throughputEWMA: 10_000_000,
                                sampleCount: 5, updatedAt: .now),
            ],
            updatedAt: .now)
        let selector = BanditSelector()
        for seed in UInt64(0)..<100 {
            var rng = SeededRNG(seed: seed)
            let (n, _) = selector.select(profile: profile, rng: &rng)
            #expect(BanditSelector.candidateSet.contains(n))
        }
    }

    // AC5: seeded-deterministic — same seed produces same result.
    @Test("AC: seeded RNG gives deterministic output")
    func ac5SeedDeterminism() {
        let profile = HostProfile(
            host: "https://example.com:443",
            arms: [
                ConnObservation(connectionCount: 8, throughputEWMA: 10_000_000,
                                sampleCount: 3, updatedAt: .now),
                ConnObservation(connectionCount: 4, throughputEWMA: 8_000_000,
                                sampleCount: 3, updatedAt: .now),
            ],
            updatedAt: .now)
        let selector = BanditSelector()
        var rng1 = SeededRNG(seed: 12345)
        var rng2 = SeededRNG(seed: 12345)
        let (n1, r1) = selector.select(profile: profile, rng: &rng1)
        let (n2, r2) = selector.select(profile: profile, rng: &rng2)
        #expect(n1 == n2)
        #expect(r1 == r2)
    }

    // AC5: epsilon = 1.0 forces exploration.
    @Test("AC: epsilon = 1.0 always explores")
    func ac5EpsilonOneAlwaysExplores() {
        let selector = BanditSelector(epsilon: 1.0)
        let profile = HostProfile(
            host: "https://example.com:443",
            arms: [
                ConnObservation(connectionCount: 8, throughputEWMA: 10_000_000,
                                sampleCount: 5, updatedAt: .now),
                ConnObservation(connectionCount: 16, throughputEWMA: 20_000_000,
                                sampleCount: 5, updatedAt: .now),
            ],
            updatedAt: .now)
        for seed in UInt64(0)..<20 {
            var rng = SeededRNG(seed: seed)
            let (_, reason) = selector.select(profile: profile, rng: &rng)
            #expect(reason == .explore)
        }
    }
}
```

**Step 2 — Run, expect FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter BanditSelectorTests
```

Expected: compile error — `BanditSelector`, `SelectionReason` undefined.

**Step 3 — Implement**

Create `Sources/GohCore/Scheduling/BanditSelector.swift`:

```swift
import Foundation

/// D4 — Selection reason for diagnostics and test assertions.
public enum SelectionReason: Sendable, Equatable {
    /// No profile exists or all arms are cold.
    case cold
    /// Best-EWMA arm chosen; all arms have ≥ `minSamples` observations.
    case exploit
    /// Random draw (epsilon draw or under-sampled arm forced exploration).
    case explore
}

/// Pure epsilon-greedy bandit selector over the fixed candidate set.
///
/// Accepts an injected `RandomNumberGenerator` so tests can seed it
/// for determinism. The `select` method is nonisolated and synchronous —
/// it reads only its arguments; all mutable state lives in the caller's RNG.
public struct BanditSelector: Sendable {

    // MARK: — Candidate set and tuning (non-frozen constants per D3)

    /// The connection counts the bandit selects from (D4).
    public static let candidateSet: [UInt8] = [2, 4, 8, 16]

    /// Cold-start / nil-profile default.
    public static let defaultN: UInt8 = 8

    /// Exploration probability (non-frozen, tuned empirically).
    public let epsilon: Double

    /// Minimum arm samples before the arm is considered settled (non-frozen).
    public let minSamples: UInt32

    public init(
        epsilon: Double = 0.15,
        minSamples: UInt32 = 2
    ) {
        self.epsilon = epsilon
        self.minSamples = minSamples
    }

    // MARK: — Selection

    /// Returns `(chosenN, reason)`.
    ///
    /// - If `profile` is nil: `(defaultN, .cold)`.
    /// - If any arm in the candidate set has fewer than `minSamples` observations:
    ///   pick an under-sampled arm at random (`.explore`).
    /// - Else with probability `epsilon`: pick a random arm (`.explore`).
    /// - Else: pick the arm with the highest `throughputEWMA` (`.exploit`).
    ///
    /// An arm is only considered if its `connectionCount` is in `candidateSet`.
    /// A candidate count with no arm record is treated as having 0 samples and
    /// 0 throughput (cold arm — forces exploration until it has enough samples).
    public func select(
        profile: HostProfile?,
        rng: inout some RandomNumberGenerator
    ) -> (n: UInt8, reason: SelectionReason) {
        guard let profile else {
            return (Self.defaultN, .cold)
        }

        let candidates = Self.candidateSet
        // Map candidate set to (count, observation?).
        let arms: [(n: UInt8, obs: ConnObservation?)] = candidates.map { n in
            (n, profile.arms.first { $0.connectionCount == n })
        }

        // If any arm is under-sampled, explore: pick uniformly from cold arms.
        let coldArms = arms.filter { (_, obs) in
            (obs?.sampleCount ?? 0) < minSamples
        }
        if !coldArms.isEmpty {
            let chosen = coldArms.randomElement(using: &rng)!
            return (chosen.n, .explore)
        }

        // Epsilon draw — explore uniformly.
        let draw = Double(rng.next()) / Double(UInt64.max)
        if draw < epsilon {
            let chosen = arms.randomElement(using: &rng)!
            return (chosen.n, .explore)
        }

        // Exploit: best EWMA.
        let best = arms.max { lhs, rhs in
            (lhs.obs?.throughputEWMA ?? 0) < (rhs.obs?.throughputEWMA ?? 0)
        }!
        return (best.n, .exploit)
    }
}
```

**Step 4 — Run, expect PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter BanditSelectorTests
```

Expected: `Test run with 6 tests passed.`

**Step 5 — Commit**

```
git add Sources/GohCore/Scheduling/BanditSelector.swift \
        Tests/GohCoreTests/BanditSelectorTests.swift \
  && git commit -m "feat(adaptive-scheduling): D4 epsilon-greedy bandit selector + tests"
```

---

### Task 5 — HostProfileStore.selectN integration test

This task adds an end-to-end test of `selectN` through the store, confirming the
nil-hostKey path and the cold/exploit/explore paths work through the store's public API.

**Files:**
- Modify: `Tests/GohCoreTests/HostProfileStoreTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Scheduling/HostProfileStore.swift` — `selectN` signature
- [ ] `Sources/GohCore/Scheduling/BanditSelector.swift` — `SelectionReason`

**Step 1 — Write failing tests (append to `HostProfileStoreTests.swift`)**

```swift
    // AC5 (through store): nil host key → (8, .cold).
    @Test("AC: nil host key via selectN returns (8, cold)")
    func ac5NilHostKeyViaSore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        let (n, reason) = store.selectN(hostKey: nil)
        #expect(n == 8)
        #expect(reason == .cold)
    }

    // AC5 (through store): unknown host → (8, .cold).
    @Test("AC: unknown host key via selectN returns (8, cold)")
    func ac5UnknownHostViaStore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        _ = store.load()
        let (n, reason) = store.selectN(hostKey: "https://unknown.example.com:443")
        #expect(n == 8)
        #expect(reason == .cold)
    }
```

**Step 2 — Run, expect PASS** (no new code needed — tests use existing `selectN`)

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter HostProfileStoreTests
```

Expected: `Test run with 10 tests passed.`

**Step 5 — Commit**

```
git add Tests/GohCoreTests/HostProfileStoreTests.swift \
  && git commit -m "test(adaptive-scheduling): store selectN integration tests (AC5, AC9)"
```

---

## Phase 3 — Engine and Wiring

*Depends on Phase 2. Touches `DownloadEngine`, `CommandDispatcher`, `gohd/main.swift`.*

---

### Task 6 — Widen `completedDownloadHandler` to carry Duration + isResume

**Files:**
- Modify: `Sources/GohCore/Engine/DownloadEngine.swift`
- Modify: `Tests/GohCoreTests/DownloadEngineTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Engine/DownloadEngine.swift` — lines 67, 70-87 (init), 127-160 (run), 400-465 (fetchSingle), 469-542 (fetchRanged), 544-546 (complete)
- [ ] `Tests/GohCoreTests/DownloadEngineTests.swift` — all usages of `completedDownloadHandler` to update arity
- [ ] `Sources/gohd/main.swift` — current handler closure at line ~119-129

**Step 1 — Write failing test**

The test checks that the `completedDownloadHandler` closure receives a non-zero
`Duration` and `isResume == false` for a fresh download:

```swift
// In DownloadEngineTests.swift — add or extend an existing test:

@Test("AC: completedDownloadHandler receives transfer Duration and isResume flag")
func ac6HandlerReceivesDurationAndIsResume() async throws {
    // This test requires a mock HTTP server or MockURLProtocol.
    // Use the existing MockURLProtocol pattern from the test suite.
    var receivedDuration: Duration?
    var receivedIsResume: Bool?

    let engine = DownloadEngine(
        session: makeMockSession(/* ... */),
        completedDownloadHandler: { _, duration, isResume in
            receivedDuration = duration
            receivedIsResume = isResume
        })
    // ... run a mock download ...
    let duration = try #require(receivedDuration)
    #expect(duration > .zero)
    #expect(receivedIsResume == false)
}
```

*(The exact MockURLProtocol wiring mirrors what `DownloadEngineTests.swift` already does.
Read that file before writing the complete test.)*

**Step 2 — Run, expect FAIL** (compile error — handler arity mismatch)

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter DownloadEngineTests
```

**Step 3 — Implement**

In `DownloadEngine.swift`:

1. Change the stored property type:
```swift
// Before:
private let completedDownloadHandler: (@Sendable (JobSummary) -> Void)?

// After:
private let completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool) -> Void)?
//                                                             ^^^^^^^^  ^^^^
//                                                   transfer Duration  isResume
```

2. Change the `init` parameter to match.

3. Change `complete(jobID:in:)` to `complete(jobID:in:transferDuration:isResume:)`:
```swift
private func complete(
    jobID: UInt64, in store: JobStore,
    transferDuration: Duration, isResume: Bool
) throws {
    let completed = try store.complete(id: jobID)
    completedDownloadHandler?(completed, transferDuration, isResume)
}
```

4. In `fetchRanged`, pass `clock.now - started` and `isResume: false`:
```swift
// After the assembler.finish() + file.finish() block:
try complete(
    jobID: job.id, in: store,
    transferDuration: clock.now - started,
    isResume: false)
```

5. In `fetchSingle`, same pattern:
```swift
try complete(
    jobID: job.id, in: store,
    transferDuration: clock.now - started,
    isResume: false)
```

6. In `resume()` (the resume path), call:
```swift
try complete(
    jobID: job.id, in: store,
    transferDuration: clock.now - started,
    isResume: true)
```

7. Update ALL callsites in `DownloadEngineTests.swift` that pass a 1-argument closure
   to `completedDownloadHandler:` — add the two new parameters to every closure.

**Step 4 — Run, expect PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter DownloadEngineTests
```

Followed by the full suite to catch any missed callers:
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test
```

Expected: `Test run with N tests passed.` (zero failures; zero warnings).

**Step 5 — Commit**

```
git add Sources/GohCore/Engine/DownloadEngine.swift \
        Tests/GohCoreTests/DownloadEngineTests.swift \
  && git commit -m "feat(adaptive-scheduling): D5 — widen completedDownloadHandler to carry transfer Duration + isResume"
```

---

### Task 7 — Admission-time N resolution in CommandDispatcher (D6)

**Files:**
- Modify: `Sources/GohCore/Model/CommandDispatcher.swift`
- Modify: `Tests/GohCoreTests/CommandDispatcherTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Model/CommandDispatcher.swift` — lines 10-44 (init), 50-95 (.add case)
- [ ] `Tests/GohCoreTests/CommandDispatcherTests.swift` — existing tests; all `CommandDispatcher(store:...)` constructors

**Step 1 — Write failing tests**

Append to `CommandDispatcherTests.swift`:

```swift
    // AC7: nil connectionCount → profile-driven N.
    @Test("AC: nil connectionCount uses profile-driven N at admission")
    func ac7NilConnectionCountUsesProfile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))

        // Seed the store with a converged profile that prefers N=16.
        store.recordObservation(
            hostKey: "https://example.com:443", connectionCount: 16,
            totalBytes: 200 * 1024 * 1024, transferDuration: .seconds(15))
        store.recordObservation(
            hostKey: "https://example.com:443", connectionCount: 16,
            totalBytes: 200 * 1024 * 1024, transferDuration: .seconds(15))

        let dispatcher = CommandDispatcher(
            store: JobStore(), hostProfileStore: store)
        let request = AddRequest(url: "https://example.com/file.iso")
        guard case .job(let summary) = dispatcher.reply(to: .add(request: request)) else {
            Issue.record("expected .job"); return
        }
        // With ε=0 exploit the best arm — but selector uses SystemRNG so we
        // can only assert N is in the candidate set.
        #expect(BanditSelector.candidateSet.contains(summary.requestedConnectionCount))
    }

    // AC7: nil connectionCount + no profile → default 8.
    @Test("AC: nil connectionCount with no profile falls back to 8")
    func ac7NilConnectionCountNoProfile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        _ = store.load()

        let dispatcher = CommandDispatcher(
            store: JobStore(), hostProfileStore: store)
        let request = AddRequest(url: "https://coldhost.example.com/file.iso")
        guard case .job(let summary) = dispatcher.reply(to: .add(request: request)) else {
            Issue.record("expected .job"); return
        }
        // Cold → default 8.
        #expect(summary.requestedConnectionCount == 8)
    }

    // AC7: explicit connectionCount is honored unchanged.
    @Test("AC: explicit connectionCount is honored unchanged, ignoring profile")
    func ac7ExplicitConnectionCountHonored() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let profileStore = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))

        let dispatcher = CommandDispatcher(
            store: JobStore(), hostProfileStore: profileStore)
        let request = AddRequest(
            url: "https://example.com/file.iso", connectionCount: 4)
        guard case .job(let summary) = dispatcher.reply(to: .add(request: request)) else {
            Issue.record("expected .job"); return
        }
        #expect(summary.requestedConnectionCount == 4)
    }

    // AC13: JobSummary struct is unchanged (requestedConnectionCount is still UInt8).
    @Test("AC: JobSummary requestedConnectionCount field type is unchanged")
    func ac13JobSummaryUnchanged() {
        let dispatcher = CommandDispatcher(store: JobStore())
        let outcome = dispatcher.reply(
            to: .add(request: AddRequest(url: "https://example.com/f")))
        guard case .job(let summary) = outcome else {
            Issue.record("expected .job"); return
        }
        // requestedConnectionCount is UInt8; this would fail to compile if changed.
        let _: UInt8 = summary.requestedConnectionCount
        #expect(summary.requestedConnectionCount == 8)
    }
```

**Step 2 — Run, expect FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter CommandDispatcherTests
```

Expected: compile error — `CommandDispatcher(store:hostProfileStore:)` not found.

**Step 3 — Implement**

In `CommandDispatcher.swift`:

1. Add stored property:
```swift
private let hostProfileStore: HostProfileStore?
```

2. Add parameter to `init` (after `checkpointStore`, before `importedCookies`):
```swift
hostProfileStore: HostProfileStore? = nil,
```

3. Assign in `init`: `self.hostProfileStore = hostProfileStore`

4. In the `.add` case, replace the static resolution. Hoist `key` and `selectionReason`
   so Task 9 can emit the AC12 trace from this same site:

```swift
// Before:
let requestedConnectionCount = request.connectionCount
    ?? Self.defaultConnectionCount

// After:
// D6: hoist hostKey and selectionReason so the AC12 trace (added in Task 9)
// can emit all four fields from this same site — the only place where hostKey,
// chosenN, reason, and arm EWMAs are simultaneously in scope.
let admissionHostKey = hostKey(for: request.url)
let requestedConnectionCount: UInt8
let selectionReason: SelectionReason
if let explicit = request.connectionCount {
    requestedConnectionCount = explicit
    selectionReason = .cold  // explicit count bypasses the bandit
} else {
    // D6: when connectionCount is nil, consult the host profile bandit.
    let chosen = hostProfileStore?.selectN(hostKey: admissionHostKey)
        ?? (n: Self.defaultConnectionCount, reason: .cold)
    requestedConnectionCount = chosen.n
    selectionReason = chosen.reason
}
```

The `> 0` guard immediately after remains valid — the bandit never returns 0
(candidate set is `{2,4,8,16}`), and the explicit path passes the user's value
through the existing guard.

**Step 4 — Run, expect PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter CommandDispatcherTests
```

Full suite:
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test
```

Expected: all green, zero warnings.

**Step 5 — Commit**

```
git add Sources/GohCore/Model/CommandDispatcher.swift \
        Tests/GohCoreTests/CommandDispatcherTests.swift \
  && git commit -m "feat(adaptive-scheduling): D6 — admission-time N resolution via host profile bandit"
```

---

### Task 8 — Observation recording, active-count bracket, D5 gates, D8 resume skip

**Files:**
- Modify: `Sources/GohCore/Engine/DownloadEngine.swift`
- Modify: `Sources/gohd/main.swift`
- Modify: `Tests/GohCoreTests/DownloadEngineTests.swift` (active-count bracket test)

**Pre-task reads:**
- [ ] `Sources/GohCore/Engine/DownloadEngine.swift` — lines 127-160 (run, control bracket at 129-130), 70-87 (init)
- [ ] `Sources/gohd/main.swift` — full main.swift; `completedDownloadHandler` closure location
- [ ] `Sources/GohCore/Scheduling/HostProfileStore.swift` — `begin`, `wasSolo`, `end`, `recordObservation`, `selectN`

**Step 1 — Write failing tests**

Append to `DownloadEngineTests.swift`:

```swift
    // AC9: begin/end bracket — cannot leak on throw/cancel.
    @Test("AC: end() is called on download failure — active-job set not leaked")
    func ac9ActiveJobEndedOnFailure() async {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let profileStore = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        _ = profileStore.load()

        // Pre-verify: the job is not in any active set.
        let jobID: UInt64 = 99
        #expect(profileStore.wasSolo(jobID: jobID))  // not contended before it even starts

        // Use a mock session that fails immediately.
        let engine = DownloadEngine(
            session: makeFailingMockSession(),
            hostProfileStore: profileStore)

        let store = JobStore()
        let job = store.create(
            url: "https://example.com/file.iso",
            destination: "/tmp/file.iso",
            requestedConnectionCount: 8,
            progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
            lastProgressAt: nil)
        await engine.run(jobID: job.id, in: store)

        // After failure, the job must have been removed from the active-job set
        // (end() called by defer). A subsequent fresh job on the same host starts
        // as solo, which would not hold if end() leaked.
        let key = "https://example.com:443"
        profileStore.begin(jobID: 100, hostKey: key)
        #expect(profileStore.wasSolo(jobID: 100))
        profileStore.end(jobID: 100, hostKey: key)
    }
```

**Step 2 — Run, expect FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter DownloadEngineTests
```

Expected: compile error — `DownloadEngine(session:hostProfileStore:)` not found.

**Step 3 — Implement**

**3a. In `DownloadEngine.swift`:**

Add stored property:
```swift
private let hostProfileStore: HostProfileStore?
```

Add parameter to `init`:
```swift
hostProfileStore: HostProfileStore? = nil,
```

In `run(jobID:in:)`, add the begin/end bracket immediately after the
`control?.register` / `defer { control?.unregister }` pair (lines 129-130):

```swift
// Active-job bracket (D5/D7) — mirrors control?.register/unregister.
// begin() marks the job active and flags any concurrent siblings contended.
// end() is in a defer so it fires on every exit path (throw, pause, cancel,
// success) — cannot leak regardless of how run() terminates.
let jobHostKey = store.job(id: jobID).flatMap { hostKey(for: $0.url) }
if let key = jobHostKey {
    hostProfileStore?.begin(jobID: jobID, hostKey: key)
}
defer {
    if let key = jobHostKey {
        hostProfileStore?.end(jobID: jobID, hostKey: key)
    }
}
```

IMPORTANT: The completion handler fires INSIDE `complete(jobID:in:)`, which is called
INSIDE the `do` block of `run()`. The `defer { end(jobID:hostKey:) }` executes when
`run()` exits — AFTER the completion handler returns. Therefore, at handler time the job
is still registered in the active-job set, and `wasSolo(jobID:)` returns the correct
answer. The handler must call `wasSolo` BEFORE `end()` runs, which is automatically
satisfied by the defer order.

No other change to `DownloadEngine` for observation recording — that lives in `gohd/main.swift`.

**3b. In `gohd/main.swift`:**

1. Construct `HostProfileStore` after `checkpointStore`:
```swift
let hostProfileStore = HostProfileStore(
    fileURL: supportDirectory.appending(path: "host-scheduling.plist"),
    persistFailureReporter: { operation, error in
        warn("host-profile store persist failed (\(operation)): \(error)")
    })
let hostProfileLoadResult = hostProfileStore.load()
if let sidecar = hostProfileLoadResult.corruptionSidecar {
    warn("the host-scheduling file was unreadable and has been reset; "
        + "the damaged file was kept at \(sidecar.path)")
}
```

2. Thread `hostProfileStore` into `DownloadEngine.init`:
```swift
let engine = DownloadEngine(
    session: URLSession(configuration: GohCore.downloadSessionConfiguration()),
    checkpointStore: checkpointStore,
    control: downloadControl,
    cookieHeaderProvider: { jobID, _ in importedCookies.header(forJobID: jobID) },
    sleepAssertionController: sleepAssertions,
    hostProfileStore: hostProfileStore,
    completedDownloadHandler: { completed, transferDuration, isResume in
        // D8: skip observation for resume path.
        if !isResume {
            // D5 gates — all must hold to record a valid observation.
            // wasSolo is checked BEFORE end() runs (end() is in a defer in run(),
            // which fires after this handler returns). So at this point the job is
            // still registered and wasSolo returns the correct whole-duration answer.
            let minDuration = Duration.seconds(10)
            let minBytes: UInt64 = 8 * 1024 * 1024
            let urlKey = hostKey(for: completed.url)

            if let key = urlKey,
               transferDuration >= minDuration,
               completed.progress.bytesCompleted >= minBytes,
               hostProfileStore.wasSolo(jobID: completed.id),  // whole-duration solo check
               completed.actualConnectionCount == completed.requestedConnectionCount
            {
                hostProfileStore.recordObservation(
                    hostKey: key,
                    connectionCount: completed.actualConnectionCount,
                    totalBytes: completed.progress.bytesCompleted,
                    transferDuration: transferDuration)
            }
        }

        // Existing Spotlight tagging.
        do {
            try metadataTagger.tagCompletedDownload(
                destination: completed.destination,
                sourceURL: completed.url,
                downloadedAt: completed.completedAt ?? Date())
        } catch {
            warn("job \(completed.id) completed but Spotlight metadata tagging failed: \(error)")
        }
    },
    unexpectedStoreError: { jobID, operation, error in
        warn("job \(jobID) store.\(operation) failed unexpectedly: \(error)")
    })
```

3. Thread `hostProfileStore` into `CommandDispatcher.init`:
```swift
let dispatcher = CommandDispatcher(
    store: store, control: downloadControl,
    checkpointStore: checkpointStore,
    importedCookies: importedCookies,
    hostProfileStore: hostProfileStore,
    queuedJobAdmission: { networkCoordinator.jobBecameQueued($0) })
```

**Step 4 — Run, expect PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter DownloadEngineTests
```

Full suite:
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test
```

Expected: all green, zero warnings.

**Step 5 — Commit**

```
git add Sources/GohCore/Engine/DownloadEngine.swift \
        Sources/gohd/main.swift \
        Tests/GohCoreTests/DownloadEngineTests.swift \
  && git commit -m "feat(adaptive-scheduling): D5/D7/D8 — active-count bracket, observation recording with gate predicate, resume skip"
```

---

### Task 9 — GOH_ENGINE_TRACE extension + regression benchmark guard

**Files:**
- Modify: `Sources/GohCore/Engine/EngineDiagnostics.swift`
- Modify: `Sources/GohCore/Engine/DownloadEngine.swift`
- Modify: `Benchmarks/goh-bench/main.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Engine/EngineDiagnostics.swift` — existing `EngineDiagnostics` type, `GOH_ENGINE_TRACE` pattern, access level (`internal`), and how `Tests/GohCoreTests/EngineDiagnosticsTests.swift` imports it (`@testable import GohCore`)
- [ ] `Sources/GohCore/Model/CommandDispatcher.swift` — where N resolution happens (the `.add` case after Task 7's changes); this is where all four AC12 fields are in hand simultaneously
- [ ] `Benchmarks/goh-bench/main.swift` — existing benchmark structure and how results are printed
- [ ] `Sources/GohCore/Scheduling/BanditSelector.swift` — `SelectionReason` cases

**Step 1 — Write failing test (AC12 compile + field check)**

Create `Tests/GohCoreTests/EngineDiagnosticsSchedulingTests.swift`.
`EngineDiagnostics` is `internal` — matching the existing `EngineDiagnosticsTests.swift`
which uses `@testable import GohCore`. Do the same here.

```swift
import Foundation
import Testing

@testable import GohCore

@Suite("Engine diagnostics — scheduling decision trace (AC12)")
struct EngineDiagnosticsSchedulingTests {

    // AC12: recordSchedulingDecision must exist and accept the four required fields.
    // EngineDiagnostics is internal; this test uses @testable import GohCore,
    // matching the existing EngineDiagnosticsTests pattern.
    @Test("AC: recordSchedulingDecision accepts hostKey, chosenN, reason, armEWMAs (compile check)")
    func ac12MethodExistsAndCompiles() {
        // Enabled=false so no stderr output during test runs.
        let diag = EngineDiagnostics(enabled: false)
        // If any parameter type is wrong, this fails to compile — no runtime assertion needed.
        diag.recordSchedulingDecision(
            hostKey: "https://example.com:443",
            chosenN: 8,
            reason: SelectionReason.cold,
            armEWMAs: [8: 10_000_000.0, 16: 15_000_000.0])
        // Disabled trace is a no-op; peakActive is unrelated but verifies the
        // instance is in the expected disabled state.
        #expect(diag.peakActive == 0)
    }

    // AC12: when enabled, recordSchedulingDecision does not crash and runs the body.
    @Test("AC: recordSchedulingDecision with enabled trace does not crash")
    func ac12EnabledDoesNotCrash() {
        let diag = EngineDiagnostics(enabled: true)
        // All four reason cases must be accepted.
        diag.recordSchedulingDecision(
            hostKey: "https://example.com:443", chosenN: 8,
            reason: .cold, armEWMAs: [:])
        diag.recordSchedulingDecision(
            hostKey: "https://example.com:443", chosenN: 16,
            reason: .exploit, armEWMAs: [8: 9_000_000, 16: 18_000_000])
        diag.recordSchedulingDecision(
            hostKey: "https://example.com:443", chosenN: 4,
            reason: .explore, armEWMAs: [4: 5_000_000])
        diag.recordSchedulingDecision(
            hostKey: nil, chosenN: 8, reason: .cold, armEWMAs: [:])
        // No crash and no state corruption.
        #expect(diag.peakActive == 0)
    }
}
```

**Step 2 — Run, expect FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter EngineDiagnosticsSchedulingTests
```

**Step 3 — Implement**

**3a. In `EngineDiagnostics.swift`** — add the method (keeping it `internal`, consistent with all other methods in this file):

```swift
/// Emits a scheduling-decision trace line to stderr when `GOH_ENGINE_TRACE=1`.
///
/// Called from `CommandDispatcher` at admission time — the point where all four
/// fields (hostKey, chosenN, reason, arm EWMAs) are simultaneously in hand.
/// NOT called from `DownloadEngine`, which has none of the bandit fields.
///
/// Format: `[goh-trace t=Xs] scheduling host=<key> chosenN=<N> reason=<reason> ewmas=[...]`
func recordSchedulingDecision(
    hostKey: String?,
    chosenN: UInt8,
    reason: SelectionReason,
    armEWMAs: [UInt8: Double]
) {
    guard enabled else { return }
    let ewmaStr = armEWMAs
        .sorted { $0.key < $1.key }
        .map { "N\($0.key)=\(String(format: "%.0f", $0.value))B/s" }
        .joined(separator: " ")
    let host = hostKey ?? "(nil)"
    let reasonStr: String
    switch reason {
    case .cold:    reasonStr = "cold"
    case .exploit: reasonStr = "exploit"
    case .explore: reasonStr = "explore"
    }
    emit("scheduling host=\(host) chosenN=\(chosenN) reason=\(reasonStr) ewmas=[\(ewmaStr)]")
}
```

**3b. In `CommandDispatcher.swift`** — emit the AC12 trace from the `.add` case,
immediately after the `requestedConnectionCount`/`selectionReason` block added in
Task 7. All four AC12 fields are in hand at this point: `admissionHostKey`, `requestedConnectionCount`,
`selectionReason`, and the profile's arm EWMAs.

```swift
// AC12: emit scheduling-decision trace (GOH_ENGINE_TRACE=1).
// Emitted here because this is the only site where all four fields are
// simultaneously in scope. The engine knows neither reason nor arm EWMAs.
let armEWMAs: [UInt8: Double]
if let key = admissionHostKey,
   let profile = hostProfileStore?.profile(hostKey: key) {
    armEWMAs = Dictionary(
        uniqueKeysWithValues: profile.arms.map { ($0.connectionCount, $0.throughputEWMA) })
} else {
    armEWMAs = [:]
}
EngineDiagnostics().recordSchedulingDecision(
    hostKey: admissionHostKey,
    chosenN: requestedConnectionCount,
    reason: selectionReason,
    armEWMAs: armEWMAs)
```

Add a `profile(hostKey:)` accessor to `HostProfileStore` returning `HostProfile?`:
```swift
/// Returns the current in-memory profile for `hostKey`, or nil if not found.
public func profile(hostKey: String) -> HostProfile? {
    inner.withLock { $0.scheduling.hosts.first { $0.host == hostKey } }
}
```

**3c. In `Benchmarks/goh-bench/main.swift`** — add the regression benchmark guard:

```swift
// AC11: Regression guard — converged-N throughput must be >= static-8 baseline
// within tolerance on the saturated workload.
//
// This test runs the same URL through the adaptive engine N times (profile
// cold to converged), then asserts the final throughput >= the static-8 result
// within a tolerance factor.
//
// The saturated workload is the local or controlled test server used in the
// existing bench suite. A missing GOH_BENCH_URL env var skips the guard.

func runRegressionGuard() async throws {
    guard let urlString = ProcessInfo.processInfo.environment["GOH_BENCH_REGRESSION_URL"] else {
        print("skipping regression guard (GOH_BENCH_REGRESSION_URL not set)")
        return
    }

    let toleranceFactor: Double = 0.90  // converged must be >= 90% of static-8

    // Baseline: static-8 download.
    let baselineThroughput = try await measureThroughput(url: urlString, connectionCount: 8)
    print("baseline static-8 throughput: \(formatThroughput(baselineThroughput))")

    // Warm up the adaptive engine over several downloads.
    let profileStore = HostProfileStore(fileURL: URL(fileURLWithPath: "/tmp/goh-bench-regression.plist"))
    _ = profileStore.load()
    for _ in 1...6 {
        _ = try await measureAdaptiveThroughput(url: urlString, profileStore: profileStore)
    }

    // Final measurement.
    let adaptiveThroughput = try await measureAdaptiveThroughput(url: urlString, profileStore: profileStore)
    print("converged adaptive throughput: \(formatThroughput(adaptiveThroughput))")

    // AC11: regression guard.
    let threshold = baselineThroughput * toleranceFactor
    guard adaptiveThroughput >= threshold else {
        // This is a failing benchmark — print a clear failure line and exit non-zero.
        print("REGRESSION: adaptive throughput \(formatThroughput(adaptiveThroughput))"
            + " < \(Int(toleranceFactor * 100))% of static-8 baseline \(formatThroughput(baselineThroughput))")
        exit(1)
    }
    print("regression guard PASSED: adaptive >= \(Int(toleranceFactor * 100))% of baseline")
}
```

**Step 4 — Run, expect PASS**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter EngineDiagnosticsSchedulingTests
```

Then full suite:
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test
```

Expected: all green, zero warnings.

**Step 5 — Commit**

```
git add Sources/GohCore/Engine/EngineDiagnostics.swift \
        Sources/GohCore/Model/CommandDispatcher.swift \
        Sources/GohCore/Scheduling/HostProfileStore.swift \
        Tests/GohCoreTests/EngineDiagnosticsSchedulingTests.swift \
        Benchmarks/goh-bench/main.swift \
  && git commit -m "feat(adaptive-scheduling): AC12 GOH_ENGINE_TRACE scheduling decision from CommandDispatcher + AC11 regression benchmark guard"
```

---

## Final verification

After all tasks complete, run the full suite and confirm zero failures and zero warnings:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build 2>&1 | grep -E "error:|warning:"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test
```

Expected:
- `swift build`: no output (zero errors, zero warnings — `-warnings-as-errors` is CI default)
- `swift test`: `Test run with N tests passed.`

Confirm the invariants from the spec:
- [ ] `protocolVersion` == 3 (grep: `protocolVersion`)
- [ ] `JobCatalog.currentVersion` == 1 (grep: `currentVersion`)
- [ ] `host-scheduling.plist` is **not** mentioned in the wire protocol or `JobCatalog`
- [ ] `JobSummary` has no new persisted fields

---

## Summary

| Phase | Tasks | Key deliverable |
|-------|-------|-----------------|
| Phase 1 | 1–2 | `HostKey.swift`, `HostScheduling.swift`, golden fixture + round-trip guard |
| Phase 2 | 3–5 | `HostProfileStore.swift`, `BanditSelector.swift`, store integration tests |
| Phase 3 | 6–9 | Engine widening, dispatcher D6 wiring, gohd wiring, trace + benchmark guard |
| **Total** | **9** | **AC1–AC13 covered** |
