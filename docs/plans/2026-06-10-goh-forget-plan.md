---
date: 2026-06-10
feature: goh-forget
plan-version: 1
REQUIRED_SUBSKILL: superpowers:subagent-driven-development
---

# Implementation Plan — `goh forget`

## Header

**Goal:** Deliver `goh forget <path>` and `goh forget --missing [--confirm]` —
the first provenance-ledger removal path in goh, let users expunge stale entries
without touching files on disk.

**Architecture:** Preview-and-Confirm (THE BET: "Users and scripts prefer an
explicit two-step (`--missing` then `--confirm`) over a one-step prompt." Backed
by research on restic/borg/docker prune patterns and goh's existing `--force`
flag precedent over TTY prompts.) The git-rm model applies to explicit single-path
removes (naming the path IS the confirmation); `--missing` bulk removes are gated
behind `--confirm` because "missing" can mean "unmounted drive, not deleted."

**Tech Stack:** Swift 6 language mode, swift-tools-version 6.2, macOS 26+,
modern low-level Swift XPC (protocolVersion 4), CryptoKit SHA-256, binary-plist
provenance store, Swift Testing (NOT XCTest), golden-file fixtures, CI
`-warnings-as-errors` on macos-26.

**Phase segmentation:**
- **Phase 1 (this plan, independently shippable):** CLI + daemon + store + wire + fixtures + featureLevel bump. Delivers AC1–AC4, gap #1, gap #2.
- **Phase 2 (deferred):** Tray GohMenuClient.forget + TrustWindowViewModel + SwiftUI affordance. Delivers AC5. Depends on Phase 1 daemon being live.

---

## AC → Task Mapping (Phase 0.5)

| AC | Mapped to Task | Test stub name |
|----|---------------|---------------|
| AC1 | Task 5 (`GohForgetCommand` — explicit path path), Task 6 (CLI parse/dispatch) | `testForgetTrackedPathExits0WithConfirmation`, `testForgetRoundTripsVerifyAll`, `testForgetRoundTripsVerifyQuick` |
| AC2 | Task 5 (`--missing` dry-run + `--confirm` mutating path) | `testMissingDryRunNeverMutatesLedger`, `testMissingConfirmForgetsAllAbsentLeavesPresent`, `testMissingConfirmSendsStoredPathsVerbatim`, `testPartialForgotCountSurfacesNonSuccess` |
| AC3 | Task 5 (untracked-path guard + corrupt-ledger guard) | `testForgetUntrackedPathExits1WithNotTrackedMessage`, `testForgetUntrackedNeverSendsCommand`, `testForgetCorruptLedgerExits6SendsNothing` |
| AC4 | Task 1 (`ProvenanceStore.forget`) | `testForgetWritesAtomically`, `testForgetFileSafetyPresentFileUntouched`, `testForgetEmptyPathsIsNoOp` |
| AC5 | Phase 2 (deferred) | — |

---

## Phase 2 File Map

All Phase 1 files; see Task breakdown below.

### Files Modified

| File | Adds | Exists? |
|------|------|---------|
| `Sources/GohCore/Provenance/ProvenanceStore.swift` | `forget(paths:) throws -> Int` | ✓ |
| `Sources/GohCore/Model/Command.swift` | `case forgetProvenance(request: ForgetProvenanceRequest)` + `ForgetProvenanceRequest` struct | ✓ |
| `Sources/GohCore/Model/CommandReply.swift` | `ForgetProvenanceReply` struct | ✓ |
| `Sources/GohCore/Model/CommandOutcome.swift` | `case forgotProvenance(ForgetProvenanceReply)` | ✓ |
| `Sources/GohCore/Model/CommandService.swift` | `encodeReply` arm for `.forgotProvenance` | ✓ |
| `Sources/GohCore/Model/CommandDispatcher.swift` | `case .forgetProvenance` in exhaustive switch | ✓ |
| `Sources/GohCore/Model/GohFeatureLevel.swift` | `current: Int = 1 → 2` | ✓ |
| `Sources/GohCore/CLI/GohCommandLine.swift` | `ParsedCommand.forget`, `case .forget` in `run()`, `case "forget"` in `parse()`, usage line | ✓ |

### Files Created

| File | Responsibility |
|------|---------------|
| `Sources/GohCore/CLI/GohForgetCommand.swift` | CLI runner: explicit path + `--missing` + `--confirm` + mount annotation + skew gate |
| `Tests/GohCoreTests/Fixtures/envelope-v4-forget-provenance-request.json` | Golden wire fixture — request |
| `Tests/GohCoreTests/Fixtures/envelope-v4-forget-provenance-reply.json` | Golden wire fixture — reply |
| `Tests/GohCoreTests/ForgetProvenanceStoreTests.swift` | AC4 store-level tests |
| `Tests/GohCoreTests/GohForgetCommandTests.swift` | AC1–AC3 + gap tests |
| `Tests/GohCoreTests/EnvelopeCodecTests+ForgetProvenance.swift` | Golden fixture round-trip tests |
| `docs/superpowers/progress/2026-06-10-goh-forget-phase1.md` | Phase 2 interface contract |

---

## Dependency Order

```
Task 0  STATE.md branch note
Task 1  ProvenanceStore.forget (store method + tests)
Task 2  Command wire types (ForgetProvenanceRequest, ForgetProvenanceReply, CommandOutcome.forgotProvenance, CommandService arm)
Task 3  GohFeatureLevel bump 1→2 + DESIGN.md paragraph
Task 4  Golden fixtures + EnvelopeCodec tests  ← depends on Task 2
Task 5  GohForgetCommand CLI runner             ← depends on Tasks 1, 2, 3, 4
Task 6  GohCommandLine parse/dispatch + usage   ← depends on Task 5
Task 7  CommandDispatcher case                   ← depends on Tasks 1, 2
Task 8  Phase 1 artifact + integration verify
```

Tasks 2 and 3 are independent of each other.
Tasks 4 and 7 are independent of each other (both depend on Task 2).
Task 7 is independent of Tasks 4, 5, 6.
Task 5 depends on Tasks 1, 2, 3, 4 (needs the gate logic and all types).

---

## Task 0 — Branch + STATE.md note

**Pre-task reads:** `STATE.md`, `ROADMAP.md` (orientation only — no file edits specified from memory).

### Step 0.1 — Create branch

```bash
git checkout -b feat/goh-forget
```

Expected: new branch `feat/goh-forget` checked out.

### Step 0.2 — Update STATE.md

Add a "Current slice" entry: `goh forget — Phase 1 (CLI + daemon + store + wire)`, branch `feat/goh-forget`, started `2026-06-10`. No other STATE.md content modified.

### Step 0.3 — Build baseline

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: `Build complete!` with zero errors. Record any existing warnings as baseline (they must not increase).

### Step 0.4 — Commit

```bash
git add STATE.md
git commit -m "chore(state): open feat/goh-forget branch — Phase 1 CLI + daemon + store + wire"
```

---

## Task 1 — `ProvenanceStore.forget(paths:) throws -> Int`

**AC mapping:** AC4 (`testForgetWritesAtomically`, `testForgetFileSafetyPresentFileUntouched`, `testForgetEmptyPathsIsNoOp`)

### Pre-task reads

- `Sources/GohCore/Provenance/ProvenanceStore.swift` — READ IN FULL before writing any code.
  Confirm: `writeAtomically(_:)` is a private method taking `inout ProvenanceRecord`; `inner` is a `Mutex<Inner>`; `Inner.record.entries` is `[ProvenanceEntry]`; `ProvenanceEntry.destinationPath` is `String` (stored canonical); `ProvenanceRecord.currentVersion` is `1`. Verify no existing `forget` or `delete` method exists.

### Step 1.1 — Write failing tests (TDD)

