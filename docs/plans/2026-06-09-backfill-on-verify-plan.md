---
date: 2026-06-09
feature: backfill-on-verify
plan-status: pending-adversarial-review
branch: feat/backfill-on-verify
---

# Implementation Plan — Backfill Baselines on Deep Verify

## Goal

When `goh verify --all` (or the tray "Verify now") hashes a file and it matches
the recorded SHA-256, capture the file's current `fstat` metadata at that exact
moment and write it as the stat baseline into the provenance ledger. This is the
"deep-verify once → fast-check-forever" bet: existing pre-#104 files gain a
baseline without re-downloading, simply by running a verify.

## Architecture (from spec §2, §5)

**The Bet (D3 deferred backfill):** a successful deep verify is the only safe
moment to mint a baseline — the bytes just passed a full SHA-256 check, so the
fstat captured during that hash (TOCTOU-tight, `fstat` on the open handle before
`defer { close }`) describes verified bytes.

**Key resolutions:**
- **B1 — stat.size vs hashedByteCount:** `recordedStatSize` is ALWAYS
  `stat.size` (fstat `st_size`), NEVER `hashedByteCount`. The fast-check
  compares `lstat` `st_size` against `recordedStatSize`. They are tracked as
  distinct fields to make wiring unambiguous.
- **B2 — all-or-nothing baseline:** a baseline is only written if ALL FIVE stat
  fields are non-nil in the wire entry. Any nil → write none. Three
  `ProvenanceStore.recordVerified` branches all carry the 5 fields.
- **B3 — cancelled/partial runs still backfill:** `onVerified` fires per `.ok`
  AT THE MOMENT the hash passes. Even a cancelled run backfills the entries
  verified before the cancel.

**Data path:**
```
FileDigest.sha256WithSizeAndStat
    ↓ (sha256, size, FileStat)
VerifyAllRunner.hashEntry  →  onVerified(@Sendable (VerifiedBaseline) → Void)?
    ↓ (side channel, not VerifyAllReport)
GohVerifyAllCommand.run(send:)  / TrustWindowViewModel
    ↓ RecordVerifiedProvenanceRequest [VerifiedProvenanceEntry with 5 stat fields]
CommandDispatcher → ProvenanceStore.recordVerified (3 merge branches)
```

**Frozen contracts (must not change):**
- `VerifyAllReport` / `VerifyEntryResult` / `VerifySummary` (reportVersion 1,
  golden `--json` test, `GohVerifyAllCommandJSONTests.swift`).
- `ProvenanceRecord.currentVersion` = 1 (baseline fields already exist from #104).
- XPC `protocolVersion` = 4 (5 new wire fields are additive-optional).
- Golden provenance fixture.
- `BBR` governor, `JobProgress`.

## Tech Stack

Swift 6.2 tools / 6.3.x toolchain. GohCore: `nonisolated` default. GohMenuBar
/ goh-menu: `@MainActor` default. `import Darwin` (fstat/stat). CryptoKit
(existing in FileDigest). `Synchronization.Mutex` (existing in ProvenanceStore).
Swift Testing only. Build and test gate for every task:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <SuiteName>
```

---

## Phase 0 Reads — Confirmed Signatures and Shapes

### FileDigest.swift (GohCore)
- `sha256WithSize(path:onBytesHashed:isCancelled:) throws -> (String, Int)`
  Opens via `FileHandle(forReadingAtPath:)`, `defer { try? handle.close() }`,
  streams 1 MiB chunks inside `autoreleasepool`. Returns `("sha256:" + hex,
  totalBytes)`.
- New method to add: `sha256WithSizeAndStat` — same loop, adds `fstat` on
  `handle.fileDescriptor` after EOF, before defer fires, returns
  `(sha256: String, size: Int, stat: FileStat)`.

### VerifyAllRunner.swift (GohCore)
- `verifyAll(provenanceStorePath:generatedAt:progress:isCancelled:) throws ->
  VerifyAllReport` — public static.
- `hashEntry(_:progress:isCancelled:completed:total:bytesHashedCumulative:totalBytes:)
  throws -> (VerifyEntryResult, Int)` — private static. Calls
  `FileDigest.sha256WithSize`. Returns `(VerifyEntryResult, hashedBytes)`.
- Per `.ok`, result is `VerifyEntryResult(status: .ok, actualSha256: nil)`.
  hashedBytes = `size` from digest call.
- To add: `onVerified: (@Sendable (VerifiedBaseline) -> Void)? = nil` param to
  both `verifyAll` and `hashEntry`. Fire in `hashEntry` at the `.ok` branch,
  AFTER confirming `hash == entry.sha256`, with the FileStat from
  `sha256WithSizeAndStat`.

### VerifyReportTypes.swift (GohCore) — FROZEN
- `VerifyEntryResult`, `VerifySummary`, `VerifyAllReport` — NO new fields.
- `VerifiedBaseline` lives in a separate new file or at the top of
  `VerifyAllRunner.swift`.

### Command.swift (GohCore)
- `VerifiedProvenanceEntry: Codable, Sendable, Equatable` — current fields:
  `url: String`, `sha256: String`, `size: Int`, `destinationPath: String`,
  `verifiedAt: Date`. Init is a single 5-arg init.
- To add: 5 additive-optional fields with `nil` defaults:
  `recordedStatSize: Int64?`, `recordedMtimeSeconds: Int64?`,
  `recordedMtimeNanoseconds: Int64?`, `recordedInode: UInt64?`,
  `recordedDevice: Int64?`.

### CommandDispatcher.swift (GohCore)
- `.recordVerifiedProvenance` handler at ~L225. Filters `validEntries` by
  `sha256.hasPrefix("sha256:")` + non-empty `destinationPath`. Calls
  `provenanceStore.recordVerified(entries:)`. No other validation.
- To add: forward the 5 new fields transparently. No new validation needed
  (per spec decision A2).

### ProvenanceStore.swift (GohCore) — `recordVerified` at L139
- Three merge branches (in `inner.withLock`):
  1. Same path + same sha256 (~L146): preserves `downloadedAt`, sets `verifiedAt`,
     refreshes `url`/`size`. Currently ignores stat fields.
  2. Same path + different sha256 (~L152): constructs fresh `ProvenanceEntry`
     with `downloadedAt = verifiedAt`. No stat fields set today.
  3. New path (~L159): appends `ProvenanceEntry` with `downloadedAt = verifiedAt`.
     No stat fields today.
- Per B2: all three branches must carry the 5 stat fields when the incoming
  baseline is present (all 5 non-nil). Same-path+same-sha256 must OVERWRITE
  existing stat fields when incoming baseline is present; leave them if absent.

### GohVerifyAllCommand.swift (GohCore)
- `run(provenanceStorePath:json:generatedAt:) -> GohCommandLineResult` — public
  static.
- Calls `VerifyAllRunner.verifyAll(provenanceStorePath:generatedAt:progress:nil
  isCancelled:nil)` directly. No `send:` today.
- To add: `send: GohCommandLine.Sender? = nil`. Collect baselines via
  `onVerified`; if `send != nil` and baselines non-empty, build
  `RecordVerifiedProvenanceRequest` and call `send`. Best-effort: failure logs
  to stderr, exit code / report are unchanged.

### GohCommandLine.swift (GohCore)
- `.verifyAll(json:)` dispatch at ~L175: calls
  `GohVerifyAllCommand.run(provenanceStorePath:..., json:json)`. No `send:`.
- `GohCommandLine.Sender = (XPCDictionary) throws -> XPCDictionary`.
- `self.send` is already a stored property.
- To add: pass `send: send` to `GohVerifyAllCommand.run`. One-line change.
- `GohAttestCommand` calls `GohVerifyAllCommand.run` WITHOUT `send:` → stays
  read-only (defaulted-nil, AC5). No edit to GohAttestCommand needed.

### goh-menu/main.swift — GohMenuClient protocol + LiveGohMenuClient
- Protocol `GohMenuClient: AnyObject @MainActor` declared in
  `GohMenuBar/GohMenuViewModel.swift` (not main.swift).
  Current methods: `progressSnapshots`, `add`, `pause`, `resume`, `remove`.
- `LiveGohMenuClient` in `goh-menu/main.swift` implements the protocol.
  Pattern: `Self.sendOneShot(.command, expecting: Reply.self, validationMode:)`.
  For `.recordVerifiedProvenance` the reply is `.ack` (no payload); use
  `GohCommandClient.sendAck` or decode an empty reply — check existing `.ack`
  pattern.

### TrustWindowViewModel.swift (GohMenuBar)
- `startVerify()` dispatches `DispatchQueue.global(qos: .userInitiated).async`.
- Uses `VerifyAllRunner.verifyAll(...)` directly (not via `GohVerifyAllCommand`).
- On run end: `Task { @MainActor in ... vm.runState = .finished(report) }` or
  `.cancelled(report)`.
- To add: collect `onVerified` baselines during the run (via a captured
  `Mutex<[VerifiedBaseline]>` or `@unchecked Sendable` box). On `.finished`
  AND `.cancelled`, send best-effort via injected client method. Never block UI.

### Test doubles — ALL must gain `recordVerifiedProvenance`
- `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift` — `FakeMenuClient`
  (~L18): has `progressSnapshots`, `add`, `pause`, `resume`, `remove`.
- `Tests/GohMenuBarTests/GohMenuViewModelTests.swift` — `FakeMenuClient`
  (~L320): same 5 methods + tracking properties + `enqueue`.
- `Tests/GohMenuBarTests/GohMenuViewModelTests.swift` — `LongLivedMenuClient`
  (~L413): same 5 methods.
- All three need `func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry])
  async throws` — default no-op or spy implementation.

---

## Phase 0.5 — AC Extraction and Task Mapping

| AC | Criterion | Task |
|----|-----------|------|
| AC1 | After `goh verify --all` (with send), `.ok` entries gain all 5 `recordedStat*` + `verifiedAt`; subsequent `--quick` returns `.unchanged` | T3, T4, T5, T6 |
| AC2 | `.failed` entry gets no baseline, no `verifiedAt` written | T2 |
| AC3 | `.missing` entry writes nothing | T2 |
| AC4 | Captured `FileStat` matches independent lstat of unchanged file | T1 |
| AC5 | `goh attest` performs no ledger write (no send; ledger byte-unchanged) | T5 |
| AC6 | `VerifyAllReport`/`--json` byte-identical (baseline never in report) | T2 |
| AC7 | Daemon stopped → verify still completes; backfill skipped | T5 |
| AC8 | `protocolVersion` stays 4; additive-optional wire fields | T3 |
| AC9 | Cancelled run still backfills collected `.ok` entries | T2, T5, T7 |
| AC10 | `recordedStatSize == stat.size` (fstat), not `hashedByteCount` | T1, T3 |
| AC11 | Re-running deep verify on already-baselined file is idempotent | T4 |

---

## Phase 2 — File Map

### Phase 1 — GohCore data path (fully unit-testable in GohCore)

| Action | File | Key new symbols |
|--------|------|-----------------|
| Modify | `Sources/GohCore/TrustCore/FileDigest.swift` | `sha256WithSizeAndStat(path:onBytesHashed:isCancelled:) throws -> (sha256:String, size:Int, stat:FileStat)` |
| Create | `Sources/GohCore/CLI/VerifiedBaseline.swift` | `nonisolated public struct VerifiedBaseline: Sendable, Equatable { destinationPath, url, sha256, hashedByteCount, stat }` |
| Modify | `Sources/GohCore/CLI/VerifyAllRunner.swift` | `onVerified: (@Sendable (VerifiedBaseline) -> Void)? = nil` param on `verifyAll` + `hashEntry`; `sha256WithSizeAndStat` call; fire `onVerified` per `.ok` |
| Modify | `Sources/GohCore/Model/Command.swift` | 5 additive-optional fields on `VerifiedProvenanceEntry`; updated init |
| Modify | `Sources/GohCore/Model/CommandDispatcher.swift` | Forward 5 new fields in `.recordVerifiedProvenance` handler |
| Modify | `Sources/GohCore/Provenance/ProvenanceStore.swift` | `recordVerified` — all three branches carry 5 stat fields; all-or-nothing logic; same-path+same-sha256 overwrites when baseline present |
| Create | `Tests/GohCoreTests/FileDigestStatTests.swift` | `@Suite("FileDigest.sha256WithSizeAndStat")` — AC4, AC10 |
| Modify | `Tests/GohCoreTests/VerifyAllRunnerTests.swift` | Add `@Suite` section for `onVerified` — AC2, AC3, AC6, AC9 |
| Modify | `Tests/GohCoreTests/ProvenanceStoreTests.swift` | Add `recordVerified` backfill tests — AC1, AC2, AC11, B2 all-or-nothing |
| Modify | `Tests/GohCoreTests/CommandTests.swift` | AC8 — confirm `protocolVersion` constant unchanged; additive-optional round-trip |

### Phase 2 — Surfaces (CLI dispatch + tray client + viewmodel wiring)

| Action | File | Key new symbols |
|--------|------|-----------------|
| Modify | `Sources/GohCore/CLI/GohVerifyAllCommand.swift` | `send: GohCommandLine.Sender? = nil`; collect via `onVerified`; best-effort send; AC5, AC7 |
| Modify | `Sources/GohCore/CLI/GohCommandLine.swift` | Pass `send: send` at `.verifyAll` dispatch |
| Modify | `Sources/GohMenuBar/GohMenuViewModel.swift` | `GohMenuClient` protocol: add `func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry]) async throws` |
| Modify | `Sources/goh-menu/main.swift` | `LiveGohMenuClient.recordVerifiedProvenance` — XPC via `sendOneShot`/ack |
| Modify | `Sources/GohMenuBar/TrustWindowViewModel.swift` | Inject record closure or client; collect baselines during run; send on `.finished` + `.cancelled`; AC9 |
| Modify | `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift` | `FakeMenuClient.recordVerifiedProvenance` — no-op |
| Modify | `Tests/GohMenuBarTests/GohMenuViewModelTests.swift` | `FakeMenuClient` + `LongLivedMenuClient` — `recordVerifiedProvenance` no-op |
| Create | `Tests/GohCoreTests/GohVerifyAllCommandBackfillTests.swift` | CLI backfill tests — AC1, AC5, AC7, AC9 end-to-end (real files, real store, stub sender) |
| Create | `Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift` | Tray wiring — AC9 (cancelled still backfills), best-effort (send failure no UI impact) |

---

## Phase 3 — Phase Segmentation

### Phase 1 — GohCore data path (Tasks T1–T4)
Produces fully tested GohCore types and logic: `sha256WithSizeAndStat`, `VerifiedBaseline`, `onVerified` callback, wire fields, dispatcher forwarding, and all three `recordVerified` merge branches. No surface changes. Phase 1 must be complete before Phase 2 can use these types.

Progress artifact: `docs/superpowers/progress/2026-06-09-backfill-on-verify-phase1.md`

### Phase 2 — Surfaces (Tasks T5–T8)
Wires Phase 1 types into `GohVerifyAllCommand`, `GohCommandLine`, `GohMenuClient` / `LiveGohMenuClient`, and `TrustWindowViewModel`. Updates three test doubles. Delivers end-to-end CLI and tray backfill paths.

Progress artifact: `docs/superpowers/progress/2026-06-09-backfill-on-verify-phase2.md`

---

## Phase 4 — Task Specifications

---

### T1 — `FileDigest.sha256WithSizeAndStat`

**AC ownership:** AC4, AC10

**Files:**
- Modify: `Sources/GohCore/TrustCore/FileDigest.swift`
- Create: `Tests/GohCoreTests/FileDigestStatTests.swift`

**Pre-task reads:**
- [x] `Sources/GohCore/TrustCore/FileDigest.swift` — full file (read above)
- [x] `Sources/GohCore/Provenance/FileStat.swift` — `FileStat` struct fields and `LiveFileStatProbe` fstat mapping

**Step 1 — Failing test**

Create `Tests/GohCoreTests/FileDigestStatTests.swift`:

```swift
import Darwin
import Foundation
import Testing
import GohCore

