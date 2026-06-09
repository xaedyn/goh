---
date: 2026-06-08
feature: tiered-rapid-trust
type: implementation-plan
spec: docs/superpowers/specs/2026-06-08-tiered-rapid-trust-design.md
branch: design/tiered-rapid-trust
---

# Implementation Plan — Tiered Rapid Trust

## Goal

Add a fast, O(1) heuristic trust check ("does this file still look like what I recorded?")
alongside the existing O(size) SHA-256 deep verify. Three deliverables:

1. **GohCore data + pure logic** — `FileStat`, probe protocol, `FastCheckRunner`, five
   additive-optional baseline fields on `ProvenanceEntry`. Independently shippable.
2. **Capture path** — `DownloadFile.fileStat()`, widen `complete()/completedDownloadHandler`
   with a trailing `FileStat?`, three finalization-point capture sites, daemon routing.
3. **Surfaces** — `goh verify --quick` CLI, `TrustDisplayStatus` + presenter changes +
   Trust window fast-check on open, `LiveFileStatProbe` wired in goh-menu.

## Architecture (the bets)

**Bet 1 — additive-optional, no version bump.** Five new `Optional` integer fields on
`ProvenanceEntry` with `nil` defaults. `PropertyListEncoder` omits nil keys; old readers
ignore unknown keys. `ProvenanceRecord.currentVersion` stays `1`. The golden fixture
`Tests/GohCoreTests/Fixtures/provenance-v1.plist` round-trips byte-for-byte unchanged.
Precedent: `verifiedAt` used identical mechanics.

**Bet 2 — fstat-at-finalize closes TOCTOU.** The engine holds the file descriptor open
while hashing. Capturing `fstat(descriptor)` at the moment SHA-256 is finalized means
the baseline provably describes the hashed bytes. The fd is the same inode as the on-disk
file (`pwrite` in place, no `.part+rename`), so a later `lstat` matches.

**Bet 3 — `looksUnchanged` ≠ `verified` at the model layer.** Enforced by
`TrustDisplayStatus` as distinct enum cases — a future UI change cannot collapse a
heuristic result into a cryptographic claim.

## Tech Stack

Swift 6.3.x toolchain / 6.2 tools-version. SwiftPM. macOS 26.0+. Targets:
`GohCore` (nonisolated-default isolation), `GohMenuBar` (MainActor-default),
`gohd` (daemon, nonisolated-default), `goh` (CLI), `goh-menu` (app).
CryptoKit SHA-256, `import Darwin` for `lstat`/`fstat`/`struct stat`,
`Synchronization.Mutex`, `PropertyListEncoder` (binary plist), Swift Testing.

**Build/test commands (all tasks use these exactly):**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <SuiteName>
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## AC Ownership Map

| AC | Description | Task |
|----|-------------|------|
| AC1 | Fast-check does only lstat — no content reads | T1.3 |
| AC2 | All five fields match → `.unchanged` | T1.3 |
| AC3 | Any single field differs → `.changed(reason:)` | T1.3 |
| AC4 | `lstat` ENOENT → `.missing` | T1.2 |
| AC5 | `lstat` other errno → `.indeterminate` | T1.2 |
| AC6 | Entry missing any baseline field → `.notBaselined` | T1.3 |
| AC7 | Path is not a regular file → `.changed(.identity)` | T1.3 |
| AC8 | `looksUnchanged` ≠ `verified` display tokens | T3.1 |
| AC9 | Golden fixture round-trips unchanged after new fields | T1.1 |

## File Map

### Phase 1 — GohCore data + pure logic

| File | Create/Modify | Key new symbols |
|------|--------------|-----------------|
| `Sources/GohCore/Provenance/FileStat.swift` | **Create** | `FileStat`, `FileProbeResult`, `FileStatProbing`, `LiveFileStatProbe` |
| `Sources/GohCore/Provenance/FastCheck.swift` | **Create** | `FastChangeReason`, `FastCheckStatus`, `FastCheckRunner` |
| `Sources/GohCore/Provenance/ProvenanceRecord.swift` | **Modify** | +5 optional fields on `ProvenanceEntry` |
| `Tests/GohCoreTests/FileStatProbeTests.swift` | **Create** | probe tests (AC4, AC5) |
| `Tests/GohCoreTests/FastCheckRunnerTests.swift` | **Create** | fast-check logic tests (AC1–AC3, AC6–AC7) |
| `Tests/GohCoreTests/ProvenanceRecordTests.swift` | **Modify** | extend golden round-trip test (AC9) |

### Phase 2 — Capture path

| File | Create/Modify | Key changes |
|------|--------------|-------------|
| `Sources/GohCore/Engine/DownloadFile.swift` | **Modify** | `fileStat() throws -> FileStat` |
| `Sources/GohCore/Engine/DownloadEngine.swift` | **Modify** | widen `complete(...)` + handler type + 3 capture sites |
| `Sources/gohd/main.swift` | **Modify** | route `FileStat?` → `ProvenanceEntry` baseline fields |
| `Tests/GohCoreTests/DownloadFileTests.swift` | **Modify** | add `fileStat()` test |

### Phase 3 — Surfaces

| File | Create/Modify | Key changes |
|------|--------------|-------------|
| `Sources/GohCore/CLI/GohCommandLine.swift` | **Modify** | `verifyQuick` parsed case; `--quick` flag dispatch |
| `Sources/GohCore/CLI/GohVerifyQuickCommand.swift` | **Create** | `GohVerifyQuickCommand.run(...)` |
| `Sources/GohMenuBar/GohTrustModels.swift` | **Modify** | `TrustDisplayStatus`; update `GohTrustEntryRow` |
| `Sources/GohMenuBar/GohTrustPresenter.swift` | **Modify** | `static displayStatus(entry:fastStatus:)` + `static displayStatus(verifiedAt:fastStatus:)` convenience overload |
| `Sources/GohMenuBar/TrustWindowViewModel.swift` | **Modify** | run `FastCheckRunner.checkAll` on `loadOverview()`; publish `fastStatuses: [String: FastCheckStatus]`; inject `any FileStatProbing` |
| `Sources/GohMenuBar/TrustWindowView.swift` | **Modify** | render `TrustDisplayStatus` per row; distinct chip for `looksUnchanged` |
| `Sources/goh-menu/main.swift` | **Modify** | wire `LiveFileStatProbe` into `TrustWindowViewModel` |
| `Tests/GohCoreTests/GohVerifyQuickCommandTests.swift` | **Create** | CLI `--quick` tests |
| `Tests/GohMenuBarTests/GohTrustPresenterTests.swift` | **Modify** | AC8 token-distinctness test |

## Phase Artifact Paths

- `docs/superpowers/progress/2026-06-08-tiered-rapid-trust-phase1.md`
- `docs/superpowers/progress/2026-06-08-tiered-rapid-trust-phase2.md`
- `docs/superpowers/progress/2026-06-08-tiered-rapid-trust-phase3.md`

---

# Phase 1 — GohCore Data + Pure Logic

**Independently shippable.** No daemon or surface changes. All tests are pure
(injected `FileStat`, no real files, no `Date()`).

THE BET CHECK (Phase 1): After adding the five optional fields, run
`swift test --filter ProvenanceRecordTests`. The golden fixture round-trip test MUST
pass unchanged. If it fails, STOP — the format invariant is broken.

---

## Task 1.1 — `ProvenanceEntry` +5 optional baseline fields + AC9 golden test

**Files:**
- Modify: `Sources/GohCore/Provenance/ProvenanceRecord.swift`
- Test: `Tests/GohCoreTests/ProvenanceRecordTests.swift`

**Pre-task reads:**
- [x] `Sources/GohCore/Provenance/ProvenanceRecord.swift` — read in Phase 0. `ProvenanceEntry` has 6 stored props + init with `verifiedAt: Date? = nil`. `ProvenanceRecord.currentVersion == 1`.
- [x] `Tests/GohCoreTests/ProvenanceRecordTests.swift` — read in Phase 0. Golden round-trip test at `goldenFixtureRoundTrip()` decodes `provenance-v1.plist`, asserts `version == 1`, 2 entries, nil `verifiedAt`. The round-trip uses encode→decode equality (NOT byte-identity).

**AC ownership:** AC9

### Step 1 — Write failing test

Add to `Tests/GohCoreTests/ProvenanceRecordTests.swift` (inside `@Suite("ProvenanceRecord")`):

```swift
// AC9: adding the 5 optional baseline fields does NOT break the golden fixture.
// The fixture must still decode (nil baseline), round-trip unchanged, and
// ProvenanceRecord.currentVersion must remain 1.
@Test("AC9: golden fixture still round-trips after adding 5 optional baseline fields")
func baselineFieldsAreAdditivePONilDecodes() throws {
    // Re-read the fixture.
    let fixtureURL = Bundle.module.url(
        forResource: "provenance-v1", withExtension: "plist",
        subdirectory: "Fixtures")
    let fixtureData = try Data(contentsOf: #require(fixtureURL))
    let decoded = try PropertyListDecoder().decode(ProvenanceRecord.self, from: fixtureData)

    // Version must not have changed.
    #expect(ProvenanceRecord.currentVersion == 1)
    #expect(decoded.version == 1)

    // All five new fields must decode as nil (not present in the old fixture).
    for entry in decoded.entries {
        #expect(entry.recordedStatSize == nil,
            "recordedStatSize should be nil for pre-feature entries")
        #expect(entry.recordedMtimeSeconds == nil,
            "recordedMtimeSeconds should be nil for pre-feature entries")
        #expect(entry.recordedMtimeNanoseconds == nil,
            "recordedMtimeNanoseconds should be nil for pre-feature entries")
        #expect(entry.recordedInode == nil,
            "recordedInode should be nil for pre-feature entries")
        #expect(entry.recordedDevice == nil,
            "recordedDevice should be nil for pre-feature entries")
    }

    // Round-trip the decoded value — encode→decode must be identity.
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let reencoded = try encoder.encode(decoded)
    let redecoded = try PropertyListDecoder().decode(ProvenanceRecord.self, from: reencoded)
    #expect(redecoded == decoded)

    // Round-trip an entry WITH baseline fields set — they must survive.
    var entryWithBaseline = decoded.entries[0]
    entryWithBaseline.recordedStatSize = 1_048_576
    entryWithBaseline.recordedMtimeSeconds = 1_748_000_000
    entryWithBaseline.recordedMtimeNanoseconds = 123_456_789
    entryWithBaseline.recordedInode = 42_000
    entryWithBaseline.recordedDevice = 1
    let recordWithBaseline = ProvenanceRecord(version: 1, entries: [entryWithBaseline])
    let data2 = try encoder.encode(recordWithBaseline)
    let decoded2 = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data2)
    #expect(decoded2.entries[0].recordedStatSize == 1_048_576)
    #expect(decoded2.entries[0].recordedMtimeSeconds == 1_748_000_000)
    #expect(decoded2.entries[0].recordedMtimeNanoseconds == 123_456_789)
    #expect(decoded2.entries[0].recordedInode == 42_000)
    #expect(decoded2.entries[0].recordedDevice == 1)
}
```

### Step 2 — Run test expecting failure (fields not yet declared)

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProvenanceRecordTests/baselineFieldsAreAdditivePONilDecodes
```

Expected: compile error — `recordedStatSize` / `recordedMtimeSeconds` etc. not found.

### Step 3 — Implementation

Modify `Sources/GohCore/Provenance/ProvenanceRecord.swift`. Add the five optional
properties to `ProvenanceEntry` after `verifiedAt`, with the same `Optional` / default-nil
pattern. Extend the init to accept them with defaults.

```swift
// In ProvenanceEntry, after the `verifiedAt` property:

/// Stat baseline captured by `fstat(2)` on the engine's file descriptor at the
/// moment SHA-256 finalization completes. All five fields are present iff the
/// engine ran `DownloadFile.fileStat()` successfully; any nil → `.notBaselined`.
///
/// Stored as raw integers (exact through binary plist — Swift `Date` would lose
/// `st_mtimespec` nanoseconds to a Double). Additive-optional: absent from old
/// records (decode to nil); nil fields serialize without the key.
/// `ProvenanceRecord.currentVersion` stays 1.
public var recordedStatSize: Int64?          // st_size (off_t)
public var recordedMtimeSeconds: Int64?      // st_mtimespec.tv_sec
public var recordedMtimeNanoseconds: Int64?  // st_mtimespec.tv_nsec
public var recordedInode: UInt64?            // st_ino (ino_t = __uint64_t)
public var recordedDevice: Int64?            // st_dev (dev_t = Int32) widened losslessly

// In ProvenanceEntry.init, add trailing parameters with nil defaults:
public init(
    url: String,
    sha256: String,
    size: Int,
    downloadedAt: Date,
    destinationPath: String,
    verifiedAt: Date? = nil,
    recordedStatSize: Int64? = nil,
    recordedMtimeSeconds: Int64? = nil,
    recordedMtimeNanoseconds: Int64? = nil,
    recordedInode: UInt64? = nil,
    recordedDevice: Int64? = nil
) {
    self.url = url
    self.sha256 = sha256
    self.size = size
    self.downloadedAt = downloadedAt
    self.destinationPath = destinationPath
    self.verifiedAt = verifiedAt
    self.recordedStatSize = recordedStatSize
    self.recordedMtimeSeconds = recordedMtimeSeconds
    self.recordedMtimeNanoseconds = recordedMtimeNanoseconds
    self.recordedInode = recordedInode
    self.recordedDevice = recordedDevice
}
```

All callers (daemon, tests) use trailing defaults — no call site changes needed.

### Step 4 — Run test expecting pass

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProvenanceRecordTests
```

Expected: all ProvenanceRecordTests pass including the pre-existing golden round-trip
and the new `baselineFieldsAreAdditivePONilDecodes` test.

### Step 5 — Commit

```
git add Sources/GohCore/Provenance/ProvenanceRecord.swift \
        Tests/GohCoreTests/ProvenanceRecordTests.swift
git commit -m "feat(provenance): add 5 additive-optional stat baseline fields to ProvenanceEntry (AC9)"
```

---

## Task 1.2 — `FileStat`, `FileProbeResult`, `FileStatProbing`, `LiveFileStatProbe` + probe tests (AC4, AC5)

**Files:**
- Create: `Sources/GohCore/Provenance/FileStat.swift`
- Create: `Tests/GohCoreTests/FileStatProbeTests.swift`

**AC ownership:** AC4, AC5

### Step 1 — Write failing tests

Create `Tests/GohCoreTests/FileStatProbeTests.swift`:

```swift
import Darwin
import Foundation
import Testing
@testable import GohCore

// Stub probe for testing without real files.
private struct StubProbe: FileStatProbing {
    let result: FileProbeResult
    nonisolated func probe(path: String) -> FileProbeResult { result }
}

// Counting probe — records call count to assert no content reads (AC1).
// @unchecked Sendable: single-threaded test assumption — only the test body accesses _count.
nonisolated final class CountingProbe: FileStatProbing, @unchecked Sendable {
    private var _count = 0
    var count: Int { _count }

    nonisolated func probe(path: String) -> FileProbeResult {
        _count += 1
        return .notFound
    }
}

@Suite("FileStatProbe")
struct FileStatProbeTests {

    // AC4: ENOENT → .notFound
    @Test("AC4: lstat ENOENT maps to .notFound")
    func enoentMapsToNotFound() {
        let probe = StubProbe(result: .notFound)
        let result = probe.probe(path: "/nonexistent/path/file.bin")
        #expect(result == .notFound)
    }

    // AC5: other errno → .unreadable (NOT .notFound)
    @Test("AC5: errno EACCES maps to .unreadable, not .notFound")
    func eaccesIsUnreadable() {
        let probe = StubProbe(result: .unreadable(EACCES))
        guard case .unreadable(let code) = probe.probe(path: "/restricted/file.bin") else {
            Issue.record("Expected .unreadable, got .notFound")
            return
        }
        #expect(code == EACCES)
    }

    // AC5: ELOOP → .unreadable
    @Test("AC5: errno ELOOP maps to .unreadable")
    func eloopIsUnreadable() {
        let probe = StubProbe(result: .unreadable(ELOOP))
        guard case .unreadable(let code) = probe.probe(path: "/loop/file.bin") else {
            Issue.record("Expected .unreadable")
            return
        }
        #expect(code == ELOOP)
    }

    // AC5: ENOTDIR → .unreadable
    @Test("AC5: errno ENOTDIR maps to .unreadable")
    func enotdirIsUnreadable() {
        let probe = StubProbe(result: .unreadable(ENOTDIR))
        guard case .unreadable(let code) = probe.probe(path: "/not/a/dir/file.bin") else {
            Issue.record("Expected .unreadable")
            return
        }
        #expect(code == ENOTDIR)
    }

    // LiveFileStatProbe on a real absent path → .notFound
    @Test("AC4: LiveFileStatProbe on absent path yields .notFound")
    func liveProbeAbsentPath() {
        let probe = LiveFileStatProbe()
        let result = probe.probe(path: "/tmp/goh-test-definitely-missing-\(UUID().uuidString)")
        #expect(result == .notFound)
    }

    // LiveFileStatProbe on a real existing file → .stat(FileStat) with isRegularFile == true
    @Test("LiveFileStatProbe on a real file yields .stat with isRegularFile true")
    func liveProbeRealFile() throws {
        let tmpPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("goh-probe-test-\(UUID().uuidString).bin").path
        try Data("hello".utf8).write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let probe = LiveFileStatProbe()
        let result = probe.probe(path: tmpPath)
        guard case .stat(let s) = result else {
            Issue.record("Expected .stat, got \(result)")
            return
        }
        #expect(s.size == 5)
        #expect(s.isRegularFile == true)
        #expect(s.inode > 0)
        #expect(s.device != 0)
    }

    // FileStat.isRegularFile false for a directory
    @Test("LiveFileStatProbe on a directory yields isRegularFile == false")
    func liveProbeDirectory() {
        let probe = LiveFileStatProbe()
        let result = probe.probe(path: NSTemporaryDirectory())
        guard case .stat(let s) = result else {
            Issue.record("Expected .stat for /tmp directory")
            return
        }
        #expect(s.isRegularFile == false)
    }
}
```

### Step 2 — Run test expecting failure

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FileStatProbeTests
```

Expected: compile error — `FileStat`, `FileProbeResult`, `FileStatProbing`, `LiveFileStatProbe` not found.

### Step 3 — Implementation

Create `Sources/GohCore/Provenance/FileStat.swift`:

```swift
import Darwin

/// Captured filesystem metadata for one file — the fast-check baseline.
///
/// All fields are raw integers (exact; no floating-point conversion).
/// `isRegularFile` is derived from `st_mode` via `(st_mode & S_IFMT) == S_IFREG` at probe time.
/// (`S_ISREG` is a function-like C macro and cannot be imported into Swift; use the bit-test instead.)
public struct FileStat: Sendable, Equatable {
    public let size: Int64           // st_size (off_t)
    public let mtimeSeconds: Int64   // st_mtimespec.tv_sec
    public let mtimeNanoseconds: Int64 // st_mtimespec.tv_nsec
    public let inode: UInt64         // st_ino (ino_t = __uint64_t)
    public let device: Int64         // st_dev (dev_t = Int32) widened losslessly to Int64
    public let isRegularFile: Bool   // (st_mode & S_IFMT) == S_IFREG

    public init(
        size: Int64,
        mtimeSeconds: Int64,
        mtimeNanoseconds: Int64,
        inode: UInt64,
        device: Int64,
        isRegularFile: Bool
    ) {
        self.size = size
        self.mtimeSeconds = mtimeSeconds
        self.mtimeNanoseconds = mtimeNanoseconds
        self.inode = inode
        self.device = device
        self.isRegularFile = isRegularFile
    }
}

/// The result of probing a path's filesystem metadata.
///
/// `lstat(2)` is used — symlinks at the path are not followed.
public enum FileProbeResult: Sendable, Equatable {
    /// The stat succeeded and the file is accessible.
    case stat(FileStat)
    /// `lstat` failed with `ENOENT` — the path does not exist.
    case notFound
    /// `lstat` failed with any other errno (e.g. `EACCES`, `ELOOP`, `ENOTDIR`).
    /// A present-but-unreadable file is never reported as `notFound`.
    case unreadable(Int32)
}

/// Injectable protocol for probing file metadata.
///
/// The real implementation uses `lstat(2)` (does NOT follow symlinks); tests
/// inject a stub so the comparison logic is exercised with zero real file I/O.
public protocol FileStatProbing: Sendable {
    /// Probes `path` with `lstat(2)` and returns the classified result.
    /// Never throws — errors are mapped to `FileProbeResult`.
    func probe(path: String) -> FileProbeResult
}

/// The real `FileStatProbing` implementation — uses `lstat(2)` directly.
///
/// Mapping:
///   - `ENOENT` → `.notFound`
///   - any other non-zero errno → `.unreadable(errno)`
///   - success → `.stat(FileStat)` with `isRegularFile` derived from `st_mode`
public struct LiveFileStatProbe: FileStatProbing {
    public init() {}

    public nonisolated func probe(path: String) -> FileProbeResult {
        var st = stat()
        let rc = path.withCString { Darwin.lstat($0, &st) }
        if rc != 0 {
            let err = errno
            if err == ENOENT {
                return .notFound
            }
            return .unreadable(err)
        }
        let fs = FileStat(
            size: Int64(st.st_size),
            mtimeSeconds: Int64(st.st_mtimespec.tv_sec),
            mtimeNanoseconds: Int64(st.st_mtimespec.tv_nsec),
            inode: UInt64(st.st_ino),
            device: Int64(st.st_dev),
            isRegularFile: (st.st_mode & S_IFMT) == S_IFREG)
        return .stat(fs)
    }
}
```

### Step 4 — Run test expecting pass

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FileStatProbeTests
```

Expected: all FileStatProbeTests pass.

### Step 5 — Commit

```
git add Sources/GohCore/Provenance/FileStat.swift \
        Tests/GohCoreTests/FileStatProbeTests.swift
git commit -m "feat(provenance): add FileStat, FileProbeResult, FileStatProbing, LiveFileStatProbe (AC4, AC5)"
```

---

## Task 1.3 — `FastChangeReason`, `FastCheckStatus`, `FastCheckRunner` + tests (AC1–AC3, AC6–AC7)

**Files:**
- Create: `Sources/GohCore/Provenance/FastCheck.swift`
- Create: `Tests/GohCoreTests/FastCheckRunnerTests.swift`

**AC ownership:** AC1, AC2, AC3, AC6, AC7

### Step 1 — Write failing tests

Create `Tests/GohCoreTests/FastCheckRunnerTests.swift`:

```swift
import Darwin
import Foundation
import Testing
@testable import GohCore

// Stub probe with a configurable return value.
private struct FixedProbe: FileStatProbing {
    let result: FileProbeResult
    nonisolated func probe(path: String) -> FileProbeResult { result }
}

// Call-counting probe to assert no content reads (AC1).
// @unchecked Sendable: single-threaded test assumption — only the test body accesses _calls.
private nonisolated final class CallCountingProbe: FileStatProbing, @unchecked Sendable {
    private var _calls: [String] = []
    var calls: [String] { _calls }

    nonisolated func probe(path: String) -> FileProbeResult {
        _calls.append(path)
        return .notFound
    }
}

// Helpers to build entries with and without a complete baseline.
private func makeEntry(
    path: String = "/tmp/a.bin",
    withBaseline baseline: FileStat? = nil
) -> ProvenanceEntry {
    ProvenanceEntry(
        url: "https://example.com/a.bin",
        sha256: "sha256:" + String(repeating: "a", count: 64),
        size: Int(baseline?.size ?? 100),
        downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
        destinationPath: path,
        verifiedAt: nil,
        recordedStatSize: baseline.map { $0.size },
        recordedMtimeSeconds: baseline.map { $0.mtimeSeconds },
        recordedMtimeNanoseconds: baseline.map { $0.mtimeNanoseconds },
        recordedInode: baseline.map { $0.inode },
        recordedDevice: baseline.map { $0.device })
}

private let referenceBaseline = FileStat(
    size: 1_048_576,
    mtimeSeconds: 1_748_000_000,
    mtimeNanoseconds: 123_456_789,
    inode: 42_000,
    device: 1,
    isRegularFile: true)

@Suite("FastCheckRunner")
struct FastCheckRunnerTests {

    // AC1: fast-check does only lstat — no content reads.
    @Test("AC1: FastCheckRunner.checkAll issues only probe calls, no content reads")
    func noContentReads() {
        let probe = CallCountingProbe()
        let entries = [
            makeEntry(path: "/tmp/a.bin", withBaseline: referenceBaseline),
            makeEntry(path: "/tmp/b.bin", withBaseline: referenceBaseline),
        ]
        _ = FastCheckRunner.checkAll(entries, probe: probe)
        // Each entry must result in exactly one lstat call — no hash/read syscalls.
        #expect(probe.calls.count == 2)
        #expect(Set(probe.calls) == Set(["/tmp/a.bin", "/tmp/b.bin"]))
    }

    // AC2: all five fields match → .unchanged
    @Test("AC2: matching FileStat → .unchanged")
    func allFieldsMatchYieldsUnchanged() {
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(referenceBaseline))
        let status = FastCheckRunner.check(entry, probe: probe)
        #expect(status == .unchanged)
    }

    // AC3: size differs → .changed(.size)
    @Test("AC3: size mismatch → .changed(.size)")
    func sizeMismatchYieldsChangedSize() {
        let current = FileStat(
            size: referenceBaseline.size + 1,
            mtimeSeconds: referenceBaseline.mtimeSeconds,
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds,
            inode: referenceBaseline.inode,
            device: referenceBaseline.device,
            isRegularFile: true)
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        let status = FastCheckRunner.check(entry, probe: probe)
        #expect(status == .changed(.size))
    }

    // AC3: mtime seconds differ → .changed(.mtime)
    @Test("AC3: mtime seconds mismatch → .changed(.mtime)")
    func mtimeSecondsMismatch() {
        let current = FileStat(
            size: referenceBaseline.size,
            mtimeSeconds: referenceBaseline.mtimeSeconds + 1,
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds,
            inode: referenceBaseline.inode,
            device: referenceBaseline.device,
            isRegularFile: true)
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        #expect(FastCheckRunner.check(entry, probe: probe) == .changed(.mtime))
    }

    // AC3: mtime nanoseconds differ → .changed(.mtime)
    @Test("AC3: mtime nanoseconds mismatch → .changed(.mtime)")
    func mtimeNanosMismatch() {
        let current = FileStat(
            size: referenceBaseline.size,
            mtimeSeconds: referenceBaseline.mtimeSeconds,
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds + 1,
            inode: referenceBaseline.inode,
            device: referenceBaseline.device,
            isRegularFile: true)
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        #expect(FastCheckRunner.check(entry, probe: probe) == .changed(.mtime))
    }

    // AC3: inode differs → .changed(.identity)
    @Test("AC3: inode mismatch → .changed(.identity)")
    func inodeMismatch() {
        let current = FileStat(
            size: referenceBaseline.size,
            mtimeSeconds: referenceBaseline.mtimeSeconds,
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds,
            inode: referenceBaseline.inode + 1,
            device: referenceBaseline.device,
            isRegularFile: true)
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        #expect(FastCheckRunner.check(entry, probe: probe) == .changed(.identity))
    }

    // AC3: device differs → .changed(.identity)
    @Test("AC3: device mismatch → .changed(.identity)")
    func deviceMismatch() {
        let current = FileStat(
            size: referenceBaseline.size,
            mtimeSeconds: referenceBaseline.mtimeSeconds,
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds,
            inode: referenceBaseline.inode,
            device: referenceBaseline.device + 1,
            isRegularFile: true)
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        #expect(FastCheckRunner.check(entry, probe: probe) == .changed(.identity))
    }

    // AC3: precedence — identity > size > mtime.
    // inode+size both wrong → identity wins.
    @Test("AC3: identity takes precedence over size and mtime")
    func identityPrecedence() {
        let current = FileStat(
            size: referenceBaseline.size + 99,          // size wrong too
            mtimeSeconds: referenceBaseline.mtimeSeconds + 1, // mtime wrong too
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds,
            inode: referenceBaseline.inode + 1,          // identity wrong
            device: referenceBaseline.device,
            isRegularFile: true)
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        #expect(FastCheckRunner.check(entry, probe: probe) == .changed(.identity))
    }

    // AC3: size > mtime when inode/device match.
    @Test("AC3: size takes precedence over mtime when identity matches")
    func sizePrecedence() {
        let current = FileStat(
            size: referenceBaseline.size + 1,           // size wrong
            mtimeSeconds: referenceBaseline.mtimeSeconds + 1, // mtime wrong too
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds,
            inode: referenceBaseline.inode,
            device: referenceBaseline.device,
            isRegularFile: true)
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        #expect(FastCheckRunner.check(entry, probe: probe) == .changed(.size))
    }

    // AC4: probe → .notFound → .missing
    @Test("AC4: probe .notFound → .missing")
    func notFoundYieldsMissing() {
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .notFound)
        #expect(FastCheckRunner.check(entry, probe: probe) == .missing)
    }

    // AC5: probe → .unreadable → .indeterminate (NOT .missing)
    @Test("AC5: probe .unreadable → .indeterminate, not .missing")
    func unreadableYieldsIndeterminate() {
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .unreadable(EACCES))
        #expect(FastCheckRunner.check(entry, probe: probe) == .indeterminate)
    }

    // AC6: missing any baseline field → .notBaselined (never silently .unchanged)
    @Test("AC6: entry with nil recordedStatSize → .notBaselined")
    func partialBaselineIsNotBaselined_missingSize() {
        var entry = makeEntry(withBaseline: referenceBaseline)
        entry.recordedStatSize = nil   // punch out one field
        let probe = FixedProbe(result: .stat(referenceBaseline))
        #expect(FastCheckRunner.check(entry, probe: probe) == .notBaselined)
    }

    @Test("AC6: entry with nil recordedMtimeSeconds → .notBaselined")
    func partialBaselineIsNotBaselined_missingMtimeSec() {
        var entry = makeEntry(withBaseline: referenceBaseline)
        entry.recordedMtimeSeconds = nil
        let probe = FixedProbe(result: .stat(referenceBaseline))
        #expect(FastCheckRunner.check(entry, probe: probe) == .notBaselined)
    }

    @Test("AC6: entry with nil recordedMtimeNanoseconds → .notBaselined")
    func partialBaselineIsNotBaselined_missingMtimeNsec() {
        var entry = makeEntry(withBaseline: referenceBaseline)
        entry.recordedMtimeNanoseconds = nil
        let probe = FixedProbe(result: .stat(referenceBaseline))
        #expect(FastCheckRunner.check(entry, probe: probe) == .notBaselined)
    }

    @Test("AC6: entry with nil recordedInode → .notBaselined")
    func partialBaselineIsNotBaselined_missingInode() {
        var entry = makeEntry(withBaseline: referenceBaseline)
        entry.recordedInode = nil
        let probe = FixedProbe(result: .stat(referenceBaseline))
        #expect(FastCheckRunner.check(entry, probe: probe) == .notBaselined)
    }

    @Test("AC6: entry with nil recordedDevice → .notBaselined")
    func partialBaselineIsNotBaselined_missingDevice() {
        var entry = makeEntry(withBaseline: referenceBaseline)
        entry.recordedDevice = nil
        let probe = FixedProbe(result: .stat(referenceBaseline))
        #expect(FastCheckRunner.check(entry, probe: probe) == .notBaselined)
    }

    @Test("AC6: entry with ALL baseline fields nil → .notBaselined")
    func noBaselineAtAllIsNotBaselined() {
        let entry = makeEntry(withBaseline: nil)  // no baseline
        let probe = FixedProbe(result: .stat(referenceBaseline))
        #expect(FastCheckRunner.check(entry, probe: probe) == .notBaselined)
    }

    // AC7: path is not a regular file (symlink, dir, device) → .changed(.identity)
    @Test("AC7: non-regular file (isRegularFile == false) → .changed(.identity)")
    func nonRegularFileYieldsChangedIdentity() {
        let current = FileStat(
            size: referenceBaseline.size,
            mtimeSeconds: referenceBaseline.mtimeSeconds,
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds,
            inode: referenceBaseline.inode,
            device: referenceBaseline.device,
            isRegularFile: false)            // symlink or dir
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        #expect(FastCheckRunner.check(entry, probe: probe) == .changed(.identity))
    }

    // checkAll returns results in INPUT order, 1:1.
    @Test("FastCheckRunner.checkAll returns results in input order")
    func checkAllOrder() {
        let entryA = makeEntry(path: "/tmp/a.bin", withBaseline: referenceBaseline)
        let entryB = makeEntry(path: "/tmp/b.bin", withBaseline: nil)  // no baseline
        let probe = FixedProbe(result: .stat(referenceBaseline))
        let results = FastCheckRunner.checkAll([entryA, entryB], probe: probe)
        #expect(results.count == 2)
        #expect(results[0].0.destinationPath == "/tmp/a.bin")
        #expect(results[0].1 == .unchanged)
        #expect(results[1].0.destinationPath == "/tmp/b.bin")
        #expect(results[1].1 == .notBaselined)
    }
}
```

### Step 2 — Run test expecting failure

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FastCheckRunnerTests
```

Expected: compile error — `FastChangeReason`, `FastCheckStatus`, `FastCheckRunner` not found.

### Step 3 — Implementation

Create `Sources/GohCore/Provenance/FastCheck.swift`:

```swift
import Foundation

/// The reason a file's fast metadata check concluded the file has changed.
///
/// Precedence (highest to lowest): identity > size > mtime.
/// The most fundamental change is reported when multiple fields differ.
public enum FastChangeReason: Sendable, Equatable {
    /// The inode/device pair changed — the path now refers to a different object
    /// (replaced, cloned, or restored with a new inode). Also fires when the path
    /// is no longer a regular file (symlink/dir/device).
    case identity
    /// The file size changed.
    case size
    /// The modification time changed (tv_sec or tv_nsec).
    case mtime
}

/// The result of a fast metadata check for one file.
public enum FastCheckStatus: Sendable, Equatable {
    /// All five baseline fields (size, mtime, inode, device) match exactly.
    /// HEURISTIC — not a cryptographic proof. `looksUnchanged` in the presenter.
    case unchanged
    /// At least one field differs. See `FastChangeReason` for which.
    case changed(FastChangeReason)
    /// `lstat` returned `ENOENT` — the file is missing.
    case missing
    /// `lstat` failed with a non-ENOENT errno (e.g. EACCES, ELOOP, ENOTDIR).
    /// A present-but-unreadable file is never reported `.missing`.
    case indeterminate
    /// The `ProvenanceEntry` does not have a complete baseline (one or more of the
    /// five fields is nil). Fast-check cannot run — not an alert state.
    case notBaselined
}

/// Pure, probe-injectable fast-check logic. No real I/O; no `Date()`.
///
/// Thread-safe: all methods are static and pure.
public enum FastCheckRunner {