Create `Tests/GohCoreTests/ForgetProvenanceStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import GohCore

@Suite("ProvenanceStore.forget")
struct ForgetProvenanceStoreTests {

    // MARK: - Helpers

    private func makeStore(entries: [ProvenanceEntry]) throws -> (ProvenanceStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "goh-forget-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "provenance.plist")
        let store = ProvenanceStore(fileURL: url)
        // Pre-populate by recording each entry individually.
        for entry in entries {
            try store.record(entry: entry)
        }
        return (store, url)
    }

    private func makeEntry(path: String, url: String = "https://example.com/f.bin") -> ProvenanceEntry {
        ProvenanceEntry(
            url: url,
            sha256: "sha256:" + String(repeating: "a", count: 64),
            size: 1024,
            downloadedAt: Date(timeIntervalSince1970: 0),
            destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path,
            verifiedAt: nil)
    }

    // MARK: - AC4 tests

    @Test("empty paths is a no-op — returns 0, no disk write")
    func testForgetEmptyPathsIsNoOp() throws {
        let (store, url) = try makeStore(entries: [makeEntry(path: "/tmp/a.bin")])
        let before = try Data(contentsOf: url)
        let removed = try store.forget(paths: [])
        let after = try Data(contentsOf: url)
        #expect(removed == 0)
        #expect(before == after, "no-op forget must not touch the ledger on disk")
    }

    @Test("forget removes a matching entry and returns 1")
    func testForgetTrackedEntry() throws {
        let path = "/tmp/goh-forget-test-\(UUID().uuidString)/file.bin"
        let (store, _) = try makeStore(entries: [makeEntry(path: path)])
        let removed = try store.forget(paths: [path])
        #expect(removed == 1)
        #expect(store.lookup(destinationPath: path) == nil)
    }

    @Test("forget untracked path returns 0 and leaves ledger unchanged")
    func testForgetUntrackedReturns0() throws {
        let tracked = "/tmp/tracked.bin"
        let untracked = "/tmp/untracked.bin"
        let (store, url) = try makeStore(entries: [makeEntry(path: tracked)])
        let before = try Data(contentsOf: url)
        let removed = try store.forget(paths: [untracked])
        let after = try Data(contentsOf: url)
        #expect(removed == 0)
        #expect(before == after, "no-match forget must not rewrite the ledger")
    }

    @Test("forget leaves non-requested entries intact")
    func testForgetLeavesOtherEntriesIntact() throws {
        let a = "/tmp/a.bin"
        let b = "/tmp/b.bin"
        let (store, _) = try makeStore(entries: [makeEntry(path: a), makeEntry(path: b)])
        let removed = try store.forget(paths: [a])
        #expect(removed == 1)
        #expect(store.lookup(destinationPath: a) == nil)
        #expect(store.lookup(destinationPath: b) != nil)
    }

    @Test("forget multiple paths — removes all matching, returns correct count")
    func testForgetMultiplePaths() throws {
        let a = "/tmp/ma.bin"
        let b = "/tmp/mb.bin"
        let c = "/tmp/mc.bin"
        let (store, _) = try makeStore(entries: [
            makeEntry(path: a), makeEntry(path: b), makeEntry(path: c)])
        let removed = try store.forget(paths: [a, b])
        #expect(removed == 2)
        #expect(store.lookup(destinationPath: a) == nil)
        #expect(store.lookup(destinationPath: b) == nil)
        #expect(store.lookup(destinationPath: c) != nil)
    }

    // AC4: atomic write — the rewritten file decodes as a valid ProvenanceRecord
    @Test("forget writes atomically — result decodes as valid ProvenanceRecord version 1")
    func testForgetWritesAtomically() throws {
        let path = "/tmp/atomic-\(UUID().uuidString).bin"
        let (store, url) = try makeStore(entries: [makeEntry(path: path)])
        _ = try store.forget(paths: [path])
        let data = try Data(contentsOf: url)
        let record = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
        #expect(record.version == ProvenanceRecord.currentVersion)
        #expect(record.entries.isEmpty)
    }

    // AC4 / M7 (gap #2): file-safety — forget never touches the file at the path
    @Test("forget never modifies the file at the requested path — file-safety invariant")
    func testForgetFileSafetyPresentFileUntouched() throws {
        // Write a real file.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "goh-forget-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filePath = dir.appending(path: "target.bin").path
        let originalBytes = Data("hello provenance".utf8)
        try originalBytes.write(to: URL(fileURLWithPath: filePath))

        let (store, _) = try makeStore(entries: [makeEntry(path: filePath)])
        _ = try store.forget(paths: [filePath])

        // File must still exist and be byte-identical.
        let afterBytes = try Data(contentsOf: URL(fileURLWithPath: filePath))
        #expect(afterBytes == originalBytes, "forget must NEVER modify the file at the path")
        #expect(store.lookup(destinationPath: filePath) == nil, "entry must be gone from the ledger")
    }

    @Test("forget canonicalizes trailing-slash path — no crash, valid result")
    func testForgetTrailingSlashCanonicalization() throws {
        let path = "/tmp/goh-slash-\(UUID().uuidString)/file.bin"
        let (store, url) = try makeStore(entries: [makeEntry(path: path)])
        // A trailing slash appended to a file path does not match the stored canonical key
        // (standardizedFileURL resolves differently). Assert: no crash, ledger is still valid.
        let removed = try store.forget(paths: [path + "/"])
        #expect(removed == 0 || removed == 1)
        let data = try Data(contentsOf: url)
        let record = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
        #expect(record.version == ProvenanceRecord.currentVersion)
    }
}

### Step 1.2 — Run failing tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ForgetProvenanceStoreTests -Xswiftc -warnings-as-errors 2>&1
```

Expected: compile error — `ProvenanceStore` has no `forget` method. (If it errors on `ProvenanceEntry` initializer missing `verifiedAt`, adjust the helper to use nil.)

### Step 1.3 — Implement `ProvenanceStore.forget(paths:)`

Read `Sources/GohCore/Provenance/ProvenanceStore.swift` in full. Add the following
after `allEntries()` in the `// MARK: — Read` section (before `// MARK: — Private helpers`):

```swift
    // MARK: — Delete

    /// Removes every entry whose canonical `destinationPath` matches one of `paths`,
    /// then atomically rewrites the ledger. Empty `paths` is a no-op (no lock, no
    /// write). A path matching no entry is silently skipped (idempotent).
    ///
    /// INVARIANT (security): this method mutates `record.entries[]` ONLY. It MUST
    /// NEVER unlink, truncate, or modify any file at any of `paths`. The only
    /// filesystem writes are `writeAtomically`'s own temp/target/dir operations.
    ///
    /// Each input path is canonicalized via
    /// `URL(fileURLWithPath:).standardizedFileURL.path` before matching, exactly
    /// as `recordVerified` / `lookup` do — stored keys are already canonical.
    ///
    /// Returns the number of entries actually removed. Throws on `writeAtomically`
    /// failure (the dispatcher turns that into a failure reply — not a best-effort .ack).
    @discardableResult
    public func forget(paths: [String]) throws -> Int {
        guard !paths.isEmpty else { return 0 }
        let canonical = Set(paths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        return try inner.withLock { inner in
            let before = inner.record.entries.count
            inner.record.entries.removeAll { canonical.contains($0.destinationPath) }
            let removed = before - inner.record.entries.count
            // Only write when something actually changed — avoids a needless atomic
            // rewrite (and fsync) when no requested path matched.
            if removed != 0 {
                try writeAtomically(&inner.record)
            }
            return removed
        }
    }
```

### Step 1.4 — Run tests green

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ForgetProvenanceStoreTests -Xswiftc -warnings-as-errors 2>&1
```

Expected: all `ForgetProvenanceStoreTests` pass. Zero new warnings. `Build complete!` before the test run.

### Step 1.5 — Full build + test suite

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -Xswiftc -warnings-as-errors 2>&1 && \
  swift test -Xswiftc -warnings-as-errors 2>&1
```

Expected: `Build complete!`, all tests pass.

### Step 1.6 — Commit

```bash
git add Sources/GohCore/Provenance/ProvenanceStore.swift \
        Tests/GohCoreTests/ForgetProvenanceStoreTests.swift
git commit -m "feat(provenance): ProvenanceStore.forget(paths:) — atomic ledger-entry removal (AC4)"
```

---

## Task 2 — Wire types: `ForgetProvenanceRequest`, `ForgetProvenanceReply`, `CommandOutcome.forgotProvenance`, `CommandService.encodeReply` arm

**AC mapping:** wire contract for AC1, AC2, AC4.

### Pre-task reads

- `Sources/GohCore/Model/Command.swift` — READ IN FULL. Confirm the `Command` enum has 8 cases; `RecordVerifiedProvenanceRequest` shape as template. No existing `forgetProvenance` case.
- `Sources/GohCore/Model/CommandReply.swift` — READ IN FULL. Confirm `AckReply` and `RmReply` exist; no `ForgetProvenanceReply`.
- `Sources/GohCore/Model/CommandOutcome.swift` — READ IN FULL. Confirm 6 cases: `.job`, `.list`, `.removed`, `.authImported`, `.ack`, `.failure`. No `.forgotProvenance`.
- `Sources/GohCore/Model/CommandService.swift` — READ IN FULL. Confirm `encodeReply`'s exhaustive switch; the `.ack` arm as template for the new arm.

### Step 2.1 — Add `ForgetProvenanceRequest` to `Command.swift`

After the closing brace of `RecordVerifiedProvenanceRequest` (around line 79), add:

```swift
/// The `forgetProvenance` command's request payload.
/// Removes the ledger entries whose canonical `destinationPath` matches one of
/// `paths`. The daemon canonicalizes each path via
/// `URL(fileURLWithPath:).standardizedFileURL.path` before matching (the
/// `recordVerifiedProvenance` precedent). A path matching no entry is a no-op.
/// `forgetProvenance` NEVER touches the file at any path — it removes ledger
/// entries only. Reply is `ForgetProvenanceReply`, carrying the count actually
/// removed (`forgotCount`).
public struct ForgetProvenanceRequest: Codable, Sendable, Equatable {
    public var paths: [String]
    public init(paths: [String]) { self.paths = paths }
}
```

And add to the `Command` enum (after `case recordVerifiedProvenance(request: RecordVerifiedProvenanceRequest)`):

```swift
    case forgetProvenance(request: ForgetProvenanceRequest)
```

### Step 2.2 — Add `ForgetProvenanceReply` to `CommandReply.swift`

After `AckReply` (end of file), add:

```swift
/// The `forgetProvenance` command's success reply.
/// `forgotCount` is the number of ledger entries actually removed by this call
/// (entries whose canonical `destinationPath` matched a requested path). The CLI
/// asserts `forgotCount == paths.count`; a smaller count is a non-success outcome.
public struct ForgetProvenanceReply: Codable, Sendable, Equatable {
    public var forgotCount: Int
    public init(forgotCount: Int) { self.forgotCount = forgotCount }
}
```

### Step 2.3 — Add `CommandOutcome.forgotProvenance` to `CommandOutcome.swift`

After `case ack` (before `case failure`), add:

```swift
    /// `forgetProvenance` — the count of entries actually removed.
    case forgotProvenance(ForgetProvenanceReply)
```

### Step 2.4 — Add `encodeReply` arm to `CommandService.swift`

In `encodeReply(for:requestID:)`, after `case .ack:` arm (around line 219), add:

```swift
        case .forgotProvenance(let reply):
            return try replyEnvelope(requestID: requestID, payload: reply)
```

### Step 2.5 — Build to confirm exhaustive-switch compile error in CommandDispatcher

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: **build fails** with a "switch must be exhaustive" error on `CommandDispatcher.reply(to:)` — this confirms the exhaustive switch is catching the new case as required. `CommandService` should compile cleanly because its `handle` method uses `default`.

### Step 2.6 — Stub out dispatcher case (temporary, to allow remaining tasks to build)

In `CommandDispatcher.swift`, add a temporary case that will be replaced in Task 7:

```swift
            case .forgetProvenance:
                // TODO Task 7: implement forgetProvenance dispatch
                return .failure(GohError(code: .invalidArgument, message: "forgetProvenance not yet implemented"))
```

### Step 2.7 — Build green

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: `Build complete!`.

### Step 2.8 — Full test suite

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test -Xswiftc -warnings-as-errors 2>&1
```

Expected: all existing tests pass.

### Step 2.9 — Commit

```bash
git add Sources/GohCore/Model/Command.swift \
        Sources/GohCore/Model/CommandReply.swift \
        Sources/GohCore/Model/CommandOutcome.swift \
        Sources/GohCore/Model/CommandService.swift \
        Sources/GohCore/Model/CommandDispatcher.swift