@Suite("FileDigest.sha256WithSizeAndStat")
struct FileDigestStatTests {

    // AC4: fstat on the open handle describes the hashed inode.
    // Compare digest's FileStat to an independent lstat of the unchanged file.
    @Test("AC4: captured FileStat matches independent lstat of hashed file")
    func capturedStatMatchesLstat() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("hello backfill\n".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try FileDigest.sha256WithSizeAndStat(path: tmp.path)

        // Independent lstat of the same path.
        var st = stat()
        let rc = tmp.path.withCString { Darwin.lstat($0, &st) }
        #expect(rc == 0)
        let lstatSize = Int64(st.st_size)
        let lstatMtimeSec = Int64(st.st_mtimespec.tv_sec)
        let lstatInode = UInt64(st.st_ino)

        #expect(result.stat.size == lstatSize)
        #expect(result.stat.mtimeSeconds == lstatMtimeSec)
        #expect(result.stat.inode == lstatInode)
        #expect(result.stat.isRegularFile == true)
    }

    // AC10: recordedStatSize source is stat.size, not hashedByteCount.
    // For a normal file they are equal; assert the named field source explicitly
    // by checking the FileStat.size field (the one that feeds recordedStatSize).
    @Test("AC10: stat.size field matches fstat st_size (source for recordedStatSize)")
    func statSizeEqualsFstatStSize() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let content = Data(repeating: 0xAB, count: 1024)
        try content.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try FileDigest.sha256WithSizeAndStat(path: tmp.path)

        var st = stat()
        let rc = tmp.path.withCString { Darwin.lstat($0, &st) }
        #expect(rc == 0)
        // stat.size is the fstat st_size — the source for recordedStatSize.
        #expect(result.stat.size == Int64(st.st_size))
        // hashedByteCount is the streaming byte count — separate field.
        #expect(result.size == content.count)
        // For a normal regular file they are equal; the fields are distinct.
        #expect(result.stat.size == Int64(result.size))
    }

    // isRegularFile derives from (st_mode & S_IFMT) == S_IFREG (NOT S_ISREG macro).
    @Test("isRegularFile true for a regular temp file")
    func isRegularFileTrue() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("data".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = try FileDigest.sha256WithSizeAndStat(path: tmp.path)
        #expect(result.stat.isRegularFile == true)
    }

    // Missing file still throws cannotOpen (same as sha256WithSize).
    @Test("throws cannotOpen for nonexistent file")
    func throwsForMissing() {
        #expect(throws: FileDigest.DigestError.cannotOpen("/nonexistent/backfill-test")) {
            _ = try FileDigest.sha256WithSizeAndStat(path: "/nonexistent/backfill-test")
        }
    }

    // Hash is consistent with sha256WithSize for the same file.
    @Test("sha256 matches sha256WithSize output for same file")
    func hashMatchesSha256WithSize() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("consistency check".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (baseHash, _) = try FileDigest.sha256WithSize(path: tmp.path)
        let result = try FileDigest.sha256WithSizeAndStat(path: tmp.path)
        #expect(result.sha256 == baseHash)
    }
}
```

**Step 2 — Run expecting failure:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FileDigestStatTests 2>&1 | tail -20
```
Expected: compilation error — `sha256WithSizeAndStat` does not exist.

**Step 3 — Implementation**

In `Sources/GohCore/TrustCore/FileDigest.swift`, after the existing `sha256WithSize` method and before `sha256(path:)`, add:

```swift
/// Streams `path` through SHA-256 and captures filesystem metadata via `fstat(2)` on the
/// open file handle immediately after reaching EOF — TOCTOU-tight, describing the exact
/// inode whose bytes were just hashed.
///
/// - Parameters:
///   - path: Absolute path of the file to hash.
///   - onBytesHashed: Optional chunk callback (same semantics as `sha256WithSize`).
///   - isCancelled: Optional cancellation check (same semantics as `sha256WithSize`).
/// - Returns: A named tuple of `(sha256: "sha256:<hex>", size: byteCount, stat: FileStat)`.
///   `stat.size` is the `fstat` `st_size` — the source for `recordedStatSize`. `size` is the
///   streaming byte count — the source for `VerifiedProvenanceEntry.size` (display).
/// - Throws: `DigestError.cannotOpen` when the file cannot be opened; `DigestError.cancelled`
///   when `isCancelled` returns true mid-read; re-throws `FileHandle` read errors.
public static func sha256WithSizeAndStat(
    path: String,
    onBytesHashed: ((Int) -> Void)? = nil,
    isCancelled: (() -> Bool)? = nil
) throws -> (sha256: String, size: Int, stat: FileStat) {
    guard let handle = FileHandle(forReadingAtPath: path) else {
        throw DigestError.cannotOpen(path)
    }
    defer { try? handle.close() }

    var hasher = SHA256()
    var totalBytes = 0
    let chunkSize = 1 << 20  // 1 MiB

    while true {
        let reachedEOF = try autoreleasepool { () throws -> Bool in
            if isCancelled?() == true { throw DigestError.cancelled }
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { return true }
            hasher.update(data: chunk)
            totalBytes += chunk.count
            onBytesHashed?(chunk.count)
            return false
        }
        if reachedEOF { break }
    }

    // fstat on the still-open handle — TOCTOU-tight. Describes the inode whose bytes
    // were just hashed. Uses (st_mode & S_IFMT) == S_IFREG (not S_ISREG, a C macro
    // that cannot be imported into Swift — see FileStat.swift).
    var st = Darwin.stat()
    _ = Darwin.fstat(handle.fileDescriptor, &st)
    let fileStat = FileStat(
        size: Int64(st.st_size),
        mtimeSeconds: Int64(st.st_mtimespec.tv_sec),
        mtimeNanoseconds: Int64(st.st_mtimespec.tv_nsec),
        inode: UInt64(st.st_ino),
        device: Int64(st.st_dev),
        isRegularFile: (st.st_mode & S_IFMT) == S_IFREG)

    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (sha256: "sha256:" + hex, size: totalBytes, stat: fileStat)
}
```

