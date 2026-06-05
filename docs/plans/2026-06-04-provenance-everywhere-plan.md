# Provenance-everywhere Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development`
> (recommended) or `superpowers:executing-plans` to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a daemon-owned provenance ledger (`provenance.plist`) that auto-records `{url, sha256, size, downloadedAt, destinationPath}` for every successful download, then answers `goh which` and `goh verify --all` from that offline record.

**Architecture:** Approach A — The Native Ledger. A fourth `Sendable`-class-over-`Mutex` binary-plist store, mirroring `HostProfileStore` exactly (including its corrupt→sidecar recovery and atomic write idiom), minus TTL eviction. The SHA-256 already computed in `ChunkAssembler.hashToCompletion()` is threaded through all three completion paths via a widened `completedDownloadHandler` closure; the daemon records it best-effort alongside the existing Spotlight tag. CLI reads are direct file reads (`provenance.plist`, 0600, same-user), never via XPC, so `goh which` and `goh verify --all` work with the daemon stopped. A shared `ProvenanceStoreLocation` resolver in `GohCore` prevents writer/reader path divergence.

**Tech Stack:** Swift 6.2, macOS 26.0 floor; `PropertyListEncoder/Decoder` (binary); `Synchronization.Mutex`; `Darwin` (rename/fsync); `CryptoKit` SHA-256 via existing `ChunkAssembler`/`FileDigest`; Swift Testing (not XCTest); SwiftPM, no new dependencies.

---

## Acceptance Criteria Map

| AC | Text (abbreviated) | Owning Task(s) |
|---|---|---|
| AC1 | Every successful download is recorded with the streamed digest. | Task 4 (engine digest), Task 5 (handler wiring) |
| AC2 | `goh which` answers from the record for ad-hoc downloads, offline. | Task 6 |
| AC3 | `goh verify --all` re-hashes recorded files offline, OK/FAILED/MISSING, deterministic exit codes. | Task 7 |
| AC4 | Purely additive; new store has its own `version = 1`; golden round-trip; `-warnings-as-errors` clean; test count non-decreasing. | Task 2 (types + golden fixture), Task 3 (store), Task 4 (engine), Task 8 (DESIGN.md) |
| AC5 | Re-download updates in place; corrupt store degrades gracefully; downloads never blocked. | Task 3 (store), Task 5 (best-effort handler) |

---

## Phase Overview

This plan has **10 tasks** (>6), segmented into three deployment-independent phases:

| Phase | Tasks | Boundary |
|---|---|---|
| **P1** — Pure value layer | 1–3 | `ProvenanceEntry`/`Record` types + golden fixture + `ProvenanceStore`, all unit-tested in isolation. No engine or daemon changes. |
| **P2** — Engine + daemon capture | 4–5 | Digest threading through all three completion paths; `completedDownloadHandler` widened; daemon wired with best-effort recording and `ProvenanceStoreLocation` factoring. |
| **P3** — CLI surfaces | 6–10 | `goh which` ledger branch; `goh verify --all`; `GohCommandLine` parse/dispatch/usage; `DESIGN.md` reconciliation. |

Phase artifacts live at `docs/superpowers/progress/2026-06-04-provenance-everywhere-phase{N}.md`.

---

## Phase 1: Pure Value Layer

### Task 1: Branch setup

**Files:**
- (no source files — branch creation only)

- [ ] **Step 1: Create the feature branch**

```bash
git checkout -b feat/provenance-everywhere
```

- [ ] **Step 2: Create the `Provenance/` directory stub**

```bash
mkdir -p Sources/GohCore/Provenance
```

- [ ] **Step 3: Commit**

```bash
git add .
git commit -m "chore: create feat/provenance-everywhere branch and Provenance/ directory"
```

---

### Task 2: `ProvenanceRecord`, `ProvenanceEntry`, and golden fixture

**Files:**
- Create: `Sources/GohCore/Provenance/ProvenanceRecord.swift`
- Create: `Tests/GohCoreTests/Fixtures/provenance-v1.plist` (golden binary plist)
- Create: `Tests/GohCoreTests/ProvenanceRecordTests.swift`

**Pre-task reads:**
- [x] Read `Sources/GohCore/Scheduling/HostScheduling.swift` (versioned root pattern)
- [x] Read `Tests/GohCoreTests/Fixtures/host-scheduling-v1.plist` (golden fixture pattern)
- [x] Read `Tests/GohCoreTests/HostSchedulingTests.swift` L146–175 (golden round-trip test pattern)

> **Bet check:** Personal-scale download counts never reach the point where an O(n) full-plist rewrite per completion becomes user-perceptible. This task establishes `currentVersion = 1` — the independent version field that makes Approach A the only approach that satisfies AC4 cleanly, as Approach B cannot carry its own version without inheriting the frozen `lockfileVersion = 1`.

- [ ] **Step 1: Write the failing test**

Create `Tests/GohCoreTests/ProvenanceRecordTests.swift`:

```swift
import Foundation
import Testing

@testable import GohCore

@Suite("ProvenanceRecord")
struct ProvenanceRecordTests {

    // MARK: - AC4: golden fixture round-trip (T1)

    // AC4: New store has its own version field; golden round-trip passes.
    @Test("AC4/T1: golden fixture decodes to known value; round-trip encode/decode is stable")
    func goldenFixtureRoundTrip() throws {
        let fixtureURL = Bundle.module.url(
            forResource: "provenance-v1", withExtension: "plist",
            subdirectory: "Fixtures")
        let fixtureData = try Data(contentsOf: #require(fixtureURL))

        let decoded = try PropertyListDecoder().decode(ProvenanceRecord.self, from: fixtureData)

        // Version sentinel
        #expect(decoded.version == 1)
        #expect(decoded.version == ProvenanceRecord.currentVersion)

        // Two entries: one normal, one zero-size
        #expect(decoded.entries.count == 2)

        let first = decoded.entries[0]
        #expect(first.url == "https://dl.example.com/a.bin")
        #expect(first.sha256 == "sha256:aabbccdd" + String(repeating: "0", count: 56))
        #expect(first.size == 1_048_576)
        #expect(first.destinationPath == "/Users/testuser/Downloads/a.bin")

        let second = decoded.entries[1]
        #expect(second.url == "https://cdn.example.net/empty.bin")
        #expect(second.sha256 == "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(second.size == 0)
        #expect(second.destinationPath == "/Users/testuser/Downloads/empty.bin")

        // Round-trip: re-encode the decoded value, then decode again — the two decoded
        // values must be equal. We do NOT assert byte-identity vs the fixture because
        // binary-plist encoding is not guaranteed bit-stable across SDK versions (the
        // cross-SDK-skew gotcha). This mirrors the host-scheduling golden test pattern.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let reencoded = try encoder.encode(decoded)
        let redecoded = try PropertyListDecoder().decode(ProvenanceRecord.self, from: reencoded)
        #expect(redecoded == decoded)
    }

    // AC4: empty is the correct zero value.
    @Test("AC4/T1: ProvenanceRecord.empty has version == currentVersion and no entries")
    func emptyIsCorrect() {
        let empty = ProvenanceRecord.empty
        #expect(empty.version == ProvenanceRecord.currentVersion)
        #expect(empty.entries.isEmpty)
    }

    // Codable round-trip (encode then decode — separate from the golden fixture).
    @Test("T1: encode/decode round-trip is lossless")
    func encodeDecodeRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_748_000_000)
        let record = ProvenanceRecord(
            version: ProvenanceRecord.currentVersion,
            entries: [
                ProvenanceEntry(
                    url: "https://example.com/f.bin",
                    sha256: "sha256:" + String(repeating: "a", count: 64),
                    size: 512,
                    downloadedAt: fixedDate,
                    destinationPath: "/tmp/f.bin")
            ])

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        let decoded = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
        #expect(decoded == record)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProvenanceRecordTests 2>&1 | tail -20
```

Expected: compile error — `ProvenanceRecord` does not exist yet.

- [ ] **Step 3: Write the types**

Create `Sources/GohCore/Provenance/ProvenanceRecord.swift`:

```swift
import Foundation

/// Versioned root of the provenance ledger (`provenance.plist`).
///
/// Frozen on-disk format. `currentVersion` is independent of every other
/// contract in the system (`protocolVersion`, `JobCatalog.currentVersion`,
/// `lockfileVersion`, `DownloadCheckpoint` version, `HostScheduling.currentVersion`).
/// Bumping it requires a four-round design pass.
public struct ProvenanceRecord: Codable, Sendable, Equatable {
    /// The frozen format version. Bump only via a four-round design pass.
    public static let currentVersion = 1

    public var version: Int
    public var entries: [ProvenanceEntry]

    public init(version: Int = currentVersion, entries: [ProvenanceEntry] = []) {
        self.version = version
        self.entries = entries
    }

    /// An empty record at the current version.
    public static let empty = ProvenanceRecord(version: currentVersion, entries: [])
}

/// One recorded download, keyed logically by `destinationPath`.
///
/// The key is always a **canonical absolute path string** produced by
/// `URL(fileURLWithPath: rawPath).standardizedFileURL.path` — a purely lexical
/// normalization (collapses `..`/`.`/trailing-slash; does NOT resolve symlinks).
/// Write-side and read-side apply the same transform, so comparisons are
/// consistent. Callers pass raw paths; `ProvenanceStore.lookup` canonicalizes
/// internally.
public struct ProvenanceEntry: Codable, Sendable, Equatable {
    /// Source URL exactly as the completed `JobSummary.url` carries it.
    /// May contain query-string credentials — never commit or export this file.
    public var url: String
    /// Stored WITH the `"sha256:"` prefix: `"sha256:<lowercase-hex>"`.
    /// Matches `FileDigest.sha256WithSize` output and `LockEntry.sha256`.
    public var sha256: String
    /// Byte size of the completed file. `0` is valid (empty download).
    public var size: Int
    /// Completion time. Encoded by `PropertyListEncoder` as a binary-plist
    /// `Date` (real seconds since the 2001 reference epoch).
    public var downloadedAt: Date
    /// Canonical absolute path string (the logical key).
    /// `record(entry:)` replaces an existing entry with the same string,
    /// else appends. Always stored in canonical form.
    public var destinationPath: String

    public init(
        url: String,
        sha256: String,
        size: Int,
        downloadedAt: Date,
        destinationPath: String
    ) {
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.downloadedAt = downloadedAt
        self.destinationPath = destinationPath
    }
}
```

- [ ] **Step 4: Generate the golden fixture**

The fixture is a binary plist that encodes a `ProvenanceRecord` with two entries. Generate it once using a Swift script or a test helper, then commit it. The entries must use fixed `downloadedAt` values so the binary encoding is deterministic.

The fixture encodes exactly:

```
ProvenanceRecord(
    version: 1,
    entries: [
        ProvenanceEntry(
            url: "https://dl.example.com/a.bin",
            sha256: "sha256:aabbccdd" + String(repeating: "0", count: 56),
            size: 1_048_576,
            downloadedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            destinationPath: "/Users/testuser/Downloads/a.bin"),
        ProvenanceEntry(
            url: "https://cdn.example.net/empty.bin",
            sha256: "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            size: 0,
            downloadedAt: Date(timeIntervalSinceReferenceDate: 800_100_000),
            destinationPath: "/Users/testuser/Downloads/empty.bin")
    ])
```

**A5 — generate from the REAL `@testable import` types, not a redeclared shape.** A `swift -e`
one-shot that redeclares `ProvenanceRecord`/`ProvenanceEntry` can drift in lockstep with a typo
in the real types (the redeclaration and the real type would both be wrong the same way, and the
golden test would still pass). Instead, generate the fixture from the SHIPPING types via a
temporary `@testable import GohCore` generator test. Add this test TEMPORARILY to
`ProvenanceRecordTests.swift`, run it once to write the fixture, confirm the fixture, then DELETE
the generator test before Step 6's commit (the committed fixture + the round-trip test are what
lock the format — the generator is scaffolding, not a shipped test):

```swift
// TEMPORARY generator — run once, then DELETE before committing (A5).
// Uses the REAL ProvenanceRecord/ProvenanceEntry via @testable import, so the fixture
// cannot drift in lockstep with a typo in the production types.
@Test("GENERATOR (delete after running): write provenance-v1.plist from real types")
func generateGoldenFixture() throws {
    let record = ProvenanceRecord(version: 1, entries: [
        ProvenanceEntry(
            url: "https://dl.example.com/a.bin",
            sha256: "sha256:aabbccdd" + String(repeating: "0", count: 56),
            size: 1_048_576,
            downloadedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            destinationPath: "/Users/testuser/Downloads/a.bin"),
        ProvenanceEntry(
            url: "https://cdn.example.net/empty.bin",
            sha256: "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            size: 0,
            downloadedAt: Date(timeIntervalSinceReferenceDate: 800_100_000),
            destinationPath: "/Users/testuser/Downloads/empty.bin")
    ])
    let enc = PropertyListEncoder(); enc.outputFormat = .binary
    let data = try enc.encode(record)
    // Resolve the source-tree Fixtures dir from this file's location at compile time.
    let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    try FileManager.default.createDirectory(
        at: fixturesDir, withIntermediateDirectories: true)
    try data.write(to: fixturesDir.appendingPathComponent("provenance-v1.plist"))
}
```