git commit -m "feat(wire): forgetProvenance Command case + ForgetProvenanceRequest/Reply + CommandOutcome.forgotProvenance"
```

---

## Task 3 — `GohFeatureLevel.current` 1 → 2 + DESIGN.md paragraph

### Pre-task reads

- `Sources/GohCore/Model/GohFeatureLevel.swift` — READ IN FULL. Confirm `current: Int = 1`. No other state.
- `DESIGN.md` — READ the featureLevel-1 section to reproduce its doc style exactly.

### Step 3.1 — Bump featureLevel

In `Sources/GohCore/Model/GohFeatureLevel.swift`, change `public static let current: Int = 1` to:

```swift
    public static let current: Int = 2
```

### Step 3.2 — Add DESIGN.md paragraph

Read the existing featureLevel section in `DESIGN.md` and add after the featureLevel-1 paragraph:

```
**featureLevel 2** (`GohFeatureLevel.current = 2`, merged with `feat/goh-forget`)
— the daemon honors the `forgetProvenance` command (`Command.forgetProvenance`,
`ForgetProvenanceRequest`, `ForgetProvenanceReply`). A new CLI (`featureLevel < 2`
or unreachable) refuses to send `forgetProvenance` with a clear "daemon too old"
message and exit 1, rather than silently dropping the command. A CLI older than
featureLevel 2 ignores this bump — `LsReply.featureLevel` is additive-optional.
`GohFeatureLevel.current` goes `1 → 2` in the same commit as the dispatcher case
and CLI runner.

Error-handling divergence: `forgetProvenance` returns a structured `.failure` reply
when `ProvenanceStore.forget(paths:)` throws (e.g. atomic-write / rename failure),
rather than mirroring `recordVerifiedProvenance`'s best-effort `.ack`-on-throw. A
destructive ledger mutation that fails mid-write must be surfaced to the caller as
a non-zero exit, not silently swallowed.
```

### Step 3.3 — Update `DaemonFeatureLevelTests.swift` to match new `current`

`Tests/GohCoreTests/DaemonFeatureLevelTests.swift` contains a test that hard-asserts
`GohFeatureLevel.current == 1`. Bumping `current` to 2 breaks it. Edit that file now,
in the same step as the source bump, so the commit is atomic (green test ships with
the change):

- **Change line 8:** `@Test("current is a positive integer and equals 1")` → `@Test("current is a positive integer and equals 2")`
- **Change line 9:** `func currentIsOne()` → `func currentIsTwo()`
- **Change line 10:** `#expect(GohFeatureLevel.current == 1)` → `#expect(GohFeatureLevel.current == 2)`

**Must NOT change:** The two uses of `featureLevel: 1` at lines 19 and 33 inside
`lsReplyFeatureLevelRoundTrip()` — those are wire-decode tests that construct
`LsReply(jobs: [], featureLevel: 1)` and assert the JSON round-trip encodes/decodes
`1`. They are testing the additive-optional decode behaviour of `LsReply.featureLevel`,
not `GohFeatureLevel.current`. Leave them as-is.

### Step 3.4 — Build

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: `Build complete!`. DaemonAutoHeal.swift uses `GohFeatureLevel.current` — this now compares against 2. Confirm `DaemonAutoHeal` tests still pass (they do not pin `current` to a literal — they observe the relative comparison).

### Step 3.5 — Full test suite

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test -Xswiftc -warnings-as-errors 2>&1
```

Expected: all tests pass. `DaemonFeatureLevelTests.currentIsTwo` passes; `lsReplyFeatureLevelRoundTrip` still uses `featureLevel: 1` literals and still passes (those literals test the wire-decode path, not `GohFeatureLevel.current`). No other test should pin `.current` to a literal.

### Step 3.6 — Commit

```bash
git add Sources/GohCore/Model/GohFeatureLevel.swift \
        Tests/GohCoreTests/DaemonFeatureLevelTests.swift \
        DESIGN.md
git commit -m "feat(daemon): featureLevel 1→2 — forgetProvenance capability signal"
```

---

## Task 4 — Golden fixtures + `EnvelopeCodecTests` round-trip tests

**Depends on:** Task 2 (wire types must exist for decode to succeed).

### Pre-task reads

- `Tests/GohCoreTests/Fixtures/envelope-v4-record-verified-provenance-request.json` — READ to confirm exact key ordering and escape style.
- `Tests/GohCoreTests/Fixtures/envelope-v4-record-verified-provenance-reply.json` — READ to confirm `"payload":{}` style.
- `Tests/GohCoreTests/EnvelopeCodecTests.swift` lines 105–133 — READ to confirm the decode+assert pattern.

### Step 4.1 — Create request fixture

Create `Tests/GohCoreTests/Fixtures/envelope-v4-forget-provenance-request.json`:

```json
{"messageType":"request","payload":{"forgetProvenance":{"request":{"paths":["\/Users\/testuser\/Downloads\/gone.bin","\/Volumes\/Archive\/old.iso"]}}},"protocolVersion":4,"requestID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F"}
```

This is a single line with no trailing newline. Forward slashes are escaped (`\/`) because `CommandCoding.encoder` uses `.sortedKeys` and the JSON encoder escapes them. The key `forgetProvenance` is the synthesized coding key for `Command.forgetProvenance(request:)`.

> **Note:** The exact JSON key generated for `Command.forgetProvenance(request:)` depends on how `Command` derives its `CodingKeys`. Inspect the existing `recordVerifiedProvenance` key in the request fixture (`"recordVerifiedProvenance"`) and the enum case name (`recordVerifiedProvenance`). If `Command` uses synthesized coding (the enum associated-value key is the case name), then `forgetProvenance` will encode as the outer key with `request` as the associated-value label. Verify by running a quick encode in a test and printing the output before committing the fixture.

### Step 4.2 — Create reply fixture

Create `Tests/GohCoreTests/Fixtures/envelope-v4-forget-provenance-reply.json`:

```json
{"messageType":"reply","payload":{"forgotCount":2},"protocolVersion":4,"requestID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F"}
```

Single line, no trailing newline, `.sortedKeys`.

### Step 4.3 — Write failing golden fixture tests

Create `Tests/GohCoreTests/EnvelopeCodecTests+ForgetProvenance.swift`:

```swift
import Foundation
import Testing
@testable import GohCore

@Suite("XPC envelope codec — forgetProvenance golden fixtures")
struct EnvelopeCodecForgetProvenanceTests {

    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing golden fixture: Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    @Test("decodes the protocolVersion=4 forgetProvenance request fixture")
    func decodesV4ForgetProvenanceRequestFixture() throws {
        let data = try fixtureData("envelope-v4-forget-provenance-request")
        let envelope = try CommandCoding.decoder.decode(GohEnvelope<Command>.self, from: data)
        #expect(envelope.protocolVersion == 4)
        #expect(envelope.requestID == UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        #expect(envelope.messageType == .request)
        if case .forgetProvenance(let req) = envelope.payload {
            #expect(req.paths.count == 2)
            #expect(req.paths[0] == "/Users/testuser/Downloads/gone.bin")
            #expect(req.paths[1] == "/Volumes/Archive/old.iso")
        } else {
            Issue.record("expected .forgetProvenance payload, got \(envelope.payload)")
        }
    }

    @Test("decodes the protocolVersion=4 forgetProvenance reply fixture")
    func decodesV4ForgetProvenanceReplyFixture() throws {
        let data = try fixtureData("envelope-v4-forget-provenance-reply")
        let envelope = try CommandCoding.decoder.decode(
            GohEnvelope<ForgetProvenanceReply>.self, from: data)
        #expect(envelope.protocolVersion == 4)
        #expect(envelope.messageType == .reply)
        #expect(envelope.payload == ForgetProvenanceReply(forgotCount: 2))
    }

    @Test("forgetProvenance request fixture round-trips through encode→decode byte-equal")
    func forgetProvenanceRequestRoundTrips() throws {
        let data = try fixtureData("envelope-v4-forget-provenance-request")
        let envelope = try CommandCoding.decoder.decode(GohEnvelope<Command>.self, from: data)
        let reEncoded = try CommandCoding.encoder.encode(envelope)
        #expect(reEncoded == data, "re-encoded forgetProvenance request must be byte-equal to the committed fixture")
    }

    @Test("forgetProvenance reply fixture round-trips through encode→decode byte-equal")
    func forgetProvenanceReplyRoundTrips() throws {
        let data = try fixtureData("envelope-v4-forget-provenance-reply")
        let envelope = try CommandCoding.decoder.decode(
            GohEnvelope<ForgetProvenanceReply>.self, from: data)
        let reEncoded = try CommandCoding.encoder.encode(envelope)
        #expect(reEncoded == data, "re-encoded forgetProvenance reply must be byte-equal to the committed fixture")
    }
}
```

### Step 4.4 — Run failing tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter EnvelopeCodecForgetProvenanceTests -Xswiftc -warnings-as-errors 2>&1
```

Expected: test compilation succeeds; tests FAIL because fixture files are missing or the encoded JSON does not match (use this failure output to calibrate the fixture bytes if needed).

**Fixture calibration procedure:** If the round-trip fails due to key order or escape differences, add a temporary `@Test` that encodes a fresh `GohEnvelope<Command>.forgetProvenance` envelope and prints the JSON bytes:

```swift
    @Test("print forgetProvenance request JSON — use to calibrate fixture")
    func printForgetProvenanceJSON() throws {
        let requestID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        let envelope = GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .request,
            payload: Command.forgetProvenance(request: ForgetProvenanceRequest(paths: [
                "/Users/testuser/Downloads/gone.bin",
                "/Volumes/Archive/old.iso"
            ])))
        let data = try CommandCoding.encoder.encode(envelope)
        print("REQUEST JSON:", String(decoding: data, as: UTF8.self))
        #expect(Bool(true))  // remove after calibration
    }
```

Run this test, copy the printed JSON into the fixture file byte-for-byte, then remove the calibration test. The fixture is now the ground truth — never regenerate it automatically.

### Step 4.5 — Run tests green

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter EnvelopeCodecForgetProvenanceTests -Xswiftc -warnings-as-errors 2>&1
```

Expected: all 4 fixture tests pass, including byte-equal round-trips.

### Step 4.6 — Full test suite

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test -Xswiftc -warnings-as-errors 2>&1
```

Expected: all tests pass.

### Step 4.7 — Commit