    /// Checks one entry against the current filesystem state.
    ///
    /// Comparison order (precedence high→low): incomplete baseline → notBaselined;
    /// probe result → missing/indeterminate; isRegularFile → identity;
    /// (inode, device) → identity; size → size; (mtimeSec, mtimeNsec) → mtime;
    /// else → unchanged.
    public static func check(
        _ entry: ProvenanceEntry,
        probe: any FileStatProbing
    ) -> FastCheckStatus {
        // AC6: all five fields must be non-nil for a valid baseline.
        guard
            let recordedSize   = entry.recordedStatSize,
            let mtimeSec       = entry.recordedMtimeSeconds,
            let mtimeNsec      = entry.recordedMtimeNanoseconds,
            let recordedInode  = entry.recordedInode,
            let recordedDevice = entry.recordedDevice
        else {
            return .notBaselined
        }

        switch probe.probe(path: entry.destinationPath) {
        case .notFound:
            return .missing                    // AC4

        case .unreadable:
            return .indeterminate              // AC5

        case .stat(let current):
            // AC7: non-regular file → identity change.
            guard current.isRegularFile else {
                return .changed(.identity)
            }
            // AC3 precedence: identity > size > mtime.
            if current.inode != recordedInode || current.device != recordedDevice {
                return .changed(.identity)
            }
            if current.size != recordedSize {
                return .changed(.size)
            }
            if current.mtimeSeconds != mtimeSec || current.mtimeNanoseconds != mtimeNsec {
                return .changed(.mtime)
            }
            return .unchanged                  // AC2
        }
    }

    /// Checks all entries, returning results in INPUT order, 1:1.
    ///
    /// Each entry generates exactly one `probe.probe(path:)` call — no content reads.
    public static func checkAll(
        _ entries: [ProvenanceEntry],
        probe: any FileStatProbing
    ) -> [(ProvenanceEntry, FastCheckStatus)] {
        entries.map { entry in (entry, check(entry, probe: probe)) }
    }
}
```

### Step 4 — Run test expecting pass

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FastCheckRunnerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohCoreTests
```

Expected: all FastCheckRunnerTests pass. Full GohCoreTests suite stays green.

### Step 5 — Commit

```
git add Sources/GohCore/Provenance/FastCheck.swift \
        Tests/GohCoreTests/FastCheckRunnerTests.swift
git commit -m "feat(provenance): add FastChangeReason, FastCheckStatus, FastCheckRunner (AC1-AC3, AC6-AC7)"
```

**Phase 1 complete. Write phase artifact:**
`docs/superpowers/progress/2026-06-08-tiered-rapid-trust-phase1.md`
Content: confirm all Phase 1 tests pass, golden fixture still round-trips, governor block untouched.

---

# Phase 2 — Capture Path

**Gated on Phase 1.** Adds `DownloadFile.fileStat()`, widens the completion seam, and routes
the baseline into the daemon's `ProvenanceEntry` construction.

THE BET CHECK (Phase 2): After all Phase 2 changes, run `swift test --filter GohCoreTests`.
The complete engine test suite AND the existing golden provenance tests must stay green.
The governor sampling block in `fetchRanged` must be byte-for-byte unchanged.

---

## Task 2.1 — `DownloadFile.fileStat()` + test

**Files:**
- Modify: `Sources/GohCore/Engine/DownloadFile.swift`
- Modify: `Tests/GohCoreTests/DownloadFileTests.swift`

**Pre-task reads:**
- [x] `Sources/GohCore/Engine/DownloadFile.swift` — read in Phase 0.
  - `private let descriptor: Int32` at line 43.
  - `finish()` at lines 111–120: `fsync` + `close(descriptor)`.
  - `finish()` sets `closed = true` before calling `close`. The file descriptor is valid
    until after `close(descriptor)` executes inside `finish()`.
  - `fileStat()` must be called **before** `file.finish()` at all three capture sites.

### Step 1 — Write failing test

Find the existing `@Suite("DownloadFile")` in `Tests/GohCoreTests/DownloadFileTests.swift`
and add inside it:

```swift
// fileStat() returns a FileStat with correct size for a written file.
@Test("fileStat() returns accurate size and isRegularFile for a written file")
func fileStatReturnsAccurateSize() throws {
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
    let path = tmpDir.appendingPathComponent("goh-fileStat-test-\(UUID().uuidString).bin").path
    defer { try? FileManager.default.removeItem(atPath: path) }

    let file = try DownloadFile(path: path, expectedSize: nil)
    let payload = Data(repeating: 0xAB, count: 1024)
    try file.write(payload, at: 0)

    let stat = try file.fileStat()
    #expect(stat.size == 1024)
    #expect(stat.isRegularFile == true)
    #expect(stat.inode > 0)
    #expect(stat.device != 0)

    try file.finish()
}
```

### Step 2 — Run test expecting failure

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadFileTests/fileStatReturnsAccurateSize
```

Expected: compile error — `fileStat()` not found on `DownloadFile`.

### Step 3 — Implementation

Add to `Sources/GohCore/Engine/DownloadFile.swift`, after the `sync()` method and before
`finish()`:

```swift
/// Captures the current file metadata via `fstat(2)` on the open descriptor.
///
/// Call this BEFORE `finish()` — the descriptor is closed inside `finish()`.
/// Maps `struct stat` fields to `FileStat` exactly as `LiveFileStatProbe.probe` does.
///
/// - Throws: `DownloadFileError.syncFailed(errno:)` on `fstat` failure.
///   This should never happen on a successfully opened, written file. The caller
///   should use `try? file.fileStat()` so a should-never-happen failure leaves the
///   baseline nil (→ `.notBaselined`), never blocking the download.
public func fileStat() throws -> FileStat {
    var st = stat()
    guard Darwin.fstat(descriptor, &st) == 0 else {
        throw DownloadFileError.syncFailed(errno: errno)
    }
    return FileStat(
        size: Int64(st.st_size),
        mtimeSeconds: Int64(st.st_mtimespec.tv_sec),
        mtimeNanoseconds: Int64(st.st_mtimespec.tv_nsec),
        inode: UInt64(st.st_ino),
        device: Int64(st.st_dev),
        isRegularFile: (st.st_mode & S_IFMT) == S_IFREG)
}
```

Note: `import Darwin` is already present at the top of `DownloadFile.swift`.

### Step 4 — Run test expecting pass

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadFileTests
```

### Step 5 — Commit

```
git add Sources/GohCore/Engine/DownloadFile.swift \
        Tests/GohCoreTests/DownloadFileTests.swift
git commit -m "feat(engine): add DownloadFile.fileStat() for fstat baseline capture"
```

---

## Task 2.2 — Widen `complete()` + `completedDownloadHandler` + three capture sites

**Files:**
- Modify: `Sources/GohCore/Engine/DownloadEngine.swift`

**Pre-task reads (exact locations from Phase 0):**

- [x] **`completedDownloadHandler` type** — line 100:
  ```swift
  private let completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome) -> Void)?
  ```
- [x] **`init` parameter** — line 112:
  ```swift
  completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome) -> Void)? = nil,
  ```
- [x] **`complete()` method** — lines 914–922:
  ```swift
  private func complete(
      jobID: UInt64, in store: JobStore,
      transferDuration: Duration, isResume: Bool,
      sha256: String?,
      governorOutcome: GovernorOutcome = .governorOff
  ) throws {
      let completed = try store.complete(id: jobID)
      completedDownloadHandler?(completed, transferDuration, isResume, sha256, governorOutcome)
  }
  ```
- [x] **Single/fetchSingle capture site** — lines 559–572. The digest extraction happens at
  ~L559, `try file.finish()` at L564. The `complete(...)` call is at lines 569–572.
  Capture site: between assembler-outcome extraction and `file.finish()`.
- [x] **Ranged/fetchRanged capture site** — lines 888–911. Digest extraction ~L895, 
  `try file.finish()` at L900, `complete(...)` call at lines 906–910.
  Capture site: between digest extraction and `file.finish()`.
- [x] **Resume capture site** — lines 392–407. `verifyHash` at L393, `try file.finish()` 
  at L394. `complete(...)` at lines 403–406.
  Capture site: between `verifyHash` and `file.finish()`.
- [x] **Governor block** — lines 831–858. MUST NOT be touched.

**CRITICAL: Do NOT touch the governor sampling block (lines 831–858). Only touch the
three `complete(...)` call sites and the handler/`complete` method signatures.**

### Step 1 — No failing test needed for signature change

The existing engine tests will validate the widen compiles correctly. The daemon in Task 2.3
consumes the new parameter; a compile error there is the "test."

### Step 2 — Skip (signature change; compile is the test gate)

### Step 3 — Implementation

Four edits to `Sources/GohCore/Engine/DownloadEngine.swift`:

**Edit A — widen the stored property type (line 100):**

```swift
// OLD:
private let completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome) -> Void)?

// NEW:
private let completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome, FileStat?) -> Void)?
```

**Edit B — widen the init parameter (line 112):**

```swift
// OLD:
completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome) -> Void)? = nil,

// NEW:
completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome, FileStat?) -> Void)? = nil,
```

**Edit C — widen `complete()` method and its invocation (lines 914–922):**

```swift
// OLD:
private func complete(
    jobID: UInt64, in store: JobStore,
    transferDuration: Duration, isResume: Bool,
    sha256: String?,
    governorOutcome: GovernorOutcome = .governorOff
) throws {
    let completed = try store.complete(id: jobID)
    completedDownloadHandler?(completed, transferDuration, isResume, sha256, governorOutcome)
}

// NEW:
private func complete(
    jobID: UInt64, in store: JobStore,
    transferDuration: Duration, isResume: Bool,
    sha256: String?,
    governorOutcome: GovernorOutcome = .governorOff,
    fileStat: FileStat? = nil
) throws {
    let completed = try store.complete(id: jobID)
    completedDownloadHandler?(completed, transferDuration, isResume, sha256, governorOutcome, fileStat)
}
```

**Edit D — three capture sites:**

*Site 1: fetchSingle (~L559–572)*
Locate the block:
```swift
        // assemblerOutcome is .digest(hex) — extract the hex for provenance recording.
        let fetchSingleDigest: String?
        if case .digest(let hex) = assemblerOutcome {
            fetchSingleDigest = hex
        } else {
            fatalError("unreachable: ChunkAssemblerResult has only .digest/.failed")
        }
        try file.finish()
```
Change to:
```swift
        // assemblerOutcome is .digest(hex) — extract the hex for provenance recording.
        let fetchSingleDigest: String?
        if case .digest(let hex) = assemblerOutcome {
            fetchSingleDigest = hex
        } else {
            fatalError("unreachable: ChunkAssemblerResult has only .digest/.failed")
        }
        // Capture stat baseline before finish() closes the fd. try? so a
        // should-never-happen fstat failure leaves baseline nil (→ .notBaselined).
        let fetchSingleFileStat = try? file.fileStat()
        try file.finish()
```
Then update the `complete(...)` call from:
```swift
        try complete(
            jobID: job.id, in: store,
            transferDuration: clock.now - started, isResume: false,
            sha256: fetchSingleDigest)
```
To:
```swift
        try complete(
            jobID: job.id, in: store,
            transferDuration: clock.now - started, isResume: false,
            sha256: fetchSingleDigest,
            fileStat: fetchSingleFileStat)
```

*Site 2: fetchRanged (~L894–910)*
Locate:
```swift
        let fetchRangedDigest: String?
        if case .digest(let hex) = rangedOutcome {
            fetchRangedDigest = hex
        } else {
            fatalError("unreachable: ChunkAssemblerResult has only .digest/.failed")
        }
        try file.finish()
```
Change to:
```swift
        let fetchRangedDigest: String?
        if case .digest(let hex) = rangedOutcome {
            fetchRangedDigest = hex
        } else {
            fatalError("unreachable: ChunkAssemblerResult has only .digest/.failed")
        }
        // Capture stat baseline before finish() closes the fd.
        let fetchRangedFileStat = try? file.fileStat()
        try file.finish()
```
Then update the `complete(...)` call:
```swift
        let governorOutcome = governorEnabled ? governor.outcome : .governorOff
        try complete(
            jobID: job.id, in: store,
            transferDuration: clock.now - started, isResume: false,
            sha256: fetchRangedDigest,
            governorOutcome: governorOutcome,
            fileStat: fetchRangedFileStat)
```