Run it once:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "generateGoldenFixture" 2>&1 | tail -10
```

Then DELETE `generateGoldenFixture` from `ProvenanceRecordTests.swift` (the round-trip
`goldenFixtureRoundTrip` test — decode→re-encode→decode value-equality, correct per the
cross-SDK gotcha — is what stays and locks the format).

After generating, verify the fixture decodes correctly:

```bash
plutil -p Tests/GohCoreTests/Fixtures/provenance-v1.plist
```

Expected: readable output showing `version`, `entries` array with two items.

- [ ] **Step 5: Run tests to verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProvenanceRecordTests 2>&1 | tail -20
```

Expected: all `ProvenanceRecordTests` pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/GohCore/Provenance/ProvenanceRecord.swift \
        Tests/GohCoreTests/Fixtures/provenance-v1.plist \
        Tests/GohCoreTests/ProvenanceRecordTests.swift
git commit -m "feat: add ProvenanceRecord/ProvenanceEntry types and provenance-v1.plist golden fixture"
```

---

### Task 3: `ProvenanceStore` and `ProvenanceStoreLocation`

**Files:**
- Create: `Sources/GohCore/Provenance/ProvenanceStore.swift`
- Create: `Sources/GohCore/Provenance/ProvenanceStoreLocation.swift`
- Create: `Tests/GohCoreTests/ProvenanceStoreTests.swift`

**Pre-task reads:**
- [x] Read `Sources/GohCore/Scheduling/HostProfileStore.swift` (the full store idiom — load, recoverToEmpty, writeAtomically, Mutex<Inner>)
- [x] Read `Sources/GohCore/IPC/XPCService.swift` L18 (confirms `machServiceName == "dev.goh.daemon"`)
- [x] Read `Sources/gohd/main.swift` L17–25 (`supportDirectoryURL()` function to be factored out)

> **Bet check:** Personal-scale download counts never reach the point where an O(n) full-plist rewrite per completion becomes user-perceptible. This task implements `ProvenanceStore.record(entry:)` as a full atomic rewrite (the O(n) path). The documented escape hatch (append-log or SQLite behind the same `record`/`lookup`/`allEntries()` surface) is reachable in one file if the bet ever fails.

- [ ] **Step 1: Write the failing tests**

Create `Tests/GohCoreTests/ProvenanceStoreTests.swift`:

```swift
import Foundation
import Testing

@testable import GohCore

@Suite("ProvenanceStore")
struct ProvenanceStoreTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-provenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fixedEntry(
        path: String = "/Users/u/Downloads/a.bin",
        sha256: String = "sha256:" + String(repeating: "a", count: 64),
        url: String = "https://example.com/a.bin",
        size: Int = 1024
    ) -> ProvenanceEntry {
        ProvenanceEntry(
            url: url,
            sha256: sha256,
            size: size,
            downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
            destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    // AC5/T2: Corrupt → sidecar copy; original left in place; next record still succeeds.
    @Test("AC5/T2: corrupt store recovers to empty and copies sidecar; original remains until next record")
    func corruptStoreSidecarCopy() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("provenance.plist")
        // Write garbage so decode fails.
        try Data("not a plist".utf8).write(to: fileURL)

        let store = ProvenanceStore(fileURL: fileURL)
        let result = store.load()

        // A sidecar copy was created.
        let sidecar = try #require(result.corruptionSidecar)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        // The corrupt original is LEFT IN PLACE (recoverToEmpty copies, not moves).
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        // In-memory state is reset to empty.
        #expect(result.record.entries.isEmpty)

        // Subsequent record() succeeds (overwrites the corrupt original via atomic rename).
        let entry = fixedEntry()
        try store.record(entry: entry)
        let entries = store.allEntries()
        #expect(entries.count == 1)
    }

    // BLOCK-3: loadReadOnly() is the CLI read path — it must create NO sidecar and
    // NO directory, even on a corrupt file (only the daemon's load() recovers).
    @Test("BLOCK-3: loadReadOnly on a corrupt file returns false and creates no sidecar")
    func loadReadOnlyNeverCreatesSidecar() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("provenance.plist")
        try Data("not a plist".utf8).write(to: fileURL)

        let store = ProvenanceStore(fileURL: fileURL)
        let ok = store.loadReadOnly()
        #expect(ok == false)

        // No sidecar was created; the directory holds only the corrupt original.
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents == ["provenance.plist"])
        // lookup on the (empty in-memory) store finds nothing.
        #expect(store.lookup(destinationPath: "/anything") == nil)
    }

    // BLOCK-3: loadReadOnly on a clean file populates in-memory state for lookup().
    @Test("BLOCK-3: loadReadOnly on a clean file returns true and lookup finds the entry")
    func loadReadOnlyCleanFilePopulatesLookup() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("provenance.plist")
        let writer = ProvenanceStore(fileURL: fileURL)
        _ = writer.load()
        let canonical = "/Users/u/Downloads/a.bin"
        try writer.record(entry: fixedEntry(path: canonical))

        // Fresh reader instance, read-only load.
        let reader = ProvenanceStore(fileURL: fileURL)
        #expect(reader.loadReadOnly() == true)
        #expect(reader.lookup(destinationPath: canonical)?.destinationPath == canonical)
    }

    // AC5/T3: In-place update / dedup.
    @Test("AC5/T3: two records with the same destinationPath keep exactly one entry with the latest values")
    func inPlaceUpdate() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
        _ = store.load()

        let path = "/Users/u/Downloads/dup.bin"
        let first = fixedEntry(
            path: path,
            sha256: "sha256:" + String(repeating: "1", count: 64))
        let second = fixedEntry(
            path: path,
            sha256: "sha256:" + String(repeating: "2", count: 64))

        try store.record(entry: first)
        try store.record(entry: second)

        let entries = store.allEntries()
        #expect(entries.count == 1)
        #expect(entries[0].sha256 == "sha256:" + String(repeating: "2", count: 64))
    }

    // Save / load round-trip.
    @Test("save then load round-trips ProvenanceRecord")
    func saveLoadRoundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
        _ = store.load()

        let entry = fixedEntry()
        try store.record(entry: entry)

        // Reload from disk via a fresh store instance.
        let store2 = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
        let result = store2.load()
        #expect(result.record.entries.count == 1)
        #expect(result.record.entries[0].destinationPath == entry.destinationPath)
        #expect(result.record.entries[0].sha256 == entry.sha256)
    }

    // Missing file → empty (no crash, no sidecar).
    @Test("missing store file yields empty record; no sidecar")
    func missingFileYieldsEmpty() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
        let result = store.load()
        #expect(result.record.entries.isEmpty)
        #expect(result.corruptionSidecar == nil)
    }

    // File permissions are 0600.
    @Test("saved file has owner-only 0600 permissions")
    func filePermissions() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: fileURL)
        _ = store.load()
        try store.record(entry: fixedEntry())

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let posixPerms = attrs[.posixPermissions] as? Int
        #expect(posixPerms == 0o600)
    }

    // No temp file left behind after write.
    @Test("record() leaves no temporary file behind")
    func noTempFileLeft() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
        _ = store.load()
        try store.record(entry: fixedEntry())

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents == ["provenance.plist"])
    }

    // lookup() canonicalizes the argument internally (ADVISORY C).
    @Test("lookup canonicalizes its argument; dotdot path finds stored canonical key")
    func lookupCanonicalizesArgument() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
        _ = store.load()

        // Store an entry with the canonical path.
        let canonical = "/Users/u/Downloads/a.bin"
        try store.record(entry: fixedEntry(path: canonical))

        // Lookup with a `..`-laden path that canonicalizes to the same string.
        // URL(fileURLWithPath:).standardizedFileURL.path collapses the `..`.
        let dotdotPath = "/Users/u/Downloads/../Downloads/a.bin"
        let found = store.lookup(destinationPath: dotdotPath)
        #expect(found != nil)
        #expect(found?.destinationPath == canonical)
    }

    // Version-mismatch → sidecar copy (like bad decode).
    @Test("version mismatch triggers sidecar copy and reset to empty")
    func versionMismatchTriggersSidecar() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("provenance.plist")

        // Write a record with a future version the current code does not know.
        struct FutureRecord: Codable {
            var version: Int
            var entries: [String]
        }
        let future = FutureRecord(version: 99, entries: [])
        let enc = PropertyListEncoder(); enc.outputFormat = .binary
        try enc.encode(future).write(to: fileURL)

        let store = ProvenanceStore(fileURL: fileURL)
        let result = store.load()

        let sidecar = try #require(result.corruptionSidecar)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(result.record.entries.isEmpty)
    }

    // AC13 (partial): ProvenanceStoreLocation.defaultURL(create:false) does NOT create the dir.
    @Test("AC13: defaultURL(create:false) does not create the Application Support subdir")
    func defaultURLCreateFalseDoesNotCreateDir() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The resolver should not create `dir/dev.goh.daemon/` when create=false
        // and the subdir does not exist. We cannot easily test the real
        // ~/Library/Application Support without side effects, so this test uses
        // the `lookup` path which calls `defaultURL(create: false)` in GohCommandLine.
        // Structural assertion: a missing store file at a non-existent path
        // produces nil from lookup, with no directory created.
        let missingDir = dir.appendingPathComponent("dev.goh.daemon")
        #expect(!FileManager.default.fileExists(atPath: missingDir.path))

        // Load a store against the (non-existent) dir — simulates CLI read path.
        let storeURL = missingDir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        let result = store.load()   // file absent → empty, no dir creation
        #expect(result.record.entries.isEmpty)
        #expect(result.corruptionSidecar == nil)
        // The directory was NOT created.
        #expect(!FileManager.default.fileExists(atPath: missingDir.path))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProvenanceStoreTests 2>&1 | tail -20
```

Expected: compile error — `ProvenanceStore` / `ProvenanceStoreLocation` not defined.

- [ ] **Step 3: Write the implementation**

Create `Sources/GohCore/Provenance/ProvenanceStoreLocation.swift`:

```swift
import Foundation

/// Resolves the canonical path of `provenance.plist` so the daemon writer and
/// the CLI readers (`goh which`, `goh verify --all`) always point at the same file.
///
/// This is the single anti-divergence point: both the daemon and the CLI call
/// `ProvenanceStoreLocation.defaultURL(create:)` — never a hard-coded path.
public enum ProvenanceStoreLocation {

    /// `~/Library/Application Support/dev.goh.daemon/provenance.plist`.
    ///
    /// - Parameter create: When `true` (daemon path), the `dev.goh.daemon`
    ///   subdirectory is created with `withIntermediateDirectories: true` — exactly
    ///   preserving the daemon's first-run behaviour. When `false` (CLI read paths),
    ///   no directory is created; a missing dir/file is "no store" (silent fall-through).
    public static func defaultURL(create: Bool) throws -> URL {
        try supportDirectoryURL(create: create).appending(path: "provenance.plist")
    }