```bash
git add Tests/GohCoreTests/Fixtures/envelope-v4-forget-provenance-request.json \
        Tests/GohCoreTests/Fixtures/envelope-v4-forget-provenance-reply.json \
        Tests/GohCoreTests/EnvelopeCodecTests+ForgetProvenance.swift
git commit -m "test(wire): golden fixtures + codec round-trip tests for forgetProvenance envelope (protocolVersion=4)"
```

---

## Task 5 — `GohForgetCommand` CLI runner

**AC mapping:** AC1 (`testForgetTrackedPathExits0WithConfirmation`, `testForgetRoundTripsVerifyAll`, `testForgetRoundTripsVerifyQuick`), AC2 (`testMissingDryRunNeverMutatesLedger`, `testMissingConfirmForgetsAllAbsentLeavesPresent`, `testMissingConfirmSendsStoredPathsVerbatim`, `testPartialForgotCountSurfacesNonSuccess`), AC3 (`testForgetUntrackedPathExits1WithNotTrackedMessage`, `testForgetUntrackedNeverSendsCommand`), gap #1 (`testDaemonTooOldEmitsErrorExits1SendsNothing`, `testDaemonUnreachableEmitsErrorExits1SendsNothing`), gap #2 (covered by `testForgetFileSafetyPresentFileUntouched` in Task 1)

**THE BET reference:** The `--missing` dry-run-default + `--confirm` gate is the spec-chosen approach under "Preview-and-Confirm." The dry run preview (human-readable, volume-annotated candidate list) is the primary safety signal; `--confirm` is the second step. No TTY prompt, no `readLine`, no `isatty` — consistent with goh's `daemon restart --force` precedent.

**Spec advisory (1): dispatcher `.failure(GohError)` → `GohCommandClientError.daemon` → CLI exit 1.**
Reading `GohCommandClient.sendWithRequestID` (confirmed at `Sources/GohCore/IPC/GohCommandClient.swift` lines 42–51): when the daemon sends a `.error`-kind envelope, `decodeGohReply` returns `.daemonError(id, error)`, which throws `GohCommandClientError.daemon(error)`. In `GohCommandLine.run()` (confirmed at lines 273–280), this bubbles to `catch let error as GohCommandLineError` via `GohCommandLineError.daemon(GohError)`. The `failureResult` function (lines 781–793) renders it as `exitCode: 1` with `"gohd: \(message)\n"` on stderr. The `GohForgetCommand` runner uses `GohCommandLine.sendCommand`-equivalent logic via the injected `send` closure — when the daemon replies `.failure(GohError(.destinationUnwritable,...))`, the client throws, the runner catches and returns exit 1. No special-casing needed — the existing error path covers it.

**Spec advisory (2): `provenanceStorePathResolver() == nil` branch for `--missing`.**
The resolver is the same `ProvenanceStorePathResolver` seam used by `which` and `verify --all`. When it returns `nil` (cannot resolve, e.g. sandbox), the runner uses `provenanceStorePathResolver() ?? ""`. An empty string passed to `ProvenanceLedgerReader.read(at:)` returns `.absent` (FileManager.fileExists is false for `""`). `.absent` maps to "No tracked entries." + exit 0. This matches the `verify --quick` convention confirmed in `GohVerifyQuickCommand.swift` line 48.

### Pre-task reads

- `Sources/GohCore/CLI/GohVerifyQuickCommand.swift` — READ IN FULL. Use as the exact structural template: `public enum GohForgetCommand`, `public static func run(...)`, `ProvenanceLedgerReader.read(at:)` switch, `LiveFileStatProbe().probe(path)`, `DaemonAutoHeal.runIfNeeded`.
- `Sources/GohCore/CLI/DaemonAutoHeal.swift` — READ the `runIfNeeded` signature and confirm the return value is `String?` (discardable, irrelevant to the skew gate). Confirm `GohCommandLine.Sender` is the parameter type.
- `Sources/GohCore/IPC/GohCommandClient.swift` — READ the `send` method (lines 18–24) to confirm the exact call site: `GohCommandClient(send:).send(_ command:expecting:) throws -> Reply`.
- `Sources/GohCore/CLI/GohCommandLine.swift` — READ the `sendCommand` private method (lines 283–313) to understand the reply-decode pattern; the runner will replicate it inline using `GohCommandClient`.

### Step 5.1 — Write failing tests

Create `Tests/GohCoreTests/GohForgetCommandTests.swift`:

The test file uses the same fake-sender pattern as `GohSyncCommandTests.swift` and
`GohCommandLineTests.swift`: `withUnsafeUnderlyingDictionary` + `GohEnvelope<Command>(xpcDictionary:)`
to decode the incoming XPC request, then build and return an XPC reply envelope.
This is the only pattern that works — `XPCDictionary` has no JSON round-trip in test
code, and `GohEnvelope<Command>(xpcDictionary:)` is already tested by `EnvelopeCodecTests`.