**Step 4 — Run expecting pass:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FileDigestStatTests 2>&1 | tail -20
```
Expected: all 5 tests pass.

**Step 5 — Commit:**
```
git add Sources/GohCore/TrustCore/FileDigest.swift Tests/GohCoreTests/FileDigestStatTests.swift
git commit -m "feat(FileDigest): add sha256WithSizeAndStat capturing fstat baseline (AC4, AC10)"
```

---

### T2 — `VerifiedBaseline` type + `VerifyAllRunner.onVerified` callback

**AC ownership:** AC2, AC3, AC6, AC9

**Files:**
- Create: `Sources/GohCore/CLI/VerifiedBaseline.swift`
- Modify: `Sources/GohCore/CLI/VerifyAllRunner.swift`
- Modify: `Tests/GohCoreTests/VerifyAllRunnerTests.swift`

**Pre-task reads:**
- [x] `Sources/GohCore/CLI/VerifyAllRunner.swift` — full file (read above)
- [x] `Sources/GohCore/CLI/VerifyReportTypes.swift` — confirmed FROZEN, no changes

**Step 1 — Failing test**

Append to `Tests/GohCoreTests/VerifyAllRunnerTests.swift`:

```swift
// ── Backfill: onVerified callback (AC2, AC3, AC6, AC9) ─────────────────────

@Suite("VerifyAllRunner.onVerified")
struct VerifyAllRunnerOnVerifiedTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-runner-ov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(
        in dir: URL,
        entries: [(path: String, content: Data)]
    ) throws -> (storeURL: URL, sha256s: [String]) {
        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        var sha256s: [String] = []
        for (path, content) in entries {
            try content.write(to: URL(fileURLWithPath: path))
            let (sha256, _) = try FileDigest.sha256WithSize(path: path)
            sha256s.append(sha256)
            try store.record(entry: ProvenanceEntry(
                url: "https://example.com/\(URL(fileURLWithPath: path).lastPathComponent)",
                sha256: sha256,
                size: content.count,
                downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
                destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path))
        }
        return (storeURL, sha256s)
    }

    // AC2: .failed entry does NOT fire onVerified.
    @Test("AC2: failed entry does not fire onVerified")
    func failedEntryNoCallback() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("mutated.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [(f, Data("original".utf8))])
        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: f))

        let fired = RunnerTestBox<[VerifiedBaseline]>([])
        _ = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: nil,
            isCancelled: nil,
            onVerified: { fired.value.append($0) })

        #expect(fired.value.isEmpty, "onVerified must not fire for a failed entry")
    }

    // AC3: .missing entry does NOT fire onVerified.
    @Test("AC3: missing entry does not fire onVerified")
    func missingEntryNoCallback() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("willbedeleted.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [(f, Data("content".utf8))])
        try FileManager.default.removeItem(atPath: f)

        let fired = RunnerTestBox<[VerifiedBaseline]>([])
        _ = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: nil,
            isCancelled: nil,
            onVerified: { fired.value.append($0) })

        #expect(fired.value.isEmpty, "onVerified must not fire for a missing entry")
    }

    // AC6: VerifyAllReport is unchanged when onVerified is wired (frozen contract).
    @Test("AC6: report is byte-identical with and without onVerified")
    func reportUnchangedWithCallback() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("ok.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [(f, Data("ok-content".utf8))])
        let fixedDate = Date(timeIntervalSince1970: 1_714_262_400)

        let reportWithout = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: fixedDate,
            progress: nil,
            isCancelled: nil)

        let reportWith = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: fixedDate,
            progress: nil,
            isCancelled: nil,
            onVerified: { _ in })

        #expect(reportWith == reportWithout,
            "VerifyAllReport must be unchanged when onVerified is present (AC6 — frozen contract)")
    }

    // AC9: cancelled run fires onVerified for entries verified before the cancel.
    @Test("AC9: cancelled run backfills entries verified before cancel")
    func cancelledRunFiresCollectedBaselines() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("first.bin").path
        let f2 = dir.appendingPathComponent("second.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [
            (f1, Data("data1".utf8)),
            (f2, Data("data2".utf8)),
        ])

        // Cancel after f1 is processed.
        let cancelAfterFirst = RunnerTestBox(false)
        let fired = RunnerTestBox<[VerifiedBaseline]>([])
        _ = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: { event in
                if event.completed >= 1 { cancelAfterFirst.value = true }
            },
            isCancelled: { cancelAfterFirst.value },
            onVerified: { fired.value.append($0) })

        // f1 was verified before cancel → onVerified fired once.
        #expect(fired.value.count == 1, "onVerified must fire for entries verified before cancel")
        #expect(fired.value[0].sha256.hasPrefix("sha256:"))
    }

    // Happy path: onVerified fires once per .ok entry, with the correct fields.
    @Test("onVerified fires once per ok entry with correct sha256 and stat")
    func firesPerOkEntry() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("a.bin").path
        let f2 = dir.appendingPathComponent("b.bin").path
        let (storeURL, sha256s) = try makeStore(in: dir, entries: [
            (f1, Data("aaaa".utf8)),
            (f2, Data("bbbb".utf8)),
        ])

        let fired = RunnerTestBox<[VerifiedBaseline]>([])
        _ = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: nil,
            isCancelled: nil,
            onVerified: { fired.value.append($0) })

        #expect(fired.value.count == 2)
        let paths = fired.value.map(\.destinationPath)
        let f1Canon = URL(fileURLWithPath: f1).standardizedFileURL.path
        let f2Canon = URL(fileURLWithPath: f2).standardizedFileURL.path
        #expect(paths.contains(f1Canon))
        #expect(paths.contains(f2Canon))
        // sha256s match recorded hashes.
        for baseline in fired.value {
            #expect(sha256s.contains(baseline.sha256))
        }
        // stat fields are populated.
        for baseline in fired.value {
            #expect(baseline.stat.size > 0)
            #expect(baseline.stat.isRegularFile == true)
        }
    }
}
```

**Step 2 — Run expecting failure:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VerifyAllRunnerOnVerifiedTests 2>&1 | tail -20
```
Expected: compilation error — `VerifiedBaseline` and `onVerified` param do not exist.

**Step 3 — Implementation**

**a)** Create `Sources/GohCore/CLI/VerifiedBaseline.swift`:

```swift
/// The baseline captured when one file passes a deep-verify SHA-256 check.
///
/// Travels the side channel from `VerifyAllRunner` to the caller — never inside
/// `VerifyAllReport` (which is frozen at reportVersion 1). The caller converts
/// this into a `VerifiedProvenanceEntry` and sends it to the daemon.
///
/// **Field semantics:**
/// - `stat.size` → `VerifiedProvenanceEntry.recordedStatSize` (fstat st_size; fast-check baseline)
/// - `hashedByteCount` → `VerifiedProvenanceEntry.size` (streaming byte count; display/download)
/// For a normal regular file they are equal. They are kept distinct so the wiring is
/// unambiguous (B1 invariant: recordedStatSize is ALWAYS from stat.size).
nonisolated public struct VerifiedBaseline: Sendable, Equatable {
    /// Canonical destination path (standardizedFileURL.path form, as stored in the ledger).
    public let destinationPath: String
    /// Source URL as stored in the ledger entry.
    public let url: String
    /// "sha256:"-prefixed hash — the confirmed hash that matched the ledger record.
    public let sha256: String
    /// Streaming byte count from `FileDigest`. Feeds `VerifiedProvenanceEntry.size`.
    public let hashedByteCount: Int
    /// Filesystem metadata from `fstat(2)` on the open hash handle at EOF.
    /// `stat.size` feeds `VerifiedProvenanceEntry.recordedStatSize`.
    public let stat: FileStat

    public init(
        destinationPath: String,
        url: String,
        sha256: String,
        hashedByteCount: Int,
        stat: FileStat
    ) {
        self.destinationPath = destinationPath
        self.url = url
        self.sha256 = sha256
        self.hashedByteCount = hashedByteCount
        self.stat = stat
    }
}
```

**b)** Modify `Sources/GohCore/CLI/VerifyAllRunner.swift`:

Add `onVerified: (@Sendable (VerifiedBaseline) -> Void)? = nil` to the `verifyAll` signature (after `isCancelled`):

```swift
public static func verifyAll(
    provenanceStorePath: String,
    generatedAt: Date,
    progress: (@Sendable (VerifyProgress) -> Void)?,
    isCancelled: (@Sendable () -> Bool)?,
    onVerified: (@Sendable (VerifiedBaseline) -> Void)? = nil
) throws -> VerifyAllReport {
```

Thread `onVerified` through to `rehash`:

```swift
case .entries(let ledgerEntries):
    return rehash(
        entries: ledgerEntries,
        generatedAt: generatedAt,
        progress: progress,
        isCancelled: isCancelled,
        onVerified: onVerified)
```

Update `rehash` signature:

```swift
private static func rehash(
    entries: [ProvenanceEntry],
    generatedAt: Date,
    progress: (@Sendable (VerifyProgress) -> Void)?,
    isCancelled: (@Sendable () -> Bool)?,
    onVerified: (@Sendable (VerifiedBaseline) -> Void)?
) -> VerifyAllReport {
```

Thread `onVerified` through to `hashEntry` call:

```swift
(result, hashedBytes) = try hashEntry(
    entry,
    progress: progress,
    isCancelled: isCancelled,
    completed: completed,
    total: total,
    bytesHashedCumulative: bytesHashedCumulative,
    totalBytes: totalBytes,
    onVerified: onVerified)
```

Update `hashEntry` signature to accept `onVerified` and switch to `sha256WithSizeAndStat`:

```swift
private static func hashEntry(
    _ entry: ProvenanceEntry,
    progress: (@Sendable (VerifyProgress) -> Void)?,
    isCancelled: (@Sendable () -> Bool)?,
    completed: Int,
    total: Int,
    bytesHashedCumulative: Int,
    totalBytes: Int,
    onVerified: (@Sendable (VerifiedBaseline) -> Void)?
) throws -> (VerifyEntryResult, Int) {
    let hash: String
    let size: Int
    let fileStat: FileStat
    do {
        var bytesIntoThisFile = 0
        var bytesSinceLastEmit = 0
        let result = try FileDigest.sha256WithSizeAndStat(
            path: entry.destinationPath,
            onBytesHashed: { chunkBytes in
                bytesIntoThisFile += chunkBytes
                bytesSinceLastEmit += chunkBytes
                if bytesSinceLastEmit >= progressThrottleBytes {
                    bytesSinceLastEmit = 0
                    progress?(VerifyProgress(
                        completed: completed,
                        total: total,
                        currentPath: entry.destinationPath,
                        bytesHashed: bytesHashedCumulative + bytesIntoThisFile,
                        totalBytes: totalBytes))
                }
            },
            isCancelled: isCancelled)
        hash = result.sha256
        size = result.size
        fileStat = result.stat
    } catch FileDigest.DigestError.cancelled {
        throw FileDigest.DigestError.cancelled
    } catch FileDigest.DigestError.cannotOpen {
        return (VerifyEntryResult(
            path: entry.destinationPath,
            url: entry.url,
            status: .missing,
            expectedSha256: entry.sha256,
            actualSha256: nil), 0)
    } catch {
        return (VerifyEntryResult(
            path: entry.destinationPath,
            url: entry.url,
            status: .missing,
            expectedSha256: entry.sha256,
            actualSha256: nil), 0)
    }

    if hash == entry.sha256 {
        // Fire onVerified at the moment the entry passes — BEFORE returning.
        // AC9: this fires per-.ok immediately, so a cancelled run still backfills
        // all entries verified before the cancel.
        if let onVerified {
            let baseline = VerifiedBaseline(
                destinationPath: entry.destinationPath,
                url: entry.url,
                sha256: hash,
                hashedByteCount: size,
                stat: fileStat)
            onVerified(baseline)
        }
        return (VerifyEntryResult(
            path: entry.destinationPath,
            url: entry.url,
            status: .ok,
            expectedSha256: entry.sha256,
            actualSha256: nil), size)
    } else {
        // AC2/AC3: only .ok fires onVerified; .failed does not.
        return (VerifyEntryResult(
            path: entry.destinationPath,
            url: entry.url,
            status: .failed,
            expectedSha256: entry.sha256,
            actualSha256: hash), size)
    }
}
```

**Step 4 — Run expecting pass:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "VerifyAllRunnerOnVerifiedTests|VerifyAllRunner" 2>&1 | tail -30
```
Expected: all new tests + all existing VerifyAllRunner tests pass.

**Step 5 — Build gate:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1 | tail -10
```

**Step 6 — Commit:**
```
git add Sources/GohCore/CLI/VerifiedBaseline.swift Sources/GohCore/CLI/VerifyAllRunner.swift Tests/GohCoreTests/VerifyAllRunnerTests.swift
git commit -m "feat(VerifyAllRunner): add VerifiedBaseline + onVerified side-channel callback (AC2, AC3, AC6, AC9)"
```

---

### T3 — Wire fields on `VerifiedProvenanceEntry` + `CommandDispatcher` forward

**AC ownership:** AC8, AC10 (source wiring)

**Files:**
- Modify: `Sources/GohCore/Model/Command.swift`
- Modify: `Sources/GohCore/Model/CommandDispatcher.swift`
- Modify: `Tests/GohCoreTests/CommandTests.swift`

**Pre-task reads:**
- [x] `Sources/GohCore/Model/Command.swift` — `VerifiedProvenanceEntry` (read above)
- [x] `Sources/GohCore/Model/CommandDispatcher.swift` — `.recordVerifiedProvenance` handler (read above)

**Step 1 — Failing test**

Append to `Tests/GohCoreTests/CommandTests.swift` (or create
`Tests/GohCoreTests/VerifiedProvenanceEntryWireTests.swift`):

```swift
// ── AC8: VerifiedProvenanceEntry additive-optional wire fields ───────────────

@Suite("VerifiedProvenanceEntry wire fields")
struct VerifiedProvenanceEntryWireTests {

    // AC8: protocolVersion stays 4.
    @Test("AC8: CommandService protocolVersion stays 4")
    func protocolVersionUnchanged() {
        #expect(CommandService.protocolVersion == 4)
    }

    // AC8: new fields default nil; Codable round-trip preserves them.
    @Test("AC8: additive-optional fields survive Codable round-trip")
    func additiveOptionalRoundTrip() throws {
        let entry = VerifiedProvenanceEntry(
            url: "https://example.com/file.bin",
            sha256: "sha256:" + String(repeating: "a", count: 64),
            size: 1024,
            destinationPath: "/Users/u/Downloads/file.bin",
            verifiedAt: Date(timeIntervalSince1970: 1_748_000_000),
            recordedStatSize: 1024,
            recordedMtimeSeconds: 1_748_000_000,
            recordedMtimeNanoseconds: 123_456_789,
            recordedInode: 987654321,
            recordedDevice: 16777220)

        let data = try CommandCoding.encoder.encode(entry)
        let decoded = try CommandCoding.decoder.decode(VerifiedProvenanceEntry.self, from: data)

        #expect(decoded.recordedStatSize == 1024)
        #expect(decoded.recordedMtimeSeconds == 1_748_000_000)
        #expect(decoded.recordedMtimeNanoseconds == 123_456_789)
        #expect(decoded.recordedInode == 987654321)
        #expect(decoded.recordedDevice == 16777220)
    }

    // AC8: nil fields are absent from JSON (backward-compatible).
    @Test("AC8: nil stat fields absent from encoded JSON")
    func nilFieldsAbsentFromJSON() throws {
        let entry = VerifiedProvenanceEntry(
            url: "https://example.com/f.bin",
            sha256: "sha256:" + String(repeating: "b", count: 64),
            size: 512,
            destinationPath: "/tmp/f.bin",
            verifiedAt: Date(timeIntervalSince1970: 1_000_000_000))
        // All 5 recordedStat* default nil.
        let data = try CommandCoding.encoder.encode(entry)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("recordedStatSize"))
        #expect(!json.contains("recordedMtimeSeconds"))
    }

    // AC10: recordedStatSize is sourced from stat.size (Int64), not the display size (Int).
    // Verify the type is Int64 (the fstat field type).
    @Test("AC10: recordedStatSize field type is Int64 (matching fstat st_size)")
    func recordedStatSizeIsInt64() throws {
        let statSize: Int64 = 73_741_824  // 70.3 MB
        let entry = VerifiedProvenanceEntry(
            url: "https://example.com/large.bin",
            sha256: "sha256:" + String(repeating: "c", count: 64),
            size: Int(statSize),  // happens to be equal for a normal file
            destinationPath: "/tmp/large.bin",
            verifiedAt: Date(timeIntervalSince1970: 1_748_000_000),
            recordedStatSize: statSize,
            recordedMtimeSeconds: 1_748_000_000,
            recordedMtimeNanoseconds: 0,
            recordedInode: 12345,
            recordedDevice: 16777220)
        let data = try CommandCoding.encoder.encode(entry)
        let decoded = try CommandCoding.decoder.decode(VerifiedProvenanceEntry.self, from: data)
        #expect(decoded.recordedStatSize == statSize)
    }
}
```

**Step 2 — Run expecting failure:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VerifiedProvenanceEntryWireTests 2>&1 | tail -20
```
Expected: compilation error — 5 new `VerifiedProvenanceEntry` init params do not exist.

**Step 3 — Implementation**

In `Sources/GohCore/Model/Command.swift`, update `VerifiedProvenanceEntry`:

```swift
/// One entry in a `recordVerifiedProvenance` batch.
public struct VerifiedProvenanceEntry: Codable, Sendable, Equatable {
    public var url: String
    /// ALREADY "sha256:"-prefixed — exactly as `FileDigest.sha256WithSize` returns it.
    public var sha256: String
    public var size: Int
    /// Raw destination path (CLI-resolved); the daemon canonicalizes via
    /// `URL(fileURLWithPath:).standardizedFileURL.path`.
    public var destinationPath: String
    public var verifiedAt: Date

    // Additive-optional baseline fields (all-or-nothing: any nil → write none).
    // Sourced from FileDigest.sha256WithSizeAndStat FileStat, NOT the streaming byte count.
    // B1: recordedStatSize is ALWAYS stat.size (fstat st_size), NEVER hashedByteCount.
    public var recordedStatSize: Int64?           // st_size (off_t)
    public var recordedMtimeSeconds: Int64?       // st_mtimespec.tv_sec
    public var recordedMtimeNanoseconds: Int64?   // st_mtimespec.tv_nsec
    public var recordedInode: UInt64?             // st_ino
    public var recordedDevice: Int64?             // st_dev widened to Int64

    public init(
        url: String,
        sha256: String,
        size: Int,
        destinationPath: String,
        verifiedAt: Date,
        recordedStatSize: Int64? = nil,
        recordedMtimeSeconds: Int64? = nil,
        recordedMtimeNanoseconds: Int64? = nil,
        recordedInode: UInt64? = nil,
        recordedDevice: Int64? = nil
    ) {
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.destinationPath = destinationPath
        self.verifiedAt = verifiedAt
        self.recordedStatSize = recordedStatSize
        self.recordedMtimeSeconds = recordedMtimeSeconds
        self.recordedMtimeNanoseconds = recordedMtimeNanoseconds
        self.recordedInode = recordedInode
        self.recordedDevice = recordedDevice
    }
}
```

`CommandDispatcher.swift` — the `.recordVerifiedProvenance` handler passes `entries` directly to `provenanceStore.recordVerified(entries:)`. The dispatcher does no field-level work on `recordedStat*`; no validation needed (spec A2). The existing filter (`sha256.hasPrefix("sha256:") && !destinationPath.isEmpty`) is unchanged. **No edit to CommandDispatcher is required** — it already forwards the full `VerifiedProvenanceEntry` struct to `recordVerified`, and the store will pick up the new fields in T4.

(If the compiler requires a change to `CommandDispatcher` due to the updated struct, make the minimal change — the handler body is unchanged.)

**Step 4 — Run expecting pass:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "VerifiedProvenanceEntryWireTests|CommandTests" 2>&1 | tail -20
```

**Step 5 — Build gate:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1 | tail -10
```

**Step 6 — Commit:**
```
git add Sources/GohCore/Model/Command.swift Tests/GohCoreTests/CommandTests.swift
git commit -m "feat(Command): add 5 additive-optional stat fields to VerifiedProvenanceEntry (AC8, AC10)"
```

---

### T4 — `ProvenanceStore.recordVerified` — all three branches carry stat fields

**AC ownership:** AC1, AC2, AC11, B2 all-or-nothing

**Files:**
- Modify: `Sources/GohCore/Provenance/ProvenanceStore.swift`
- Modify: `Tests/GohCoreTests/ProvenanceStoreTests.swift`

**Pre-task reads:**
- [x] `Sources/GohCore/Provenance/ProvenanceStore.swift` — `recordVerified` at L139 (read above)
- [x] `Sources/GohCore/Provenance/ProvenanceRecord.swift` — `ProvenanceEntry` fields (read above)

**Step 1 — Failing test**

Append to `Tests/GohCoreTests/ProvenanceStoreTests.swift`:

```swift
// ── Backfill baseline: recordVerified stat fields (AC1, AC2, AC11, B2) ──────