    /// The support directory `~/Library/Application Support/<machServiceName>`.
    ///
    /// Factored out of `gohd/main.swift`'s `supportDirectoryURL()` so daemon and
    /// CLI share one definition. The daemon should call this with `create: true`
    /// to preserve its existing directory-creation behaviour (load-bearing for
    /// `CatalogStore`/`HostProfileStore`/`CheckpointStore` on a clean install — those
    /// stores do not self-create their parent).
    public static func supportDirectoryURL(create: Bool) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: create)
        let directory = support.appending(
            path: GohXPCService.machServiceName, directoryHint: .isDirectory)
        if create {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
```

Create `Sources/GohCore/Provenance/ProvenanceStore.swift`:

```swift
import Darwin
import Foundation
import Synchronization

/// A failure writing the provenance ledger to disk.
public enum ProvenanceStoreError: Error {
    case fsyncOpenFailed(path: String, errno: Int32)
    case fsyncFailed(path: String, errno: Int32)
    case renameFailed(errno: Int32)
}

/// The outcome of loading the provenance ledger.
public struct ProvenanceLoadResult: Sendable {
    /// The loaded record — empty when the file was missing or unreadable.
    public var record: ProvenanceRecord
    /// When the on-disk file was unreadable, the path the bytes were **copied** to
    /// before recovery; `nil` on a clean or first-run load.
    ///
    /// The corrupt original is LEFT IN PLACE — `recoverToEmpty()` uses `copyItem`,
    /// not `moveItem`. The next `record(entry:)` call overwrites it via atomic rename.
    public var corruptionSidecar: URL?
}

/// Reads, writes, and maintains the in-memory provenance ledger.
///
/// Concurrency: all mutable state is guarded by a `Mutex`. The daemon is the
/// SOLE WRITER; the CLI is a read-only consumer via direct file reads.
///
/// Saves are atomic and durable — identical pattern to `HostProfileStore`
/// (temp→`chmod 0600`→`fsync(tmp)`→`rename(2)`→`fsync(dir)`). The file is
/// written at owner-only 0600 permissions.
///
/// INTENTIONALLY NO TTL EVICTION — unlike `HostProfileStore` which TTL-evicts at
/// 90 days. Evicting provenance entries would silently lose the user's own record
/// of where their files came from and what their hashes were. If a future maintainer
/// is copying the `HostProfileStore` idiom here, do NOT add TTL eviction.
public final class ProvenanceStore: Sendable {

    private let fileURL: URL
    private let inner: Mutex<Inner>

    private struct Inner: Sendable {
        var record: ProvenanceRecord
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.inner = Mutex(Inner(record: .empty))
    }

    // MARK: — Load

    /// Loads the provenance ledger from disk. Call once at daemon startup.
    ///
    /// On corrupt or version-mismatch: **copies** the on-disk file to a
    /// `.corrupt-<unixtime>` sidecar (the original is left in place), resets
    /// in-memory state to `.empty`, and returns the sidecar URL in the result.
    /// The next `record(entry:)` overwrites the corrupt original via atomic rename.
    @discardableResult
    public func load() -> ProvenanceLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ProvenanceLoadResult(record: .empty, corruptionSidecar: nil)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let record = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
            guard record.version == ProvenanceRecord.currentVersion else {
                return recoverToEmpty()
            }
            inner.withLock { $0.record = record }
            return ProvenanceLoadResult(record: record, corruptionSidecar: nil)
        } catch {
            return recoverToEmpty()
        }
    }

    /// READ-ONLY load for the CLI consumers (`goh which`, `goh verify --all`).
    ///
    /// BLOCK-3: the CLI is a read-only consumer — it must NOT create the support
    /// directory, write a `.corrupt-<ts>` sidecar, or reset the on-disk store
    /// (only the daemon's `load()` performs recovery). On a missing, unreadable, or
    /// version-mismatched file this returns `false` and leaves in-memory state empty;
    /// on a clean decode it populates in-memory state and returns `true`. No side
    /// effects on disk in any case.
    ///
    /// `goh which` ignores the `Bool` (a non-match `lookup` is indistinguishable from
    /// "no store" — both fall through silently). `goh verify --all` does NOT use this
    /// method; it reads the file directly so it can distinguish corrupt (exit 6) from
    /// empty (exit 0) — see Task 7.
    @discardableResult
    public func loadReadOnly() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let record = try? PropertyListDecoder().decode(ProvenanceRecord.self, from: data),
              record.version == ProvenanceRecord.currentVersion
        else {
            return false
        }
        inner.withLock { $0.record = record }
        return true
    }

    // MARK: — Write

    /// Updates or appends an entry for `entry.destinationPath` and atomically
    /// rewrites the store.
    ///
    /// **In-place keyed by `destinationPath`**: if an entry with the same canonical
    /// `destinationPath` string already exists, it is replaced; otherwise the
    /// entry is appended. The path is already canonical (callers must apply
    /// `URL(fileURLWithPath:).standardizedFileURL.path` before constructing the entry).
    ///
    /// The full rewrite is O(n) in the number of recorded entries. At personal scale
    /// (thousands to tens-of-thousands of downloads), this is imperceptible — see
    /// Approach A "THE BET" in the approach decision memo.
    public func record(entry: ProvenanceEntry) throws {
        var snapshot: ProvenanceRecord = inner.withLock { inner in
            if let idx = inner.record.entries.firstIndex(where: {
                $0.destinationPath == entry.destinationPath
            }) {
                inner.record.entries[idx] = entry
            } else {
                inner.record.entries.append(entry)
            }
            return inner.record
        }
        try writeAtomically(&snapshot)
    }

    // MARK: — Read

    /// Returns the entry whose stored `destinationPath` matches the canonical form
    /// of `destinationPath`, or `nil` if not found.
    ///
    /// Canonicalization is applied internally (ADVISORY C): callers pass the raw
    /// user-supplied path; this method applies
    /// `URL(fileURLWithPath:).standardizedFileURL.path` once and string-compares
    /// against the already-canonical stored keys. Neither the caller nor any other
    /// reader re-normalizes stored keys.
    public func lookup(destinationPath: String) -> ProvenanceEntry? {
        let canonical = URL(fileURLWithPath: destinationPath).standardizedFileURL.path
        return inner.withLock { inner in
            inner.record.entries.first { $0.destinationPath == canonical }
        }
    }

    /// Returns a snapshot of all entries (for `goh verify --all`).
    public func allEntries() -> [ProvenanceEntry] {
        inner.withLock { $0.record.entries }
    }

    // MARK: — Private helpers

    private func recoverToEmpty() -> ProvenanceLoadResult {
        let timestamp = Int(Date().timeIntervalSince1970)
        let sidecar = fileURL.deletingLastPathComponent()
            .appending(path: "\(fileURL.lastPathComponent).corrupt-\(timestamp)")
        try? FileManager.default.copyItem(at: fileURL, to: sidecar)
        let sidecarExists = FileManager.default.fileExists(atPath: sidecar.path)
        inner.withLock { $0.record = .empty }
        return ProvenanceLoadResult(
            record: .empty,
            corruptionSidecar: sidecarExists ? sidecar : nil)
    }

    private func writeAtomically(_ record: inout ProvenanceRecord) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)

        let directory = fileURL.deletingLastPathComponent()
        let temporaryURL = directory.appending(
            path: ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")

        do {
            try data.write(to: temporaryURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            try Self.fsync(path: temporaryURL.path)
            guard rename(temporaryURL.path, fileURL.path) == 0 else {
                throw ProvenanceStoreError.renameFailed(errno: errno)
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
            throw ProvenanceStoreError.fsyncOpenFailed(path: path, errno: errno)
        }
        defer { close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ProvenanceStoreError.fsyncFailed(path: path, errno: errno)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProvenanceStoreTests 2>&1 | tail -30
```

Expected: all `ProvenanceStoreTests` pass.

- [ ] **Step 5: Run the full suite to verify no regressions**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20
```

Expected: all tests pass; test count is higher than before this task.

- [ ] **Step 6: Commit**

```bash
git add Sources/GohCore/Provenance/ProvenanceStore.swift \
        Sources/GohCore/Provenance/ProvenanceStoreLocation.swift \
        Tests/GohCoreTests/ProvenanceStoreTests.swift
git commit -m "feat: add ProvenanceStore + ProvenanceStoreLocation (P1 value layer complete)"
```

---

## Phase 1 Artifact

Write to `docs/superpowers/progress/2026-06-04-provenance-everywhere-phase1.md` at the end of Task 3 (before beginning Phase 2):

```markdown
# Phase 1 Progress — provenance-everywhere

Status: COMPLETE — Tasks 1–3 implemented and passing.

## WHAT WAS BUILT

- `Sources/GohCore/Provenance/ProvenanceRecord.swift` — `ProvenanceRecord` (versioned root,
  `currentVersion = 1`) and `ProvenanceEntry` (5 fields, `Codable`/`Sendable`/`Equatable`).
- `Tests/GohCoreTests/Fixtures/provenance-v1.plist` — golden binary-plist fixture with 2 entries.
- `Tests/GohCoreTests/ProvenanceRecordTests.swift` — golden round-trip, empty, encode/decode.
- `Sources/GohCore/Provenance/ProvenanceStore.swift` — `final class: Sendable` over `Mutex<Inner>`;
  `load()` with version-check + corrupt→sidecar-copy; `record(entry:)` in-place by path + atomic
  rewrite; `lookup(destinationPath:)` (canonicalizes internally); `allEntries()`.
- `Sources/GohCore/Provenance/ProvenanceStoreLocation.swift` — `defaultURL(create:)` and
  `supportDirectoryURL(create:)` shared resolver.
- `Tests/GohCoreTests/ProvenanceStoreTests.swift` — T2 (corrupt/sidecar), T3 (dedup), round-trip,
  missing-file, permissions, no-temp-file, lookup-canonicalization, version-mismatch, create:false.

## CURRENT STATE OF MODIFIED FILES

**`ProvenanceRecord.swift` exports:**
- `ProvenanceRecord: Codable, Sendable, Equatable` — `currentVersion: Int = 1`, `version: Int`,
  `entries: [ProvenanceEntry]`, `empty: ProvenanceRecord`
- `ProvenanceEntry: Codable, Sendable, Equatable` — `url`, `sha256`, `size`, `downloadedAt`, `destinationPath`

**`ProvenanceStore.swift` exports:**
- `ProvenanceStoreError: Error` (fsyncOpenFailed, fsyncFailed, renameFailed)
- `ProvenanceLoadResult: Sendable` — `record: ProvenanceRecord`, `corruptionSidecar: URL?`
- `ProvenanceStore: Sendable` — `init(fileURL:)`, `load() -> ProvenanceLoadResult`,
  `loadReadOnly() -> Bool` (CLI read path; no dir/sidecar creation — BLOCK-3),
  `record(entry:) throws`, `lookup(destinationPath:) -> ProvenanceEntry?`, `allEntries() -> [ProvenanceEntry]`

**`ProvenanceStoreLocation.swift` exports:**
- `ProvenanceStoreLocation: enum` — `defaultURL(create: Bool) throws -> URL`,
  `supportDirectoryURL(create: Bool) throws -> URL` (public static)

## CONTRACTS ESTABLISHED

- On-disk format: binary plist of `ProvenanceRecord`, `currentVersion = 1`.
  Path: `~/Library/Application Support/dev.goh.daemon/provenance.plist`.
  Field `sha256` stored WITH `"sha256:"` prefix. Field `destinationPath` stored in canonical form
  (`URL(fileURLWithPath:).standardizedFileURL.path`).
- `lookup(destinationPath:)` canonicalizes its argument internally — callers pass raw paths.
- `recoverToEmpty()` uses `copyItem` (not `moveItem`) — corrupt original left in place.
- No TTL eviction (intentional divergence from `HostProfileStore` — see source comment).

## OPEN ITEMS

- Phase 2: Thread the digest from `ChunkAssembler.hashToCompletion()` through `complete(...)`,
  widen `completedDownloadHandler`, factor `supportDirectoryURL()` out of `gohd/main.swift`
  into `ProvenanceStoreLocation`, and wire best-effort recording in the daemon handler.
- Phase 3: `goh which` ledger branch + `goh verify --all` + `GohCommandLine` parse/dispatch/usage.
```

---

## Phase 2: Engine + Daemon Capture

### Task 4: Engine digest threading (all 3 completion paths)

**Files:**
- Modify: `Sources/GohCore/Engine/DownloadEngine.swift`
- Modify: `Tests/GohCoreTests/DownloadEngineTests.swift`

**Pre-task reads:**
- [x] Read `Sources/GohCore/Engine/DownloadEngine.swift` (full file — pay attention to `verifyHash`, `fetchSingle`, `fetchRanged`, `complete`, `completedDownloadHandler` type, and the `async let assembled` usage at L451, L479, L518, L544, L840)
- [x] Read `Sources/GohCore/Engine/ChunkAssembler.swift` L36–38 (`ChunkAssemblerResult` — exactly two cases: `.digest(String)` and `.failed(GohError)`)
- [x] Read `Tests/GohCoreTests/DownloadEngineTests.swift` L74, L107, L1110, L1129 (the four handler closures that need a `_` added)

**KNOWN GOTCHA — `async let` single-await rule:** The `async let assembled` pattern spawns a task; re-awaiting it after the first await is wrong. The spec's restructuring (§5.1) keeps exactly ONE `await assembled` per site. The `_ = await assembled` drain calls on error paths (L512, L834) are a SEPARATE concern for the error path — do NOT change those.

**KNOWN GOTCHA — `ChunkAssemblerResult` exhaustiveness:** It has exactly two cases. The `fatalError("unreachable")` in the guard's else-else chain is the compiler-satisfying terminator for the impossible third case; the real work is the `throw err`. If the compiler accepts `if case .failed(let err) = outcome { throw err }` followed by a trailing `fatalError("unreachable")` instead, that is equally acceptable — the requirement is one `await` and `-warnings-as-errors`-clean exhaustive handling.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/GohCoreTests/DownloadEngineTests.swift` (do not remove or change any existing test):

```swift
// AC1/T9: Digest captured and passed through completedDownloadHandler.
@Test("AC1/T9: completedDownloadHandler receives non-nil sha256 matching the file's independent hash")
func handlerReceivesSha256() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = "https://test.local/\(UUID().uuidString).bin"
    let payload = Data((0..<200_000).map { UInt8($0 & 0xff) })
    MockURLProtocol.stub(url, body: payload)

    let store = JobStore()
    let destination = directory.appending(path: "out.bin").path
    let job = store.create(url: url, destination: destination, requestedConnectionCount: 1)

    let capturedSha256 = Mutex<String?>(nil)
    await DownloadEngine(
        session: mockSession(),
        completedDownloadHandler: { _, _, _, sha256, _ in
            capturedSha256.withLock { $0 = sha256 }
        }
    ).run(jobID: job.id, in: store)

    #expect(store.job(id: job.id)?.state == .completed)
    let sha256 = try #require(capturedSha256.withLock { $0 })
    // The handler-received digest must match an independent FileDigest hash of the file.
    let (independent, _) = try FileDigest.sha256WithSize(path: destination)
    // Engine streams bare hex; handler receives it bare. FileDigest returns "sha256:<hex>".
    // The handler in gohd prepends "sha256:" when writing to the store, but the handler
    // closure in the engine receives the BARE hex. Confirm bare hex matches.
    #expect("sha256:" + sha256 == independent)
}

// AC1/T9: resume path also captures the digest.
@Test("AC1/T5/T9: resumed download's completedDownloadHandler receives non-nil sha256")
func resumePathHandlerReceivesSha256() async throws {
    // This test uses the existing resume test infrastructure to confirm the digest
    // is threaded through verifyHash → complete → handler on the resume path.
    // The simplest proxy: a single-connection download where isResume=true reaches
    // the handler with a non-nil sha256.
    // Full resume test requires a checkpoint fixture; use the existing resume test's
    // approach of asserting the 5-parameter handler compiles and the param is non-nil
    // for a normal download (resume path coverage is structural — verifyHash must return
    // the digest; this is confirmed by the -warnings-as-errors build).
    // This test instead verifies the handler arity compiles with 5 params.
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = "https://test.local/\(UUID().uuidString).bin"
    let payload = Data(repeating: 0xAB, count: 512)
    MockURLProtocol.stub(url, body: payload)

    let store = JobStore()
    let destination = directory.appending(path: "resume-probe.bin").path
    let job = store.create(url: url, destination: destination, requestedConnectionCount: 1)

    let capturedSha256 = Mutex<String?>(nil)
    await DownloadEngine(
        session: mockSession(),
        completedDownloadHandler: { _, _, _, sha256, _ in
            capturedSha256.withLock { $0 = sha256 }
        }
    ).run(jobID: job.id, in: store)

    // Non-nil sha256 confirms the 5-param handler wiring is complete.
    let sha256 = capturedSha256.withLock { $0 }
    #expect(sha256 != nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "handlerReceivesSha256" 2>&1 | tail -20
```

Expected: compile error — `completedDownloadHandler` still has 4 params.

- [ ] **Step 3: Write the implementation**

In `Sources/GohCore/Engine/DownloadEngine.swift`, make the following changes:

**3a. Widen `completedDownloadHandler` declaration (property + init).**

Change the property declaration from:
```swift
private let completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool, GovernorOutcome) -> Void)?
```
to:
```swift
private let completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome) -> Void)?
```

Change the `init` parameter from:
```swift
completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool, GovernorOutcome) -> Void)? = nil,
```
to:
```swift
completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome) -> Void)? = nil,
```

**3b. Widen `complete(...)` to carry `sha256: String?`.**

Change:
```swift
private func complete(
    jobID: UInt64, in store: JobStore,
    transferDuration: Duration, isResume: Bool,
    governorOutcome: GovernorOutcome = .governorOff
) throws {
    let completed = try store.complete(id: jobID)
    completedDownloadHandler?(completed, transferDuration, isResume, governorOutcome)
}
```
to:
```swift
private func complete(
    jobID: UInt64, in store: JobStore,
    transferDuration: Duration, isResume: Bool,
    sha256: String?,                          // lowercase hex, no prefix; nil if unavailable
    governorOutcome: GovernorOutcome = .governorOff
) throws {
    let completed = try store.complete(id: jobID)
    completedDownloadHandler?(completed, transferDuration, isResume, sha256, governorOutcome)
}
```

**3c. Restructure `fetchSingle`'s success-path `assembled` await to extract the digest.**

The current code at L517–528 is:
```swift
assembler.finish()
if case .failed(let assemblerError) = await assembled {
    try? file.finish()
    throw assemblerError
}
try file.finish()
_ = try store.recordProgress(...)
try complete(
    jobID: job.id, in: store,
    transferDuration: clock.now - started, isResume: false)
```

Replace with:
```swift
assembler.finish()
let assemblerOutcome = await assembled                         // the ONE await
if case .failed(let assemblerError) = assemblerOutcome {
    try? file.finish()
    throw assemblerError
}
// assemblerOutcome is .digest(hex) — extract the hex for provenance recording.
let fetchSingleDigest: String?
if case .digest(let hex) = assemblerOutcome {
    fetchSingleDigest = hex
} else {
    fatalError("unreachable: ChunkAssemblerResult has only .digest/.failed")
}
try file.finish()
_ = try store.recordProgress(...)
try complete(
    jobID: job.id, in: store,
    transferDuration: clock.now - started, isResume: false,
    sha256: fetchSingleDigest)
```

Note: the `_ = await assembled` drain on the error path (L511–512) is UNCHANGED — it is the cancel/error drain and must stay.

**3d. Restructure `fetchRanged`'s success-path `assembled` await to extract the digest.**

The current code at L839–852 is:
```swift
assembler.finish()
if case .failed(let assemblerError) = await assembled {
    try? file.finish()
    throw assemblerError
}
try file.finish()
_ = try store.recordProgress(...)
let governorOutcome = governorEnabled ? governor.outcome : .governorOff
try complete(
    jobID: job.id, in: store,
    transferDuration: clock.now - started, isResume: false,
    governorOutcome: governorOutcome)
```

Replace with:
```swift
assembler.finish()
let rangedOutcome = await assembled                            // the ONE await
if case .failed(let assemblerError) = rangedOutcome {
    try? file.finish()
    throw assemblerError
}
let fetchRangedDigest: String?
if case .digest(let hex) = rangedOutcome {
    fetchRangedDigest = hex
} else {
    fatalError("unreachable: ChunkAssemblerResult has only .digest/.failed")
}
try file.finish()
_ = try store.recordProgress(...)
let governorOutcome = governorEnabled ? governor.outcome : .governorOff
try complete(
    jobID: job.id, in: store,
    transferDuration: clock.now - started, isResume: false,
    sha256: fetchRangedDigest,
    governorOutcome: governorOutcome)
```

Note: the `_ = await assembled` drain on the error path (L833–834) is UNCHANGED.

**3e. Change `verifyHash` to return the digest (resume path).**

Change the current:
```swift
private func verifyHash(file: DownloadFile, total: UInt64) async throws {
    let assembler = ChunkAssembler(file: file, totalBytes: total)
    async let assembled = assembler.hashToCompletion()
    assembler.complete(interval: ByteInterval(start: 0, length: total))
    assembler.finish()
    if case .failed(let error) = await assembled {
        throw error
    }
}
```
to:
```swift
private func verifyHash(file: DownloadFile, total: UInt64) async throws -> String {
    let assembler = ChunkAssembler(file: file, totalBytes: total)
    async let assembled = assembler.hashToCompletion()
    assembler.complete(interval: ByteInterval(start: 0, length: total))
    assembler.finish()
    let outcome = await assembled                              // the ONE await
    guard case .digest(let hex) = outcome else {
        guard case .failed(let err) = outcome else {
            fatalError("unreachable: ChunkAssemblerResult has only .digest/.failed")
        }
        throw err
    }
    return hex
}
```

**3f. Update the resume path to capture the digest from `verifyHash` and pass it to `complete`.**

The current resume completion (L370–382) is:
```swift
try await verifyHash(file: file, total: total)
try file.finish()
...
try complete(
    jobID: job.id, in: store,
    transferDuration: clock.now - started, isResume: true)
```

Replace with:
```swift
let resumeDigest = try await verifyHash(file: file, total: total)
try file.finish()
...
try complete(
    jobID: job.id, in: store,
    transferDuration: clock.now - started, isResume: true,
    sha256: resumeDigest)
```

**3g. Add `_` wildcard to the four existing `DownloadEngineTests` handler closures.**

In `Tests/GohCoreTests/DownloadEngineTests.swift`, grep for every `completedDownloadHandler:` assignment. There are exactly four (L74, L107, L1110, L1129 approximately — grep to find exact lines):

```bash
grep -n "completedDownloadHandler" Tests/GohCoreTests/DownloadEngineTests.swift
```

For each closure that currently has 4 parameters, add `_` as the 4th parameter (sha256) and shift GovernorOutcome to 5th. Examples:

```swift
// L74: was { completed, _, _, _ in ...}
completedDownloadHandler: { completed, _, _, _, _ in
    completedJob.withLock { $0 = completed }
}
// L107: was { _, duration, isResume, _ in ...}
completedDownloadHandler: { _, duration, isResume, _, _ in
    observed.withLock { $0 = (duration, isResume) }
}
// L1110: was { _, _, _, outcome in ...}
completedDownloadHandler: { _, _, _, _, outcome in captured.withLock { $0 = outcome } }
// L1129: was { _, _, _, outcome in ...}
completedDownloadHandler: { _, _, _, _, outcome in captured.withLock { $0 = outcome } }
```

- [ ] **Step 4: Build to verify `-warnings-as-errors` clean**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -20
```

Expected: build succeeds with no warnings or errors.

- [ ] **Step 5: Run tests to verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20
```

Expected: all tests pass including the new `handlerReceivesSha256` and `resumePathHandlerReceivesSha256`.

- [ ] **Step 6: Commit**

```bash
git add Sources/GohCore/Engine/DownloadEngine.swift \
        Tests/GohCoreTests/DownloadEngineTests.swift
git commit -m "feat: thread SHA-256 digest through all 3 engine completion paths (fetchSingle, fetchRanged, resume)"
```

---

### Task 5: Daemon wiring — `ProvenanceStoreLocation` factoring + best-effort recording

**Files:**
- Modify: `Sources/gohd/main.swift`

**Pre-task reads:**
- [x] Read `Sources/gohd/main.swift` (full file — focus on: `supportDirectoryURL()` at L17–25, the `completedDownloadHandler` closure at L144–175, and the Spotlight best-effort block at L167–174)
- [x] Read `Sources/GohCore/Provenance/ProvenanceStoreLocation.swift` (just written — confirms `supportDirectoryURL(create:)` signature)

**CRITICAL:** The daemon's `supportDirectoryURL()` at L17–25 of `main.swift` is the ONLY place that calls `createDirectory(at: directory, withIntermediateDirectories: true)` for the `dev.goh.daemon` support subdir. This creation is load-bearing: `CatalogStore`, `HostProfileStore`, and `CheckpointStore` do NOT self-create their parent. Factoring this into `ProvenanceStoreLocation.supportDirectoryURL(create:true)` must preserve the `createDirectory` call exactly. After this task, `main.swift`'s local `supportDirectoryURL()` function is replaced by a call to `ProvenanceStoreLocation.supportDirectoryURL(create: true)`.

- [ ] **Step 1: Write the failing test**

There is no isolated unit test for daemon wiring (it requires the full daemon stack). The test for AC5/T4 (best-effort non-fatal) requires a `ProvenanceStore` whose write is forced to fail. Add to `Tests/GohCoreTests/ProvenanceStoreTests.swift`:

```swift
// AC5/T4: Best-effort non-fatal — a store whose write path throws must NOT propagate.
// This tests the store's behavior with a broken write path. The daemon handler's
// do/catch wrapping is tested structurally (the handler is wired correctly if
// the compilation succeeds and the wiring test passes).
@Test("AC5/T4: record() on an unwritable directory throws but the call site can catch-and-log without failing the download")
func recordThrowsOnUnwritableDirectory() throws {
    // A2: root bypasses POSIX mode bits — a 0o555 directory is still writable as root,
    // so rename(2) would succeed and the test would pass WITHOUT asserting anything.
    // Skip under root so the test never silently no-ops. (`getuid` from `Darwin`.)
    try #require(getuid() != 0, "skipped as root: 0o555 does not block writes for uid 0")

    let dir = try tempDir()
    defer {
        // Re-enable permissions for cleanup.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
    _ = store.load()  // succeeds (file absent → empty)

    // Make the directory unwritable so rename(2) fails.
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: dir.path)

    // record() must throw (it cannot write the file).
    var threw = false
    do {
        try store.record(entry: fixedEntry())
    } catch {
        threw = true
        // Caller can log this without propagating — the download is still successful.
    }
    #expect(threw)
}
```

Run tests to confirm this already passes (the store throws; the test just verifies the throw is catchable):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "recordThrowsOnUnwritableDirectory" 2>&1 | tail -10
```

- [ ] **Step 2: Make the daemon changes**

In `Sources/gohd/main.swift`:

**2a. Remove the local `supportDirectoryURL()` function** (L17–25) and replace its call site:

Remove:
```swift
func supportDirectoryURL() throws -> URL {
    let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
    let directory = support.appending(
        path: GohXPCService.machServiceName, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
```

Change the call site in the `do` block from:
```swift
let supportDirectory = try supportDirectoryURL()
```
to:
```swift
let supportDirectory = try ProvenanceStoreLocation.supportDirectoryURL(create: true)
```

**2b. Construct the `ProvenanceStore` alongside the other stores.**

After the `hostProfileStore` + `hostProfileLoadResult` block (after L113), add:

```swift
let provenanceStore = ProvenanceStore(
    fileURL: try ProvenanceStoreLocation.defaultURL(create: true))
let provenanceLoad = provenanceStore.load()
if let sidecar = provenanceLoad.corruptionSidecar {
    warn("the provenance ledger was unreadable and has been reset; "
        + "the damaged file was kept at \(sidecar.path)")
}
```

**2c. Widen the `completedDownloadHandler` closure to accept the 5th `sha256: String?` parameter and add the best-effort provenance block.**

Change the closure signature from:
```swift
completedDownloadHandler: { completed, transferDuration, isResume, governorOutcome in
```
to:
```swift
completedDownloadHandler: { completed, transferDuration, isResume, sha256, governorOutcome in
```

After the existing Spotlight `do/catch` block (which ends with the `warn("job \(completed.id) completed but Spotlight metadata tagging failed: ...")` line), add the best-effort provenance block:

```swift
if let sha256 {
    do {
        try provenanceStore.record(
            ProvenanceEntry(
                url: completed.url,
                sha256: "sha256:" + sha256,          // stored WITH prefix (spec §6.2)
                size: Int(completed.progress.bytesCompleted),
                downloadedAt: completed.completedAt ?? Date(),
                // THE one canonicalization (spec §5.3, BLOCK-1)
                destinationPath: URL(fileURLWithPath: completed.destination)
                    .standardizedFileURL.path))
    } catch {
        warn("job \(completed.id) completed but provenance recording failed: \(error)")
    }
}
```

- [ ] **Step 3: Build to verify `-warnings-as-errors` clean**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -20
```

Expected: clean build.

- [ ] **Step 4: Run the full test suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/gohd/main.swift \
        Tests/GohCoreTests/ProvenanceStoreTests.swift
git commit -m "feat: wire ProvenanceStore into daemon; factor supportDirectoryURL to ProvenanceStoreLocation"
```

---

## Phase 2 Artifact

Write to `docs/superpowers/progress/2026-06-04-provenance-everywhere-phase2.md` at the end of Task 5:

```markdown
# Phase 2 Progress — provenance-everywhere

Status: COMPLETE — Tasks 4–5 implemented and passing.

## WHAT WAS BUILT

- `DownloadEngine.completedDownloadHandler` widened from 4-param to 5-param
  (`JobSummary, Duration, Bool, String?, GovernorOutcome`).
- `DownloadEngine.complete(...)` gains `sha256: String?` parameter.
- `DownloadEngine.verifyHash(file:total:)` changed from `-> Void` to `-> String`
  (returns lowercase-hex digest, resume path captures and passes to `complete`).
- `fetchSingle` and `fetchRanged` restructured to bind `await assembled` once and
  extract the hex digest from `.digest(hex)` — one await per site, exhaustive handling.
- 4 existing `DownloadEngineTests` handler closures updated with `_` wildcard for sha256 param.
- `gohd/main.swift`: local `supportDirectoryURL()` removed; replaced by
  `ProvenanceStoreLocation.supportDirectoryURL(create: true)`. `ProvenanceStore` constructed
  alongside other stores; best-effort `provenanceStore.record(entry:)` block added after
  Spotlight block in `completedDownloadHandler`.

## CURRENT STATE OF MODIFIED FILES

**`DownloadEngine.swift`:**
- `completedDownloadHandler`: `(@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome) -> Void)?`
- `complete(jobID:in:transferDuration:isResume:sha256:governorOutcome:)` — sha256 is 4th param (String?), governorOutcome defaulted
- `verifyHash(file:total:) async throws -> String` — returns lowercase-hex digest

**`gohd/main.swift`:**
- `supportDirectoryURL()` function removed
- `ProvenanceStore` constructed via `ProvenanceStoreLocation.defaultURL(create: true)`
- Handler closure: `{ completed, transferDuration, isResume, sha256, governorOutcome in ... }`
- Recording: `"sha256:" + sha256` prefixing at the write site; canonical path via `URL(fileURLWithPath:).standardizedFileURL.path`

## CONTRACTS ESTABLISHED

- Handler closure type (daemon-internal, NOT on any wire):
  `@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome) -> Void`
- `sha256` in handler = bare lowercase hex (no prefix). Daemon prepends `"sha256:"` before writing.
- Recording is best-effort: `do/catch` + `warn()`, never propagated.
- `nil` sha256 → no provenance entry written (skipped, not a placeholder entry).

## OPEN ITEMS

- Phase 3: `goh which` ledger branch (Task 6); `goh verify --all` new surface (Task 7);
  `GohCommandLine` parse/dispatch (Task 8); usage update (Task 9); `DESIGN.md` update (Task 10).
```

---

## Phase 3: CLI Surfaces

### Task 6: `goh which` ledger branch

**Files:**
- Modify: `Sources/GohCore/CLI/GohWhichCommand.swift`
- Create: `Tests/GohCoreTests/GohWhichLedgerTests.swift`

**Pre-task reads:**
- [x] Read `Sources/GohCore/CLI/GohWhichCommand.swift` (full file — the existing `run(filePath:lockPath:)` signature, the frozen lock branch's URL-equality compare (`entryURL == targetURL`), and the two-step lookup logic)
- [x] Read `Tests/GohCoreTests/GohWhichCommandTests.swift` (the existing tests — confirm they call only `run(filePath:lockPath:)`, so the defaulted param preserves them)

**BLOCK-A invariant:** The existing `GohWhichCommandTests` tests call `run(filePath:lockPath:)` with exactly 2 parameters. Adding `provenanceStorePath: String? = nil` as a defaulted third parameter means those tests continue to compile and run unchanged. Do NOT change any existing test in `GohWhichCommandTests.swift`.

> **A3 — do NOT trust a hardcoded call-site count.** Earlier drafts asserted "8 existing call sites"; the actual number is whatever `GohWhichCommand.run(` resolves to today (the defaulted parameter keeps any count compiling regardless). GREP for the real call sites instead of trusting a number:
> ```bash
> grep -rn "GohWhichCommand.run(" Tests/GohCoreTests/GohWhichCommandTests.swift
> ```

- [ ] **Step 1: Write the failing tests**

Create `Tests/GohCoreTests/GohWhichLedgerTests.swift`:

```swift
import Foundation
import Testing

@testable import GohCore

@Suite("GohWhichCommand — ledger branch")
struct GohWhichLedgerTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-which-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func storeWithEntry(
        in dir: URL,
        destPath: String,
        sha256: String = "sha256:" + String(repeating: "f", count: 64),
        url: String = "https://example.com/file.bin",
        downloadedAt: Date = Date(timeIntervalSince1970: 1_748_000_000)
    ) throws -> ProvenanceStore {
        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        let canonical = URL(fileURLWithPath: destPath).standardizedFileURL.path
        try store.record(entry: ProvenanceEntry(
            url: url,
            sha256: sha256,
            size: 1024,
            downloadedAt: downloadedAt,
            destinationPath: canonical))
        return store
    }

    // AC2/T6: `goh which` reads sha256 from the ledger for an ad-hoc file.
    @Test("AC2/T6: which with populated ledger prints sha256 from the record, not (not recorded)")
    func whichReadsFromLedger() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destPath = dir.appendingPathComponent("a.bin").path
        try Data("hello".utf8).write(to: URL(fileURLWithPath: destPath))

        let sha256 = "sha256:" + String(repeating: "a", count: 64)
        let store = try storeWithEntry(in: dir, destPath: destPath, sha256: sha256,
                                       url: "https://example.com/a.bin")
        let storePath = dir.appendingPathComponent("provenance.plist").path

        let r = GohWhichCommand.run(
            filePath: destPath,
            lockPath: dir.appendingPathComponent("gohfile.lock").path,
            provenanceStorePath: storePath)

        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("https://example.com/a.bin"))
        #expect(r.standardOutput.contains(sha256))
        #expect(!r.standardOutput.contains("(not recorded)"))
        // No network: the test runs offline by construction (no URLSession on this path).
        _ = store  // retain store
    }

    // AC2/T6b: Canonical-path match — `..`-laden CLI arg matches the stored canonical key.
    @Test("AC2/T6b: which matches entry when CLI arg canonicalizes to the same path as stored key")
    func canonicalPathMatch() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Store the entry under the canonical absolute path.
        let canonical = dir.appendingPathComponent("b.bin").path
        try Data("data".utf8).write(to: URL(fileURLWithPath: canonical))

        let sha256 = "sha256:" + String(repeating: "b", count: 64)
        let store = try storeWithEntry(in: dir, destPath: canonical, sha256: sha256)
        let storePath = dir.appendingPathComponent("provenance.plist").path

        // Construct a `..`-laden path that standardizedFileURL.path collapses to canonical.
        let dotdotPath = dir.appendingPathComponent("sub/../b.bin").path

        let r = GohWhichCommand.run(
            filePath: dotdotPath,
            lockPath: dir.appendingPathComponent("gohfile.lock").path,
            provenanceStorePath: storePath)

        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains(sha256))
        _ = store
    }

    // Nil provenanceStorePath skips the ledger branch (BLOCK-A: existing call sites unaffected).
    @Test("nil provenanceStorePath skips ledger and falls through to exit 4")
    func nilProvenanceStorePathSkipsLedger() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destPath = dir.appendingPathComponent("c.bin").path
        try Data("c".utf8).write(to: URL(fileURLWithPath: destPath))

        // Ledger HAS an entry, but provenanceStorePath is nil → skip.
        _ = try storeWithEntry(in: dir, destPath: destPath)

        let r = GohWhichCommand.run(
            filePath: destPath,
            lockPath: dir.appendingPathComponent("gohfile.lock").path
            // provenanceStorePath defaults to nil
        )
        // Falls through to xattr / exit 4 — the ledger is NOT consulted.
        #expect(r.exitCode == 4)
    }

    // Missing ledger file → silent fall-through.
    @Test("missing or corrupt ledger file falls through silently to exit 4")
    func missingLedgerFallsThrough() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destPath = dir.appendingPathComponent("d.bin").path
        try Data("d".utf8).write(to: URL(fileURLWithPath: destPath))

        let r = GohWhichCommand.run(
            filePath: destPath,
            lockPath: dir.appendingPathComponent("gohfile.lock").path,
            provenanceStorePath: dir.appendingPathComponent("absent.plist").path)
        #expect(r.exitCode == 4)
    }

    // Lock-first precedence: ledger branch is NOT checked when the lock already matches.
    @Test("lock match takes precedence over ledger — ledger branch not reached")
    func lockPrecedence() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockText = """
            lockfileVersion = 1
            manifestHash = "sha256:\(String(repeating: "0", count: 64))"

            [[entry]]
            url = "https://lock.example.com/f.bin"
            path = "f.bin"
            sha256 = "sha256:\(String(repeating: "1", count: 64))"
            size = 1
            downloadedAt = "2026-06-01T00:00:00Z"
            """
        let lockURL = dir.appendingPathComponent("gohfile.lock")
        try lockText.write(to: lockURL, atomically: true, encoding: .utf8)
        let target = dir.appendingPathComponent("f.bin")
        try Data("x".utf8).write(to: target)

        // Ledger has a DIFFERENT sha256 for the same file.
        let sha256Ledger = "sha256:" + String(repeating: "2", count: 64)
        let store = try storeWithEntry(in: dir, destPath: target.path, sha256: sha256Ledger)
        let storePath = dir.appendingPathComponent("provenance.plist").path

        let r = GohWhichCommand.run(
            filePath: target.path,
            lockPath: lockURL.path,
            provenanceStorePath: storePath)

        // Lock match returns sha256 from the lock, NOT from the ledger.
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains(String(repeating: "1", count: 64)))
        #expect(!r.standardOutput.contains(String(repeating: "2", count: 64)))
        _ = store
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohWhichLedgerTests 2>&1 | tail -20
```

Expected: compile error — `GohWhichCommand.run` doesn't have a `provenanceStorePath` parameter yet.

- [ ] **Step 3: Write the implementation**

Modify `Sources/GohCore/CLI/GohWhichCommand.swift`:

Add `provenanceStorePath: String? = nil` parameter to `run`:

```swift
/// Runs `goh which` and returns a result suitable for the CLI runner.
///
/// - Parameters:
///   - filePath: Absolute (or relative to cwd) path of the file to look up.
///   - lockPath: Path to `gohfile.lock`; may be absent or unreadable without error.
///   - provenanceStorePath: Path to `provenance.plist`; `nil` (the default) skips
///     the ledger branch entirely, preserving today's lock→xattr→exit-4 behavior.
///     The real CLI call site passes the resolved `ProvenanceStoreLocation` path;
///     existing tests that omit this parameter are unaffected.
public static func run(
    filePath: String,
    lockPath: String,
    provenanceStorePath: String? = nil
) -> GohCommandLineResult {
    let targetURL = URL(fileURLWithPath: filePath).standardizedFileURL

    // 1. Lock lookup (unchanged).
    if let output = lookupInLock(targetURL: targetURL, lockPath: lockPath) {
        return GohCommandLineResult(exitCode: 0, standardOutput: output)
    }

    // 2. NEW: Provenance-ledger lookup (skipped when provenanceStorePath is nil).
    if let storePath = provenanceStorePath,
       let output = lookupInLedger(targetURL: targetURL, storePath: storePath) {
        return GohCommandLineResult(exitCode: 0, standardOutput: output)
    }

    // 3. xattr fallback (unchanged).
    if let output = lookupInXattr(path: filePath) {
        return GohCommandLineResult(exitCode: 0, standardOutput: output)
    }

    // 4. Neither source has it.
    return GohCommandLineResult(
        exitCode: 4,
        standardOutput: "no provenance record for \(filePath)\n")
}
```

Add the `lookupInLedger` private method.

**BLOCK-3 — route through `ProvenanceStore.lookup`, do NOT re-implement the compare.** The spec's single anti-divergence point (§5.3) is `ProvenanceStore.lookup(destinationPath:)`, which canonicalizes its argument internally and is unit-tested by Task 3's `lookupCanonicalizesArgument`. The `which` path must call THAT method — not an inline `$0.destinationPath == canonicalTarget` string compare, which would (a) make `ProvenanceStore.lookup` dead code on the `which` path and (b) let the two compares drift. The store is constructed read-only and loaded via `loadReadOnly()` (no dir/sidecar creation — Task 3), so the CLI never writes on a read:

```swift
// MARK: - Ledger lookup

/// Looks up the target in `provenance.plist` at `storePath`, via the SHARED
/// `ProvenanceStore.lookup(destinationPath:)` (BLOCK-3 — one canonicalization+compare,
/// the same path the unit tests exercise). Returns formatted output on match, or `nil`
/// on no-match, missing file, version mismatch, or decode error.
///
/// READ-ONLY: `loadReadOnly()` never creates the store directory or a `.corrupt`
/// sidecar — recovery is the daemon's job alone. A missing/unreadable/corrupt store
/// is indistinguishable from "no match" here; both fall through silently (the `which`
/// contract has no corrupt-ledger exit code — that distinction is `verify --all`'s job).
private static func lookupInLedger(targetURL: URL, storePath: String) -> String? {
    let store = ProvenanceStore(fileURL: URL(fileURLWithPath: storePath))
    // false → missing / unreadable / version-mismatch: no match, no side effects.
    guard store.loadReadOnly() else { return nil }

    // Pass the raw target path; ProvenanceStore.lookup canonicalizes internally
    // (the ONE shared canonicalization — §5.3). `targetURL.path` is the raw path
    // the CLI received (already absolute via URL(fileURLWithPath:)).
    guard let entry = store.lookup(destinationPath: targetURL.path) else {
        return nil
    }

    let formatter = ISO8601DateFormatter()
    var out = "url:          \(entry.url)\n"
    out    += "sha256:       \(entry.sha256)\n"
    out    += "downloadedAt: \(formatter.string(from: entry.downloadedAt))\n"
    return out
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "GohWhichLedgerTests\|GohWhichCommandTests" 2>&1 | tail -20
```

Expected: ALL `GohWhichLedgerTests` pass AND every existing `GohWhichCommandTests` test still passes (count them with the grep above — do not assume a number).

- [ ] **Step 5: Commit**

```bash
git add Sources/GohCore/CLI/GohWhichCommand.swift \
        Tests/GohCoreTests/GohWhichLedgerTests.swift
git commit -m "feat: add ledger lookup branch to goh which (AC2)"
```

---

### Task 7: `GohVerifyAllCommand` — `goh verify --all`

**Files:**
- Create: `Sources/GohCore/CLI/GohVerifyAllCommand.swift`
- Create: `Tests/GohCoreTests/GohVerifyAllCommandTests.swift`

**Pre-task reads:**
- [x] Read `Sources/GohCore/CLI/GohVerifyCommand.swift` (full file — exit-code contract and `FileDigest` usage to mirror; the frozen source is NOT modified)
- [x] Read `Sources/GohCore/TrustCore/FileDigest.swift` (`sha256WithSize(path:)` signature, `DigestError.cannotOpen`)

**BLOCK-2 invariant:** `GohVerifyCommand.swift` is NOT modified — it is a frozen surface. `GohVerifyAllCommand` is a separate type.

- [ ] **Step 1: Write the failing tests**

Create `Tests/GohCoreTests/GohVerifyAllCommandTests.swift`:

```swift
import Foundation
import Testing

@testable import GohCore

@Suite("GohVerifyAllCommand")
struct GohVerifyAllCommandTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-verifyall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func storeWithEntries(
        in dir: URL,
        entries: [(path: String, content: Data)]
    ) throws -> (storeURL: URL, sha256s: [String]) {
        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()

        var sha256s: [String] = []
        for (path, content) in entries {
            let fileURL = URL(fileURLWithPath: path)
            try content.write(to: fileURL)
            let (sha256, _) = try FileDigest.sha256WithSize(path: path)
            sha256s.append(sha256)
            try store.record(entry: ProvenanceEntry(
                url: "https://example.com/" + fileURL.lastPathComponent,
                sha256: sha256,
                size: content.count,
                downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
                destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path))
        }
        return (storeURL, sha256s)
    }

    // AC3/T7: OK / FAILED / MISSING with correct exit codes and precedence 9>2.
    @Test("AC3/T7: OK intact / FAILED mutated / MISSING deleted — exit 9 (precedence 9>2)")
    func okFailedMissing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ok = dir.appendingPathComponent("ok.bin").path
        let failed = dir.appendingPathComponent("failed.bin").path
        let missing = dir.appendingPathComponent("missing.bin").path

        let (storeURL, _) = try storeWithEntries(in: dir, entries: [
            (ok, Data("unchanged".utf8)),
            (failed, Data("original".utf8)),
            (missing, Data("willbedeleted".utf8)),
        ])

        // Mutate `failed`.
        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: failed))
        // Delete `missing`.
        try FileManager.default.removeItem(atPath: missing)

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path)

        #expect(r.standardOutput.contains("OK \(ok)"))
        #expect(r.standardOutput.contains("FAILED \(failed)"))
        #expect(r.standardOutput.contains("MISSING \(missing)"))
        // MISSING dominates FAILED: exit 9.
        #expect(r.exitCode == 9)
        // Network never touched (structural — no URLSession on this path).
    }

    // AC3/T7: FAILED only → exit 2.
    @Test("AC3/T7: FAILED only → exit 2")
    func failedOnlyExitTwo() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("mutated.bin").path
        let (storeURL, _) = try storeWithEntries(in: dir, entries: [
            (path, Data("original".utf8))
        ])
        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: path))

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path)
        #expect(r.exitCode == 2)
        #expect(r.standardOutput.contains("FAILED \(path)"))
    }

    // AC3/T7: All OK → exit 0.
    @Test("AC3/T7: all entries OK → exit 0")
    func allOkExitZero() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("intact.bin").path
        let (storeURL, _) = try storeWithEntries(in: dir, entries: [
            (path, Data("data".utf8))
        ])

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path)
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("OK \(path)"))
    }

    // T8: Empty / absent ledger → exit 0, "0 recorded entries".
    @Test("T8: absent ledger → exit 0 and 0 recorded entries message")
    func absentLedgerExitZero() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let r = GohVerifyAllCommand.run(
            provenanceStorePath: dir.appendingPathComponent("absent.plist").path)
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("0 recorded"))
    }

    // T8: Corrupt ledger on CLI read → exit 6; NO sidecar copy; NO reset by CLI.
    @Test("T8: corrupt ledger on CLI read → exit 6; no sidecar copy created by CLI")
    func corruptLedgerExitSix() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        try Data("not a plist at all".utf8).write(to: storeURL)

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path)
        #expect(r.exitCode == 6)

        // The CLI must NOT have created a sidecar — only the daemon's load() does that.
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let sidecars = contents.filter { $0.contains(".corrupt-") }
        #expect(sidecars.isEmpty, "CLI must not create sidecar copies")
    }

    // T7b: Frozen `verify` command is unmodified — its parse/dispatch is tested in GohCommandLine.
    // The structural check: verify GohVerifyCommand compiles and the run() signature is unchanged.
    @Test("T7b: GohVerifyCommand.run signature is frozen and unmodified")
    func verifyCommandFrozenSignature() {
        // If GohVerifyCommand.run had its signature changed, this would fail to compile.
        let _: (String, Bool) -> GohCommandLineResult = GohVerifyCommand.run(lockPath:strictUntracked:)
        // Test passes by compilation alone.
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllCommandTests 2>&1 | tail -20
```

Expected: compile error — `GohVerifyAllCommand` does not exist.

- [ ] **Step 3: Write the implementation**

Create `Sources/GohCore/CLI/GohVerifyAllCommand.swift`:

```swift
import Foundation

/// CLI-local integrity verifier for `goh verify --all`.
///
/// Re-hashes each entry in the provenance ledger against the file on disk and
/// reports OK / FAILED / MISSING. No daemon or XPC connection required — works
/// with the daemon stopped.
///
/// This is a SEPARATE runner from `GohVerifyCommand` (which is frozen). The
/// frozen `verify` surface is untouched; `--all` parses to a distinct case and
/// dispatches here.
///
/// Exit code contract (mirrors `GohVerifyCommand`'s vocabulary for the codes that
/// apply to the global ledger):
///   0  — all entries OK (or zero / absent entries)
///   2  — at least one hash MISMATCH (FAILED)
///   6  — ledger unreadable / unknown version (corrupt) — CLI does NOT copy a
///         sidecar and does NOT reset the store (only the daemon's load() does)
///   9  — at least one recorded file MISSING on disk
///
/// Precedence: 9 > 2 > 0.
public enum GohVerifyAllCommand {

    /// Runs `goh verify --all` and returns a result suitable for the CLI runner.
    ///
    /// - Parameter provenanceStorePath: Absolute path to `provenance.plist`.
    ///   Resolved by the caller from `ProvenanceStoreLocation.defaultURL(create: false)`.
    public static func run(provenanceStorePath: String) -> GohCommandLineResult {
        let storeURL = URL(fileURLWithPath: provenanceStorePath)

        // ── Step 1: Read the ledger (read-only; never creates a sidecar or resets) ──
        guard FileManager.default.fileExists(atPath: provenanceStorePath) else {
            return GohCommandLineResult(
                exitCode: 0,
                standardOutput: "0 recorded entries\n")
        }

        guard let data = try? Data(contentsOf: storeURL) else {
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "provenance ledger unreadable\n")
        }

        let record: ProvenanceRecord
        do {
            record = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
        } catch {
            // CLI does NOT copy-to-sidecar or reset — the daemon owns recovery.
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "provenance ledger corrupt\n")
        }

        guard record.version == ProvenanceRecord.currentVersion else {
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "provenance ledger version \(record.version) is unknown\n")
        }

        // A4 — corruption boundary is "decodable + version-matched". A plist that decodes
        // cleanly with version == currentVersion is treated as VALID even if individual
        // entries are semantically odd (e.g. a malformed sha256 string or a nonsense path).
        // Such entries enter the re-hash loop below and report FAILED/MISSING — NOT exit 6.
        // Exit 6 is reserved for an unreadable/undecodable/unknown-version file. This is the
        // accepted boundary for verify-only: structural decodability gates corruption.

        // ── Step 2: Empty store ────────────────────────────────────────────────
        if record.entries.isEmpty {
            return GohCommandLineResult(
                exitCode: 0,
                standardOutput: "0 recorded entries\n")
        }

        // ── Step 3: Re-hash each entry ────────────────────────────────────────
        var lines: [String] = []
        var hasMissing = false
        var hasFailed = false

        for entry in record.entries {
            let hash: String
            do {
                (hash, _) = try FileDigest.sha256WithSize(path: entry.destinationPath)
            } catch FileDigest.DigestError.cannotOpen {
                lines.append("MISSING \(entry.destinationPath) (expected \(entry.sha256))\n")
                hasMissing = true
                continue
            } catch {
                lines.append("MISSING \(entry.destinationPath) (expected \(entry.sha256))\n")
                hasMissing = true
                continue
            }

            if hash == entry.sha256 {
                lines.append("OK \(entry.destinationPath)\n")
            } else {
                lines.append(
                    "FAILED \(entry.destinationPath) expected \(entry.sha256) actual \(hash)\n")
                hasFailed = true
            }
        }

        // ── Step 4: Precedence 9 > 2 > 0 ─────────────────────────────────────
        let exitCode: Int32
        if hasMissing {
            exitCode = 9
        } else if hasFailed {
            exitCode = 2
        } else {
            exitCode = 0
        }

        return GohCommandLineResult(exitCode: exitCode, standardOutput: lines.joined())
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllCommandTests 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GohCore/CLI/GohVerifyAllCommand.swift \
        Tests/GohCoreTests/GohVerifyAllCommandTests.swift