```swift
import Foundation
import Testing
import XPC
@testable import GohCore

// MARK: - Test support

/// Builds a fake XPC sender that handles .ls and .forgetProvenance.
/// `featureLevel`: the level to report in the LsReply (nil = old daemon).
/// `forgotCount`: the count to report in ForgetProvenanceReply.
private func makeFakeSender(
    featureLevel: Int?,
    forgotCount: Int
) -> GohCommandLine.Sender {
    { requestDict in
        try requestDict.withUnsafeUnderlyingDictionary { rawRequest in
            guard let envelope = try? GohEnvelope<Command>(xpcDictionary: rawRequest) else {
                throw GohCommandClientError.malformedReply("bad request")
            }
            switch envelope.payload {
            case .ls:
                let reply = LsReply(jobs: [], featureLevel: featureLevel)
                return try XPCDictionary(GohEnvelope(
                    protocolVersion: CommandService.protocolVersion,
                    requestID: envelope.requestID,
                    messageType: .reply,
                    payload: reply).xpcDictionary())
            case .forgetProvenance:
                let reply = ForgetProvenanceReply(forgotCount: forgotCount)
                return try XPCDictionary(GohEnvelope(
                    protocolVersion: CommandService.protocolVersion,
                    requestID: envelope.requestID,
                    messageType: .reply,
                    payload: reply).xpcDictionary())
            default:
                throw GohCommandClientError.malformedReply("unexpected command")
            }
        }
    }
}

/// A spy sender that records every Command sent through it.
private final class CommandSpySender: @unchecked Sendable {
    var commands: [Command] = []
    var featureLevel: Int?
    var forgotCount: Int = 0

    lazy var send: GohCommandLine.Sender = { [weak self] requestDict in
        guard let self else { throw GohCommandClientError.malformedReply("sender deallocated") }
        return try requestDict.withUnsafeUnderlyingDictionary { rawRequest in
            guard let envelope = try? GohEnvelope<Command>(xpcDictionary: rawRequest) else {
                throw GohCommandClientError.malformedReply("bad request")
            }
            self.commands.append(envelope.payload)
            switch envelope.payload {
            case .ls:
                let reply = LsReply(jobs: [], featureLevel: self.featureLevel)
                return try XPCDictionary(GohEnvelope(
                    protocolVersion: CommandService.protocolVersion,
                    requestID: envelope.requestID,
                    messageType: .reply,
                    payload: reply).xpcDictionary())
            case .forgetProvenance(let req):
                let count = min(self.forgotCount, req.paths.count)
                let reply = ForgetProvenanceReply(forgotCount: count)
                return try XPCDictionary(GohEnvelope(
                    protocolVersion: CommandService.protocolVersion,
                    requestID: envelope.requestID,
                    messageType: .reply,
                    payload: reply).xpcDictionary())
            default:
                throw GohCommandClientError.malformedReply("unexpected command in spy")
            }
        }
    }
}

// MARK: - Provenance store helpers

private func makeTempStore() throws -> (store: ProvenanceStore, path: String) {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "goh-forget-cmd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "provenance.plist")
    let store = ProvenanceStore(fileURL: url)
    return (store, url.path)
}

private func addEntry(to store: ProvenanceStore, path: String, url: String = "https://example.com/f.bin") throws {
    let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
    try store.record(entry: ProvenanceEntry(
        url: url,
        sha256: "sha256:" + String(repeating: "a", count: 64),
        size: 1024,
        downloadedAt: Date(timeIntervalSince1970: 0),
        destinationPath: canonical,
        verifiedAt: nil))
}

// MARK: - Tests

@Suite("GohForgetCommand")
struct GohForgetCommandTests {

    // MARK: - AC3: untracked path

    @Test("AC3 — forget untracked path exits 1 with 'not tracked' message")
    func testForgetUntrackedPathExits1WithNotTrackedMessage() throws {
        let (_, storePath) = try makeTempStore()
        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 0
        let result = GohForgetCommand.run(
            path: "/tmp/untracked-\(UUID().uuidString).bin",
            provenanceStorePath: storePath,
            send: spy.send)
        #expect(result.exitCode == 1)
        #expect(result.standardError.contains("not tracked"))
        #expect(result.standardOutput.isEmpty)
    }

    @Test("AC3 — forget untracked path never sends a command to the daemon")
    func testForgetUntrackedNeverSendsCommand() throws {
        let (_, storePath) = try makeTempStore()
        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 0
        _ = GohForgetCommand.run(
            path: "/tmp/never-tracked-\(UUID().uuidString).bin",
            provenanceStorePath: storePath,
            send: spy.send)
        // Only .ls may be sent (as part of auto-heal); forgetProvenance must NOT be sent.
        let forgotSent = spy.commands.contains { if case .forgetProvenance = $0 { return true }; return false }
        #expect(!forgotSent, "forgetProvenance must never be sent for an untracked path")
    }

    @Test("AC3 — corrupt ledger exits 6 (not silently 'not tracked'), sends nothing")
    func testForgetCorruptLedgerExits6SendsNothing() throws {
        // Write a file at the store path that is not a valid binary plist.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "goh-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storePath = dir.appending(path: "provenance.plist").path
        try Data("not a plist at all".utf8).write(to: URL(fileURLWithPath: storePath))

        let spy = CommandSpySender()
        spy.featureLevel = 2
        let result = GohForgetCommand.run(
            path: "/tmp/any-path.bin",
            provenanceStorePath: storePath,
            send: spy.send)
        #expect(result.exitCode == 6, "corrupt ledger must exit 6, not 1")
        #expect(result.standardError.contains("corrupt") || result.standardError.contains("unreadable"))
        let forgotSent = spy.commands.contains { if case .forgetProvenance = $0 { return true }; return false }
        #expect(!forgotSent, "must not send forgetProvenance when ledger is corrupt")
    }

    // MARK: - AC1: tracked path, explicit forget

    @Test("AC1 — forget tracked path exits 0 with confirmation line naming the path")
    func testForgetTrackedPathExits0WithConfirmation() throws {
        let (store, storePath) = try makeTempStore()
        let path = "/tmp/tracked-\(UUID().uuidString).bin"
        try addEntry(to: store, path: path)
        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 1
        let result = GohForgetCommand.run(
            path: path,
            provenanceStorePath: storePath,
            send: spy.send)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("Forgot"))
        #expect(result.standardError.isEmpty)
    }

    @Test("AC1 — forget tracked path sends exactly one forgetProvenance command")
    func testForgetTrackedPathSendsOneForgetProvenance() throws {
        let (store, storePath) = try makeTempStore()
        let path = "/tmp/oneshot-\(UUID().uuidString).bin"
        try addEntry(to: store, path: path)
        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 1
        _ = GohForgetCommand.run(
            path: path,
            provenanceStorePath: storePath,
            send: spy.send)
        let forgetCommands = spy.commands.filter { if case .forgetProvenance = $0 { return true }; return false }
        #expect(forgetCommands.count == 1)
    }

    @Test("AC1 — forgotCount == 0 on tracked path (rare race) exits 1 — no clean success")
    func testForgotCount0OnTrackedPathIsNonSuccess() throws {
        let (store, storePath) = try makeTempStore()
        let path = "/tmp/race-\(UUID().uuidString).bin"
        try addEntry(to: store, path: path)
        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 0  // simulate: path was removed between lookup and send
        let result = GohForgetCommand.run(
            path: path,
            provenanceStorePath: storePath,
            send: spy.send)
        #expect(result.exitCode == 1)
        #expect(result.standardOutput.contains("Forgot") == false)
    }

    // MARK: - gap #1: stale daemon / unreachable daemon

    @Test("gap #1 — daemon too old (featureLevel 1) → exits 1, no forgetProvenance sent")
    func testDaemonTooOldEmitsErrorExits1SendsNothing() throws {
        let (store, storePath) = try makeTempStore()
        let path = "/tmp/stale-\(UUID().uuidString).bin"
        try addEntry(to: store, path: path)
        let spy = CommandSpySender()
        spy.featureLevel = 1  // old daemon
        spy.forgotCount = 0
        let result = GohForgetCommand.run(
            path: path,
            provenanceStorePath: storePath,
            send: spy.send)
        #expect(result.exitCode == 1)
        #expect(result.standardError.lowercased().contains("too old") ||
                result.standardError.lowercased().contains("restart"))
        let forgotSent = spy.commands.contains { if case .forgetProvenance = $0 { return true }; return false }
        #expect(!forgotSent, "forgetProvenance must never be sent to a stale daemon")
    }

    @Test("gap #1 — daemon featureLevel nil → exits 1, no forgetProvenance sent")
    func testDaemonFeatureLevelNilEmitsErrorExits1() throws {
        let (store, storePath) = try makeTempStore()
        let path = "/tmp/nilfl-\(UUID().uuidString).bin"
        try addEntry(to: store, path: path)
        let spy = CommandSpySender()
        spy.featureLevel = nil  // very old daemon, no featureLevel field
        spy.forgotCount = 0
        let result = GohForgetCommand.run(
            path: path,
            provenanceStorePath: storePath,
            send: spy.send)
        #expect(result.exitCode == 1)
        let forgotSent = spy.commands.contains { if case .forgetProvenance = $0 { return true }; return false }
        #expect(!forgotSent)
    }

    @Test("gap #1 — daemon unreachable (ls throws) → exits 1, sends nothing, 'cannot reach' message")
    func testDaemonUnreachableEmitsErrorExits1SendsNothing() throws {
        let (store, storePath) = try makeTempStore()
        let path = "/tmp/unreachable-\(UUID().uuidString).bin"
        try addEntry(to: store, path: path)
        struct UnreachableError: Error {}
        let unreachableSend: GohCommandLine.Sender = { _ in throw UnreachableError() }
        let result = GohForgetCommand.run(
            path: path,
            provenanceStorePath: storePath,
            send: unreachableSend)
        #expect(result.exitCode == 1)
        #expect(result.standardError.lowercased().contains("cannot reach") ||
                result.standardError.lowercased().contains("daemon"))
    }

    // MARK: - AC2: --missing dry-run

    @Test("AC2 — --missing dry-run never mutates the ledger (byte-identical before/after)")
    func testMissingDryRunNeverMutatesLedger() throws {
        let (store, storePath) = try makeTempStore()
        // Add one tracked entry pointing to a nonexistent path.
        let missingPath = "/tmp/definitely-does-not-exist-\(UUID().uuidString).bin"
        try addEntry(to: store, path: missingPath)
        let beforeData = try Data(contentsOf: URL(fileURLWithPath: storePath))
        let spy = CommandSpySender()
        spy.featureLevel = 2
        _ = GohForgetCommand.runMissing(
            provenanceStorePath: storePath,
            confirm: false,
            send: spy.send)
        let afterData = try Data(contentsOf: URL(fileURLWithPath: storePath))
        #expect(beforeData == afterData, "dry-run must leave the ledger byte-identical")
        let forgotSent = spy.commands.contains { if case .forgetProvenance = $0 { return true }; return false }
        #expect(!forgotSent, "dry-run must never send forgetProvenance")
    }

    @Test("AC2 — --missing dry-run lists absent paths, zero candidates → 'No missing entries.'")
    func testMissingDryRunNoCandidatesMessage() throws {
        let (_, storePath) = try makeTempStore()  // empty ledger
        let spy = CommandSpySender()
        spy.featureLevel = 2
        let result = GohForgetCommand.runMissing(
            provenanceStorePath: storePath,
            confirm: false,
            send: spy.send)
        #expect(result.exitCode == 0)
        // Empty ledger → "No tracked entries."
        #expect(result.standardOutput.contains("No tracked entries") ||
                result.standardOutput.contains("No missing entries"))
    }

    @Test("AC2 — --missing --confirm forgets all absent, leaves present entries intact")
    func testMissingConfirmForgetsAllAbsentLeavesPresent() throws {
        let (store, storePath) = try makeTempStore()
        let missingPath = "/tmp/gone-\(UUID().uuidString).bin"
        // Add a tracked missing path and a tracked present path.
        try addEntry(to: store, path: missingPath)
        // Create a real present file:
        let presentDir = FileManager.default.temporaryDirectory
            .appending(path: "goh-present-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: presentDir, withIntermediateDirectories: true)
        let presentPath = presentDir.appending(path: "present.bin").path
        try Data("content".utf8).write(to: URL(fileURLWithPath: presentPath))
        try addEntry(to: store, path: presentPath)

        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 1  // expect 1 missing path forgotten

        let result = GohForgetCommand.runMissing(
            provenanceStorePath: storePath,
            confirm: true,
            send: spy.send)
        #expect(result.exitCode == 0)
        // Exactly one forgetProvenance was sent.
        let forgetCmds = spy.commands.filter { if case .forgetProvenance = $0 { return true }; return false }
        #expect(forgetCmds.count == 1)
        // The forgetProvenance paths contained only the missing path, not the present path.
        if case .forgetProvenance(let req) = forgetCmds.first {
            let canonical = URL(fileURLWithPath: missingPath).standardizedFileURL.path
            #expect(req.paths.contains(canonical) || req.paths.contains(missingPath))
            #expect(!req.paths.contains(URL(fileURLWithPath: presentPath).standardizedFileURL.path),
                    "present-file paths must never appear in the forgetProvenance request")
        }
    }

    @Test("AC2 — --missing --confirm sends stored destinationPath strings verbatim")
    func testMissingConfirmSendsStoredPathsVerbatim() throws {
        let (store, storePath) = try makeTempStore()
        let canonical = "/tmp/verbatim-\(UUID().uuidString)/file.bin"
        // Insert with a slightly different input (trailing slash stripped) to confirm stored form.
        let entry = ProvenanceEntry(
            url: "https://example.com/f.bin",
            sha256: "sha256:" + String(repeating: "a", count: 64),
            size: 1024,
            downloadedAt: Date(timeIntervalSince1970: 0),
            destinationPath: canonical,
            verifiedAt: nil)
        try store.record(entry: entry)

        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 1
        _ = GohForgetCommand.runMissing(
            provenanceStorePath: storePath,
            confirm: true,
            send: spy.send)
        let forgetCmds = spy.commands.filter { if case .forgetProvenance = $0 { return true }; return false }
        if case .forgetProvenance(let req) = forgetCmds.first {
            // The path in the request must be exactly the stored canonical string — not re-canonicalized.
            #expect(req.paths == [canonical],
                    "CLI must send stored destinationPath verbatim, not re-canonicalize")
        }
    }

    @Test("AC2 — forgotCount < K on --missing --confirm is a non-success (exit non-zero)")
    func testPartialForgotCountSurfacesNonSuccess() throws {
        let (store, storePath) = try makeTempStore()
        let p1 = "/tmp/partial-1-\(UUID().uuidString).bin"
        let p2 = "/tmp/partial-2-\(UUID().uuidString).bin"
        try addEntry(to: store, path: p1)
        try addEntry(to: store, path: p2)
        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 1  // only 1 of 2 removed — simulate race
        let result = GohForgetCommand.runMissing(
            provenanceStorePath: storePath,
            confirm: true,
            send: spy.send)
        #expect(result.exitCode != 0)
        // Must not print a clean success line.
        #expect(!result.standardOutput.lowercased().contains("forgot 2"))
    }
}
```

### Step 5.2 — Run failing tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohForgetCommandTests -Xswiftc -warnings-as-errors 2>&1
```

Expected: compile error — `GohForgetCommand` type does not exist.

### Step 5.3 — Implement `GohForgetCommand.swift`

Create `Sources/GohCore/CLI/GohForgetCommand.swift`:

```swift
import Darwin
import Foundation
import XPC