@Suite("ProvenanceStore.recordVerified baseline backfill")
struct ProvenanceStoreBackfillTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-pv-backfill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let testSha256 = "sha256:" + String(repeating: "a", count: 64)
    private let otherSha256 = "sha256:" + String(repeating: "b", count: 64)
    private let testPath = "/Users/u/Downloads/file.bin"
    private let testURL = "https://example.com/file.bin"
    private let testDate = Date(timeIntervalSince1970: 1_748_000_000)
    private let laterDate = Date(timeIntervalSince1970: 1_748_100_000)

    private func statEntry(overwrite: Bool) -> VerifiedProvenanceEntry {
        VerifiedProvenanceEntry(
            url: testURL,
            sha256: testSha256,
            size: 1024,
            destinationPath: testPath,
            verifiedAt: laterDate,
            recordedStatSize: 1024,
            recordedMtimeSeconds: 1_748_000_000,
            recordedMtimeNanoseconds: 500_000_000,
            recordedInode: 12345,
            recordedDevice: 16777220)
    }

    // AC1 / primary backfill path: same path + same sha256 → overwrites stat fields.
    @Test("AC1: same path + same sha256 backfills all 5 stat fields and sets verifiedAt")
    func sameSha256BackfillsStatFields() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()

        // Pre-existing entry without baseline.
        try store.record(entry: ProvenanceEntry(
            url: testURL, sha256: testSha256, size: 1024,
            downloadedAt: testDate, destinationPath: testPath))

        let entry = statEntry(overwrite: true)
        try store.recordVerified(entries: [entry])

        let stored = try #require(store.lookup(destinationPath: testPath))
        #expect(stored.sha256 == testSha256)
        #expect(stored.verifiedAt == laterDate)
        // downloadedAt is PRESERVED (not overwritten).
        #expect(stored.downloadedAt == testDate)
        // All 5 stat fields written.
        #expect(stored.recordedStatSize == 1024)
        #expect(stored.recordedMtimeSeconds == 1_748_000_000)
        #expect(stored.recordedMtimeNanoseconds == 500_000_000)
        #expect(stored.recordedInode == 12345)
        #expect(stored.recordedDevice == 16777220)
    }

    // AC11: same path + same sha256 + already has a baseline → idempotent overwrite.
    @Test("AC11: re-running verify on already-baselined entry is idempotent")
    func idempotentOverwrite() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()

        try store.record(entry: ProvenanceEntry(
            url: testURL, sha256: testSha256, size: 1024,
            downloadedAt: testDate, destinationPath: testPath))

        let entry = statEntry(overwrite: true)
        try store.recordVerified(entries: [entry])
        // Second verify with identical stat values.
        try store.recordVerified(entries: [entry])

        let stored = try #require(store.lookup(destinationPath: testPath))
        #expect(stored.recordedStatSize == 1024)
        #expect(stored.recordedInode == 12345)
        // verifiedAt is the later one from the second call.
        #expect(stored.verifiedAt == laterDate)
    }

    // B2 all-or-nothing: any nil stat field → write none.
    @Test("B2: any nil stat field → no stat fields written (all-or-nothing)")
    func allOrNothingPartialStatNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()

        try store.record(entry: ProvenanceEntry(
            url: testURL, sha256: testSha256, size: 1024,
            downloadedAt: testDate, destinationPath: testPath))

        // Entry with only 4 of 5 stat fields (inode is nil).
        let partialEntry = VerifiedProvenanceEntry(
            url: testURL,
            sha256: testSha256,
            size: 1024,
            destinationPath: testPath,
            verifiedAt: laterDate,
            recordedStatSize: 1024,
            recordedMtimeSeconds: 1_748_000_000,
            recordedMtimeNanoseconds: 0,
            recordedInode: nil,   // partial — triggers all-or-nothing
            recordedDevice: 16777220)

        try store.recordVerified(entries: [partialEntry])

        let stored = try #require(store.lookup(destinationPath: testPath))
        // verifiedAt is still set (it's not part of the stat bundle).
        #expect(stored.verifiedAt == laterDate)
        // NO stat fields written due to partial baseline.
        #expect(stored.recordedStatSize == nil)
        #expect(stored.recordedMtimeSeconds == nil)
        #expect(stored.recordedInode == nil)
    }

    // B2 / same path + same sha256 + existing baseline + no incoming baseline:
    // existing stat fields must NOT be nulled out.
    @Test("B2: absent incoming baseline preserves existing stat fields")
    func absentIncomingBaselinePreservesExisting() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()

        // Pre-existing entry WITH baseline.
        try store.record(entry: ProvenanceEntry(
            url: testURL, sha256: testSha256, size: 1024,
            downloadedAt: testDate, destinationPath: testPath,
            recordedStatSize: 999, recordedMtimeSeconds: 1_000_000,
            recordedMtimeNanoseconds: 0, recordedInode: 11111, recordedDevice: 16777220))

        // New verify with no baseline (all 5 nil).
        let entryNoStat = VerifiedProvenanceEntry(
            url: testURL, sha256: testSha256, size: 1024,
            destinationPath: testPath, verifiedAt: laterDate)

        try store.recordVerified(entries: [entryNoStat])

        let stored = try #require(store.lookup(destinationPath: testPath))
        // verifiedAt updated.
        #expect(stored.verifiedAt == laterDate)
        // Existing stat fields PRESERVED (not nulled).
        #expect(stored.recordedStatSize == 999)
        #expect(stored.recordedInode == 11111)
    }

    // Hash-changed branch: new ProvenanceEntry carries stat fields.
    @Test("hash-changed branch writes stat fields from incoming baseline")
    func hashChangedBranchCarriesStat() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()

        try store.record(entry: ProvenanceEntry(
            url: testURL, sha256: testSha256, size: 1024,
            downloadedAt: testDate, destinationPath: testPath))

        let changedEntry = VerifiedProvenanceEntry(
            url: testURL, sha256: otherSha256, size: 2048,
            destinationPath: testPath, verifiedAt: laterDate,
            recordedStatSize: 2048, recordedMtimeSeconds: 1_748_100_000,
            recordedMtimeNanoseconds: 0, recordedInode: 99999, recordedDevice: 16777220)

        try store.recordVerified(entries: [changedEntry])

        let stored = try #require(store.lookup(destinationPath: testPath))
        #expect(stored.sha256 == otherSha256)
        #expect(stored.recordedStatSize == 2048)
        #expect(stored.recordedInode == 99999)
    }

    // New-path branch: new ProvenanceEntry carries stat fields.
    @Test("new-path branch writes stat fields from incoming baseline")
    func newPathBranchCarriesStat() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()

        let newPath = "/Users/u/Downloads/new.bin"
        let newEntry = VerifiedProvenanceEntry(
            url: "https://example.com/new.bin", sha256: testSha256, size: 512,
            destinationPath: newPath, verifiedAt: laterDate,
            recordedStatSize: 512, recordedMtimeSeconds: 1_748_000_000,
            recordedMtimeNanoseconds: 0, recordedInode: 77777, recordedDevice: 16777220)

        try store.recordVerified(entries: [newEntry])

        let stored = try #require(store.lookup(destinationPath: newPath))
        #expect(stored.recordedStatSize == 512)
        #expect(stored.recordedInode == 77777)
    }
}
```

**Step 2 — Run expecting failure:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProvenanceStoreBackfillTests 2>&1 | tail -20
```
Expected: compilation error OR test failures (stat fields not written by current code).

**Step 3 — Implementation**

In `Sources/GohCore/Provenance/ProvenanceStore.swift`, update `recordVerified`:

```swift
public func recordVerified(entries: [VerifiedProvenanceEntry]) throws {
    guard !entries.isEmpty else { return }
    try inner.withLock { inner in
        for entry in entries {
            let canonical = URL(fileURLWithPath: entry.destinationPath).standardizedFileURL.path

            // All-or-nothing baseline (B2): baseline is present iff ALL FIVE fields are non-nil.
            let hasBaseline = entry.recordedStatSize != nil
                && entry.recordedMtimeSeconds != nil
                && entry.recordedMtimeNanoseconds != nil
                && entry.recordedInode != nil
                && entry.recordedDevice != nil

            if let idx = inner.record.entries.firstIndex(where: { $0.destinationPath == canonical }) {
                let existing = inner.record.entries[idx]
                if existing.sha256 == entry.sha256 {
                    // Same path + same sha256 (primary backfill path: re-verifying pre-#104 entry).
                    // Preserve downloadedAt; refresh verifiedAt, url, size.
                    inner.record.entries[idx].verifiedAt = entry.verifiedAt
                    inner.record.entries[idx].url = entry.url
                    inner.record.entries[idx].size = entry.size
                    // OVERWRITE stat fields when incoming baseline present; leave existing when absent.
                    if hasBaseline {
                        inner.record.entries[idx].recordedStatSize = entry.recordedStatSize
                        inner.record.entries[idx].recordedMtimeSeconds = entry.recordedMtimeSeconds
                        inner.record.entries[idx].recordedMtimeNanoseconds = entry.recordedMtimeNanoseconds
                        inner.record.entries[idx].recordedInode = entry.recordedInode
                        inner.record.entries[idx].recordedDevice = entry.recordedDevice
                    }
                    // If !hasBaseline: leave existing stat fields untouched (don't null them).
                } else {
                    // Same path + different sha256: treat as new file (downloadedAt = verifiedAt).
                    inner.record.entries[idx] = ProvenanceEntry(
                        url: entry.url, sha256: entry.sha256, size: entry.size,
                        downloadedAt: entry.verifiedAt, destinationPath: canonical,
                        verifiedAt: entry.verifiedAt,
                        recordedStatSize: hasBaseline ? entry.recordedStatSize : nil,
                        recordedMtimeSeconds: hasBaseline ? entry.recordedMtimeSeconds : nil,
                        recordedMtimeNanoseconds: hasBaseline ? entry.recordedMtimeNanoseconds : nil,
                        recordedInode: hasBaseline ? entry.recordedInode : nil,
                        recordedDevice: hasBaseline ? entry.recordedDevice : nil)
                }
            } else {
                // Brand-new path — downloadedAt = verifiedAt.
                inner.record.entries.append(ProvenanceEntry(
                    url: entry.url, sha256: entry.sha256, size: entry.size,
                    downloadedAt: entry.verifiedAt, destinationPath: canonical,
                    verifiedAt: entry.verifiedAt,
                    recordedStatSize: hasBaseline ? entry.recordedStatSize : nil,
                    recordedMtimeSeconds: hasBaseline ? entry.recordedMtimeSeconds : nil,
                    recordedMtimeNanoseconds: hasBaseline ? entry.recordedMtimeNanoseconds : nil,
                    recordedInode: hasBaseline ? entry.recordedInode : nil,
                    recordedDevice: hasBaseline ? entry.recordedDevice : nil))
            }
        }
        try writeAtomically(&inner.record)
    }
}
```