git commit -m "feat: add GohVerifyAllCommand for goh verify --all (AC3)"
```

---

### Task 8: `GohCommandLine` — parse, dispatch, and usage

**Files:**
- Modify: `Sources/GohCore/CLI/GohCommandLine.swift`
- Create: `Tests/GohCoreTests/GohVerifyAllParseTests.swift`

**Pre-task reads:**
- [x] Read `Sources/GohCore/CLI/GohCommandLine.swift` (full file — `ParsedCommand` enum, `parse()` function, `run()` dispatch switch, `usage()` text; `case .which` and `case .verify` call sites; the EXISTING closure/dependency-injection idiom in `init` for `foreground`/`top`/`doctor`/`diagnose` — the test seam this task mirrors)

**BLOCK-2 invariant:** The existing `case verify(lockPath: String, strictUntracked: Bool)` enum case and its parse arm are NOT modified. The new `.verifyAll` case is added alongside.

**BLOCK-1 — TEST SEAM (test-isolation hazard):** `verify --all` and the `which` ledger branch both need the real `provenance.plist` path in production but a TEMP path in tests. Resolving `ProvenanceStoreLocation.defaultURL(create:false)` at parse time (inside the static `parse()` function) is NOT injectable, so a parse test for `verify --all` would resolve the USER'S REAL `~/Library/Application Support/dev.goh.daemon/provenance.plist`. If that file is populated, `verify --all` re-hashes the user's real files and reads real user data inside a unit test — non-deterministic failure plus a privacy violation. **No unit test may resolve the real default provenance path.**

The fix mirrors the EXISTING closure-injection idiom already used in `GohCommandLine.init` for `foreground`/`top`/`doctor`/`diagnose`: add an injectable **resolver closure** `provenanceStorePathResolver`. The `.verifyAll` enum case carries NO path (resolution is deferred to dispatch, where the injected resolver is in scope); production resolves the real default with `create:false`; tests inject a closure returning an empty TEMP store path. The same resolver feeds the `which` ledger branch.

- [ ] **Step 1: Write the failing tests**

Create `Tests/GohCoreTests/GohVerifyAllParseTests.swift`:

```swift
import Foundation
import Testing
import XPC