/// CLI runner for `goh forget` — removes provenance-ledger entries.
///
/// Grammar (parsed by GohCommandLine.parse, routed here):
///   goh forget <path>                  explicit single-path forget
///   goh forget --missing               dry-run: list absent entries, delete nothing
///   goh forget --missing --confirm     delete absent entries
///
/// DESIGN reference: Preview-and-Confirm approach (THE BET: users prefer an
/// explicit two-step over a one-step TTY prompt). Dry-run is the default for
/// bulk `--missing`; `--confirm` is the second step. Explicit `<path>` is
/// immediate (git-rm model — naming the target IS the confirmation).
///
/// featureLevel gate: before any mutating send, a FRESH `.ls` reads
/// `LsReply.featureLevel`. `nil` or `< 2` → error + exit 1, no send.
/// XPC unreachable → error + exit 1, no send.
public enum GohForgetCommand {

    // MARK: - Public entry points

    /// Explicit single-path forget: `goh forget <path>`.
    ///
    /// - Parameters:
    ///   - path: Raw user-supplied path (canonicalized internally).
    ///   - provenanceStorePath: Resolved path from `provenanceStorePathResolver`.
    ///   - send: XPC sender closure (injectable for tests).
    /// - Returns: A CLI result (exitCode, stdout, stderr).
    public static func run(
        path: String,
        provenanceStorePath: String,
        send: @escaping GohCommandLine.Sender
    ) -> GohCommandLineResult {
        // Step 1: Read-only lookup — no daemon contact.
        // AC3: if not tracked, exit 1. Corrupt ledger → exit 6 (not a silent "not tracked").
        // `canonical` is declared before the switch so Steps 2 and 3 can use it in scope.
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        switch ProvenanceLedgerReader.read(at: provenanceStorePath) {
        case .unreadable(.io):
            return GohCommandLineResult(
                exitCode: 6,
                standardError: "goh forget: provenance ledger unreadable\n")
        case .unreadable(.corrupt):
            return GohCommandLineResult(
                exitCode: 6,
                standardError: "goh forget: provenance ledger corrupt\n")
        case .unreadable(.versionUnknown(let found)):
            return GohCommandLineResult(
                exitCode: 6,
                standardError: "goh forget: provenance ledger version \(found) is unknown\n")
        case .absent:
            return GohCommandLineResult(
                exitCode: 1,
                standardError: "goh forget: \(path) is not tracked (no provenance entry)\n")
        case .entries(let entries):
            // Path present but no matching entry → not tracked.
            guard entries.contains(where: { $0.destinationPath == canonical }) else {
                return GohCommandLineResult(
                    exitCode: 1,
                    standardError: "goh forget: \(path) is not tracked (no provenance entry)\n")
            }
            // Entry exists — fall through to featureLevel gate + send.
        }

        // Step 2: featureLevel gate — fresh .ls required before any mutating send.
        switch featureLevelGateResult(send: send) {
        case .proceed:
            break
        case .failure(let result):
            return result
        }

        // Step 3: Send one forgetProvenance command.
        let client = GohCommandClient(send: send)
        do {
            let reply: ForgetProvenanceReply = try client.send(
                .forgetProvenance(request: ForgetProvenanceRequest(paths: [canonical])),
                expecting: ForgetProvenanceReply.self)
            if reply.forgotCount == 1 {
                return GohCommandLineResult(exitCode: 0, standardOutput: "Forgot \(canonical).\n")
            } else {
                // forgotCount == 0: rare race — path was removed between lookup and send.
                return GohCommandLineResult(
                    exitCode: 1,
                    standardError: "goh forget: \(canonical) was no longer tracked\n")
            }
        } catch let error as GohCommandClientError {
            return GohCommandLineResult(
                exitCode: 1,
                standardError: commandClientErrorMessage(error))
        } catch {
            return GohCommandLineResult(
                exitCode: 1,
                standardError: "goh forget: transport error: \(error)\n")
        }
    }

    /// `--missing` path: dry-run preview or `--confirm` delete.
    ///
    /// - Parameters:
    ///   - provenanceStorePath: Resolved path from `provenanceStorePathResolver`.
    ///   - confirm: `true` when `--confirm` was passed; `false` for dry-run.
    ///   - send: XPC sender closure (injectable for tests; nil → no daemon calls, errors on mutating path).
    ///   - probe: Injectable lstat probe (default `LiveFileStatProbe()`).
    ///   - mountedVolumeURLs: Injectable volume URL resolver (default Foundation API).
    public static func runMissing(
        provenanceStorePath: String,
        confirm: Bool,
        send: @escaping GohCommandLine.Sender,
        probe: any FileStatProbing = LiveFileStatProbe(),
        mountedVolumeURLs: () -> [URL]? = {
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])
        }
    ) -> GohCommandLineResult {
        // Step 1: Read ledger read-only.
        let outcome = ProvenanceLedgerReader.read(at: provenanceStorePath)
        switch outcome {
        case .absent, .entries([]):
            return GohCommandLineResult(exitCode: 0, standardOutput: "No tracked entries.\n")
        case .unreadable(.io):
            return GohCommandLineResult(exitCode: 6, standardError: "provenance ledger unreadable\n")
        case .unreadable(.corrupt):
            return GohCommandLineResult(exitCode: 6, standardError: "provenance ledger corrupt\n")
        case .unreadable(.versionUnknown(let found)):
            return GohCommandLineResult(
                exitCode: 6,
                standardError: "provenance ledger version \(found) is unknown\n")
        case .entries(let entries):
            return processMissing(
                entries: entries,
                confirm: confirm,
                send: send,
                probe: probe,
                mountedVolumeURLs: mountedVolumeURLs)
        }
    }

    // MARK: - Private

    private enum GateResult {
        case proceed
        case failure(GohCommandLineResult)
    }

    /// Sends a fresh `.ls`, reads featureLevel, and returns whether it is safe to send
    /// `forgetProvenance`. This is the NEW gate specific to forget — NOT DaemonAutoHeal.
    /// Its return value is exit-code-affecting (not best-effort), and it distinguishes
    /// "XPC unreachable" from "featureLevel too low" — two things DaemonAutoHeal.runIfNeeded
    /// conflates into a discardable String? return.
    ///
    /// Spec advisory (1): GohCommandClient.send throws GohCommandClientError.daemon(GohError)
    /// when the daemon sends a .error envelope; throws GohCommandClientError.malformedReply
    /// for decode failures; and throws a transport error when XPC is unreachable. All three
    /// paths reach the `catch` below and produce "cannot reach" + exit 1 (correct, since if
    /// we can't classify featureLevel we must not proceed).
    private static func featureLevelGateResult(send: @escaping GohCommandLine.Sender) -> GateResult {
        let client = GohCommandClient(send: send)
        let lsReply: LsReply
        do {
            lsReply = try client.send(.ls, expecting: LsReply.self)
        } catch {
            return .failure(GohCommandLineResult(
                exitCode: 1,
                standardError: "goh forget: cannot reach the goh daemon — is it running? try: goh daemon restart\n"))
        }
        guard let featureLevel = lsReply.featureLevel, featureLevel >= 2 else {
            return .failure(GohCommandLineResult(
                exitCode: 1,
                standardError: "goh forget: this goh daemon is too old to support forget — restart it: goh daemon restart\n"))
        }
        return .proceed
    }

    private static func processMissing(
        entries: [ProvenanceEntry],
        confirm: Bool,
        send: @escaping GohCommandLine.Sender,
        probe: any FileStatProbing,
        mountedVolumeURLs: () -> [URL]?
    ) -> GohCommandLineResult {
        // Step 2: lstat each entry; candidates are exactly .notFound (ENOENT).
        let candidates = entries.filter { probe.probe(path: $0.destinationPath) == .notFound }

        if candidates.isEmpty {
            return GohCommandLineResult(exitCode: 0, standardOutput: "No missing entries.\n")
        }

        if !confirm {
            // Dry-run: print candidate list with mount annotation. Delete nothing.
            let volumes: [URL]? = mountedVolumeURLs()
            var lines: [String] = []
            for entry in candidates {
                let annotation = mountAnnotation(for: entry.destinationPath, mountedVolumes: volumes)
                lines.append("MISSING   \(entry.destinationPath)\(annotation)\n")
            }
            let n = candidates.count
            lines.append("\(n) entr\(n == 1 ? "y" : "ies") missing; re-run with --confirm to forget them\n")
            return GohCommandLineResult(exitCode: 0, standardOutput: lines.joined())
        }

        // --confirm path: featureLevel gate first.
        switch featureLevelGateResult(send: send) {
        case .proceed:
            break
        case .failure(let result):
            return result
        }

        // Send one forgetProvenance with the stored destinationPath strings VERBATIM.
        // AC2: paths are NOT re-canonicalized — they were already stored canonical.
        // This is the tested invariant: forgotCount == K by construction on --missing.
        let verbatimPaths = candidates.map { $0.destinationPath }
        let client = GohCommandClient(send: send)
        do {
            let reply: ForgetProvenanceReply = try client.send(
                .forgetProvenance(request: ForgetProvenanceRequest(paths: verbatimPaths)),
                expecting: ForgetProvenanceReply.self)
            let k = verbatimPaths.count
            if reply.forgotCount == k {
                let n = reply.forgotCount
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: "Forgot \(n) entr\(n == 1 ? "y" : "ies").\n")
            } else {
                let got = reply.forgotCount
                let still = k - got
                return GohCommandLineResult(
                    exitCode: 1,
                    standardError: "goh forget: forgot \(got) of \(k) entr\(k == 1 ? "y" : "ies"); \(still) still tracked\n")
            }
        } catch let error as GohCommandClientError {
            return GohCommandLineResult(
                exitCode: 1,
                standardError: commandClientErrorMessage(error))
        } catch {
            return GohCommandLineResult(
                exitCode: 1,
                standardError: "goh forget: transport error: \(error)\n")
        }
    }

    /// Returns the mount annotation string for a path (empty string or "   (VOLUME NOT MOUNTED)").
    ///
    /// Mount detection uses component-boundary prefix matching (not raw string hasPrefix),
    /// so /Volumes/Arc does not falsely match /Volumes/Archive. Picks the longest match.
    /// If `mountedVolumes` is nil (FileManager returned nil), degrades gracefully: returns "".
    private static func mountAnnotation(for path: String, mountedVolumes: [URL]?) -> String {
        guard let volumes = mountedVolumes else {
            // nil return from mountedVolumeURLs → degrade gracefully, no annotation.
            return ""
        }
        let pathComponents = (path as NSString).pathComponents
        var bestMatchLength = 0
        for volumeURL in volumes {
            let vComponents = volumeURL.standardizedFileURL.pathComponents
            guard vComponents.count <= pathComponents.count else { continue }
            // Component-boundary match: every volume component must equal the corresponding path component.
            let matches = zip(vComponents, pathComponents).allSatisfy { $0 == $1 }
            if matches, vComponents.count > bestMatchLength {
                bestMatchLength = vComponents.count
            }
        }
        if bestMatchLength > 0 {
            // Path is on a currently-mounted volume — bare MISSING line.
            return ""
        } else {
            // No mounted volume is a component-boundary prefix — likely detached drive.
            return "   (VOLUME NOT MOUNTED)"
        }
    }

    private static func commandClientErrorMessage(_ error: GohCommandClientError) -> String {
        switch error {
        case .daemon(let gohError):
            let detail = gohError.message ?? gohError.code.rawValue
            return "goh forget: daemon error: \(detail)\n"
        case .malformedReply(let msg):
            return "goh forget: daemon returned an invalid reply: \(msg)\n"
        }
    }
}
```

### Step 5.4 — Run tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohForgetCommandTests -Xswiftc -warnings-as-errors 2>&1
```