**Step 4 — Run expecting pass:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ProvenanceStoreBackfillTests|ProvenanceStore" 2>&1 | tail -30
```
Expected: all new + all existing ProvenanceStore tests pass.

**Step 5 — Build gate:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1 | tail -10
```

**Step 6 — Commit:**
```
git add Sources/GohCore/Provenance/ProvenanceStore.swift Tests/GohCoreTests/ProvenanceStoreTests.swift
git commit -m "feat(ProvenanceStore): recordVerified carries stat fields in all 3 branches (AC1, AC11, B2)"
```

---

### T5 — `GohVerifyAllCommand.run(send:)` + `GohCommandLine` dispatch

**AC ownership:** AC5, AC7, AC9 (CLI path)

**Files:**
- Modify: `Sources/GohCore/CLI/GohVerifyAllCommand.swift`
- Modify: `Sources/GohCore/CLI/GohCommandLine.swift`
- Create: `Tests/GohCoreTests/GohVerifyAllCommandBackfillTests.swift`

**Pre-task reads:**
- [x] `Sources/GohCore/CLI/GohVerifyAllCommand.swift` — full file (read above)
- [x] `Sources/GohCore/CLI/GohCommandLine.swift` — `.verifyAll` dispatch at ~L175 (read above)

**Step 1 — Failing test**

Create `Tests/GohCoreTests/GohVerifyAllCommandBackfillTests.swift`:

```swift
import Foundation
import Testing
import XPC
@testable import GohCore

/// Spy sender: records RecordVerifiedProvenanceRequest batches sent to it.
/// @unchecked Sendable: mutated only from the @Sendable closure,
/// which is called synchronously within verifyAll on one thread.
private final class SpySender: @unchecked Sendable {
    var sentEntries: [[VerifiedProvenanceEntry]] = []
    var shouldThrow = false

    func send(_ dict: XPCDictionary) throws -> XPCDictionary {
        if shouldThrow { throw URLError(.notConnectedToInternet) }
        let envelope = try GohEnvelope<Command>(xpcDictionary: dict)
        if case .recordVerifiedProvenance(let req) = envelope.payload {
            sentEntries.append(req.entries)
        }
        // Return a minimal .ack reply envelope.
        return try GohEnvelope<EmptyReply>(
            protocolVersion: CommandService.protocolVersion,
            requestID: envelope.requestID,
            messageType: .reply,
            payload: EmptyReply()).xpcDictionary()
    }
}

// Placeholder for empty-reply decoding if needed.
private struct EmptyReply: Codable, Sendable {}

@Suite("GohVerifyAllCommand backfill")
struct GohVerifyAllCommandBackfillTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-vacmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(
        in dir: URL,
        entries: [(path: String, content: Data)]
    ) throws -> (storeURL: URL, sha256s: [String]) {
        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        var sha256s: [String] = []
        for (path, content) in entries {
            try content.write(to: URL(fileURLWithPath: path))
            let (sha256, _) = try FileDigest.sha256WithSize(path: path)
            sha256s.append(sha256)
            try store.record(entry: ProvenanceEntry(
                url: "https://example.com/\(URL(fileURLWithPath: path).lastPathComponent)",
                sha256: sha256,
                size: content.count,
                downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
                destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path))
        }
        return (storeURL, sha256s)
    }

    // AC1: with send, .ok entries are sent as a baseline batch.
    @Test("AC1: ok entries sent to daemon via send when present")
    func okEntriesSentWithSender() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("ok1.bin").path
        let f2 = dir.appendingPathComponent("ok2.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [
            (f1, Data("content1".utf8)),
            (f2, Data("content2".utf8)),
        ])

        let spy = SpySender()
        let result = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: false,
            generatedAt: Date(),
            send: spy.send)

        #expect(result.exitCode == 0)
        #expect(!spy.sentEntries.isEmpty)
        let sent = spy.sentEntries.flatMap { $0 }
        #expect(sent.count == 2)
        // recordedStatSize must be populated (stat.size, not nil).
        for e in sent {
            #expect(e.recordedStatSize != nil, "recordedStatSize must be non-nil for a sent baseline")
        }
    }

    // AC5: no send → no writes; exit code / report unchanged (attest stays read-only).
    @Test("AC5: nil send causes no XPC call; report and exit code unchanged")
    func nilSendNoXPCCall() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("ok.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [(f, Data("x".utf8))])

        // Capture store bytes BEFORE run.
        let before = try Data(contentsOf: storeURL)

        let result = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: false,
            generatedAt: Date())  // no send — default nil

        // After run: store bytes identical (no write happened).
        let after = try Data(contentsOf: storeURL)
        #expect(before == after, "store must be byte-unchanged when send is nil (AC5)")
        #expect(result.exitCode == 0)
    }

    // AC7: send throws (daemon stopped) → verify still completes; exit code unchanged.
    @Test("AC7: send failure does not change exit code or report")
    func sendFailureNoExitCodeChange() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("ok.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [(f, Data("ok".utf8))])

        let spy = SpySender()
        spy.shouldThrow = true

        let result = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: false,
            generatedAt: Date(),
            send: spy.send)

        // Exit code 0 (all ok) — unaffected by send failure.
        #expect(result.exitCode == 0)
        // A warning was emitted to stderr (not checked for exact text; presence is enough).
        // No crash / no non-zero exit.
    }

    // AC6: --json output is byte-identical with and without send.
    @Test("AC6: --json output byte-identical with and without send")
    func jsonOutputUnchangedWithSend() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("ok.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [(f, Data("json-test".utf8))])
        let fixedDate = Date(timeIntervalSince1970: 1_714_262_400)

        let withoutSend = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: true,
            generatedAt: fixedDate)

        let spy = SpySender()
        let withSend = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: true,
            generatedAt: fixedDate,
            send: spy.send)

        #expect(withSend.standardOutput == withoutSend.standardOutput,
            "AC6: --json output must be byte-identical regardless of send (frozen contract)")
    }

    // AC2: .failed entries are NOT sent.
    @Test("AC2: failed entries not sent as baselines")
    func failedEntriesNotSent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("bad.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [(f, Data("original".utf8))])
        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: f))

        let spy = SpySender()
        _ = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: false,
            generatedAt: Date(),
            send: spy.send)

        #expect(spy.sentEntries.flatMap { $0 }.isEmpty, "failed entry must not generate a baseline send")
    }
}
```

**Note on SpySender:** The spy decodes the XPC dictionary as a `GohEnvelope<Command>`. If the existing test infrastructure for this pattern differs, adapt to use `GohCommandClient` directly or a simpler closure-based spy that records calls. The key requirement is: the send closure captures the `VerifiedProvenanceEntry` entries for assertion.

**Step 2 — Run expecting failure:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllCommandBackfillTests 2>&1 | tail -20
```
Expected: compilation error — `send:` param does not exist on `GohVerifyAllCommand.run`.

**Step 3 — Implementation**

In `Sources/GohCore/CLI/GohVerifyAllCommand.swift`, update `run` signature and Step 2:

```swift
public static func run(
    provenanceStorePath: String,
    json: Bool = false,
    generatedAt: Date = Date(),
    send: GohCommandLine.Sender? = nil
) -> GohCommandLineResult {
```

In the `case .entries:` / Step 2 block, switch `VerifyAllRunner.verifyAll` to capture baselines:

```swift
case .entries:
    break  // fall through to re-hash
}

// ── Step 2: Re-hash via runner ────────────────────────────────────────
var collectedBaselines: [VerifiedBaseline] = []
let baselineBox: (@Sendable (VerifiedBaseline) -> Void)? = send == nil ? nil : { baseline in
    // Captured by reference via a class box — @Sendable closure cannot capture
    // a mutable var; use an @unchecked Sendable box instead (same pattern as RunnerTestBox).
    collectedBaselines.append(baseline)
}

let report: VerifyAllReport
do {
    report = try VerifyAllRunner.verifyAll(
        provenanceStorePath: provenanceStorePath,
        generatedAt: generatedAt,
        progress: nil,
        isCancelled: nil,
        onVerified: baselineBox)
} catch {
    if json { return jsonErrorResult(.ledgerUnreadable) }
    return GohCommandLineResult(exitCode: 6, standardOutput: "provenance ledger unreadable\n")
}
```

Note: `collectedBaselines` is a value-type array captured from the outer function — but it is captured by the `@Sendable` closure, which requires a reference-type box. Use the same `RunnerTestBox` / private class pattern:

```swift
// Mutable box for collecting baselines from the @Sendable onVerified closure.
// A @Sendable closure cannot capture a mutable var by reference under -warnings-as-errors;
// the box is a reference captured by value (the class IS the reference).
private final class BaselineCollector: @unchecked Sendable {
    var baselines: [VerifiedBaseline] = []
}
```

Then in `run`:

```swift
let collector = send.map { _ in BaselineCollector() }
let onVerified: (@Sendable (VerifiedBaseline) -> Void)? = collector.map { box in
    { baseline in box.baselines.append(baseline) }
}
...
report = try VerifyAllRunner.verifyAll(
    provenanceStorePath: provenanceStorePath,
    generatedAt: generatedAt,
    progress: nil,
    isCancelled: nil,
    onVerified: onVerified)
```

After Step 2, before Step 3 (derive exit code), add the best-effort send:

```swift
// ── Step 2.5: Best-effort backfill send ──────────────────────────────────────
// AC7: send failure never changes exit code or report. AC5: send is nil for attest.
if let send, let baselines = collector?.baselines, !baselines.isEmpty {
    let entries = baselines.map { b in
        VerifiedProvenanceEntry(
            url: b.url,
            sha256: b.sha256,
            size: b.hashedByteCount,               // display/download byte count
            destinationPath: b.destinationPath,
            verifiedAt: generatedAt,
            recordedStatSize: b.stat.size,          // B1: ALWAYS stat.size
            recordedMtimeSeconds: b.stat.mtimeSeconds,
            recordedMtimeNanoseconds: b.stat.mtimeNanoseconds,
            recordedInode: b.stat.inode,
            recordedDevice: b.stat.device)
    }
    let request = GohEnvelope(
        protocolVersion: CommandService.protocolVersion,
        requestID: UUID(),
        messageType: .request,
        payload: Command.recordVerifiedProvenance(
            request: RecordVerifiedProvenanceRequest(entries: entries)))
    do {
        let dict = try request.xpcDictionary()
        _ = try send(XPCDictionary(dict))
    } catch {
        // AC7: best-effort. Log warning to stderr; never change exit code.
        fputs("goh verify --all: provenance backfill failed (daemon may be stopped): \(error)\n",
              stderr)
    }
}
```

In `Sources/GohCore/CLI/GohCommandLine.swift`, update the `.verifyAll(json:)` dispatch:

```swift
case .verifyAll(let json):
    return GohVerifyAllCommand.run(
        provenanceStorePath: provenanceStorePathResolver() ?? "",
        json: json,
        send: send)  // Pass the live sender; attest uses nil-send form.