*Site 3: resume (~L392–407)*

`resumeFileStat` must be declared BEFORE the `do` block so it is in scope at the
`complete(...)` call site after the block. Declare as `var ... = nil`, then assign inside
the `do` before `file.finish()`.

Locate the existing `var resumeDigest: String` declaration and the `do { ... } catch { ... }`
block that contains `verifyHash` + `file.finish()`. Change to:

```swift
        var resumeDigest: String
        var resumeFileStat: FileStat? = nil   // declared before do — in scope at complete(...)
        do {
            for range in missingRanges { ... }
            resumeDigest = try await verifyHash(file: file, total: total)
            // Capture stat baseline before finish() closes the fd. try? so a
            // should-never-happen fstat failure leaves baseline nil (→ .notBaselined).
            resumeFileStat = try? file.fileStat()
            try file.finish()
        } catch {
            try? file.finish()
            throw error
        }
```

Update the `complete(...)` call after the `do/catch` block:
```swift
        try complete(
            jobID: job.id, in: store,
            transferDuration: clock.now - started, isResume: true,
            sha256: resumeDigest,
            fileStat: resumeFileStat)
```

### Step 4 — Build and run full engine test suite

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadEngineTests
```

Expected: clean build; all DownloadEngineTests pass. Governor block bytes unchanged.

### Step 5 — Commit

```
git add Sources/GohCore/Engine/DownloadEngine.swift
git commit -m "feat(engine): widen completedDownloadHandler with trailing FileStat? for stat baseline"
```

---

## Task 2.3 — Daemon routes `FileStat?` → `ProvenanceEntry` baseline fields

**Files:**
- Modify: `Sources/gohd/main.swift`

**Pre-task reads:**
- [x] `Sources/gohd/main.swift` — read in Phase 0. The `completedDownloadHandler` closure
  starts at line 139. The `ProvenanceEntry(...)` construction is at lines 172–181.
  Current closure signature (line 139):
  ```swift
  completedDownloadHandler: { completed, transferDuration, isResume, sha256, governorOutcome in
  ```
  The `ProvenanceEntry` init call is at lines 172–181 — the new baseline parameters go
  at the end of that init call.

### Step 1 — No separate failing test (daemon compiles against the widened handler)

The Phase 2.2 widen causes a compile error here until the handler signature is updated.
That compile error is the "test."

### Step 2 — Skip

### Step 3 — Implementation

Two edits to `Sources/gohd/main.swift`:

**Edit A — update the handler closure signature (line 139):**

```swift
// OLD:
        completedDownloadHandler: { completed, transferDuration, isResume, sha256, governorOutcome in

// NEW:
        completedDownloadHandler: { completed, transferDuration, isResume, sha256, governorOutcome, completedFileStat in
```

**Edit B — populate baseline fields in the `ProvenanceEntry` construction (~line 172):**

```swift
// OLD:
                    try provenanceStore.record(
                        entry: ProvenanceEntry(
                            url: completed.url,
                            sha256: "sha256:" + sha256,
                            size: Int(completed.progress.bytesCompleted),
                            downloadedAt: completed.completedAt ?? Date(),
                            destinationPath: URL(fileURLWithPath: completed.destination)
                                .standardizedFileURL.path))

// NEW:
                    try provenanceStore.record(
                        entry: ProvenanceEntry(
                            url: completed.url,
                            sha256: "sha256:" + sha256,
                            size: Int(completed.progress.bytesCompleted),
                            downloadedAt: completed.completedAt ?? Date(),
                            destinationPath: URL(fileURLWithPath: completed.destination)
                                .standardizedFileURL.path,
                            recordedStatSize: completedFileStat.map { Int64($0.size) },
                            recordedMtimeSeconds: completedFileStat.map { $0.mtimeSeconds },
                            recordedMtimeNanoseconds: completedFileStat.map { $0.mtimeNanoseconds },
                            recordedInode: completedFileStat.map { $0.inode },
                            recordedDevice: completedFileStat.map { $0.device }))
```

Note: `completedFileStat?.size` is already `Int64`; the `map` pattern handles the
nil-propagation cleanly and keeps each field consistent (all five nil or all five non-nil).

### Step 4 — Build and run full suite

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: clean build; full test suite green. No changes to governor block.

### Step 5 — Commit

```
git add Sources/gohd/main.swift
git commit -m "feat(daemon): route FileStat baseline from engine finalization into ProvenanceEntry"
```

**Phase 2 complete. Write phase artifact:**
`docs/superpowers/progress/2026-06-08-tiered-rapid-trust-phase2.md`
Content: confirm build clean, all tests green, governor block byte-unchanged (copy the
block verbatim and note it is unmodified), daemon routing verified.

---

# Phase 3 — Surfaces

**Gated on Phase 1 and Phase 2.** CLI `--quick` flag, GohMenuBar trust display,
Trust window fast-check on open, `LiveFileStatProbe` wired in goh-menu.

THE BET CHECK (Phase 3): AC8 test asserts that
`TrustDisplayStatus.looksUnchanged` and `TrustDisplayStatus.verified(at:)` produce
different labels AND different system image names. The test must fail if these are ever
made equal.

---

## Task 3.1 — `TrustDisplayStatus` + AC8 presenter token-distinctness test

**Files:**
- Modify: `Sources/GohMenuBar/GohTrustModels.swift`
- Modify: `Tests/GohMenuBarTests/GohTrustPresenterTests.swift`

**Pre-task reads:**
- [x] `Sources/GohMenuBar/GohTrustModels.swift` — read in Phase 0. Defines `GohTrustSummary`,
  `GohTrustOverview`, `GohTrustEntryRow` (6 stored props + init), and `ProvenanceReading`
  protocol. `GohTrustEntryRow` is `nonisolated public struct`.
- [x] `Tests/GohMenuBarTests/GohTrustPresenterTests.swift` — read in Phase 0. `@Suite("GohTrustPresenter")` with AC1/AC2/AC5 tests. Uses `makeEntry(path:url:verifiedAt:)` helper.

**AC ownership:** AC8

### Step 1 — Write failing test

Add to `Tests/GohMenuBarTests/GohTrustPresenterTests.swift` (inside `@Suite("GohTrustPresenter")`):

```swift
    // AC8: .looksUnchanged and .verified(at:) must be DISTINCT display tokens.
    // This test asserts the model layer enforces non-collapsibility — a future
    // UI change cannot accidentally present a heuristic result as a cryptographic proof.
    @Test("AC8: TrustDisplayStatus.looksUnchanged and .verified(at:) have distinct label and icon")
    func looksUnchangedAndVerifiedAreDistinctTokens() {
        let verifiedDate = Date(timeIntervalSince1970: 1_748_000_000)

        let verifiedToken = TrustDisplayStatus.verified(at: verifiedDate)
        let looksUnchangedToken = TrustDisplayStatus.looksUnchanged

        // The two cases must not be equal (enforces model-layer distinctness).
        #expect(verifiedToken != looksUnchangedToken)

        // Their labels must be different strings.
        #expect(verifiedToken.label != looksUnchangedToken.label)

        // Their system image names must be different strings.
        #expect(verifiedToken.systemImage != looksUnchangedToken.systemImage)

        // Sanity: looksUnchanged label must mention "looks" or "unchanged" to
        // communicate the heuristic limitation.
        let label = looksUnchangedToken.label.lowercased()
        #expect(label.contains("looks") || label.contains("unchanged"),
            "looksUnchanged label must communicate the heuristic limitation")

        // Sanity: verified label must mention "verified" or the date.
        let verifiedLabel = verifiedToken.label.lowercased()
        #expect(verifiedLabel.contains("verif"),
            "verified label must communicate the cryptographic claim")
    }
```

### Step 2 — Run test expecting failure

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohTrustPresenterTests/looksUnchangedAndVerifiedAreDistinctTokens
```

Expected: compile error — `TrustDisplayStatus` not found.

### Step 3 — Implementation

**Edit `Sources/GohMenuBar/GohTrustModels.swift`** — add `TrustDisplayStatus` after
the `ProvenanceReading` protocol:

```swift
/// The display status of one provenance entry in the Trust window.
///
/// Safety invariant (AC8): `.looksUnchanged` and `.verified(at:)` MUST be
/// distinct cases — a heuristic result must never read as a cryptographic proof.
/// This is enforced at the model layer, not just in copy or UI layout.
nonisolated public enum TrustDisplayStatus: Sendable, Equatable {
    /// Deep re-hash confirmed the bytes match the recorded SHA-256.
    /// The cryptographic integrity claim.
    case verified(at: Date)

    /// All five stat fields (size, mtime, inode, device) match the baseline.
    /// HEURISTIC ONLY — not a proof; cannot detect silent bit-rot or a tamper
    /// that preserves size and timestamp. Label must communicate this limitation.
    case looksUnchanged

    /// At least one stat field differs. The file likely changed.
    case changed(FastChangeReason)

    /// The file is missing from disk.
    case missing

    /// `lstat` failed — file present but unreadable (EACCES, ELOOP, etc.).
    case indeterminate

    /// No baseline recorded — pre-feature entry or baseline capture failed.
    /// Neutral/informational; not an alert state.
    case notBaselined

    /// No fast-check run yet and `verifiedAt == nil` (downloaded, never verified
    /// or fast-checked this session).
    case recordedOnly

    /// A human-readable label for the Trust window row chip.
    /// The `looksUnchanged` label MUST communicate the heuristic limitation.
    public var label: String {
        switch self {
        case .verified(let date):
            return "verified \(date.formatted(date: .abbreviated, time: .omitted))"
        case .looksUnchanged:
            return "looks unchanged"
        case .changed(let reason):
            switch reason {
            case .identity: return "changed (replaced)"
            case .size:     return "changed (size)"
            case .mtime:    return "changed (modified)"
            }
        case .missing:
            return "missing"
        case .indeterminate:
            return "unreadable"
        case .notBaselined:
            return "no baseline"
        case .recordedOnly:
            return "downloaded"
        }
    }

    /// SF Symbol name for the Trust window row chip icon.
    public var systemImage: String {
        switch self {
        case .verified:
            return "checkmark.shield.fill"
        case .looksUnchanged:
            return "checkmark.circle"
        case .changed:
            return "exclamationmark.triangle.fill"
        case .missing:
            return "questionmark.circle.fill"
        case .indeterminate:
            return "lock.slash"
        case .notBaselined:
            return "minus.circle"
        case .recordedOnly:
            return "arrow.down.circle"
        }
    }
}
```

### Step 4 — Run test expecting pass

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohTrustPresenterTests
```

Expected: all GohTrustPresenterTests pass including the new AC8 token-distinctness test.

### Step 5 — Commit

```
git add Sources/GohMenuBar/GohTrustModels.swift \
        Tests/GohMenuBarTests/GohTrustPresenterTests.swift
git commit -m "feat(tray): add TrustDisplayStatus with distinct looksUnchanged vs verified tokens (AC8)"
```

---

## Task 3.2 — Presenter `displayStatus(entry:fastStatus:)` + `displayStatus(verifiedAt:fastStatus:)` convenience overload

**Files:**
- Modify: `Sources/GohMenuBar/GohTrustPresenter.swift`
- Modify: `Tests/GohMenuBarTests/GohTrustPresenterTests.swift`

**Pre-task reads:**
- [x] `Sources/GohMenuBar/GohTrustPresenter.swift` — read in Phase 0. `GohTrustPresenter`
  is a `nonisolated public struct`. `present(_:)` takes `ProvenanceReadOutcome` and returns
  `(GohTrustOverview, [GohTrustEntryRow])`. `makeRow(_:)` maps `ProvenanceEntry` →
  `GohTrustEntryRow`.

### Step 1 — Write failing tests

Add to `Tests/GohMenuBarTests/GohTrustPresenterTests.swift`:

```swift
    // displayStatus: verifiedAt + .unchanged fast → .verified(at:)
    @Test("displayStatus: verifiedAt non-nil → .verified(at:) regardless of fast status")
    func displayStatusVerifiedAtWins() {
        let verifiedDate = Date(timeIntervalSince1970: 2_000_000)
        let entry = makeEntry(path: "/a.bin", verifiedAt: verifiedDate)
        let status = GohTrustPresenter.displayStatus(entry: entry, fastStatus: .unchanged)
        guard case .verified(let at) = status else {
            Issue.record("Expected .verified, got \(status)")
            return
        }
        #expect(at == verifiedDate)
    }

    // displayStatus: no verifiedAt, fast .unchanged → .looksUnchanged
    @Test("displayStatus: no verifiedAt + fast .unchanged → .looksUnchanged")
    func displayStatusLooksUnchanged() {
        let entry = makeEntry(path: "/a.bin", verifiedAt: nil)
        let status = GohTrustPresenter.displayStatus(entry: entry, fastStatus: .unchanged)
        #expect(status == .looksUnchanged)
    }

    // displayStatus: no verifiedAt, fast .changed → .changed
    @Test("displayStatus: no verifiedAt + fast .changed(.size) → .changed(.size)")
    func displayStatusChanged() {
        let entry = makeEntry(path: "/a.bin", verifiedAt: nil)
        let status = GohTrustPresenter.displayStatus(entry: entry, fastStatus: .changed(.size))
        #expect(status == .changed(.size))
    }

    // displayStatus: no verifiedAt, fast .missing → .missing
    @Test("displayStatus: no verifiedAt + fast .missing → .missing")
    func displayStatusMissing() {
        let entry = makeEntry(path: "/a.bin", verifiedAt: nil)
        let status = GohTrustPresenter.displayStatus(entry: entry, fastStatus: .missing)
        #expect(status == .missing)
    }

    // displayStatus: no verifiedAt, fast .notBaselined → .notBaselined
    @Test("displayStatus: no verifiedAt + fast .notBaselined → .notBaselined")
    func displayStatusNotBaselined() {
        let entry = makeEntry(path: "/a.bin", verifiedAt: nil)
        let status = GohTrustPresenter.displayStatus(entry: entry, fastStatus: .notBaselined)
        #expect(status == .notBaselined)
    }

    // displayStatus: no verifiedAt, nil fast status → .recordedOnly
    @Test("displayStatus: no verifiedAt + nil fast status → .recordedOnly")
    func displayStatusRecordedOnly() {
        let entry = makeEntry(path: "/a.bin", verifiedAt: nil)
        let status = GohTrustPresenter.displayStatus(entry: entry, fastStatus: nil)
        #expect(status == .recordedOnly)
    }
```

### Step 2 — Run test expecting failure

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohTrustPresenterTests
```

Expected: compile error — `GohTrustPresenter.displayStatus(entry:fastStatus:)` not found.

### Step 3 — Implementation

Modify `Sources/GohMenuBar/GohTrustPresenter.swift`:

```swift
import Foundation
import GohCore

/// Pure presenter: `ProvenanceReadOutcome` → `(GohTrustOverview, [GohTrustEntryRow])`.
///
/// No disk access, no framework, no Swift concurrency — unit-testable with stubs.
/// Entry order is preserved (ledger order). URLs are sanitized via `URLDisplay.sanitized`.
nonisolated public struct GohTrustPresenter: Sendable {

    public init() {}

    /// Maps a ledger read outcome to the overview and per-file rows for display.
    ///
    /// - `.absent` / `.entries([])` → `.empty`, `[]`
    /// - `.entries(n)` → `.summary(GohTrustSummary)`, `[GohTrustEntryRow]` in ledger order
    /// - `.unreadable(_)` → `.unavailable`, `[]` (all three reasons collapse to unavailable)
    public func present(_ outcome: ProvenanceReadOutcome) -> (GohTrustOverview, [GohTrustEntryRow]) {
        switch outcome {
        case .absent:
            return (.empty, [])

        case .entries(let entries) where entries.isEmpty:
            return (.empty, [])

        case .entries(let entries):
            let verified = entries.filter { $0.verifiedAt != nil }.count
            let downloadOnly = entries.count - verified
            let summary = GohTrustSummary(
                tracked: entries.count,
                verified: verified,
                downloadOnly: downloadOnly)
            let rows = entries.map(makeRow(_:))
            return (.summary(summary), rows)

        case .unreadable:
            return (.unavailable, [])
        }
    }

    /// Maps a single `ProvenanceEntry` and its optional fast-check result to a
    /// `TrustDisplayStatus` for rendering.
    ///
    /// Mapping:
    /// - `entry.verifiedAt` non-nil → `.verified(at:)` (deep proof wins)
    /// - fast `.unchanged` → `.looksUnchanged`
    /// - fast `.changed(r)` → `.changed(r)`
    /// - fast `.missing` → `.missing`
    /// - fast `.indeterminate` → `.indeterminate`
    /// - fast `.notBaselined` → `.notBaselined`
    /// - `fastStatus == nil` and `verifiedAt == nil` → `.recordedOnly`
    public static func displayStatus(
        entry: ProvenanceEntry,
        fastStatus: FastCheckStatus?
    ) -> TrustDisplayStatus {
        if let verifiedAt = entry.verifiedAt {
            return .verified(at: verifiedAt)
        }
        guard let fast = fastStatus else {
            return .recordedOnly
        }
        switch fast {
        case .unchanged:    return .looksUnchanged
        case .changed(let r): return .changed(r)
        case .missing:      return .missing
        case .indeterminate: return .indeterminate
        case .notBaselined: return .notBaselined
        }
    }

    /// Convenience overload for call sites that already have `verifiedAt: Date?`
    /// (e.g. `TrustWindowView` which reads from `GohTrustEntryRow.verifiedAt`
    /// without needing to reconstruct a full `ProvenanceEntry`).
    public static func displayStatus(
        verifiedAt: Date?,
        fastStatus: FastCheckStatus?
    ) -> TrustDisplayStatus {
        if let verifiedAt { return .verified(at: verifiedAt) }
        guard let fast = fastStatus else { return .recordedOnly }
        switch fast {
        case .unchanged:    return .looksUnchanged
        case .changed(let r): return .changed(r)
        case .missing:      return .missing
        case .indeterminate: return .indeterminate
        case .notBaselined: return .notBaselined
        }
    }

    // MARK: - Private

    private func makeRow(_ entry: ProvenanceEntry) -> GohTrustEntryRow {
        GohTrustEntryRow(
            displayPath: entry.destinationPath,
            sanitizedURL: URLDisplay.sanitized(entry.url),
            sha256: entry.sha256,
            downloadedAt: entry.downloadedAt,
            verifiedAt: entry.verifiedAt)
    }
}
```

### Step 4 — Run test expecting pass

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohTrustPresenterTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohMenuBarTests
```

### Step 5 — Commit

```
git add Sources/GohMenuBar/GohTrustPresenter.swift \
        Tests/GohMenuBarTests/GohTrustPresenterTests.swift
git commit -m "feat(tray): add GohTrustPresenter.displayStatus() mapping entry+FastCheckStatus→TrustDisplayStatus"
```

---

## Task 3.3 — `TrustWindowViewModel` runs fast-check on `loadOverview()`

**Files:**
- Modify: `Sources/GohMenuBar/TrustWindowViewModel.swift`

**Pre-task reads:**
- [x] `Sources/GohMenuBar/TrustWindowViewModel.swift` — read in Phase 0.
  - `@MainActor final class TrustWindowViewModel` with `@Published var rows: [GohTrustEntryRow]`.
  - `loadOverview()` is `async`, dispatches reader off-main via `Task.detached`, sets
    `overview` and `rows`.
  - `private let presenter: GohTrustPresenter`.
  - No existing `fastStatuses` storage.

The fast-check is synchronous (pure `lstat` + comparison). Run it off-main immediately after
`loadOverview()` reads the ledger, using the injected probe. Publish the per-path statuses
as `[String: FastCheckStatus]` keyed by `destinationPath`.

**No separate failing test for this task** — the wiring is verified by Task 3.4's view test.
Add a targeted unit test checking that `fastStatuses` populates after `loadOverview()`:

```swift
// In GohMenuBarTests — add to GohTrustPresenterTests or a new file.
// Tests that after loadOverview(), fastStatuses is populated for baselined entries.
// (Integration test via stub reader + stub probe — no real files.)
```

This is the only wiring-level test needed; AC coverage for the statuses themselves is in
Task 1.3. Keep this test simple.

### Step 3 — Implementation

Key changes to `TrustWindowViewModel.swift`:

```swift
// Add after existing imports:
import GohCore

// Add stored properties to TrustWindowViewModel:
/// Injected probe for fast-check calls. `LiveFileStatProbe` in production;
/// a stub in tests.
private let probe: any FileStatProbing

/// Fast-check statuses keyed by `destinationPath`. Populated immediately
/// after `loadOverview()` reads the ledger — before the view re-renders.
@Published public private(set) var fastStatuses: [String: FastCheckStatus] = [:]

// Update init to accept probe injection:
public init(
    reader: any ProvenanceReading,
    provenanceStorePath: String,
    presenter: GohTrustPresenter = GohTrustPresenter(),
    probe: any FileStatProbing = LiveFileStatProbe()
) {
    self.reader = reader
    self.provenanceStorePath = provenanceStorePath
    self.presenter = presenter
    self.probe = probe
}

// Update loadOverview() to run fast-check off-main after reading:
public func loadOverview() async {
    let capturedProbe = probe
    let (outcome, statuses) = await Task.detached(priority: .userInitiated) { [reader] in
        let outcome = reader.read()
        // Run the fast-check synchronously off-main with the injected probe.
        let entries: [ProvenanceEntry]
        if case .entries(let e) = outcome { entries = e } else { entries = [] }
        let fastResults = FastCheckRunner.checkAll(entries, probe: capturedProbe)
        let statuses = Dictionary(uniqueKeysWithValues: fastResults.map {
            ($0.destinationPath, $1)
        })
        return (outcome, statuses)
    }.value
    let (ov, rs) = presenter.present(outcome)
    overview = ov
    rows = rs
    fastStatuses = statuses
}
```

Note: `FastCheckRunner.checkAll` is pure and `Sendable`-safe inside the detached task.
The `probe` captured by `capturedProbe` is `any FileStatProbing: Sendable`.

### Step 5 — Commit

```
git add Sources/GohMenuBar/TrustWindowViewModel.swift
git commit -m "feat(tray): run fast-check on Trust window open; publish fastStatuses per entry"
```

---

## Task 3.4 — `TrustWindowView` renders `TrustDisplayStatus` per row

**Files:**
- Modify: `Sources/GohMenuBar/TrustWindowView.swift`

**Pre-task reads (done in Phase 0 — real shapes recorded here):**

`TrustWindowView.swift` real state after Tasks 3.1–3.3:
- `private func liveResult(for row: GohTrustEntryRow) -> VerifyStatus?` — looks up the
  post-verify result from `viewModel.runState` (`.finished`/`.cancelled` report).
- `private struct TrustEntryRowView: View` — takes `row: GohTrustEntryRow` and
  `liveResult: VerifyStatus?`.
- `atRestStatusChip` renders `row.verifiedAt` as "verified <date>" or "downloaded".
- The `entryList` ForEach passes `TrustEntryRowView(row: row, liveResult: liveResult(for: row))`.

After Task 3.3, `TrustWindowViewModel` has:
- `@Published public private(set) var fastStatuses: [String: FastCheckStatus]` — keyed
  by `destinationPath`, populated by `FastCheckRunner.checkAll(entries, probe: probe)` inside
  `loadOverview()`.

After Task 3.2, `GohTrustPresenter` has:
- `static func displayStatus(verifiedAt: Date?, fastStatus: FastCheckStatus?) -> TrustDisplayStatus`
  (the `verifiedAt:`-overload added at the end of Task 3.2's implementation).

**Goal:** Thread `displayStatus: TrustDisplayStatus` into `TrustEntryRowView`, computed
per-row in the parent from the ViewModel's `fastStatuses`. Replace `atRestStatusChip`
with a chip driven by `TrustDisplayStatus`. Keep `liveStatusChip` (post-verify) separate.

**Note on testability:** `TrustEntryRowView` is a private SwiftUI view — it cannot be
unit-tested directly. The correctness of the `displayStatus` mapping is covered by the
presenter tests in Task 3.2 and the AC8 token-distinctness test in Task 3.1. This task
has no additional unit tests; the compile gate and a manual smoke-check (Trust window opens,
shows "looks unchanged" chip in teal, not "verified") are the verification.

### Step 1 — No separate failing test

The compile gate is the test: adding `displayStatus:` to `TrustEntryRowView.init` will cause
a compile error at the ForEach call site until the parent is updated. See Step 3.

### Step 2 — Skip

### Step 3 — Implementation

**Edit A: add the `displayStatus:` parameter to `TrustEntryRowView`.**

Locate `private struct TrustEntryRowView: View` and change its stored properties and `body`:

```swift
// OLD stored properties:
private struct TrustEntryRowView: View {
    let row: GohTrustEntryRow
    let liveResult: VerifyStatus?

// NEW:
private struct TrustEntryRowView: View {
    let row: GohTrustEntryRow
    let liveResult: VerifyStatus?
    let displayStatus: TrustDisplayStatus   // fast-check or at-rest status (Task 3.1)
```

**Edit B: replace `atRestStatusChip` with `displayStatusChip(_:)`.**

Remove the existing `atRestStatusChip` computed property. Add in its place:

```swift
/// Fast-check / at-rest status chip. Visually distinct from `liveStatusChip`.
/// `looksUnchanged` uses teal (heuristic); `verified` uses green (cryptographic proof).
@ViewBuilder
private func displayStatusChip(_ status: TrustDisplayStatus) -> some View {
    let (label, bg, fg): (String, Color, Color) = switch status {
    case .verified:
        (status.label, Color.green.opacity(0.15), Color.green)
    case .looksUnchanged:
        (status.label, Color.teal.opacity(0.12), Color.teal)
    case .changed:
        (status.label, Color.orange.opacity(0.15), Color.orange)
    case .missing:
        (status.label, Color.red.opacity(0.12), Color.red)
    case .indeterminate:
        (status.label, Color.orange.opacity(0.10), Color.orange)
    case .notBaselined:
        (status.label, Color.secondary.opacity(0.1), Color.secondary)
    case .recordedOnly:
        (status.label, Color.secondary.opacity(0.1), Color.secondary)
    }
    Text(label)
        .font(.caption2)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(bg)
        .cornerRadius(4)
        .foregroundStyle(fg)
}
```

In `body`, replace `atRestStatusChip` with `displayStatusChip(displayStatus)`:

```swift
// OLD in body HStack:
                atRestStatusChip
                if let live = liveResult {
                    liveStatusChip(live)
                }

// NEW:
                displayStatusChip(displayStatus)
                if let live = liveResult {
                    liveStatusChip(live)
                }
```

**Edit C: update `entryList` in `TrustWindowView` to pass `displayStatus`.**

Locate the `ForEach` in `entryList`:

```swift
// OLD:
                    ForEach(viewModel.rows, id: \.displayPath) { row in
                        TrustEntryRowView(row: row, liveResult: liveResult(for: row))
                    }

// NEW:
                    ForEach(viewModel.rows, id: \.displayPath) { row in
                        TrustEntryRowView(
                            row: row,
                            liveResult: liveResult(for: row),
                            displayStatus: GohTrustPresenter.displayStatus(
                                verifiedAt: row.verifiedAt,
                                fastStatus: viewModel.fastStatuses[row.displayPath]))
                    }
```

`liveResult(for:)` is the existing private helper (unchanged):
```swift
private func liveResult(for row: GohTrustEntryRow) -> VerifyStatus? {
    switch viewModel.runState {
    case .finished(let report), .cancelled(let report):
        return report.entries.first { $0.path == row.displayPath }?.status
    default:
        return nil
    }
}
```

`viewModel.fastStatuses[row.displayPath]` is the per-row `FastCheckStatus?` produced
by `FastCheckRunner.checkAll(entries, probe: probe)` inside `loadOverview()` (Task 3.3).
When the window first opens, the `.task { await viewModel.loadOverview() }` fires, which
runs `FastCheckRunner.checkAll` off-main and publishes `fastStatuses` before the first
re-render. For entries with no baseline (pre-feature), `FastCheckStatus` is `.notBaselined`,
which `displayStatus(verifiedAt:fastStatus:)` maps to `TrustDisplayStatus.notBaselined`.

**Edit D: update `accessibilityDescription` to use `displayStatus`.**

In `TrustEntryRowView`, update `accessibilityDescription`:

```swift
// OLD:
    private var accessibilityDescription: String {
        let file = URL(fileURLWithPath: row.displayPath).lastPathComponent
        let status = row.verifiedAt != nil ? "verified" : "downloaded only"
        let live = liveResult.map { "live: \($0.rawValue)" } ?? ""
        return "\(file), \(status)\(live.isEmpty ? "" : ", \(live)")"
    }

// NEW:
    private var accessibilityDescription: String {
        let file = URL(fileURLWithPath: row.displayPath).lastPathComponent
        let live = liveResult.map { "live: \($0.rawValue)" } ?? ""
        return "\(file), \(displayStatus.label)\(live.isEmpty ? "" : ", \(live)")"
    }
```

### Step 4 — Build

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
```

Expected: clean build. The compile gate confirms `TrustEntryRowView` receives a valid
`TrustDisplayStatus` at every call site; no further unit test is added for the SwiftUI
view layer (correctness is covered by Task 3.1 AC8 and Task 3.2 presenter tests).

### Step 5 — Commit

```
git add Sources/GohMenuBar/TrustWindowView.swift
git commit -m "feat(tray): render TrustDisplayStatus per row; looksUnchanged distinct from verified chip"
```

---

## Task 3.5 — `goh verify --quick` CLI command

**Files:**
- Create: `Sources/GohCore/CLI/GohVerifyQuickCommand.swift`
- Modify: `Sources/GohCore/CLI/GohCommandLine.swift`
- Create: `Tests/GohCoreTests/GohVerifyQuickCommandTests.swift`

**Pre-task reads:**
- [x] `Sources/GohCore/CLI/GohCommandLine.swift` — read in Phase 0.
  - `ParsedCommand` enum at line 296. Add `.verifyQuick` case.
  - `parse()` — the `verify` branch at line 366. The `--all` sub-branch handles `--json`.
    Add `--quick` as another sub-branch before the frozen verify path.
  - `run()` — the `verifyAll` dispatch at line 175. Add `verifyQuick` dispatch.
  - `usage()` — add `goh verify --quick` line.
  - `provenanceStorePathResolver` is already in scope for dispatch.

**Exit codes for `--quick`:**
- 0 — all entries `unchanged` or `notBaselined`
- 2 — at least one `changed`
- 9 — at least one `missing`
- 11 — at least one `indeterminate` (new code for unreadable-but-present)
- 6 — ledger unreadable

**Precedence:** 9 > 2 > 11 > 0.

### Step 1 — Write failing tests

Create `Tests/GohCoreTests/GohVerifyQuickCommandTests.swift`:

```swift
import Foundation
import Testing
@testable import GohCore

// Stub probe returning a configurable result.
private struct StubProbe: FileStatProbing {
    let result: FileProbeResult
    nonisolated func probe(path: String) -> FileProbeResult { result }
}

@Suite("GohVerifyQuickCommand")
struct GohVerifyQuickCommandTests {

    // Parse: `goh verify --quick` parses to verifyQuick case.
    @Test("parse: 'verify --quick' routes to GohVerifyQuickCommand")
    func parseVerifyQuick() {
        let result = GohCommandLine(
            arguments: ["verify", "--quick"],
            provenanceStorePathResolver: { "/tmp/nonexistent.plist" },
            send: { _ in throw ParseTestError() }
        ).run()
        // Absent ledger → exit 0 (0 entries).
        #expect(result.exitCode == 0)
    }

    // parse: `verify --quick --json` is not supported (no JSON mode for quick).
    @Test("parse: 'verify --quick --json' exits 64 (unsupported)")
    func parseVerifyQuickJsonRejected() {
        let result = GohCommandLine(
            arguments: ["verify", "--quick", "--json"],
            provenanceStorePathResolver: { "/tmp/nonexistent.plist" },
            send: { _ in throw ParseTestError() }
        ).run()
        #expect(result.exitCode == 64)
    }

    // `--quick` is incompatible with `--all`.
    @Test("parse: 'verify --all --quick' exits 64")
    func parseVerifyAllAndQuickRejected() {
        let result = GohCommandLine(
            arguments: ["verify", "--all", "--quick"],
            provenanceStorePathResolver: { "/tmp/nonexistent.plist" },
            send: { _ in throw ParseTestError() }
        ).run()
        #expect(result.exitCode == 64)
    }

    // GohVerifyQuickCommand.run with an absent ledger → exit 0, "0 recorded entries".
    @Test("run: absent ledger → exit 0")
    func absentLedger() {
        let result = GohVerifyQuickCommand.run(
            provenanceStorePath: "/tmp/goh-quick-test-absent-\(UUID().uuidString).plist",
            probe: StubProbe(result: .notFound))
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("0 recorded entries"))
    }

    // All unchanged → exit 0.
    @Test("run: all unchanged → exit 0")
    func allUnchanged() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("goh-quick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("provenance.plist").path
        let baseline = FileStat(size: 100, mtimeSeconds: 1_748_000_000,
                                mtimeNanoseconds: 0, inode: 1, device: 1,
                                isRegularFile: true)
        let entry = makeEntry(path: "/tmp/a.bin", baseline: baseline)
        try writeStore(entry, to: path)

        let probe = StubProbe(result: .stat(baseline))
        let result = GohVerifyQuickCommand.run(provenanceStorePath: path, probe: probe)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("OK"))
    }

    // Any changed → exit 2.
    @Test("run: changed file → exit 2")
    func changedFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("goh-quick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("provenance.plist").path
        let baseline = FileStat(size: 100, mtimeSeconds: 1_748_000_000,
                                mtimeNanoseconds: 0, inode: 1, device: 1,
                                isRegularFile: true)
        let current = FileStat(size: 999, mtimeSeconds: 1_748_000_000,
                               mtimeNanoseconds: 0, inode: 1, device: 1,
                               isRegularFile: true)
        let entry = makeEntry(path: "/tmp/b.bin", baseline: baseline)
        try writeStore(entry, to: path)

        let probe = StubProbe(result: .stat(current))
        let result = GohVerifyQuickCommand.run(provenanceStorePath: path, probe: probe)
        #expect(result.exitCode == 2)
        #expect(result.standardOutput.contains("CHANGED"))
    }

    // Missing file → exit 9.
    @Test("run: missing file → exit 9")
    func missingFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("goh-quick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("provenance.plist").path
        let baseline = FileStat(size: 100, mtimeSeconds: 1_748_000_000,
                                mtimeNanoseconds: 0, inode: 1, device: 1,
                                isRegularFile: true)
        let entry = makeEntry(path: "/tmp/c.bin", baseline: baseline)
        try writeStore(entry, to: path)

        let probe = StubProbe(result: .notFound)
        let result = GohVerifyQuickCommand.run(provenanceStorePath: path, probe: probe)
        #expect(result.exitCode == 9)
        #expect(result.standardOutput.contains("MISSING"))
    }

    // Precedence: 9 > 2.
    @Test("run: missing + changed → exit 9")
    func missingBeatsChanged() throws {
        // Two entries; one missing, one changed.
        // Write a two-entry store, probe: first .notFound, second .stat(changed).
        // Probe is a FixedProbe returning .notFound for simplicity — just test exit 9.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("goh-quick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("provenance.plist").path
        let baseline = FileStat(size: 100, mtimeSeconds: 1_748_000_000,
                                mtimeNanoseconds: 0, inode: 1, device: 1,
                                isRegularFile: true)
        let entry = makeEntry(path: "/tmp/d.bin", baseline: baseline)
        try writeStore(entry, to: path)

        let probe = StubProbe(result: .notFound)
        let result = GohVerifyQuickCommand.run(provenanceStorePath: path, probe: probe)
        #expect(result.exitCode == 9)
    }

    // Helpers
    private struct ParseTestError: Error {}

    private func makeEntry(path: String, baseline: FileStat) -> ProvenanceEntry {
        ProvenanceEntry(
            url: "https://example.com/a.bin",
            sha256: "sha256:" + String(repeating: "a", count: 64),
            size: Int(baseline.size),
            downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
            destinationPath: path,
            verifiedAt: nil,
            recordedStatSize: baseline.size,
            recordedMtimeSeconds: baseline.mtimeSeconds,
            recordedMtimeNanoseconds: baseline.mtimeNanoseconds,
            recordedInode: baseline.inode,
            recordedDevice: baseline.device)
    }

    private func writeStore(_ entry: ProvenanceEntry, to path: String) throws {
        let record = ProvenanceRecord(version: 1, entries: [entry])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
```

### Step 2 — Run test expecting failure

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyQuickCommandTests
```

Expected: compile error — `GohVerifyQuickCommand` not found.

### Step 3 — Implementation

**Create `Sources/GohCore/CLI/GohVerifyQuickCommand.swift`:**

```swift
import Foundation

/// CLI-local fast-check verifier for `goh verify --quick`.
///
/// Runs `FastCheckRunner.checkAll` (lstat-only — no file content reads) against
/// all entries in the provenance ledger. Does not require the daemon.
///
/// Exit code contract:
///   0  — all entries unchanged or notBaselined (0 or absent entries → 0)
///   2  — at least one CHANGED
///   9  — at least one MISSING
///   11 — at least one INDETERMINATE (unreadable-but-present)
///   6  — ledger unreadable / corrupt / unknown version
///
/// Precedence: 9 > 2 > 11 > 0.
///
/// Output format (human-readable, one line per entry):
///   OK        <path>
///   CHANGED   <path>  (size | modified | replaced)
///   MISSING   <path>
///   UNKNOWN   <path>  (unreadable)
///   BASELINE? <path>  (no baseline recorded)
public enum GohVerifyQuickCommand {

    /// Runs the fast check and returns a CLI result.
    ///
    /// - Parameters:
    ///   - provenanceStorePath: Absolute path to `provenance.plist`.
    ///   - probe: Injectable probe (default `LiveFileStatProbe()`).
    public static func run(
        provenanceStorePath: String,
        probe: any FileStatProbing = LiveFileStatProbe()
    ) -> GohCommandLineResult {
        let outcome = ProvenanceLedgerReader.read(at: provenanceStorePath)

        switch outcome {
        case .absent, .entries([]):
            return GohCommandLineResult(exitCode: 0, standardOutput: "0 recorded entries\n")

        case .unreadable(.io):
            return GohCommandLineResult(exitCode: 6, standardOutput: "provenance ledger unreadable\n")

        case .unreadable(.corrupt):
            return GohCommandLineResult(exitCode: 6, standardOutput: "provenance ledger corrupt\n")

        case .unreadable(.versionUnknown(let found)):
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "provenance ledger version \(found) is unknown\n")

        case .entries(let entries):
            return check(entries: entries, probe: probe)
        }
    }

    // MARK: - Private

    private static func check(
        entries: [ProvenanceEntry],
        probe: any FileStatProbing
    ) -> GohCommandLineResult {
        let results = FastCheckRunner.checkAll(entries, probe: probe)

        var hasMissing      = false
        var hasChanged      = false
        var hasIndeterminate = false
        var lines: [String] = []

        for (entry, status) in results {
            let path = entry.destinationPath
            switch status {
            case .unchanged:
                lines.append("OK        \(path)\n")
            case .changed(let reason):
                hasChanged = true
                let note: String
                switch reason {
                case .size:     note = "size"
                case .mtime:    note = "modified"
                case .identity: note = "replaced"
                }
                lines.append("CHANGED   \(path)  (\(note))\n")
            case .missing:
                hasMissing = true
                lines.append("MISSING   \(path)\n")
            case .indeterminate:
                hasIndeterminate = true
                lines.append("UNKNOWN   \(path)  (unreadable)\n")
            case .notBaselined:
                lines.append("BASELINE? \(path)  (no baseline — re-download to enable)\n")
            }
        }

        // Append caveat for any unchanged entries.
        if results.contains(where: { $0.1 == .unchanged }) {
            lines.append(
                "\n"
                + "Note: 'OK' means size, mtime, and inode match the recorded baseline — "
                + "not a full integrity check.\n"
                + "Run 'goh verify --all' to detect bit-rot or tampering that preserves "
                + "size & timestamp.\n")
        }

        let exitCode: Int32
        if hasMissing {
            exitCode = 9
        } else if hasChanged {
            exitCode = 2
        } else if hasIndeterminate {
            exitCode = 11
        } else {
            exitCode = 0
        }

        return GohCommandLineResult(exitCode: exitCode, standardOutput: lines.joined())
    }
}
```

**Edit `Sources/GohCore/CLI/GohCommandLine.swift` — add `.verifyQuick` case and dispatch:**

1. Add to `ParsedCommand` enum (after `verifyAll`):
```swift
case verifyQuick
```

2. In `parse()`, inside the `verify` branch, before `--all`:
```swift
if rest.first == "--quick" {
    let after = Array(rest.dropFirst())
    guard after.isEmpty else {
        throw ParseError(
            message: "--quick does not accept additional arguments: \(after.joined(separator: " "))")
    }
    return .verifyQuick
}
```

3. In `run()`, after the `verifyAll` case:
```swift
case .verifyQuick:
    return GohVerifyQuickCommand.run(
        provenanceStorePath: provenanceStorePathResolver() ?? "")
```

4. In `usage()`, add after the `verify --all` line:
```swift
          goh verify --quick   (exit: 0 ok/no-baseline · 2 changed · 9 missing · 11 unreadable · 6 ledger error)
```

### Step 4 — Run test expecting pass

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyQuickCommandTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohCoreTests
```

### Step 5 — Commit

```
git add Sources/GohCore/CLI/GohVerifyQuickCommand.swift \
        Sources/GohCore/CLI/GohCommandLine.swift \
        Tests/GohCoreTests/GohVerifyQuickCommandTests.swift
git commit -m "feat(cli): add 'goh verify --quick' fast lstat-based check command"
```

---

## Task 3.6 — Wire `LiveFileStatProbe` in `goh-menu/main.swift`

**Files:**
- Modify: `Sources/goh-menu/main.swift`

**Pre-task reads:**
- [x] `Sources/goh-menu/main.swift` — read in Phase 0. `TrustWindowRoot` is constructed
  at line 340 with `TrustWindowViewModel(reader:provenanceStorePath:)`. The `probe`
  parameter with its default `LiveFileStatProbe()` means no change is needed in this file
  — the default is used automatically. However, explicitly pass `probe: LiveFileStatProbe()`
  for clarity and to make the wiring visible for future readers.

### Step 3 — Implementation

Locate the `TrustWindowRoot` construction (~line 340):

```swift
// OLD:
        Window("Trust", id: "trust") {
            TrustWindowRoot(
                makeViewModel: TrustWindowViewModel(
                    reader: LiveProvenanceReader(path: appDelegate.provenancePath),
                    provenanceStorePath: appDelegate.provenancePath))
        }

// NEW:
        Window("Trust", id: "trust") {
            TrustWindowRoot(
                makeViewModel: TrustWindowViewModel(
                    reader: LiveProvenanceReader(path: appDelegate.provenancePath),
                    provenanceStorePath: appDelegate.provenancePath,
                    probe: LiveFileStatProbe()))
        }
```

### Step 4 — Build

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
```

Expected: clean build. No tests to run for this wiring change (compile is the gate).

### Step 5 — Commit

```
git add Sources/goh-menu/main.swift
git commit -m "feat(goh-menu): wire LiveFileStatProbe into TrustWindowViewModel"
```

---

## Task 3.7 — Full final verification

Run the complete test suite and build:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected:
- Clean build with `-warnings-as-errors`.
- All GohCoreTests pass (including golden fixture round-trip, all FastCheckRunner/FileStat tests).
- All GohMenuBarTests pass (including AC8 token-distinctness test).
- No regressions in DownloadEngineTests, ProvenanceRecordTests, ProvenanceStoreTests,
  GohTrustPresenterTests.
- Governor block in `DownloadEngine.fetchRanged` is byte-for-byte unchanged.
- `ProvenanceRecord.currentVersion == 1` throughout.

Write phase artifact:
`docs/superpowers/progress/2026-06-08-tiered-rapid-trust-phase3.md`
Content: confirm full suite green, AC1–AC9 test coverage map, no regression summary.

---

## Summary of Phases and Task Count

**Phase 1 — GohCore data + pure logic** (3 tasks): Adds the five additive-optional baseline
fields to `ProvenanceEntry` (Task 1.1), implements `FileStat`/`FileProbeResult`/`FileStatProbing`/
`LiveFileStatProbe` with probe tests (Task 1.2), and implements `FastChangeReason`/
`FastCheckStatus`/`FastCheckRunner` with comprehensive pure unit tests (Task 1.3). Fully
independent — no daemon or surface changes. 13 new tests covering AC1–AC7 and AC9.

**Phase 2 — Capture path** (3 tasks): Adds `DownloadFile.fileStat()` via `fstat(2)` on
the open descriptor (Task 2.1), widens `completedDownloadHandler` and `complete()` with a
trailing `FileStat?` and adds three capture sites in `fetchSingle`, `fetchRanged`, and
`resume` before `file.finish()` (Task 2.2), and routes the captured baseline into the
daemon's `ProvenanceEntry` construction (Task 2.3). Governor block is byte-unchanged.

**Phase 3 — Surfaces** (6 tasks): Adds `TrustDisplayStatus` with the AC8 token-distinctness
test (Task 3.1), implements `GohTrustPresenter.displayStatus()` (Task 3.2), wires fast-check
into `TrustWindowViewModel.loadOverview()` (Task 3.3), updates `TrustWindowView` to render
`TrustDisplayStatus` per row with `looksUnchanged` visually distinct from `verified` (Task 3.4),
adds `GohVerifyQuickCommand` and the `goh verify --quick` CLI flag (Task 3.5), and wires
`LiveFileStatProbe` into `goh-menu/main.swift` (Task 3.6), followed by a full final
verification run (Task 3.7).

**Total: 12 tasks across 3 phases.** Phase 1 is shippable independently; Phase 2 requires
Phase 1 for its types; Phase 3 requires both Phase 1 (for `FastCheckRunner`/`TrustDisplayStatus`)
and Phase 2 (for the daemon baseline to be populated in new downloads).