Expected: all `GohForgetCommandTests` pass. If any test fails due to `GohCommandClient` or `XPCDictionary` API mismatches, correct the test helper pattern to match how `CommandService.handle` and `CommandDispatcher` interact with `GohCommandClient`.

### Step 5.5 — Full test suite

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test -Xswiftc -warnings-as-errors 2>&1
```

Expected: all tests pass.

### Step 5.6 — Commit

```bash
git add Sources/GohCore/CLI/GohForgetCommand.swift \
        Tests/GohCoreTests/GohForgetCommandTests.swift
git commit -m "feat(cli): GohForgetCommand — explicit path + --missing dry-run + --confirm (AC1-AC3, gap#1)"
```

---

## Task 6 — `GohCommandLine` parse/dispatch + usage

**Depends on:** Task 5 (`GohForgetCommand` must exist).

### Pre-task reads

- `Sources/GohCore/CLI/GohCommandLine.swift` — READ IN FULL. Focus on:
  - `ParsedCommand` enum (lines ~316–340): understand the existing cases to know where to insert `case forget`.
  - `parse(_:)` static method (lines ~357–531): understand how to insert the `"forget"` verb parser before the `foreground` fallback.
  - `run()` method (lines ~108–281): understand where to dispatch `case .forget`.
  - `usage()` function (lines ~746–779): understand where to insert the `goh forget` line.
  - The `value(after:in:at:)` helper used by `parseAdd` (lines ~599–610): reuse for flag parsing.

### Step 6.1 — Add `ParsedCommand.forget` cases

In `GohCommandLine.swift`, add to the `ParsedCommand` private enum after `case daemon(force: Bool)`:

```swift
    case forgetPath(path: String)
    case forgetMissing(confirm: Bool)
```

### Step 6.2 — Add `"forget"` parser to `parse(_:)`

In `parse(_:)`, before the `foreground` single-arg fallback (the `arguments.count == 1` check), add:

```swift
        if arguments.first == "forget" {
            return try parseForget(Array(arguments.dropFirst()))
        }
```

And add the `parseForget` private static method after `parseDaemon`:

```swift
    private static func parseForget(_ arguments: [String]) throws -> ParsedCommand {
        var missing = false
        var confirm = false
        var path: String?

        for arg in arguments {
            switch arg {
            case "--missing":
                missing = true
            case "--confirm":
                confirm = true
            default:
                guard !arg.hasPrefix("-") else {
                    throw ParseError(message: "unknown forget option \(arg)")
                }
                guard path == nil else {
                    throw ParseError(message: "forget accepts at most one path argument")
                }
                path = arg
            }
        }

        // Mutual exclusion: --missing and a positional path are incompatible.
        if missing, let p = path {
            throw ParseError(message: "--missing and a positional path are mutually exclusive (got: \(p))")
        }
        // --confirm without --missing is a usage error.
        if confirm, !missing {
            throw ParseError(message: "--confirm is only valid with --missing")
        }
        // --confirm with a positional path is a usage error.
        if confirm, path != nil {
            throw ParseError(message: "--confirm is only valid with --missing")
        }

        if missing {
            return .forgetMissing(confirm: confirm)
        }

        guard let p = path else {
            throw ParseError(message: "forget requires a path or --missing")
        }
        return .forgetPath(path: p)
    }
```

### Step 6.3 — Add dispatch cases to `run()`

In `run()`, after `case .daemon(let force):` dispatch arm (and before the closing `}` of the `switch`), add:

```swift
            case .forgetPath(let path):
                return GohForgetCommand.run(
                    path: path,
                    provenanceStorePath: provenanceStorePathResolver() ?? "",
                    send: send)

            case .forgetMissing(let confirm):
                return GohForgetCommand.runMissing(
                    provenanceStorePath: provenanceStorePathResolver() ?? "",
                    confirm: confirm,
                    send: send)