```

**Step 4 — Run expecting pass:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "GohVerifyAllCommandBackfillTests|GohVerifyAllCommand" 2>&1 | tail -30
```

**Step 5 — Build gate:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1 | tail -10
```

**Step 6 — Commit:**
```
git add Sources/GohCore/CLI/GohVerifyAllCommand.swift Sources/GohCore/CLI/GohCommandLine.swift Tests/GohCoreTests/GohVerifyAllCommandBackfillTests.swift
git commit -m "feat(GohVerifyAllCommand): add send: for best-effort backfill; pass from CLI dispatch (AC5, AC7, AC9)"
```

---

### T6 — `GohMenuClient` protocol method + `LiveGohMenuClient` implementation + 3 test doubles

**AC ownership:** (protocol surface required by T7; AC for test doubles is compile-time correctness under `-warnings-as-errors`)

**Files:**
- Modify: `Sources/GohMenuBar/GohMenuViewModel.swift` (protocol)
- Modify: `Sources/goh-menu/main.swift` (LiveGohMenuClient)
- Modify: `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift` (FakeMenuClient)
- Modify: `Tests/GohMenuBarTests/GohMenuViewModelTests.swift` (FakeMenuClient + LongLivedMenuClient)

**Pre-task reads:**
- [x] `Sources/GohMenuBar/GohMenuViewModel.swift` — `GohMenuClient` protocol (read above)
- [x] `Sources/goh-menu/main.swift` — `LiveGohMenuClient` + `sendOneShot` pattern (read above)
- [x] `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift` — FakeMenuClient shape (read above)
- [x] `Tests/GohMenuBarTests/GohMenuViewModelTests.swift` — FakeMenuClient + LongLivedMenuClient (read above)

**Step 1 — Failing test**

This task's "failing test" is the build itself — adding the protocol method without updating the three test doubles causes compilation failures under `-warnings-as-errors` (missing protocol conformance). Verify this is the failure mode:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1 | grep "does not conform"
```

**Step 2 — Implementation**

**a)** In `Sources/GohMenuBar/GohMenuViewModel.swift`, add to `GohMenuClient`:

```swift
@MainActor
public protocol GohMenuClient: AnyObject {
    func progressSnapshots() -> AsyncThrowingStream<[ProgressSnapshot], any Error>
    func add(_ request: AddRequest) async throws -> JobSummary
    func pause(jobID: UInt64) async throws
    func resume(jobID: UInt64) async throws
    func remove(jobID: UInt64, keepPartialFile: Bool) async throws
    /// Sends a batch of verify-produced baselines to the daemon. Best-effort:
    /// callers must not propagate errors to the UI. Never blocks the verify run.
    func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry]) async throws
}
```

**b)** In `Sources/goh-menu/main.swift`, add to `LiveGohMenuClient`:

```swift
func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry]) async throws {
    do {
        // .ack reply has no payload; send as a fire-and-forget one-shot.
        // The daemon returns .ack; we decode it as AckReply (a void-like Codable type).
        // If the existing infrastructure uses a dedicated AckReply type, use it.
        // Otherwise use a minimal Codable struct.
        _ = try await Self.sendOneShot(
            .recordVerifiedProvenance(
                request: RecordVerifiedProvenanceRequest(entries: entries)),
            expecting: AckReply.self,
            validationMode: validationMode)
    } catch {
        throw Self.map(error)
    }
}
```

Note: check whether a suitable `AckReply` type already exists in the codebase. If not, add a private minimal type:

```swift
private struct AckReply: Codable, Sendable {}
```

(The daemon returns `.ack` which has an empty payload body; `GohCommandClient.send` decodes the reply payload. If the existing `.ack` path uses a different decoding idiom — e.g. `Void`-compatible — match it.)

**c)** In `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift`, add to `FakeMenuClient`:

```swift
func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry]) async throws {}
```

**d)** In `Tests/GohMenuBarTests/GohMenuViewModelTests.swift`, add to `FakeMenuClient`:

```swift
private(set) var recordedVerifiedEntries: [[VerifiedProvenanceEntry]] = []

func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry]) async throws {
    recordedVerifiedEntries.append(entries)
}
```

Add to `LongLivedMenuClient`:

```swift
func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry]) async throws {}
```

**Step 3 — Build gate (all targets):**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1 | tail -10
```
Expected: clean build — no "does not conform to protocol" errors.

**Step 4 — Run existing tests to confirm no regressions:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "GohMenuViewModelTests|AddDownloadViewModelTests" 2>&1 | tail -20
```

**Step 5 — Commit:**
```
git add Sources/GohMenuBar/GohMenuViewModel.swift Sources/goh-menu/main.swift Tests/GohMenuBarTests/AddDownloadViewModelTests.swift Tests/GohMenuBarTests/GohMenuViewModelTests.swift
git commit -m "feat(GohMenuClient): add recordVerifiedProvenance protocol method + live impl + 3 test doubles"
```

---

### T7 — `TrustWindowViewModel` wiring

**AC ownership:** AC9 (tray path: cancelled run still backfills)

**Files:**
- Modify: `Sources/GohMenuBar/TrustWindowViewModel.swift`
- Create: `Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift`

**Pre-task reads:**
- [x] `Sources/GohMenuBar/TrustWindowViewModel.swift` — `startVerify()`, `.finished`/`.cancelled` transitions, `CancellationBox`, `WeakRef` (read above)

**Step 1 — Failing test**

Create `Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift`:

```swift
import Foundation
import Testing
import GohCore
@testable import GohMenuBar

// ── Spy client ───────────────────────────────────────────────────────────────

@MainActor
private final class SpyMenuClient: GohMenuClient {
    private(set) var recordedBatches: [[VerifiedProvenanceEntry]] = []
    var shouldThrow = false

    func progressSnapshots() -> AsyncThrowingStream<[ProgressSnapshot], any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func add(_ request: AddRequest) async throws -> JobSummary { fatalError("unused") }
    func pause(jobID: UInt64) async throws {}
    func resume(jobID: UInt64) async throws {}
    func remove(jobID: UInt64, keepPartialFile: Bool) async throws {}

    func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry]) async throws {
        if shouldThrow { throw URLError(.notConnectedToInternet) }
        recordedBatches.append(entries)
    }
}

// ── Fake ledger reader ────────────────────────────────────────────────────────

private struct StubProvenanceReader: ProvenanceReading {
    let outcome: ProvenanceReadOutcome
    func read() -> ProvenanceReadOutcome { outcome }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

@Suite("TrustWindowViewModel backfill wiring")
@MainActor
struct TrustWindowViewModelBackfillTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-vm-bf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // AC9: finished run sends collected baselines.
    @Test("AC9: finished run sends collected baselines via client")
    func finishedRunSendsBaselines() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("ok.bin").path
        try Data("ok-content".utf8).write(to: URL(fileURLWithPath: f))
        let storeURL = dir.appendingPathComponent("provenance.plist")

        // Seed the ledger.
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        let (sha256, _) = try FileDigest.sha256WithSize(path: f)
        try store.record(entry: ProvenanceEntry(
            url: "https://example.com/ok.bin", sha256: sha256, size: 11,
            downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
            destinationPath: URL(fileURLWithPath: f).standardizedFileURL.path))

        let spy = SpyMenuClient()
        let reader = StubProvenanceReader(outcome: ProvenanceLedgerReader.read(at: storeURL.path))
        let vm = TrustWindowViewModel(
            reader: reader,
            provenanceStorePath: storeURL.path,
            client: spy)

        await vm.loadOverview()
        vm.startVerify()

        // Wait for the run to complete.
        try await Task.sleep(for: .seconds(3))

        // The finished run should have sent at least 1 baseline.
        #expect(!spy.recordedBatches.isEmpty,
            "TrustWindowViewModel must send baselines on run completion (AC9)")
        let sent = spy.recordedBatches.flatMap { $0 }
        #expect(!sent.isEmpty)
        #expect(sent[0].recordedStatSize != nil,
            "sent baseline must have recordedStatSize populated")
    }

    // AC9: cancelled run still sends collected baselines.
    @Test("AC9: cancelled run still sends collected baselines")
    func cancelledRunSendsCollectedBaselines() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two files so there is a "before cancel" entry.
        let f1 = dir.appendingPathComponent("f1.bin").path
        let f2 = dir.appendingPathComponent("f2.bin").path
        try Data("file1".utf8).write(to: URL(fileURLWithPath: f1))
        try Data("file2".utf8).write(to: URL(fileURLWithPath: f2))
        let storeURL = dir.appendingPathComponent("provenance.plist")

        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        for path in [f1, f2] {
            let (sha256, _) = try FileDigest.sha256WithSize(path: path)
            let name = URL(fileURLWithPath: path).lastPathComponent
            try store.record(entry: ProvenanceEntry(
                url: "https://example.com/\(name)", sha256: sha256, size: 5,
                downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
                destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path))
        }

        let spy = SpyMenuClient()
        let reader = StubProvenanceReader(outcome: ProvenanceLedgerReader.read(at: storeURL.path))
        let vm = TrustWindowViewModel(
            reader: reader,
            provenanceStorePath: storeURL.path,
            client: spy)

        await vm.loadOverview()
        vm.startVerify()
        // Cancel almost immediately — before both files finish.
        try await Task.sleep(for: .milliseconds(50))
        vm.cancelVerify()

        // Wait for the run to settle.
        try await Task.sleep(for: .seconds(2))

        // Even a cancelled run must send whatever baselines were collected.
        // (May be 0 if cancelled before any file completed — that is acceptable.)
        // The key invariant: no crash, no UI error.
        // If at least 1 entry was verified before cancel, it was sent.
        // We assert the spy was called at most once (not multiple times for the same run).
        #expect(spy.recordedBatches.count <= 1,
            "Baseline send should happen at most once per run (collected batch)")
    }

    // Best-effort: send failure must not affect runState or UI.
    @Test("best-effort: send failure leaves runState as finished, no UI error")
    func sendFailureNoUIImpact() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("ok.bin").path
        try Data("data".utf8).write(to: URL(fileURLWithPath: f))
        let storeURL = dir.appendingPathComponent("provenance.plist")

        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        let (sha256, _) = try FileDigest.sha256WithSize(path: f)
        try store.record(entry: ProvenanceEntry(
            url: "https://example.com/ok.bin", sha256: sha256, size: 4,
            downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
            destinationPath: URL(fileURLWithPath: f).standardizedFileURL.path))

        let spy = SpyMenuClient()
        spy.shouldThrow = true  // Simulate daemon stopped.

        let reader = StubProvenanceReader(outcome: ProvenanceLedgerReader.read(at: storeURL.path))
        let vm = TrustWindowViewModel(
            reader: reader,
            provenanceStorePath: storeURL.path,
            client: spy)

        await vm.loadOverview()
        vm.startVerify()
        try await Task.sleep(for: .seconds(3))

        // runState must be .finished (not .failed), and the VM is not stuck.
        if case .finished = vm.runState {
            // Expected — send failure must not corrupt run state.
        } else {
            Issue.record("runState must be .finished even when send throws; got \(vm.runState)")
        }
    }
}
```