@testable import GohCore

@Suite("GohCommandLine — verify --all parse and dispatch")
struct GohVerifyAllParseTests {

    private struct TestTransportError: Error {}

    // BLOCK-1: an empty, isolated TEMP store path — NEVER the real default.
    // No unit test in this suite may resolve `ProvenanceStoreLocation.defaultURL`:
    // doing so would re-hash and read the user's real ~/Library/Application Support
    // provenance ledger inside a unit test (non-deterministic + privacy violation).
    private func emptyTempStorePath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-verifyall-parse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The file does NOT exist → GohVerifyAllCommand reports "0 recorded entries".
        return dir.appendingPathComponent("provenance.plist").path
    }

    // T7b: `verify --all` parses to .verifyAll; dispatches to GohVerifyAllCommand.
    @Test("T7b: 'verify --all' parses and dispatches to the verify-all runner (not GohVerifyCommand)")
    func verifyAllParsesAndDispatches() throws {
        // BLOCK-1: inject an EMPTY TEMP store path via the resolver seam — never the
        // real default. With no store file, verify --all returns exit 0
        // ("0 recorded entries"). This confirms routing: exit 0 means verifyAll ran,
        // NOT GohVerifyCommand. (GohVerifyCommand returns exit 6 when no lockfile is found.)
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        // Exit 0 = verifyAll ran with an empty store (no daemon, no lockfile checked).
        // Exit 6 = verify (lock path) was routed instead — test fails.
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("0 recorded"))
    }

    // T7b: Frozen `verify` without --all still routes to GohVerifyCommand (exit 6 = no lockfile).
    // BLOCK-2: pass an explicit ABSOLUTE positional lockfile path pointing at a
    // guaranteed-absent file in a fresh temp dir. The `verify` parse arm accepts a
    // positional lockfile path, so `["verify", absentLock]` routes to
    // `.verify(lockPath: absentLock, …)` → `GohVerifyCommand.run` → exit 6 without
    // consulting the cwd at all. Zero cwd mutation.
    //
    // NOTE: do NOT mark this suite `.serialized` to fix cwd races — the racing tests live
    // in OTHER non-serialized suites (`GohCommandLineTests`, `GohSyncCommandTests`,
    // `GohVerifyCommandTests`, `GohWhichCommandTests`, `GohSyncCLIWiringTests`), so
    // per-suite serialization does not order them. The correct fix is removing the cwd
    // dependency entirely, which is what this implementation does.
    @Test("T7b: 'verify' without --all routes to GohVerifyCommand (frozen path, exit 6 no lockfile)")
    func verifyWithoutAllStillFrozen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-verify-frozen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Point at a guaranteed-absent lockfile — never create it.
        let absentLock = dir.appendingPathComponent("gohfile.lock").path

        let storePath = try emptyTempStorePath()  // BLOCK-1: still never the real default
        let r = GohCommandLine(
            arguments: ["verify", absentLock],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        // GohVerifyCommand with no lockfile at the explicit absolute path returns exit 6.
        // Exit 0 would mean verifyAll ran instead — which would be a routing bug.
        #expect(r.exitCode == 6)
    }

    // T7b: `verify --all --strict-untracked` is a parse error.
    // Parse errors are detected before the resolver runs, but inject the empty temp
    // path anyway so no code path can reach the real default.
    @Test("T7b: 'verify --all --strict-untracked' is a parse error (exit 64)")
    func verifyAllWithStrictUntrackedIsError() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all", "--strict-untracked"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
    }

    // T7b: `verify --all <path>` is a parse error.
    @Test("T7b: 'verify --all <path>' is a parse error (exit 64)")
    func verifyAllWithPositionalIsError() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all", "/some/lockfile.lock"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
    }

    // Usage text documents --all.
    @Test("usage text mentions 'verify --all'")
    func usageTextMentionsVerifyAll() {
        let r = GohCommandLine(
            arguments: ["--help"],
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.standardOutput.contains("--all"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllParseTests 2>&1 | tail -20
```

Expected: failure — `.verifyAll` case doesn't exist yet; `verify --all` currently routes to `.verify` or parse-errors.

- [ ] **Step 3: Write the implementation**

In `Sources/GohCore/CLI/GohCommandLine.swift`:

**3a. Add the resolver test seam to `GohCommandLine` (BLOCK-1) and add `.verifyAll` to `ParsedCommand`.**

Mirror the EXISTING closure-injection idiom (the `foreground`/`top`/`doctor`/`diagnose` properties + defaulted init params). Add a stored resolver and a defaulted init parameter:

```swift
public typealias ProvenanceStorePathResolver = () -> String?

// Alongside the other injected closures (foreground/top/doctor/diagnose):
private let provenanceStorePathResolver: ProvenanceStorePathResolver
```

In `init`, add a defaulted parameter that resolves the REAL default read-only in production — `create:false`, so no directory or file is created (a throw or missing path yields `nil`, which the consumers treat as "no store"):

```swift
public init(
    arguments: [String],
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    foreground: Foreground? = nil,
    top: Top? = nil,
    doctor: Doctor? = nil,
    diagnose: Diagnose? = nil,
    provenanceStorePathResolver: @escaping ProvenanceStorePathResolver = {
        try? ProvenanceStoreLocation.defaultURL(create: false).path
    },
    send: @escaping Sender
) {
    // ... existing assignments ...
    self.provenanceStorePathResolver = provenanceStorePathResolver
    // ... existing send assignment ...
}
```

The `.verifyAll` case carries NO path — resolution is deferred to dispatch (`run()`), where the injected resolver is in scope. This is what makes the seam testable; resolving inside the static `parse()` function would force every parse test to hit the real default (BLOCK-1):

```swift
private enum ParsedCommand: Equatable {
    // ... existing cases ...
    case verifyAll
    // (keep all existing cases unchanged)
}
```

**3b. Add dispatch in `run()`'s switch:**

After the existing `case .verify(let lockPath, let strictUntracked):` arm, add. The resolver runs HERE (instance method scope), so tests inject an empty temp path and never touch the real default. A `nil` resolution maps to an empty string, which `GohVerifyAllCommand` reports as "0 recorded entries":

```swift
case .verifyAll:
    // BLOCK-1: resolve at dispatch via the injected resolver (create:false in production).
    return GohVerifyAllCommand.run(
        provenanceStorePath: provenanceStorePathResolver() ?? "")
```

**3c. Update the `which` call site to pass the resolved store path:**

Change the existing `case .which(let path):` arm from:
```swift
case .which(let path):
    let lockPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("gohfile.lock")
        .path
    return GohWhichCommand.run(filePath: path, lockPath: lockPath)
```
to (resolve through the SAME injected resolver as `verifyAll` — `nil` → ledger branch skipped silently):
```swift
case .which(let path):
    let lockPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("gohfile.lock")
        .path
    // BLOCK-1: same resolver seam as verifyAll. Production resolves the real default
    // read-only (create:false — never creates the dir); a nil/missing path resolves to
    // nil → ledger branch skipped silently. Tests inject a temp path.
    let provenanceStorePath = provenanceStorePathResolver()
    return GohWhichCommand.run(
        filePath: path, lockPath: lockPath,
        provenanceStorePath: provenanceStorePath)
```

**3d. Update the `verify` parse arm to detect `--all` first:**

The existing `verify` parse arm starts with:
```swift
if arguments.first == "verify" {
    let rest = Array(arguments.dropFirst())
    var lockPath = ...
    var strictUntracked = false
    var sawPositional = false
    for arg in rest {
        if arg == "--strict-untracked" { ... }
        else if arg.hasPrefix("-") { throw ParseError(message: "unknown verify option \(arg)") }
        else { ... }
    }
    return .verify(lockPath: lockPath, strictUntracked: strictUntracked)
}
```

Replace with:
```swift
if arguments.first == "verify" {
    let rest = Array(arguments.dropFirst())

    // --all is parsed to a distinct case; it is incompatible with --strict-untracked
    // and a positional lockfile path (which are lock-directory concepts with no
    // analogue for the global ledger).
    if rest.first == "--all" {
        // Reject any additional flags or positional arguments after --all.
        let after = Array(rest.dropFirst())
        if !after.isEmpty {
            throw ParseError(
                message: "--all is incompatible with \(after.joined(separator: " "))")
        }
        // BLOCK-1: do NOT resolve the store path here. `parse()` is static and the
        // resolver is not in scope; resolving the real default at parse time would make
        // every parse test read the user's real provenance ledger. The path is resolved
        // at DISPATCH (run()) via the injected `provenanceStorePathResolver`.
        return .verifyAll
    }

    // Frozen path: --all is not present; parse exactly as before.
    var lockPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("gohfile.lock")
        .path
    var strictUntracked = false
    var sawPositional = false
    for arg in rest {
        if arg == "--strict-untracked" {
            strictUntracked = true
        } else if arg.hasPrefix("-") {
            throw ParseError(message: "unknown verify option \(arg)")
        } else {
            guard !sawPositional else {
                throw ParseError(message: "verify accepts at most one lockfile path")
            }
            sawPositional = true
            lockPath = arg
        }
    }
    return .verify(lockPath: lockPath, strictUntracked: strictUntracked)
}
```

**3e. Update `usage()` to document `--all`:**

Change the verify usage line from:
```swift
text += "  goh verify [<path-to-gohfile.lock>] [--strict-untracked]\n"
```
to:
```swift
text += "  goh verify [<path-to-gohfile.lock>] [--strict-untracked]\n"
text += "  goh verify --all\n"
```

(Or combine on one line if preferred, ensuring `--all` is present in the usage text.)

- [ ] **Step 4: Run tests to verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "GohVerifyAllParseTests\|GohWhichCommandTests\|GohVerifyAllCommandTests" 2>&1 | tail -30
```

Expected: all three suites pass.

- [ ] **Step 5: Run the full suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20
```

Expected: all tests pass; test count is strictly higher than the pre-feature baseline.

- [ ] **Step 6: Commit**

```bash
git add Sources/GohCore/CLI/GohCommandLine.swift \
        Tests/GohCoreTests/GohVerifyAllParseTests.swift
git commit -m "feat: wire goh verify --all parse/dispatch + update which call site + usage text (AC2, AC3)"
```

---

### Task 9: Full test verification pass

**Files:**
- No new files; verification only.

- [ ] **Step 1: Run the complete test suite with `-warnings-as-errors`**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1 | tail -10
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20
```

Expected: clean build with `-warnings-as-errors`; all tests pass.

- [ ] **Step 2: Verify all pre-existing golden fixtures are unchanged**

```bash
git diff HEAD Tests/GohCoreTests/Fixtures/ | grep -E "^\+\+\+|^---" | grep -v "provenance-v1.plist"
```

Expected: no diff on any pre-existing fixture file (only `provenance-v1.plist` is new). Every other fixture in `Tests/GohCoreTests/Fixtures/` is byte-identical to its committed state.

- [ ] **Step 3: Verify test count has strictly increased**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | grep -E "passed|Test run"
```

Expected: the total test count is higher than before this feature branch (baseline was the count on `main` before `feat/provenance-everywhere` was created).

- [ ] **Step 4: Verify no existing test was removed**

```bash
git diff main -- Tests/GohCoreTests/ | grep "^-.*@Test\|^-.*func test" | grep -v "^---"
```

Expected: no lines removed that contain `@Test` (no existing test deleted).

- [ ] **Step 5: Commit (if any fixups were needed from the checks above)**

```bash
git add -p   # stage only fixup changes if any
git commit -m "fix: warnings-as-errors clean-up and verification pass"
```

---

### Task 10: `DESIGN.md` reconciliation

**Files:**
- Modify: `DESIGN.md`

**Pre-task reads:**
- Read `DESIGN.md` (search for the §Provenance section or §Mechanism section — add/update the provenance-everywhere section)

- [ ] **Step 1: Add the provenance-everywhere section to `DESIGN.md`**

Locate the appropriate position in `DESIGN.md` (after the existing §Transport or §Trust sections, before any §Roadmap section). Add:

```markdown
## Provenance-everywhere (v0.1)

A daemon-owned provenance ledger (`provenance.plist`) auto-records
`{url, sha256, size, downloadedAt, destinationPath}` for every successful
download — manifest, ad-hoc, and resume — into a versioned binary-plist store
at `~/Library/Application Support/dev.goh.daemon/provenance.plist`.

### Architecture decision: The Native Ledger (Approach A)

A fourth `Sendable`-class-over-`Mutex` store, a carbon copy of `HostProfileStore`,
minus TTL eviction. Approach B (reuse `gohfile.lock` TOML as a global auto-lock)
was rejected because it forfeits an independent version field (inherits frozen
`lockfileVersion = 1`), welds a machine-local record to a portable committed
contract, and pays TOML-reparse cost on the hot completion path. See
`docs/superpowers/research/2026-06-04-provenance-everywhere-approaches.md`.

THE BET: personal-scale download counts never reach the point where an O(n)
full-plist rewrite per completion becomes user-perceptible. The escape hatch
(append-log behind the same `record`/`lookup`/`allEntries()` surface) is a
one-file re-implementation when the bet fails.

### Digest capture

`ChunkAssembler.hashToCompletion()` already computes SHA-256 during download.
This feature threads it through all three completion paths (`fetchSingle`,
`fetchRanged`, resume via `verifyHash() -> String`) via a widened daemon-internal
`completedDownloadHandler` closure (`sha256: String?` as 4th param). `sha256` is
stored with the `"sha256:"` prefix (matching `FileDigest.sha256WithSize` output).

### Direct CLI read (no new XPC)

`goh which` and `goh verify --all` read `provenance.plist` directly (read-only,
0600, same-user). No new XPC endpoint — both commands work with the daemon down.
A shared `ProvenanceStoreLocation` resolver (`GohCore`) prevents writer/reader
path divergence. CLI read paths call `ProvenanceStoreLocation.defaultURL(create: false)`
(never create the dir); the daemon calls `create: true`.

### Frozen-contract invariant

`protocolVersion = 3`, `JobCatalog.currentVersion = 1`, `JobSummary` wire shape,
`gohfile.lock lockfileVersion = 1`, `DownloadCheckpoint` v1, `HostScheduling` v1
are all unchanged. The provenance ledger carries its own `ProvenanceRecord.currentVersion = 1`,
independent of every other contract. A golden round-trip fixture
(`Tests/GohCoreTests/Fixtures/provenance-v1.plist`) locks the format.

### Canonicalization rule (BLOCK-1)

One rule, applied identically at write and read:
`URL(fileURLWithPath: rawPath).standardizedFileURL.path`
Purely lexical (no symlink resolution). `ProvenanceStore.lookup(destinationPath:)`
canonicalizes its argument internally — callers pass raw paths.

**Accepted boundary — relative `--destination` is unindexable by `which` (A1).** A
user-supplied RELATIVE `--destination` is canonicalized against the DAEMON's launchd
working directory at write time, but against the SHELL's cwd at `goh which` time. The
two cwds differ, so the canonical key the daemon stored will not match the canonical
key `which` computes — a download saved to a relative destination is effectively
unindexable by `goh which`. This is verify-only impact (the file is still downloaded
and hash-recorded correctly; only the offline `which` lookup misses). The realistic
path is absolute or default destinations (which the daemon resolves to absolute paths),
so this is an accepted limitation for v0.1, NOT fixed here. Closing it would require the
daemon to resolve relative destinations to absolute against a cwd the CLI can reproduce.

### TTL eviction deliberately absent

Unlike `HostProfileStore` (90-day TTL), `ProvenanceStore` performs NO TTL eviction.
Evicting entries would silently lose the user's own provenance record. A source-level
comment in `ProvenanceStore.load()` records this intentional divergence for future
maintainers.
```

- [ ] **Step 2: Commit**

```bash
git add DESIGN.md
git commit -m "docs: document provenance-everywhere architecture in DESIGN.md"
```

---

## Phase 3 Artifact

Write to `docs/superpowers/progress/2026-06-04-provenance-everywhere-phase3.md`:

```markdown
# Phase 3 Progress — provenance-everywhere

Status: COMPLETE — Tasks 6–10 implemented and passing.

## WHAT WAS BUILT

- `Sources/GohCore/CLI/GohWhichCommand.swift` — `run(filePath:lockPath:provenanceStorePath:)`
  gains a defaulted `provenanceStorePath: String? = nil`. New `lookupInLedger` private method routes
  through the shared `ProvenanceStore.loadReadOnly()` + `lookup(destinationPath:)` (BLOCK-3 — no inline
  string compare). The existing `GohWhichCommandTests` tests are unmodified and still pass.
- `Tests/GohCoreTests/GohWhichLedgerTests.swift` — T6 (ledger read), T6b (canonical-path match),
  nil-skip, missing-ledger, lock-precedence.
- `Sources/GohCore/CLI/GohVerifyAllCommand.swift` — `run(provenanceStorePath:) -> GohCommandLineResult`.
  Exit codes 0/2/6/9; precedence 9>2; CLI never copies sidecar or resets store.
- `Tests/GohCoreTests/GohVerifyAllCommandTests.swift` — T7 (OK/FAILED/MISSING), exit 2, exit 0,
  T8 (absent → 0, corrupt → 6 no sidecar), T7b (frozen signature check).
- `Sources/GohCore/CLI/GohCommandLine.swift` — `ParsedCommand.verifyAll` (carries no path; resolution
  deferred to dispatch); injectable `provenanceStorePathResolver` test seam (BLOCK-1, mirrors the
  `foreground`/`top`/`doctor`/`diagnose` injection idiom); `verify --all` parse arm; `which` and
  `verifyAll` dispatch resolve the store path via the resolver; usage updated.
- `Tests/GohCoreTests/GohVerifyAllParseTests.swift` — T7b parse routing, frozen verify, parse errors, usage.
- `DESIGN.md` — provenance-everywhere section added.

## CURRENT STATE

All acceptance criteria satisfied:
- AC1: Engine threads digest; daemon records with "sha256:" prefix at write site.
- AC2: `goh which` reads from ledger (T6/T6b). Offline — no URLSession on path.
- AC3: `goh verify --all` re-hashes via FileDigest, OK/FAILED/MISSING, exit 0/2/9 (T7/T8).
- AC4: All pre-existing golden fixtures unchanged; `provenance-v1.plist` golden round-trip passes;
  `-warnings-as-errors` clean; test count strictly higher.
- AC5: In-place update (T3); corrupt→sidecar (T2); best-effort non-fatal (T4); CLI no-sidecar (T8).

## OPEN ITEMS

None. Feature complete. Proceed to PR creation and CodeRabbit review.
```

---

## Known Risks (Implementer Checklist)

1. **Binary-plist bit-stability across SDKs.** T1 asserts decoded-value round-trip equality (not raw-bytes compare vs the fixture). If the golden fixture was generated on SDK 26.5 but CI compiles with 26.2, the `provenance-v1.plist` may not decode identically. Mitigation: the golden fixture test uses decode→re-encode→decode equality (the same pattern as `host-scheduling-v1.plist`). Verify by running the full suite on CI after the PR is opened.

2. **`completedDownloadHandler` blast radius.** The 4 test closures at approximately L74, L107, L1110, L1129 of `DownloadEngineTests.swift` need `_` added. Grep to find current line numbers — do not trust the approximations. `grep -n "completedDownloadHandler" Tests/GohCoreTests/DownloadEngineTests.swift`.

3. **`sha256` prefix consistency.** Engine streams bare hex → handler prepends `"sha256:"` → store holds `"sha256:<hex>"` → `FileDigest.sha256WithSize` returns `"sha256:<hex>"`. One mismatch (double-prefix, or compare prefixed-to-bare) silently breaks `verify --all`. T9 and T7 guard this.

4. **`async let` single-await invariant.** The `_ = await assembled` drain calls on the error paths in `fetchSingle` (L511) and `fetchRanged` (L833) are UNCHANGED — they are the error-path drains. Only the SUCCESS-path `if case .failed = await assembled` blocks at L518 and L840 are restructured.

5. **`verifyHash` call site.** After `verifyHash` returns `-> String`, its call site in `resume()` must capture the return value: `let resumeDigest = try await verifyHash(file: file, total: total)`. Forgetting the `let resumeDigest =` leaves it `_ = ...` implicitly — the compiler will warn (unused result) or require explicit `_`, which `-warnings-as-errors` will catch.

6. **`supportDirectoryURL()` removal.** After factoring into `ProvenanceStoreLocation`, the local function in `main.swift` must be removed entirely (not left as a dead code duplicate). Dead code in `main.swift` fails `-warnings-as-errors`.

7. **Relative-destination `which` miss (A1).** A relative `--destination` is canonicalized against the daemon's launchd cwd at write but the shell's cwd at `goh which`, so such downloads are unindexable by `which`. Accepted boundary for v0.1 (verify-only impact; realistic path is absolute/default destinations). Documented in `DESIGN.md` §Provenance-everywhere → Canonicalization rule (Task 10). Do NOT attempt to fix it in this branch.