```

### Step 6.4 — Add usage line

In `usage()`, after the `goh rm [--keep] <id>` line, add:

```
          goh forget <path>              (removes a tracked path's provenance entry; exit: 0 ok · 1 untracked · 6 ledger-error)
          goh forget --missing           (dry-run: list absent-file entries; exit: 0 ok · 6 ledger-error)
          goh forget --missing --confirm (remove absent-file entries; exit: 0 ok · 1 partial/error · 6 ledger-error)
```

### Step 6.5 — Build

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: `Build complete!`. The `parse(_:)` switch is NOT exhaustive over `ParsedCommand` at the `run()` call site — the `run()` switch IS exhaustive over `ParsedCommand`. Confirm no exhaustiveness warning for `ParsedCommand` (it is not used in a pattern-match that requires exhaustiveness except in `run()`).

### Step 6.6 — Write parse tests

Add to `Tests/GohCoreTests/GohCommandLineParseTests.swift` (or create it if absent) a `@Suite("GohCommandLine.parse — forget verb")` with tests:

```swift
@Suite("GohCommandLine.parse — forget verb")
struct GohCommandLineForgetParseTests {

    private func makeResult(_ args: [String]) -> GohCommandLineResult {
        GohCommandLine(
            arguments: args,
            send: { _ in throw URLError(.cancelled) }
        ).run()
    }

    @Test("forget <path> parses to forgetPath")
    func testParseForgetPath() {
        let result = makeResult(["forget", "/tmp/file.bin"])
        // Will fail with "cannot reach gohd" because no real daemon — but must not be exit 64.
        #expect(result.exitCode != 64)
    }

    @Test("forget --missing parses to forgetMissing(confirm:false)")
    func testParseForgetMissing() {
        let result = makeResult(["forget", "--missing"])
        // Dry run — no daemon needed. Empty ledger → exit 0.
        #expect(result.exitCode == 0 || result.exitCode == 6)
    }

    @Test("forget --missing --confirm parses to forgetMissing(confirm:true)")
    func testParseForgetMissingConfirm() {
        let result = makeResult(["forget", "--missing", "--confirm"])
        // No real daemon but also empty ledger → "No tracked entries" → exit 0 (no send needed).
        #expect(result.exitCode == 0 || result.exitCode == 1)
    }

    @Test("forget --confirm without --missing is exit 64")
    func testForgetConfirmWithoutMissingIsUsageError() {
        let result = makeResult(["forget", "--confirm"])
        #expect(result.exitCode == 64)
    }

    @Test("forget --missing /tmp/x.bin (both selectors) is exit 64")
    func testForgetBothSelectorsIsUsageError() {
        let result = makeResult(["forget", "--missing", "/tmp/x.bin"])
        #expect(result.exitCode == 64)
    }

    @Test("forget with unknown flag is exit 64")
    func testForgetUnknownFlagIsUsageError() {
        let result = makeResult(["forget", "--zap"])
        #expect(result.exitCode == 64)
    }

    @Test("forget with no arguments is exit 64")
    func testForgetNoArguments() {
        let result = makeResult(["forget"])
        #expect(result.exitCode == 64)
    }

    @Test("forget with two positional paths is exit 64")
    func testForgetTwoPositionalsIsUsageError() {
        let result = makeResult(["forget", "/tmp/a.bin", "/tmp/b.bin"])
        #expect(result.exitCode == 64)
    }
}
```

### Step 6.7 — Run tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohCommandLineForgetParseTests -Xswiftc -warnings-as-errors 2>&1
```

Expected: all parse tests pass.

### Step 6.8 — Full test suite

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test -Xswiftc -warnings-as-errors 2>&1
```

Expected: all tests pass.

### Step 6.9 — Commit

```bash
git add Sources/GohCore/CLI/GohCommandLine.swift \
        Tests/GohCoreTests/GohCommandLineParseTests.swift
git commit -m "feat(cli): GohCommandLine parse/dispatch + usage for goh forget verb"
```

---

## Task 7 — `CommandDispatcher.forgetProvenance` case (replace stub)

**Depends on:** Tasks 1 and 2 (both `ProvenanceStore.forget` and `ForgetProvenanceRequest` must exist).
**Independent of:** Tasks 4, 5, 6.

### Pre-task reads

- `Sources/GohCore/Model/CommandDispatcher.swift` — READ the `reply(to:)` method in full. Confirm the stub case added in Task 2 Step 2.6. Confirm `provenanceStore: ProvenanceStore?` is the injected field (line ~22). Confirm `warn` closure signature `(@Sendable (String) -> Void)?` (line ~28). Confirm `recordVerifiedProvenance` case (lines ~225–245) as the structural template, noting that `forgetProvenance` deliberately diverges on error handling (throws → `.failure`, not `.ack`).
- `Sources/GohCore/Model/GohError.swift` — confirm `ErrorCode.destinationUnwritable` is the correct real case for ledger-write failure (not a phantom case). Confirmed from the read: it is case 8 in the enum.

### Step 7.1 — Write dispatcher test

Create `Tests/GohCoreTests/CommandDispatcherForgetTests.swift`:

```swift
import Foundation
import Testing
@testable import GohCore

@Suite("CommandDispatcher — forgetProvenance")
struct CommandDispatcherForgetTests {

    private func makeTempStore(entries: [ProvenanceEntry] = []) throws -> ProvenanceStore {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "goh-dispatcher-forget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "provenance.plist")
        let store = ProvenanceStore(fileURL: url)
        for entry in entries { try store.record(entry: entry) }
        return store
    }

    private func entry(path: String) -> ProvenanceEntry {
        ProvenanceEntry(
            url: "https://example.com/f.bin",
            sha256: "sha256:" + String(repeating: "a", count: 64),
            size: 1024,
            downloadedAt: Date(timeIntervalSince1970: 0),
            destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path,
            verifiedAt: nil)
    }

    @Test("forgetProvenance removes matching entry — returns .forgotProvenance(count: 1)")
    func testForgetMatchingEntry() throws {
        let path = "/tmp/dispatch-\(UUID().uuidString).bin"
        let store = try makeTempStore(entries: [entry(path: path)])
        let dispatcher = CommandDispatcher(
            store: JobStore(),
            provenanceStore: store)
        let outcome = dispatcher.reply(to: .forgetProvenance(
            request: ForgetProvenanceRequest(paths: [path])))
        if case .forgotProvenance(let reply) = outcome {
            #expect(reply.forgotCount == 1)
        } else {
            Issue.record("expected .forgotProvenance, got \(outcome)")
        }
    }

    @Test("forgetProvenance with no matching path — returns .forgotProvenance(count: 0)")
    func testForgetNoMatchReturns0() throws {
        let store = try makeTempStore()
        let dispatcher = CommandDispatcher(store: JobStore(), provenanceStore: store)
        let outcome = dispatcher.reply(to: .forgetProvenance(
            request: ForgetProvenanceRequest(paths: ["/tmp/never-tracked.bin"])))
        if case .forgotProvenance(let reply) = outcome {
            #expect(reply.forgotCount == 0)
        } else {
            Issue.record("expected .forgotProvenance, got \(outcome)")
        }
    }

    @Test("forgetProvenance with no store configured — returns .forgotProvenance(count: 0), no crash")
    func testForgetNoStoreCaseForgotCount0() {
        let dispatcher = CommandDispatcher(store: JobStore(), provenanceStore: nil)
        let outcome = dispatcher.reply(to: .forgetProvenance(
            request: ForgetProvenanceRequest(paths: ["/tmp/x.bin"])))
        if case .forgotProvenance(let reply) = outcome {
            #expect(reply.forgotCount == 0)
        } else {
            Issue.record("expected .forgotProvenance, got \(outcome)")
        }
    }

    @Test("forgetProvenance multiple paths — returns correct count")
    func testForgetMultiplePaths() throws {
        let p1 = "/tmp/dm1-\(UUID().uuidString).bin"
        let p2 = "/tmp/dm2-\(UUID().uuidString).bin"
        let p3 = "/tmp/dm3-\(UUID().uuidString).bin"
        let store = try makeTempStore(entries: [entry(path: p1), entry(path: p2), entry(path: p3)])
        let dispatcher = CommandDispatcher(store: JobStore(), provenanceStore: store)
        let outcome = dispatcher.reply(to: .forgetProvenance(
            request: ForgetProvenanceRequest(paths: [p1, p2])))
        if case .forgotProvenance(let reply) = outcome {
            #expect(reply.forgotCount == 2)
        } else {
            Issue.record("expected .forgotProvenance, got \(outcome)")
        }
    }
}
```

### Step 7.2 — Run failing tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter CommandDispatcherForgetTests -Xswiftc -warnings-as-errors 2>&1
```

Expected: tests FAIL because the stub returns `.failure(.invalidArgument)` instead of `.forgotProvenance`.

### Step 7.3 — Replace stub with real implementation

In `Sources/GohCore/Model/CommandDispatcher.swift`, replace the temporary stub:

```swift
            case .forgetProvenance:
                // TODO Task 7: implement forgetProvenance dispatch
                return .failure(GohError(code: .invalidArgument, message: "forgetProvenance not yet implemented"))
```

with the real implementation:

```swift
            case .forgetProvenance(let request):
                guard let provenanceStore else {
                    // No store configured (test/headless): nothing could be removed.
                    // Return 0 removed — not a phantom success, not an error.
                    warn?("forgetProvenance: provenance store unavailable; skipped \(request.paths.count) path(s)")
                    return .forgotProvenance(ForgetProvenanceReply(forgotCount: 0))
                }
                do {
                    let forgotCount = try provenanceStore.forget(paths: request.paths)
                    return .forgotProvenance(ForgetProvenanceReply(forgotCount: forgotCount))
                } catch {
                    // Foreground destructive command — do NOT mirror recordVerifiedProvenance's
                    // best-effort .ack-on-throw. A write failure (atomic-write / rename) is a
                    // structured failure the CLI surfaces as a non-zero exit (AC4).
                    warn?("forgetProvenance: provenance store write failed for \(request.paths.count) path(s): \(error)")
                    return .failure(GohError(
                        code: .destinationUnwritable,
                        message: "could not rewrite the provenance ledger: \(error)"))
                }
```

### Step 7.4 — Run tests green

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter CommandDispatcherForgetTests -Xswiftc -warnings-as-errors 2>&1
```

Expected: all 4 dispatcher tests pass.

### Step 7.5 — Full test suite

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test -Xswiftc -warnings-as-errors 2>&1
```

Expected: all tests pass.

### Step 7.6 — Commit

```bash
git add Sources/GohCore/Model/CommandDispatcher.swift \
        Tests/GohCoreTests/CommandDispatcherForgetTests.swift
git commit -m "feat(daemon): CommandDispatcher.forgetProvenance case — failure-on-throw, not best-effort .ack"
```

---

## Task 8 — Phase 1 artifact + integration verify + PR

### Step 8.1 — Write Phase 1 progress artifact

Write `docs/superpowers/progress/2026-06-10-goh-forget-phase1.md` (see below — this file describes what Phase 2 needs).

### Step 8.2 — Final full build + test suite

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -Xswiftc -warnings-as-errors 2>&1 && \
  swift test -Xswiftc -warnings-as-errors 2>&1
```

Expected: `Build complete!`. All tests pass. Zero new warnings.

### Step 8.3 — Update STATE.md

Record Phase 1 complete; next: Phase 2 (tray). Write Next-session handoff note.

### Step 8.4 — Commit and push

```bash
git add docs/superpowers/progress/2026-06-10-goh-forget-phase1.md STATE.md
git commit -m "docs(state): Phase 1 goh-forget complete; record Phase 2 tray handoff"
git push -u origin feat/goh-forget
```

### Step 8.5 — PR

```bash
gh pr create \
  --title "feat: goh forget — Phase 1 (CLI + daemon + store + wire)" \
  --body "$(cat <<'EOF'
## Summary

- `ProvenanceStore.forget(paths:) throws -> Int` — atomic ledger-entry removal, file-safety invariant (AC4, M7).
- Wire: `Command.forgetProvenance` + `ForgetProvenanceRequest`, `ForgetProvenanceReply`, `CommandOutcome.forgotProvenance`, `CommandService.encodeReply` arm.
- `GohFeatureLevel.current` 1→2; DESIGN.md paragraph.
- Two golden fixtures: `envelope-v4-forget-provenance-{request,reply}.json` with byte-exact round-trip tests.
- `GohForgetCommand` runner: explicit path (git-rm model, AC1, AC3), `--missing` dry-run + volume-mount annotation (AC2 preview, Preview-and-Confirm THE BET), `--missing --confirm` (AC2 confirm, sends stored paths VERBATIM), stale-daemon gate via fresh `.ls` featureLevel check (gap #1), file-safety test (gap #2/M7).
- `GohCommandLine` parse/dispatch + usage for `goh forget`.
- `CommandDispatcher.forgetProvenance` — failure reply on write error (not best-effort .ack, per AC4).

## Phase 2 (deferred)
`GohMenuClient.forget(paths:)` protocol method + 5 conformers + `TrustWindowViewModel.forget` + SwiftUI MISSING-row affordance + preview/confirm sheet (AC5). Depends on this daemon PR being live.

## Test plan
- [ ] `swift build -Xswiftc -warnings-as-errors` green on macOS 26 CI.
- [ ] `ForgetProvenanceStoreTests` — AC4 atomic write, file-safety (M7), empty no-op, multi-path.
- [ ] `GohForgetCommandTests` — AC1, AC2, AC3 (untracked path + corrupt-ledger → exit 6), gap #1 (stale/nil featureLevel/unreachable), gap #2.
- [ ] `EnvelopeCodecForgetProvenanceTests` — golden fixture decode + byte-equal round-trip.
- [ ] `CommandDispatcherForgetTests` — success count, no-store, no-match.
- [ ] `GohCommandLineForgetParseTests` — all usage-error paths (exit 64) + valid forms.
EOF
)"
```

---

## Quick Reference: Exit Code Contract

| Situation | Exit |
|-----------|------|
| `forget <path>` tracked, forgotten | 0 |
| `forget <path>` untracked | 1 |
| `forget <path>` ledger unreadable/corrupt/unknown-version | 6 |
| `forget --missing` dry-run (any candidate count) | 0 |
| `forget --missing` ledger unreadable/corrupt/unknown-version | 6 |
| `forget --missing --confirm` success (`forgotCount == K`) | 0 |
| `forget --missing --confirm` partial (`forgotCount < K`) | non-zero (1) |
| daemon too old (featureLevel `nil`/`< 2`) on mutating path | 1 |
| daemon unreachable on mutating path | 1 |
| daemon failure reply (ledger-write error) | 1 |
| usage error (`--confirm` w/o `--missing`, both selectors, unknown flag, extra positional, no args) | 64 |

---

## Frozen Contract Checklist

These MUST NOT change in Phase 1:

- [x] `protocolVersion = 4` — `CommandService.protocolVersion` stays 4.
- [x] `ProvenanceRecord.currentVersion = 1` — no schema change.
- [x] `VerifyAllReport` JSON shape — not touched.
- [x] launchd plist — not touched.
- [x] `machServiceName` — not touched.
- [x] Existing `AckReply`, `LsReply`, `RmReply` — not modified.
- [x] `DaemonAutoHeal.runIfNeeded` return value — NOT used for exit-code decisions in GohForgetCommand (only the fresh `.ls` compare matters).