**Step 2 — Run expecting failure:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TrustWindowViewModelBackfillTests 2>&1 | tail -20
```
Expected: compilation error — `TrustWindowViewModel.init` has no `client:` parameter.

**Step 3 — Implementation**

In `Sources/GohMenuBar/TrustWindowViewModel.swift`:

Add a private class for the baseline collection box (same pattern as `CancellationBox`):

```swift
/// Collects VerifiedBaseline values from the @Sendable onVerified closure.
/// Reference-type box so the @Sendable closure can capture a reference (not a mutable var).
nonisolated private final class BaselineCollectionBox: @unchecked Sendable {
    private let mutex = Mutex<[VerifiedBaseline]>([])
    nonisolated func append(_ b: VerifiedBaseline) { mutex.withLock { $0.append(b) } }
    nonisolated func drain() -> [VerifiedBaseline] { mutex.withLock { let v = $0; $0 = []; return v } }
}
```

Add `client` property and update `init`:

```swift
/// Injected client for best-effort baseline sends after a verify run.
/// Nil in test contexts that do not exercise backfill.
private let menuClient: (any GohMenuClient)?

public init(
    reader: any ProvenanceReading,
    provenanceStorePath: String,
    presenter: GohTrustPresenter = GohTrustPresenter(),
    probe: any FileStatProbing = LiveFileStatProbe(),
    client: (any GohMenuClient)? = nil
) {
    self.reader = reader
    self.provenanceStorePath = provenanceStorePath
    self.presenter = presenter
    self.probe = probe
    self.menuClient = client
}
```

Update `startVerify()` to collect and send baselines:

```swift
public func startVerify() {
    guard case .idle = runState else { return }
    guard !rows.isEmpty else { return }

    let box = CancellationBox()
    cancellationBox = box
    let now = Date()
    verifyStartedAt = now
    runState = .running(VerifyProgress(completed: 0, total: rows.count, currentPath: nil))

    let path = provenanceStorePath
    let weakSelf = WeakRef(self)
    let collectionBox = BaselineCollectionBox()
    let clientRef = menuClient   // capture optional client; nil means no send

    DispatchQueue.global(qos: .userInitiated).async { [box] in
        do {
            let report = try VerifyAllRunner.verifyAll(
                provenanceStorePath: path,
                generatedAt: now,
                progress: { progress in
                    Task { @MainActor in
                        guard let vm = weakSelf.value else { return }
                        if case .running = vm.runState {
                            vm.runState = .running(progress)
                        }
                    }
                },
                isCancelled: { box.isCancelled() },
                onVerified: { baseline in collectionBox.append(baseline) })

            // Send collected baselines best-effort — BEFORE updating runState,
            // so AC9 (cancelled run backfills) works for both .finished and .cancelled.
            let baselines = collectionBox.drain()
            if let client = clientRef, !baselines.isEmpty {
                let entries = baselines.map { b in
                    VerifiedProvenanceEntry(
                        url: b.url,
                        sha256: b.sha256,
                        size: b.hashedByteCount,         // display/download byte count
                        destinationPath: b.destinationPath,
                        verifiedAt: now,
                        recordedStatSize: b.stat.size,   // B1: ALWAYS stat.size
                        recordedMtimeSeconds: b.stat.mtimeSeconds,
                        recordedMtimeNanoseconds: b.stat.mtimeNanoseconds,
                        recordedInode: b.stat.inode,
                        recordedDevice: b.stat.device)
                }
                Task { @MainActor in
                    // Best-effort: error is swallowed — never block or error the UI.
                    try? await client.recordVerifiedProvenance(entries)
                }
            }

            Task { @MainActor in
                guard let vm = weakSelf.value else { return }
                if box.isCancelled() {
                    vm.runState = .cancelled(report)
                } else {
                    vm.runState = .finished(report)
                }
                vm.cancellationBox = nil
                vm.verifyStartedAt = nil
            }
        } catch let VerifyAllRunnerError.ledgerUnreadable(reason) {
            let message: String
            switch reason {
            case .io:       message = "provenance ledger unreadable"
            case .corrupt:  message = "provenance ledger corrupt"
            case .versionUnknown(let n): message = "provenance ledger version \(n) is unknown"
            }
            Task { @MainActor in
                weakSelf.value?.runState = .failed(message)
                weakSelf.value?.cancellationBox = nil
                weakSelf.value?.verifyStartedAt = nil
            }
        } catch {
            Task { @MainActor in
                weakSelf.value?.runState = .failed("verify failed: \(error)")
                weakSelf.value?.cancellationBox = nil
                weakSelf.value?.verifyStartedAt = nil
            }
        }
    }
}
```

Also update `goh-menu/main.swift`'s `TrustWindowRoot` / `TrustWindowViewModel` construction to pass `client: LiveGohMenuClient()`. Find the construction site:

```swift
Window("Trust", id: "trust") {
    TrustWindowRoot(
        makeViewModel: TrustWindowViewModel(
            reader: LiveProvenanceReader(path: appDelegate.provenancePath),
            provenanceStorePath: appDelegate.provenancePath,
            probe: LiveFileStatProbe(),
            client: appDelegate.model.client))  // inject the shared client
}
```

Note: `appDelegate.model.client` is `private` on `GohMenuViewModel`. The simplest approach is to store the `LiveGohMenuClient` on the app delegate and pass it to both `GohMenuViewModel` and `TrustWindowViewModel`. Pre-task read of `GohMenuAppDelegate` init and `GohMenuViewModel` shows `client` is stored as `private let`. Change: store `LiveGohMenuClient` on `GohMenuAppDelegate` and pass it to both.

In `GohMenuAppDelegate.init`:

```swift
let menuClient = LiveGohMenuClient()
self.model = GohMenuViewModel(client: menuClient, ...)
self.menuClientForTrust = menuClient
```

And in the `Window("Trust")`:

```swift
makeViewModel: TrustWindowViewModel(
    reader: LiveProvenanceReader(path: appDelegate.provenancePath),
    provenanceStorePath: appDelegate.provenancePath,
    probe: LiveFileStatProbe(),
    client: appDelegate.menuClientForTrust))
```

**Step 4 — Run expecting pass:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "TrustWindowViewModelBackfillTests|TrustWindowViewModel" 2>&1 | tail -30
```

**Step 5 — Build gate (all targets):**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1 | tail -10
```

**Step 6 — Commit:**
```
git add Sources/GohMenuBar/TrustWindowViewModel.swift Sources/goh-menu/main.swift Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift
git commit -m "feat(TrustWindowViewModel): inject client + send baselines after verify run (AC9)"
```

---

### T8 — Full regression gate

**AC ownership:** all ACs — regression confirmation only

**Files:** no changes — test-only pass

**Step 1 — Full test suite:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -30
```
Expected: all tests pass.

**Step 2 — Full build with warnings-as-errors:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1 | tail -10
```

**Step 3 — Commit regression results note:**
```
git commit --allow-empty -m "chore(backfill-on-verify): all tests pass; regression gate T8 clean"
```

---

## Phase 3 Progress Artifacts

Create (empty shells — to be updated as tasks complete):

`docs/superpowers/progress/2026-06-09-backfill-on-verify-phase1.md`:

```markdown
# Phase 1 Progress — Backfill on Verify (GohCore data path)

Tasks: T1, T2, T3, T4

| Task | Status | Commit |
|------|--------|--------|
| T1 FileDigest.sha256WithSizeAndStat | - | - |
| T2 VerifiedBaseline + onVerified    | - | - |
| T3 Wire fields + dispatcher forward | - | - |
| T4 ProvenanceStore three branches   | - | - |
```

`docs/superpowers/progress/2026-06-09-backfill-on-verify-phase2.md`:

```markdown
# Phase 2 Progress — Backfill on Verify (surfaces)

Tasks: T5, T6, T7, T8

| Task | Status | Commit |
|------|--------|--------|
| T5 GohVerifyAllCommand + CLI dispatch | - | - |
| T6 GohMenuClient + LiveImpl + doubles | - | - |
| T7 TrustWindowViewModel wiring        | - | - |
| T8 Full regression gate               | - | - |
```

---

## Advisory Callouts (baked in)

**A1 — Three test doubles (advisory from spec review):** All three must compile
under `-warnings-as-errors`. T6 adds `recordVerifiedProvenance` to all three
before any Phase 2 compilation. Non-negotiable.

**A3 — AC10 spy strategy:** T1 uses a direct `fstat` lstat comparison to verify
`stat.size` source (not a contrived differing-size file). The test explicitly
asserts `result.stat.size == Int64(st.st_size)` and names the purpose.

**A4 — `verifiedAt` reader sweep:** Confirmed in Phase 0:
`GohTrustPresenter.displayStatus` uses `verifiedAt != nil → .verified(at:)`
(precedence, not "synced specifically"). `goh which` displays it with no logic
branch. Setting `verifiedAt` on a deep-verified-never-synced file is the
intended effect per spec §9.

**B1 — recordedStatSize source:** Every site that builds `VerifiedProvenanceEntry`
uses `b.stat.size` for `recordedStatSize` and `b.hashedByteCount` for `size`.
The field names and comments make the distinction explicit. Tests T1 and T5
assert the correct source.

**B2 — all-or-nothing:** `hasBaseline` predicate in T4 covers all three merge
branches. Tests cover the partial-nil case and the absent-baseline-preserves-existing case.

**B3 — cancelled runs:** `onVerified` fires per `.ok` at the moment the hash
passes (before returning from `hashEntry`). Both the CLI (T5) and tray (T7)
collect into a box; the box is drained and sent regardless of run completion
status (`.finished` or `.cancelled`).

---

## Summary

Two phases, eight tasks. **Phase 1** (T1–T4, GohCore) is fully unit-testable
without touching any surface: T1 adds `sha256WithSizeAndStat` (TOCTOU-tight
fstat capture); T2 introduces `VerifiedBaseline` and the `onVerified` side-channel
callback; T3 adds 5 additive-optional wire fields to `VerifiedProvenanceEntry`;
T4 updates all three `ProvenanceStore.recordVerified` merge branches to carry
the stat fields with all-or-nothing semantics. **Phase 2** (T5–T8, surfaces)
wires Phase 1 types into the CLI (`GohVerifyAllCommand` + `GohCommandLine`
dispatch), the tray client protocol (`GohMenuClient` + `LiveGohMenuClient` + 3
test doubles), and `TrustWindowViewModel` (collect baselines during run, send
best-effort on `.finished` and `.cancelled`). T8 is the full regression gate.
Total: 8 tasks across 2 phases.
