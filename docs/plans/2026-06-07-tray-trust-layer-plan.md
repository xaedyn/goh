---
date: 2026-06-07
feature: tray-trust-layer
REQUIRED_SKILL: superpowers:subagent-driven-development
Goal: Surface goh's trust layer in the menu-bar tray — a glanceable at-rest provenance summary in the popover (Approach A — "Status badge + Trust window") and a dedicated Trust window with per-file detail and an on-demand background verify (re-hash with progress + cancel). Read-only; no wire/format change.
Architecture: Approach A (THE BET) — "A glanceable at-rest summary in the popover is worth the extra section — users want trust status at a glance, not only after opening a window." Shared ProvenanceLedgerReader and VerifyAllRunner in GohCore; pure presenter + trust models in GohMenuBar; Window(id:"trust") + @StateObject root wired in goh-menu/main.swift.
Tech Stack: Swift 6.2/6.3.x toolchain, SwiftPM, macOS 26.0+, SwiftUI+AppKit (MenuBarExtra + Window), GohMenuBar (.defaultIsolation MainActor), GohCore (nonisolated default), Swift Testing. CI: swift build/swift test on macos-26, -warnings-as-errors. Local: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer.
---

# Implementation Plan — Trust Layer in the Tray

## Acceptance criteria map

| AC | Description | Owning task(s) |
|----|-------------|----------------|
| AC1 | Provenance overview from direct ledger read; empty/absent → friendly empty state; labelled "last recorded" | Tasks 1, 4, 6, 7 |
| AC2 | Per-file detail: sanitized URL, sha256, downloaded/last-verified dates | Tasks 4, 6, 7 |
| AC3 | Background verify: off-main re-hash, progress, cancel, OK/FAILED/MISSING summary; no cooperative-pool freeze | Tasks 2, 3, 6, 7 |
| AC4 | Read-only; no ProvenanceRecord/VerifyAllReport/protocolVersion change; golden fixture round-trips; full suite green | Tasks 1, 2, 3, 4 |
| AC5 | Tray verify identical to `goh verify --all` for same ledger | Tasks 2, 3, 6 |

## Bet check (THE BET)

> "A glanceable at-rest summary in the popover is worth the extra section — users want trust status at a
> glance, not only after opening a window."
>
> This plan adds a one-line popover trust summary (cheap off-main ledger read on popover open, published
> to @MainActor) + a Trust window for per-file detail and background re-hash. The heavy re-hash runs on a
> dedicated OS thread (Thread.detachNewThread) — NOT Task.detached — to avoid the #81 cooperative-pool
> starvation. Approach B (window-only) is strictly a subset; the popover section is additive and
> reversible. No XPC/wire/frozen-format change anywhere.

## Critical regression gate (P1, highest-risk task)

**The GohVerifyAllCommand refactor (Task 3) MUST leave human output, --json bytes, exit codes, entry
order, and payloadBytes(for:) byte-identical.** Gate: ALL of the following must pass UNCHANGED after
Task 3:
- `GohVerifyAllCommandTests` (all 5 tests)
- `GohVerifyAllCommandJSONTests` (all 7 tests)
- `verify-all-report-v1.json` golden fixture round-trip
- `GohAttestCommandTests` (payloadBytes consumer — attest signs the exact bytes)

## Phase structure

> 9 tasks → 3 phases segmented at deployment-independence boundaries.
> Phase artifacts: `docs/superpowers/progress/2026-06-07-tray-trust-layer-phase{1,2,3}.md`

- **Phase 1 (Tasks 1–3):** GohCore — `ProvenanceLedgerReader`, `VerifyAllRunner`, `GohVerifyAllCommand`
  refactor. Independently shippable; the regression gate lives here. Validates the extraction before any
  UI depends on it.
- **Phase 2 (Tasks 4–5):** GohMenuBar value layer — `GohTrustModels` (protocol + types),
  `GohTrustPresenter`. Pure/unit-tested with stubs; no disk, no AppKit, no Swift concurrency.
- **Phase 3 (Tasks 6–9):** UI + wiring — `TrustWindowViewModel`, `TrustWindowView`, popover section,
  `main.swift` Window/live reader/@StateObject. Build-validated (no UI unit tests; manual smoke notes
  provided).

---

## Phase 1 — GohCore extraction (Tasks 1–3)

### Task 1 — CREATE `Sources/GohCore/Provenance/ProvenanceLedgerReader.swift`

**Files**
- CREATE `Sources/GohCore/Provenance/ProvenanceLedgerReader.swift`

**AC ownership:** AC1 (ledger read boundary), AC4 (no format change), AC5 (shared read path)

**Pre-task reads (completed in Phase 0)**
- `Sources/GohCore/CLI/GohVerifyAllCommand.swift` — the EXACT classification order the reader must mirror: `fileExists==false → .absent`; `Data(contentsOf:) throws → .unreadable(.io)`; `PropertyListDecoder throws → .unreadable(.corrupt)`; `record.version != currentVersion → .unreadable(.versionUnknown(found: record.version))`; else `.entries(record.entries)`.
- `Sources/GohCore/Provenance/ProvenanceRecord.swift` — `ProvenanceRecord.currentVersion` (1); `ProvenanceEntry` fields.
- `Sources/GohCore/Provenance/ProvenanceStore.swift` — `loadReadOnly()` pattern (never creates sidecar); the `create: false` invariant.

**Step 1 — Failing tests**

File: `Tests/GohCoreTests/ProvenanceLedgerReaderTests.swift` (CREATE)

```swift
import Foundation
import Testing
@testable import GohCore

// AC1/AC4/AC5: shared ledger reader used by both the CLI runner and the tray.
// Classification order must match GohVerifyAllCommand.run() exactly.
@Suite("ProvenanceLedgerReader")
struct ProvenanceLedgerReaderTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-ledgerreader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // AC1: absent file → .absent (not .unreadable)
    @Test("absent file returns .absent")
    func absentReturnsAbsent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("noexist.plist").path
        let outcome = ProvenanceLedgerReader.read(at: path)
        #expect(outcome == .absent)
    }

    // AC4: unreadable file (chmod 000) → .unreadable(.io)
    @Test("unreadable file returns .unreadable(.io)")
    func unreadableReturnsIO() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("provenance.plist")
        try Data("dummy".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let outcome = ProvenanceLedgerReader.read(at: url.path)
        #expect(outcome == .unreadable(.io))
    }

    // AC4: corrupt plist bytes → .unreadable(.corrupt)
    @Test("corrupt plist bytes returns .unreadable(.corrupt)")
    func corruptReturnscorrupt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("provenance.plist")
        try Data("not a plist at all".utf8).write(to: url)
        let outcome = ProvenanceLedgerReader.read(at: url.path)
        #expect(outcome == .unreadable(.corrupt))
    }

    // AC4: unknown-version plist → .unreadable(.versionUnknown(found: 9999))
    @Test("unknown-version record returns .unreadable(.versionUnknown(found:))")
    func unknownVersionReturnsVersionUnknown() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("provenance.plist")
        let record = ProvenanceRecord(version: 9999, entries: [])
        let data = try PropertyListEncoder().encode(record)
        try data.write(to: url)
        let outcome = ProvenanceLedgerReader.read(at: url.path)
        #expect(outcome == .unreadable(.versionUnknown(found: 9999)))
    }

    // AC1: empty entries array → .entries([]) (not .absent)
    @Test("empty entries array returns .entries([])")
    func emptyEntriesReturnsEntries() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("provenance.plist")
        let record = ProvenanceRecord(version: ProvenanceRecord.currentVersion, entries: [])
        let data = try PropertyListEncoder().encode(record)
        try data.write(to: url)
        let outcome = ProvenanceLedgerReader.read(at: url.path)
        #expect(outcome == .entries([]))
    }

    // AC5: valid ledger with entries → .entries with correct count and order preserved
    @Test("valid ledger returns .entries in stored order")
    func validLedgerReturnsEntries() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("provenance.plist")
        let entries = [
            ProvenanceEntry(url: "https://a.example.com/a.bin", sha256: "sha256:aa",
                            size: 1, downloadedAt: Date(timeIntervalSince1970: 1_000),
                            destinationPath: "/tmp/a.bin"),
            ProvenanceEntry(url: "https://b.example.com/b.bin", sha256: "sha256:bb",
                            size: 2, downloadedAt: Date(timeIntervalSince1970: 2_000),
                            destinationPath: "/tmp/b.bin"),
        ]
        let record = ProvenanceRecord(version: ProvenanceRecord.currentVersion, entries: entries)
        let data = try PropertyListEncoder().encode(record)
        try data.write(to: url)
        let outcome = ProvenanceLedgerReader.read(at: url.path)
        guard case .entries(let decoded) = outcome else {
            Issue.record("Expected .entries, got \(outcome)")
            return
        }
        #expect(decoded.count == 2)
        #expect(decoded[0].destinationPath == "/tmp/a.bin")
        #expect(decoded[1].destinationPath == "/tmp/b.bin")
    }

    // AC4: read never creates a sidecar (no side effects on disk)
    @Test("read never creates sidecar on corrupt ledger (CLI invariant)")
    func noSidecarOnCorrupt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("provenance.plist")
        try Data("not a plist".utf8).write(to: url)
        _ = ProvenanceLedgerReader.read(at: url.path)
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let sidecars = contents.filter { $0.contains(".corrupt-") }
        #expect(sidecars.isEmpty, "read must not create sidecar copies")
    }
}
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProvenanceLedgerReaderTests 2>&1
```

Expected: compile error — `ProvenanceLedgerReader`, `LedgerUnreadableReason`, `ProvenanceReadOutcome` do not exist.

**Step 3 — Implementation**

CREATE `Sources/GohCore/Provenance/ProvenanceLedgerReader.swift`:

```swift
import Foundation

/// The structured reason a ledger file could not be decoded.
///
/// Structured (not a free-form String) because the CLI's frozen --json output
/// emits three distinct, separately-tested VerifyErrorCodes — and versionUnknown
/// embeds the int — so callers must discriminate, not string-parse.
nonisolated public enum LedgerUnreadableReason: Sendable, Equatable {
    /// `Data(contentsOf:)` failed — file present but unreadable (I/O or permissions).
    /// Maps to `.ledgerUnreadable` / "provenance ledger unreadable" / exit 6.
    case io
    /// `PropertyListDecoder` failed — data present but malformed.
    /// Maps to `.ledgerCorrupt` / "provenance ledger corrupt" / exit 6.
    case corrupt
    /// Decoded cleanly but `record.version != currentVersion`.
    /// Maps to `.ledgerVersionUnknown` / "provenance ledger version \(n) is unknown" / exit 6.
    case versionUnknown(found: Int)
}

/// The outcome of a read-only ledger read.
nonisolated public enum ProvenanceReadOutcome: Sendable, Equatable {
    /// File does not exist — treat as empty (exit-0 analog; never an error).
    case absent
    /// Decoded successfully. Array may be empty.
    case entries([ProvenanceEntry])
    /// File present but unreadable / corrupt / unknown version.
    case unreadable(LedgerUnreadableReason)
}

/// Read-only ledger reader — the single decode+version-check shared by both
/// `VerifyAllRunner` and the tray's `ProvenanceReading` protocol.
///
/// Classification order MUST match `GohVerifyAllCommand.run()` exactly:
///   1. fileExists == false        → .absent
///   2. Data(contentsOf:) throws   → .unreadable(.io)
///   3. PropertyListDecoder throws  → .unreadable(.corrupt)
///   4. record.version != current   → .unreadable(.versionUnknown(found:))
///   5. else                        → .entries(record.entries) in stored order
///
/// Never writes, never throws, never creates a sidecar (only the daemon's
/// `load()` performs recovery).
nonisolated public enum ProvenanceLedgerReader {

    /// Read-only decode of the provenance ledger at `path`.
    ///
    /// - Parameter path: Absolute path to `provenance.plist`
    ///   (from `ProvenanceStoreLocation.defaultURL(create: false)`).
    /// - Returns: The classified outcome; never throws.
    public static func read(at path: String) -> ProvenanceReadOutcome {
        guard FileManager.default.fileExists(atPath: path) else {
            return .absent
        }

        let storeURL = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: storeURL) else {
            return .unreadable(.io)
        }

        let record: ProvenanceRecord
        do {
            record = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
        } catch {
            return .unreadable(.corrupt)
        }

        guard record.version == ProvenanceRecord.currentVersion else {
            return .unreadable(.versionUnknown(found: record.version))
        }

        return .entries(record.entries)
    }
}
```

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProvenanceLedgerReaderTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: all 6 reader tests pass; build clean.

**Step 5 — Commit**

```
git add Sources/GohCore/Provenance/ProvenanceLedgerReader.swift \
        Tests/GohCoreTests/ProvenanceLedgerReaderTests.swift
git commit -m "feat(trust-tray): add ProvenanceLedgerReader (shared classify-once reader)"
```

---

### Task 2 — CREATE `Sources/GohCore/CLI/VerifyAllRunner.swift`

**Files**
- CREATE `Sources/GohCore/CLI/VerifyAllRunner.swift`

**AC ownership:** AC3 (off-main, progress, cancel), AC4 (no format change), AC5 (parity with CLI)

**Pre-task reads (completed in Phase 0)**
- `Sources/GohCore/CLI/GohVerifyAllCommand.swift` — the EXACT re-hash loop (lines 114–159): `FileDigest.cannotOpen` + generic catch both → `.missing`; hash match → `.ok`; mismatch → `.failed` with `actualSha256`; `hasMissing`/`hasFailed` booleans; `lines` accumulation; entry ORDER = ledger order; summary fold from `entries[]` at the end (never a parallel tally).
- `Sources/GohCore/CLI/VerifyReportTypes.swift` — `VerifyAllReport`, `VerifySummary`, `VerifyEntryResult`, `VerifyStatus` (frozen); `VerifyErrorCode` (three codes).
- `Sources/GohCore/TrustCore/FileDigest.swift` — `sha256WithSize(path:)` throws `DigestError.cannotOpen` for missing/unreadable; re-throws `FileHandle` read errors.
- `Sources/GohMenuBar/GohMenuProgressStream.swift` — `GohMenuProgressSubscriptionCancellation` reference-box pattern for capturing a noncopyable across @Sendable (model for boxing the `Mutex<Bool>` cancel flag).

**CRITICAL concurrency constraints:**
- The caller (`TrustWindowViewModel`) dispatches `VerifyAllRunner.verifyAll(...)` on `Thread.detachNewThread` or `DispatchQueue.global().async` — NOT `Task.detached`. The runner itself is a synchronous function (no `async`); it runs blocking I/O with no suspension points. This preserves the invariant that hashing never starves the cooperative pool (#81 incident).
- `VerifyAllRunner.verifyAll` `throws` ONLY on `ProvenanceReadOutcome.unreadable` (ledger error → CLI maps to exit 6; tray maps to `.failed`). It does NOT throw on cancel — cancel returns a partial `VerifyAllReport`.
- The `isCancelled` closure is `@Sendable () -> Bool`. The cancel flag is a `Mutex<Bool>` boxed in a reference type (`CancellationBox`) before capturing in the closure — NOT `Atomic<Bool>`/bare `Mutex` (both are `~Copyable` and can't be captured into an escaping @Sendable closure). Mirror `GohMenuProgressSubscriptionCancellation`.
- `progress` fires AFTER each file is fully hashed: `completed` = number finished so far, `currentPath` = path just completed. `completed` reaches `total` only on a full (non-cancelled) run.
- Per-file errors (missing/unreadable) are caught and classified; the run NEVER aborts on one bad file.

**Step 1 — Failing tests**

File: `Tests/GohCoreTests/VerifyAllRunnerTests.swift` (CREATE)

```swift
import Foundation
import Testing
@testable import GohCore

/// Mutable box for capturing test state inside the runner's `@Sendable` progress/isCancelled
/// closures. A `@Sendable` closure cannot capture a mutable `var` by reference (it would fail
/// under -warnings-as-errors), so the closure captures this reference instead. The runner calls
/// these closures synchronously on a single thread within `verifyAll`, so `@unchecked Sendable`
/// with a plain `var` is safe in this test context.
private final class RunnerTestBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

// AC3/AC5: VerifyAllRunner tests — parity with CLI, cancel, per-file error isolation, progress.
// All tests use the temp-plist fixture pattern from GohVerifyAllCommandTests.
@Suite("VerifyAllRunner")
struct VerifyAllRunnerTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-runner-\(UUID().uuidString)")
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
                url: "https://example.com/" + URL(fileURLWithPath: path).lastPathComponent,
                sha256: sha256,
                size: content.count,
                downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
                destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path))
        }
        return (storeURL, sha256s)
    }

    // AC5: runner produces same VerifyAllReport as the CLI for a fixture ledger (parity gate)
    @Test("AC5: runner report matches CLI report for mixed fixture ledger")
    func runnerParityWithCLI() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ok = dir.appendingPathComponent("ok.bin").path
        let failed = dir.appendingPathComponent("failed.bin").path
        let missing = dir.appendingPathComponent("missing.bin").path

        let (storeURL, _) = try makeStore(in: dir, entries: [
            (ok, Data("unchanged".utf8)),
            (failed, Data("original".utf8)),
            (missing, Data("willbedeleted".utf8)),
        ])
        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: failed))
        try FileManager.default.removeItem(atPath: missing)

        let fixedDate = Date(timeIntervalSince1970: 1_714_262_400)

        // CLI result
        let cliResult = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: true,
            generatedAt: fixedDate)
        let cliReport = try CommandCoding.decoder.decode(
            VerifyAllReport.self, from: Data(cliResult.standardOutput.utf8))

        // Runner result (synchronous call — acceptable in test body; not on cooperative pool)
        // NOTE: production callers dispatch this on Thread.detachNewThread.
        let runnerReport = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: fixedDate,
            progress: nil,
            isCancelled: nil)

        // AC5: entry statuses must be identical (order, status, paths)
        #expect(runnerReport.entries.count == cliReport.entries.count)
        #expect(runnerReport.summary == cliReport.summary)
        for (runnerEntry, cliEntry) in zip(runnerReport.entries, cliReport.entries) {
            #expect(runnerEntry.path == cliEntry.path)
            #expect(runnerEntry.status == cliEntry.status)
            #expect(runnerEntry.expectedSha256 == cliEntry.expectedSha256)
            #expect(runnerEntry.actualSha256 == cliEntry.actualSha256)
        }
    }

    // AC3: cancel between files → partial report (not a throw)
    @Test("AC3: cancel after first file returns partial report with only processed entries")
    func cancelYieldsPartialReport() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("f1.bin").path
        let f2 = dir.appendingPathComponent("f2.bin").path
        let f3 = dir.appendingPathComponent("f3.bin").path

        let (storeURL, _) = try makeStore(in: dir, entries: [
            (f1, Data("data1".utf8)),
            (f2, Data("data2".utf8)),
            (f3, Data("data3".utf8)),
        ])

        // Cancel after f1 is processed (completed == 1). The flag is boxed in a
        // reference type because a `@Sendable` closure cannot capture a mutable
        // `var` by reference (it would fail under -warnings-as-errors). The runner
        // calls isCancelled synchronously on one thread, so the @unchecked box is
        // safe here. (See RunnerTestBox below.)
        let cancelCounter = RunnerTestBox(1)
        let report = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: nil,
            isCancelled: {
                if cancelCounter.value > 0 { cancelCounter.value -= 1; return false }
                return true
            })

        // Should have processed exactly 1 entry (f1); f2 and f3 were not started
        #expect(report.entries.count == 1)
        #expect(report.summary.total == 1)
        #expect(report.summary.ok == 1)
    }

    // AC3: per-file missing error → classified MISSING; run continues to next file
    @Test("AC3: missing file classified MISSING; run continues to remaining files")
    func missingFileIsolation() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("present.bin").path
        let f2 = dir.appendingPathComponent("missing.bin").path

        let (storeURL, _) = try makeStore(in: dir, entries: [
            (f1, Data("data".utf8)),
            (f2, Data("willbedeleted".utf8)),
        ])
        try FileManager.default.removeItem(atPath: f2)

        let report = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: nil,
            isCancelled: nil)

        #expect(report.entries.count == 2)
        #expect(report.summary.ok == 1)
        #expect(report.summary.missing == 1)
        let f2Canon = URL(fileURLWithPath: f2).standardizedFileURL.path
        let missingEntry = try #require(report.entries.first { $0.path == f2Canon })
        #expect(missingEntry.status == .missing)
    }

    // AC3: progress callback fires once per file, after it completes
    @Test("AC3: progress callback fires once per file in order; completed increments")
    func progressFiresAfterEachFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("a.bin").path
        let f2 = dir.appendingPathComponent("b.bin").path

        let (storeURL, _) = try makeStore(in: dir, entries: [
            (f1, Data("aaa".utf8)),
            (f2, Data("bbb".utf8)),
        ])

        // Boxed in a reference type so the @Sendable progress closure captures a
        // reference, not a mutable var (required under -warnings-as-errors).
        let progressEvents = RunnerTestBox<[VerifyProgress]>([])
        _ = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: { progressEvents.value.append($0) },
            isCancelled: nil)

        #expect(progressEvents.value.count == 2)
        #expect(progressEvents.value[0].completed == 1)
        #expect(progressEvents.value[0].total == 2)
        #expect(progressEvents.value[1].completed == 2)
        #expect(progressEvents.value[1].total == 2)
    }

    // AC4: unreadable ledger → throws (not a partial report)
    @Test("AC4: unreadable ledger causes throw, not a silent empty report")
    func unreadableLedgerThrows() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("provenance.plist")
        try Data("not a plist".utf8).write(to: url)

        // Tighter than `(any Error).self`: assert the specific runner error type, and that the
        // structured reason is `.corrupt` (decodable-file-but-not-a-plist → corrupt, not io).
        #expect(throws: VerifyAllRunnerError.self) {
            try VerifyAllRunner.verifyAll(
                provenanceStorePath: url.path,
                generatedAt: Date(),
                progress: nil,
                isCancelled: nil)
        }
        do {
            _ = try VerifyAllRunner.verifyAll(
                provenanceStorePath: url.path, generatedAt: Date(), progress: nil, isCancelled: nil)
            Issue.record("expected VerifyAllRunnerError.ledgerUnreadable")
        } catch let VerifyAllRunnerError.ledgerUnreadable(reason) {
            #expect(reason == .corrupt)
        }
    }
}
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VerifyAllRunnerTests 2>&1
```

Expected: compile error — `VerifyAllRunner`, `VerifyProgress` do not exist.

**Step 3 — Implementation**

CREATE `Sources/GohCore/CLI/VerifyAllRunner.swift`:

```swift
import Foundation

/// Progress after one file finishes hashing.
///
/// `completed` = number of files fully processed so far.
/// `total`     = total entries in the ledger at run start.
/// `currentPath` = the file just completed (for display; nil after cancel completes a file).
///
/// `progress` fires AFTER each file, so `completed` reaches `total` only on a full run.
public struct VerifyProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let currentPath: String?

    public init(completed: Int, total: Int, currentPath: String?) {
        self.completed = completed
        self.total = total
        self.currentPath = currentPath
    }
}

/// Errors thrown by `VerifyAllRunner.verifyAll(...)`.
public enum VerifyAllRunnerError: Error {
    /// The ledger could not be read/decoded. Maps to exit 6 in the CLI.
    case ledgerUnreadable(LedgerUnreadableReason)
}

/// Pure, testable verify runner shared by `GohVerifyAllCommand` (CLI) and
/// `TrustWindowViewModel` (tray).
///
/// CONTRACT:
/// - Throws ONLY on a ledger-level read failure (`ProvenanceReadOutcome.unreadable`).
/// - Does NOT throw on cancel — returns a partial `VerifyAllReport`.
/// - `.absent` / `.entries([])` → returns an empty report (exit-0 analog); no throw.
/// - Entry ORDER and summary fold match the current CLI exactly (golden fixture unchanged).
/// - `progress` fires AFTER each file; `isCancelled` is checked BETWEEN files.
/// - Per-file digest errors → MISSING/FAILED; the run NEVER aborts on one bad file.
///
/// **Concurrency:** this function is synchronous (no `async`). Callers that need
/// off-main execution MUST dispatch it on `Thread.detachNewThread` or
/// `DispatchQueue.global().async` — NOT `Task.detached`, which runs on the
/// cooperative pool and would starve it during the blocking hash loop (#81).
public enum VerifyAllRunner {

    /// Re-hashes every recorded file and returns the structured report.
    ///
    /// - Parameters:
    ///   - provenanceStorePath: Absolute path to `provenance.plist`.
    ///   - generatedAt: Timestamp for `VerifyAllReport.generatedAt`.
    ///   - progress: Called after each file completes (may be nil).
    ///   - isCancelled: Called before starting each file (may be nil).
    ///     Return `true` to stop; the partial report is returned (no throw).
    /// - Throws: `VerifyAllRunnerError.ledgerUnreadable` on ledger read failure.
    public static func verifyAll(
        provenanceStorePath: String,
        generatedAt: Date,
        progress: (@Sendable (VerifyProgress) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> VerifyAllReport {
        let outcome = ProvenanceLedgerReader.read(at: provenanceStorePath)

        switch outcome {
        case .unreadable(let reason):
            throw VerifyAllRunnerError.ledgerUnreadable(reason)

        case .absent, .entries([]):
            return VerifyAllReport(
                reportVersion: 1,
                generatedAt: generatedAt,
                summary: VerifySummary(total: 0, ok: 0, failed: 0, missing: 0),
                entries: [])

        case .entries(let ledgerEntries):
            return rehash(
                entries: ledgerEntries,
                generatedAt: generatedAt,
                progress: progress,
                isCancelled: isCancelled)
        }
    }

    // MARK: - Private

    private static func rehash(
        entries: [ProvenanceEntry],
        generatedAt: Date,
        progress: (@Sendable (VerifyProgress) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) -> VerifyAllReport {
        let total = entries.count
        var results: [VerifyEntryResult] = []
        var completed = 0

        for entry in entries {
            // Check cancellation BEFORE starting the next file.
            if isCancelled?() == true {
                break
            }

            let result = hashEntry(entry)
            results.append(result)
            completed += 1

            progress?(VerifyProgress(
                completed: completed,
                total: total,
                currentPath: entry.destinationPath))
        }

        // Summary folded from results[] — never a parallel tally (matches CLI exactly).
        let summary = VerifySummary(
            total: results.count,
            ok: results.filter { $0.status == .ok }.count,
            failed: results.filter { $0.status == .failed }.count,
            missing: results.filter { $0.status == .missing }.count)

        return VerifyAllReport(
            reportVersion: 1,
            generatedAt: generatedAt,
            summary: summary,
            entries: results)
    }

    private static func hashEntry(_ entry: ProvenanceEntry) -> VerifyEntryResult {
        let hash: String
        do {
            (hash, _) = try FileDigest.sha256WithSize(path: entry.destinationPath)
        } catch FileDigest.DigestError.cannotOpen {
            return VerifyEntryResult(
                path: entry.destinationPath,
                url: entry.url,
                status: .missing,
                expectedSha256: entry.sha256,
                actualSha256: nil)
        } catch {
            // Any other FileHandle error (I/O during read) → MISSING (file may be unreadable).
            return VerifyEntryResult(
                path: entry.destinationPath,
                url: entry.url,
                status: .missing,
                expectedSha256: entry.sha256,
                actualSha256: nil)
        }

        if hash == entry.sha256 {
            return VerifyEntryResult(
                path: entry.destinationPath,
                url: entry.url,
                status: .ok,
                expectedSha256: entry.sha256,
                actualSha256: nil)
        } else {
            return VerifyEntryResult(
                path: entry.destinationPath,
                url: entry.url,
                status: .failed,
                expectedSha256: entry.sha256,
                actualSha256: hash)
        }
    }
}
```

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VerifyAllRunnerTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: all 5 runner tests pass; build clean. (The `runnerParityWithCLI` test also proves AC5 via the existing GohVerifyAllCommand fixture.)

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/VerifyAllRunner.swift \
        Tests/GohCoreTests/VerifyAllRunnerTests.swift
git commit -m "feat(trust-tray): add VerifyAllRunner — shared pure verify runner with progress+cancel"
```

---

### Task 3 — MODIFY `Sources/GohCore/CLI/GohVerifyAllCommand.swift` (regression-critical refactor)

**Files**
- MODIFY `Sources/GohCore/CLI/GohVerifyAllCommand.swift`

**AC ownership:** AC4 (byte-identical output), AC5 (CLI still correct after extraction)

**CRITICAL:** This is the highest-risk task. `run()` must produce byte-identical human output, `--json` bytes, entry order, exit codes (0/2/9/6 with precedence 9>2>0), and `payloadBytes(for:)` output. The gate is: ALL pre-existing tests in `GohVerifyAllCommandTests`, `GohVerifyAllCommandJSONTests`, the golden `verify-all-report-v1.json` fixture, and `GohAttestCommandTests` PASS UNCHANGED.

**Pre-task reads (completed in Phase 0)**
- Full `GohVerifyAllCommand.swift` already read — the EXACT three ledger-error-code mappings, the re-hash loop, the human lines format, the `emptyReport` helper, `jsonResult`, `jsonErrorResult`, `payloadBytes`.

**Step 1 — Verify existing regression suite PASSES before touching any code**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
    --filter GohVerifyAllCommandTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
    --filter GohVerifyAllCommandJSONTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
    --filter GohAttestCommandTests 2>&1
```

All must pass green. If any fail pre-refactor, STOP and report — do not proceed.

**Step 2 — Implementation**

MODIFY `Sources/GohCore/CLI/GohVerifyAllCommand.swift` — replace `run()` body to delegate to
`ProvenanceLedgerReader` + `VerifyAllRunner`. The render layer (human lines, JSON encoding, exit codes,
`payloadBytes`) is UNCHANGED; only the core classify+rehash logic is delegated.

The new `run()` structure:

1. Call `ProvenanceLedgerReader.read(at: provenanceStorePath)`.
2. Switch on outcome:
   - `.absent` → same as "file not found" branch: exit 0, human "0 recorded entries\n" / JSON `emptyReport`.
   - `.unreadable(.io)` → EXACT frozen mapping: exit 6, human "provenance ledger unreadable\n" / JSON `.ledgerUnreadable`.
   - `.unreadable(.corrupt)` → EXACT frozen mapping: exit 6, human "provenance ledger corrupt\n" / JSON `.ledgerCorrupt`.
   - `.unreadable(.versionUnknown(let n))` → EXACT frozen mapping: exit 6, human "provenance ledger version \(n) is unknown\n" / JSON `.ledgerVersionUnknown`.
   - `.entries([])` → empty store branch: exit 0, human "0 recorded entries\n" / JSON `emptyReport`.
   - `.entries(let ledgerEntries)` → call `VerifyAllRunner.verifyAll(...)` with nil progress/cancel, then render from the returned `VerifyAllReport` (human lines + exit code derived from summary, OR JSON).
3. For the `.entries(n)` / human path: reconstruct the `lines` array from the runner's `entries[]` (same format as before: "OK path\n", "FAILED path expected E actual A\n", "MISSING path (expected E)\n"). Derive exit code from `summary.missing`/`summary.failed` with precedence 9>2>0.

Key invariants:
- `payloadBytes(for:)` is NOT changed — it remains a public static method calling `CommandCoding.encoder.encode(report)`.
- `emptyReport`, `jsonResult`, `jsonErrorResult` private helpers are NOT changed.
- Human line format is byte-identical: "OK \(path)\n", "FAILED \(path) expected \(expected) actual \(actual)\n", "MISSING \(path) (expected \(expected))\n".

```swift
// New run() — delegation to reader + runner
public static func run(
    provenanceStorePath: String,
    json: Bool = false,
    generatedAt: Date = Date()
) -> GohCommandLineResult {

    // ── Step 1: Classify ledger ────────────────────────────────────────────
    let outcome = ProvenanceLedgerReader.read(at: provenanceStorePath)

    switch outcome {
    case .absent, .entries([]):
        // Absent file OR empty entries array → exit 0, 0 recorded entries
        if json {
            return jsonResult(exitCode: 0, report: emptyReport(generatedAt: generatedAt))
        }
        return GohCommandLineResult(exitCode: 0, standardOutput: "0 recorded entries\n")

    case .unreadable(.io):
        if json { return jsonErrorResult(.ledgerUnreadable) }
        return GohCommandLineResult(exitCode: 6, standardOutput: "provenance ledger unreadable\n")

    case .unreadable(.corrupt):
        if json { return jsonErrorResult(.ledgerCorrupt) }
        return GohCommandLineResult(exitCode: 6, standardOutput: "provenance ledger corrupt\n")

    case .unreadable(.versionUnknown(let found)):
        if json { return jsonErrorResult(.ledgerVersionUnknown) }
        return GohCommandLineResult(
            exitCode: 6,
            standardOutput: "provenance ledger version \(found) is unknown\n")

    case .entries:
        break  // fall through to re-hash
    }

    // ── Step 2: Re-hash via runner ────────────────────────────────────────
    // VerifyAllRunner.verifyAll throws only on .unreadable — already handled above.
    // The catch here is a defensive guard (should never trigger given the switch above).
    let report: VerifyAllReport
    do {
        report = try VerifyAllRunner.verifyAll(
            provenanceStorePath: provenanceStorePath,
            generatedAt: generatedAt,
            progress: nil,
            isCancelled: nil)
    } catch {
        if json { return jsonErrorResult(.ledgerUnreadable) }
        return GohCommandLineResult(exitCode: 6, standardOutput: "provenance ledger unreadable\n")
    }

    // ── Step 3: Derive exit code ──────────────────────────────────────────
    let exitCode: Int32
    if report.summary.missing > 0 {
        exitCode = 9
    } else if report.summary.failed > 0 {
        exitCode = 2
    } else {
        exitCode = 0
    }

    // ── Step 4: Render ────────────────────────────────────────────────────
    if json {
        return jsonResult(exitCode: exitCode, report: report)
    }

    // Human: reconstruct lines[] from report.entries[] in order.
    let lines = report.entries.map { entry -> String in
        switch entry.status {
        case .ok:
            return "OK \(entry.path)\n"
        case .failed:
            let actual = entry.actualSha256 ?? ""
            return "FAILED \(entry.path) expected \(entry.expectedSha256) actual \(actual)\n"
        case .missing:
            return "MISSING \(entry.path) (expected \(entry.expectedSha256))\n"
        }
    }
    return GohCommandLineResult(exitCode: exitCode, standardOutput: lines.joined())
}
```

**Step 3 — Regression gate**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
    --filter GohVerifyAllCommandTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
    --filter GohVerifyAllCommandJSONTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
    --filter GohAttestCommandTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
    --filter VerifyAllRunnerTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

ALL must pass (zero regressions). If any pre-existing test fails, STOP — diagnose and fix before committing.

**Step 4 — Commit**

```
git add Sources/GohCore/CLI/GohVerifyAllCommand.swift
git commit -m "refactor(trust-tray): GohVerifyAllCommand delegates to ProvenanceLedgerReader+VerifyAllRunner"
```

---

## Phase 2 — GohMenuBar value layer (Tasks 4–5)

### Task 4 — CREATE `Sources/GohMenuBar/GohTrustModels.swift`

**Files**
- CREATE `Sources/GohMenuBar/GohTrustModels.swift`

**AC ownership:** AC1 (trust overview model), AC2 (entry row model), AC4 (read-only protocol seam)

**Pre-task reads (completed in Phase 0)**
- `Sources/GohMenuBar/GohMenuModels.swift` — `nonisolated public` + `Sendable` + `Equatable` pattern for all model types; `nonisolated public enum GohMenuHealth` as the template for `GohTrustOverview`.
- `Sources/GohCore/Provenance/ProvenanceLedgerReader.swift` (just created) — `ProvenanceReadOutcome` and `LedgerUnreadableReason` — these are the exact types `ProvenanceReading.read()` returns.

**Step 1 — Failing tests**

File: `Tests/GohMenuBarTests/GohTrustModelsTests.swift` (CREATE)

```swift
import Foundation
import Testing
import GohCore
@testable import GohMenuBar

// AC1/AC2/AC4: GohTrustModels type/field correctness + ProvenanceReading protocol seam.
@Suite("GohTrustModels")
struct GohTrustModelsTests {

    // AC1: GohTrustSummary counts are correct
    @Test("GohTrustSummary stores tracked/verified/downloadOnly counts")
    func summaryStorescounts() {
        let s = GohTrustSummary(tracked: 10, verified: 7, downloadOnly: 3)
        #expect(s.tracked == 10)
        #expect(s.verified == 7)
        #expect(s.downloadOnly == 3)
    }

    // AC1: GohTrustOverview cases exist and are Equatable
    @Test("GohTrustOverview cases: empty, unavailable, summary")
    func overviewCases() {
        let e: GohTrustOverview = .empty
        let u: GohTrustOverview = .unavailable
        let s: GohTrustOverview = .summary(GohTrustSummary(tracked: 1, verified: 1, downloadOnly: 0))
        #expect(e == .empty)
        #expect(u == .unavailable)
        #expect(e != u)
        #expect(e != s)
    }

    // AC2: GohTrustEntryRow stores expected fields
    @Test("GohTrustEntryRow stores displayPath, sanitizedURL, sha256, downloadedAt, verifiedAt")
    func entryRowFields() {
        let now = Date()
        let row = GohTrustEntryRow(
            displayPath: "/Users/me/Downloads/file.bin",
            sanitizedURL: "https://example.com/file.bin",
            sha256: "sha256:aabb",
            downloadedAt: now,
            verifiedAt: nil)
        #expect(row.displayPath == "/Users/me/Downloads/file.bin")
        #expect(row.sanitizedURL == "https://example.com/file.bin")
        #expect(row.sha256 == "sha256:aabb")
        #expect(row.downloadedAt == now)
        #expect(row.verifiedAt == nil)
    }

    // AC4: ProvenanceReading protocol — stub satisfies the seam
    @Test("ProvenanceReading stub returns injected outcome")
    func provenanceReadingStub() {
        struct StubReader: ProvenanceReading {
            let outcome: ProvenanceReadOutcome
            nonisolated func read() -> ProvenanceReadOutcome { outcome }
        }
        let stub = StubReader(outcome: .absent)
        #expect(stub.read() == .absent)
        let stub2 = StubReader(outcome: .entries([]))
        #expect(stub2.read() == .entries([]))
    }
}
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohTrustModelsTests 2>&1
```

Expected: compile errors — `GohTrustSummary`, `GohTrustOverview`, `GohTrustEntryRow`, `ProvenanceReading` do not exist.

**Step 3 — Implementation**

CREATE `Sources/GohMenuBar/GohTrustModels.swift`:

```swift
import Foundation
import GohCore

// MARK: - Trust summary types

/// At-rest provenance summary for the popover (AC1).
/// Derived from ProvenanceEntry.verifiedAt — NOT a live re-hash.
nonisolated public struct GohTrustSummary: Sendable, Equatable {
    /// Total entries in the ledger.
    public let tracked: Int
    /// Entries where verifiedAt != nil.
    public let verified: Int
    /// Entries where verifiedAt == nil (downloaded but never verified via sync).
    public let downloadOnly: Int

    public init(tracked: Int, verified: Int, downloadOnly: Int) {
        self.tracked = tracked
        self.verified = verified
        self.downloadOnly = downloadOnly
    }
}

/// The at-rest trust overview shown in the popover (AC1).
nonisolated public enum GohTrustOverview: Sendable, Equatable {
    /// No ledger present, or the ledger is present but empty — "No downloads recorded yet".
    case empty
    /// Ledger present but unreadable / corrupt / unknown version — "Trust data unavailable".
    case unavailable
    /// Ledger decoded successfully with one or more entries.
    case summary(GohTrustSummary)
}

/// One row in the Trust window's per-file list (AC2).
nonisolated public struct GohTrustEntryRow: Sendable, Equatable {
    /// The destinationPath as stored in the ledger (full canonical path).
    public let displayPath: String
    /// URLDisplay.sanitized applied to entry.url (control chars stripped, credentials redacted).
    public let sanitizedURL: String
    /// entry.sha256 verbatim ("sha256:"-prefixed).
    public let sha256: String
    /// entry.downloadedAt.
    public let downloadedAt: Date
    /// entry.verifiedAt (nil = downloaded-only; non-nil = last-verified date).
    public let verifiedAt: Date?

    public init(
        displayPath: String,
        sanitizedURL: String,
        sha256: String,
        downloadedAt: Date,
        verifiedAt: Date?
    ) {
        self.displayPath = displayPath
        self.sanitizedURL = sanitizedURL
        self.sha256 = sha256
        self.downloadedAt = downloadedAt
        self.verifiedAt = verifiedAt
    }
}

// MARK: - Read seam

/// Read seam allowing GohMenuBar unit tests to inject a stub ledger reader
/// (no disk, no XPC) while the live goh-menu target uses the real
/// ProvenanceLedgerReader. Returns the same ProvenanceReadOutcome trichotomy
/// as the runner so the corrupt/empty boundary is identical across the tray
/// and `verify --all`.
nonisolated public protocol ProvenanceReading: Sendable {
    /// Returns the read outcome — never throws (errors mapped to .unreadable).
    func read() -> ProvenanceReadOutcome
}
```

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohTrustModelsTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: all 4 tests pass; build clean.

**Step 5 — Commit**

```
git add Sources/GohMenuBar/GohTrustModels.swift \
        Tests/GohMenuBarTests/GohTrustModelsTests.swift
git commit -m "feat(trust-tray): add GohTrustModels (overview, entry row, ProvenanceReading seam)"
```

---

### Task 5 — CREATE `Sources/GohMenuBar/GohTrustPresenter.swift`

**Files**
- CREATE `Sources/GohMenuBar/GohTrustPresenter.swift`

**AC ownership:** AC1 (overview derivation, labelling), AC2 (sanitized URL per row), AC5 (empty/unavailable boundary)

**Pre-task reads (completed in Phase 0)**
- `Sources/GohMenuBar/GohMenuPresenter.swift` — `nonisolated public struct` pattern; pure presenter taking domain values, returning display values.
- `Sources/GohCore/CLI/URLDisplay.swift` — `URLDisplay.sanitized(_:)` signature; strips control chars + redacts credentials.
- `Sources/GohCore/Provenance/ProvenanceRecord.swift` — `ProvenanceEntry.verifiedAt` semantics (nil = download-only).

**Step 1 — Failing tests**

File: `Tests/GohMenuBarTests/GohTrustPresenterTests.swift` (CREATE)

```swift
import Foundation
import Testing
import GohCore
@testable import GohMenuBar

// AC1/AC2/AC5: GohTrustPresenter maps ProvenanceReadOutcome → GohTrustOverview + [GohTrustEntryRow].
@Suite("GohTrustPresenter")
struct GohTrustPresenterTests {

    private let presenter = GohTrustPresenter()

    // AC1: absent → .empty overview, empty rows
    @Test("AC1: .absent outcome → .empty overview, empty rows")
    func absentYieldsEmpty() {
        let (overview, rows) = presenter.present(.absent)
        #expect(overview == .empty)
        #expect(rows.isEmpty)
    }

    // AC1: entries([]) → .empty overview, empty rows
    @Test("AC1: .entries([]) outcome → .empty overview, empty rows")
    func emptyEntriesYieldsEmpty() {
        let (overview, rows) = presenter.present(.entries([]))
        #expect(overview == .empty)
        #expect(rows.isEmpty)
    }

    // AC5: unreadable → .unavailable overview, empty rows
    @Test("AC5: .unreadable → .unavailable overview, empty rows")
    func unreadableYieldsUnavailable() {
        for reason in [
            LedgerUnreadableReason.io,
            LedgerUnreadableReason.corrupt,
            LedgerUnreadableReason.versionUnknown(found: 99),
        ] {
            let (overview, rows) = presenter.present(.unreadable(reason))
            #expect(overview == .unavailable, "reason \(reason) should yield .unavailable")
            #expect(rows.isEmpty)
        }
    }

    // AC1: non-empty entries → .summary with correct counts
    @Test("AC1: non-empty entries → .summary with tracked/verified/downloadOnly counts")
    func nonEmptyEntriesYieldsSummary() {
        let now = Date()
        let entries = [
            makeEntry(path: "/a.bin", verifiedAt: now),    // verified
            makeEntry(path: "/b.bin", verifiedAt: now),    // verified
            makeEntry(path: "/c.bin", verifiedAt: nil),    // download-only
        ]
        let (overview, rows) = presenter.present(.entries(entries))
        guard case .summary(let s) = overview else {
            Issue.record("Expected .summary, got \(overview)")
            return
        }
        #expect(s.tracked == 3)
        #expect(s.verified == 2)
        #expect(s.downloadOnly == 1)
        #expect(rows.count == 3)
    }

    // AC2: URL is sanitized (credential redacted)
    @Test("AC2: entry URL is sanitized via URLDisplay.sanitized")
    func urlIsSanitized() {
        let entry = makeEntry(
            path: "/file.bin",
            url: "https://example.com/file?token=supersecret",
            verifiedAt: nil)
        let (_, rows) = presenter.present(.entries([entry]))
        #expect(rows.first?.sanitizedURL.contains("supersecret") == false)
        #expect(rows.first?.sanitizedURL.contains("REDACTED") == true)
    }

    // AC2: row fields map correctly
    @Test("AC2: row fields — displayPath, sha256, downloadedAt, verifiedAt mapped correctly")
    func rowFieldsCorrect() {
        let dl = Date(timeIntervalSince1970: 1_000)
        let vf = Date(timeIntervalSince1970: 2_000)
        let entry = ProvenanceEntry(
            url: "https://example.com/a.bin",
            sha256: "sha256:aabb",
            size: 42,
            downloadedAt: dl,
            destinationPath: "/Users/me/a.bin",
            verifiedAt: vf)
        let (_, rows) = presenter.present(.entries([entry]))
        let row = try? #require(rows.first)
        #expect(row?.displayPath == "/Users/me/a.bin")
        #expect(row?.sha256 == "sha256:aabb")
        #expect(row?.downloadedAt == dl)
        #expect(row?.verifiedAt == vf)
    }

    // AC1: entry order preserved (ledger order)
    @Test("AC1: row order matches ledger entry order")
    func rowOrderPreserved() {
        let entries = [
            makeEntry(path: "/z.bin", verifiedAt: nil),
            makeEntry(path: "/a.bin", verifiedAt: nil),
        ]
        let (_, rows) = presenter.present(.entries(entries))
        #expect(rows.map(\.displayPath) == ["/z.bin", "/a.bin"])
    }

    // Helper
    private func makeEntry(
        path: String,
        url: String = "https://example.com/file.bin",
        verifiedAt: Date?
    ) -> ProvenanceEntry {
        ProvenanceEntry(
            url: url,
            sha256: "sha256:aabb",
            size: 1,
            downloadedAt: Date(timeIntervalSince1970: 1_000),
            destinationPath: path,
            verifiedAt: verifiedAt)
    }
}
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohTrustPresenterTests 2>&1
```

Expected: compile error — `GohTrustPresenter` does not exist.

**Step 3 — Implementation**

CREATE `Sources/GohMenuBar/GohTrustPresenter.swift`:

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

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohTrustPresenterTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: all 7 tests pass; build clean.

**Step 5 — Commit**

```
git add Sources/GohMenuBar/GohTrustPresenter.swift \
        Tests/GohMenuBarTests/GohTrustPresenterTests.swift
git commit -m "feat(trust-tray): add GohTrustPresenter (ProvenanceReadOutcome → overview + rows)"
```

---

## Phase 3 — UI + wiring (Tasks 6–9)

> Phase 3 has no unit tests — UI + composition-root code is build-validated only.
> Each task ends with `swift build -Xswiftc -warnings-as-errors` clean + a manual smoke note.

### Task 6 — CREATE `Sources/GohMenuBar/TrustWindowViewModel.swift`

**Files**
- CREATE `Sources/GohMenuBar/TrustWindowViewModel.swift`

**AC ownership:** AC1 (off-main load), AC3 (background verify, progress, cancel, cooperative-pool safety), AC5 (verify produces same report as CLI)

**Pre-task reads (completed in Phase 0)**
- `Sources/GohMenuBar/GohMenuProgressStream.swift` — `GohMenuProgressSubscriptionCancellation` reference-box pattern; shows how to box a noncopyable (`GohMenuProgressSubscription`) in a `Mutex`-guarded reference type for @Sendable capture.
- `Sources/GohMenuBar/GohMenuViewModel.swift` — `@MainActor final class`, `@Published`, `Task { [weak self] in ... }` hop pattern for off-main work that publishes back to MainActor.
- `Sources/GohMenuBar/GohMenuModels.swift` — `nonisolated public` + Sendable conventions.
- `Sources/GohCore/CLI/VerifyAllRunner.swift` (just created) — `VerifyAllRunner.verifyAll(...)` signature.
- `Sources/GohCore/CLI/VerifyReportTypes.swift` — `VerifyAllReport` (the finished report type).

**CRITICAL concurrency:**
- The re-hash dispatched via `DispatchQueue.global().async` (or `Thread.detachNewThread`) — NOT `Task.detached` (which stays on the cooperative pool → #81 starvation).
- The cancel flag is a `Mutex<Bool>` (Swift `Synchronization`) boxed in `CancellationBox` (a `final class`) before capturing in the `@Sendable isCancelled` closure. Do NOT use `Atomic<Bool>` here: `Atomic` is `~Copyable` and cannot be captured into the escaping `@Sendable` closure — the `Mutex`-in-a-class box is the working pattern (mirrors `GohMenuProgressSubscriptionCancellation`).
- Progress published back to `@MainActor` via `Task { @MainActor in self.runState = .running(progress) }`.
- `Verify now` disabled while `.running`; one run at a time.

**Step 1 — No unit test for this task** (requires @MainActor + DispatchQueue; no practical stub boundary without a significant harness). Build validation is the gate.

**Step 2 — Implementation**

CREATE `Sources/GohMenuBar/TrustWindowViewModel.swift`:

```swift
import Foundation
import Synchronization
import GohCore

/// Boxes a `Mutex<Bool>` in a reference type so the cancel flag can be captured
/// by value in a @Sendable closure on the worker thread. (`Mutex`/`Atomic` are
/// `~Copyable` and cannot be captured directly into an escaping @Sendable closure.)
/// Pattern mirrors `GohMenuProgressSubscriptionCancellation`.
private final class CancellationBox: @unchecked Sendable {
    private let flag = Mutex(false)

    func cancel() { flag.withLock { $0 = true } }
    func isCancelled() -> Bool { flag.withLock { $0 } }
}

/// The verify run state for the Trust window.
nonisolated public enum TrustRunState: Sendable, Equatable {
    case idle
    case running(VerifyProgress)
    case finished(VerifyAllReport)
    case cancelled(VerifyAllReport)   // partial report
    case failed(String)               // plain-English error message
}

/// @MainActor view model for the Trust window.
///
/// Responsibilities:
/// - Loads trust overview + rows off-main on init (via the injected ProvenanceReading).
/// - Drives the background verify run (VerifyAllRunner on a dedicated OS thread).
/// - Publishes overview, rows, and runState to SwiftUI.
@MainActor
public final class TrustWindowViewModel: ObservableObject {

    @Published public private(set) var overview: GohTrustOverview = .empty
    @Published public private(set) var rows: [GohTrustEntryRow] = []
    @Published public private(set) var runState: TrustRunState = .idle

    private let reader: any ProvenanceReading
    private let provenanceStorePath: String
    private let presenter: GohTrustPresenter
    private var cancellationBox: CancellationBox?

    public init(
        reader: any ProvenanceReading,
        provenanceStorePath: String,
        presenter: GohTrustPresenter = GohTrustPresenter()
    ) {
        self.reader = reader
        self.provenanceStorePath = provenanceStorePath
        self.presenter = presenter
    }

    // MARK: - Load overview (off-main)

    /// Load the trust overview from the ledger. Call from `.task {}` on the Trust window.
    public func loadOverview() async {
        let outcome = await Task.detached(priority: .userInitiated) { [reader] in
            reader.read()
        }.value
        let (ov, rs) = presenter.present(outcome)
        overview = ov
        rows = rs
    }

    // MARK: - Verify now

    /// Start a background verify run. Disabled while already running.
    /// Dispatches the blocking re-hash on a real OS thread (NOT the cooperative pool).
    public func startVerify() {
        guard case .idle = runState else { return }
        guard !rows.isEmpty else { return }

        let box = CancellationBox()
        cancellationBox = box
        runState = .running(VerifyProgress(completed: 0, total: rows.count, currentPath: nil))

        let path = provenanceStorePath
        let now = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self, box] in
            do {
                let report = try VerifyAllRunner.verifyAll(
                    provenanceStorePath: path,
                    generatedAt: now,
                    progress: { progress in
                        Task { @MainActor [weak self] in
                            if case .running = self?.runState {
                                self?.runState = .running(progress)
                            }
                        }
                    },
                    isCancelled: { box.isCancelled() })

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if box.isCancelled() {
                        self.runState = .cancelled(report)
                    } else {
                        self.runState = .finished(report)
                    }
                    self.cancellationBox = nil
                }
            } catch let VerifyAllRunnerError.ledgerUnreadable(reason) {
                let message: String
                switch reason {
                case .io:       message = "provenance ledger unreadable"
                case .corrupt:  message = "provenance ledger corrupt"
                case .versionUnknown(let n): message = "provenance ledger version \(n) is unknown"
                }
                Task { @MainActor [weak self] in
                    self?.runState = .failed(message)
                    self?.cancellationBox = nil
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.runState = .failed("verify failed: \(error)")
                    self?.cancellationBox = nil
                }
            }
        }
    }

    /// Cancel the in-flight verify run. No-op if not running.
    public func cancelVerify() {
        cancellationBox?.cancel()
    }

    /// Reset to idle (called when the Trust window closes, if desired).
    public func reset() {
        cancellationBox?.cancel()
        cancellationBox = nil
        runState = .idle
    }
}
```

**Step 3 — Build validation**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: clean.

**Manual smoke note:** The `DispatchQueue.global().async` dispatch keeps the re-hash off the cooperative pool. The `CancellationBox` boxes a `Mutex<Bool>` (a reference type) so the cancel flag is safely captured in the @Sendable closure. Progress publishes via `Task { @MainActor in ... }` — the established MainActor-hop pattern.

**Step 4 — Commit**

```
git add Sources/GohMenuBar/TrustWindowViewModel.swift
git commit -m "feat(trust-tray): add TrustWindowViewModel (@MainActor run-state, off-thread verify)"
```

---

### Task 7 — CREATE `Sources/GohMenuBar/TrustWindowView.swift`

**Files**
- CREATE `Sources/GohMenuBar/TrustWindowView.swift`

**AC ownership:** AC2 (per-file provenance fields displayed), AC3 (Verify now / progress / cancel / OK/FAILED/MISSING summary), AC1 (at-rest "last recorded" labelling distinct from live result)

**Pre-task reads (completed in Phase 0)**
- `Sources/GohMenuBar/GohMenuView.swift` — SwiftUI component patterns; `@ObservedObject`; `Task { ... }` action pattern; `.accessibilityLabel`; `Label`/`Button`/`ScrollView`/`LazyVStack`.
- `Sources/GohCore/CLI/VerifyReportTypes.swift` — `VerifyAllReport`, `VerifyEntryResult`, `VerifyStatus` (`.ok`/`.failed`/`.missing`) for the live result summary.

**Step 1 — No unit test** (SwiftUI view). Build validation is the gate.

**Step 2 — Implementation**

CREATE `Sources/GohMenuBar/TrustWindowView.swift`:

```swift
import SwiftUI
import GohCore

/// The Trust window — per-file provenance list + background verify.
public struct TrustWindowView: View {
    @ObservedObject private var viewModel: TrustWindowViewModel

    public init(viewModel: TrustWindowViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            entryList
            Divider()
            verifySection
        }
        .frame(minWidth: 480, minHeight: 300)
        .padding(16)
        .task { await viewModel.loadOverview() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Trust")
                .font(.title2)
                .bold()
            overviewLine
        }
    }

    @ViewBuilder
    private var overviewLine: some View {
        switch viewModel.overview {
        case .empty:
            Text("No downloads recorded yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .unavailable:
            Text("Trust data unavailable")
                .font(.subheadline)
                .foregroundStyle(.orange)
        case .summary(let s):
            // AC1: explicitly labelled "last recorded" — NOT a live check
            Text("\(s.tracked) files tracked · last recorded: \(s.verified) verified · \(s.downloadOnly) download-only")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Entry list

    @ViewBuilder
    private var entryList: some View {
        if viewModel.rows.isEmpty {
            Text("No entries to display.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.rows, id: \.displayPath) { row in
                        TrustEntryRowView(row: row, liveResult: liveResult(for: row))
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    /// Look up the live verify result for a row (nil if no completed run yet).
    private func liveResult(for row: GohTrustEntryRow) -> VerifyStatus? {
        switch viewModel.runState {
        case .finished(let report), .cancelled(let report):
            return report.entries.first { $0.path == row.displayPath }?.status
        default:
            return nil
        }
    }

    // MARK: - Verify section

    @ViewBuilder
    private var verifySection: some View {
        switch viewModel.runState {
        case .idle:
            Button {
                viewModel.startVerify()
            } label: {
                Label("Verify now", systemImage: "checkmark.shield")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.rows.isEmpty || viewModel.overview == .unavailable)
            .accessibilityLabel("Start integrity verification of all recorded files")

        case .running(let progress):
            HStack(spacing: 10) {
                ProgressView(
                    value: Double(progress.completed),
                    total: Double(max(progress.total, 1)))
                    .frame(maxWidth: 200)
                Text("\(progress.completed) / \(progress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    viewModel.cancelVerify()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Cancel verify run")
            }

        case .finished(let report):
            liveResultSummary(report: report, cancelled: false)

        case .cancelled(let report):
            VStack(alignment: .leading, spacing: 4) {
                Text("Cancelled (partial result)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                liveResultSummary(report: report, cancelled: true)
            }

        case .failed(let message):
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func liveResultSummary(report: VerifyAllReport, cancelled: Bool) -> some View {
        HStack(spacing: 12) {
            Label("\(report.summary.ok) OK", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if report.summary.failed > 0 {
                Label("\(report.summary.failed) FAILED", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            if report.summary.missing > 0 {
                Label("\(report.summary.missing) MISSING", systemImage: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button {
                viewModel.startVerify()
            } label: {
                Label("Verify again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.rows.isEmpty)
            .accessibilityLabel("Run verification again")
        }
        .font(.subheadline)
    }
}

// MARK: - Per-entry row

private struct TrustEntryRowView: View {
    let row: GohTrustEntryRow
    let liveResult: VerifyStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(URL(fileURLWithPath: row.displayPath).lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                atRestStatusChip
                if let live = liveResult {
                    liveStatusChip(live)
                }
            }
            Text(row.sanitizedURL)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(row.sha256)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// At-rest status chip — labelled "last recorded" semantics (AC1).
    @ViewBuilder
    private var atRestStatusChip: some View {
        if let verifiedAt = row.verifiedAt {
            Text("verified \(verifiedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .cornerRadius(4)
                .foregroundStyle(.green)
        } else {
            Text("downloaded")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
                .foregroundStyle(.secondary)
        }
    }

    /// Live verify status chip — visually distinct from at-rest labels (AC1).
    @ViewBuilder
    private func liveStatusChip(_ status: VerifyStatus) -> some View {
        let (label, color): (String, Color) = switch status {
        case .ok:      ("OK", .green)
        case .failed:  ("FAILED", .red)
        case .missing: ("MISSING", .orange)
        }
        Text(label)
            .font(.caption2)
            .bold()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .cornerRadius(4)
            .foregroundStyle(color)
    }

    private var accessibilityDescription: String {
        let file = URL(fileURLWithPath: row.displayPath).lastPathComponent
        let status = row.verifiedAt != nil ? "verified" : "downloaded only"
        let live = liveResult.map { "live: \($0.rawValue)" } ?? ""
        return "\(file), \(status)\(live.isEmpty ? "" : ", \(live)")"
    }
}
```

**Step 3 — Build validation**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: clean.

**Manual smoke note:** The at-rest chip says "downloaded" / "verified \<date\>" — labelled by date, not "verified (last recorded)" in-chip but the header line provides the "last recorded" context. The live chip says "OK" / "FAILED" / "MISSING" in bold with distinct colors — visually distinct from at-rest labels (AC1). "Verify now" is disabled when `rows.isEmpty || overview == .unavailable`.

**Step 4 — Commit**

```
git add Sources/GohMenuBar/TrustWindowView.swift
git commit -m "feat(trust-tray): add TrustWindowView (per-file list, verify/progress/cancel, live summary)"
```

---

### Task 8 — MODIFY `Sources/GohMenuBar/GohMenuView.swift` + `GohMenuViewModel.swift`

**Files**
- MODIFY `Sources/GohMenuBar/GohMenuView.swift` — add trust summary section + "Trust…" button
- MODIFY `Sources/GohMenuBar/GohMenuViewModel.swift` — add `@Published trustOverview: GohTrustOverview` + off-main load

**AC ownership:** AC1 (glanceable at-rest summary in popover — THE BET), AC4 (read-only, no XPC call)

**Pre-task reads (completed in Phase 0)**
- `Sources/GohMenuBar/GohMenuView.swift` — full file: VStack layout, `addDownloadButton` pattern for `openWindow`, `AppKit` already imported (line 1: `import AppKit`), `@Environment(\.openWindow)` usage.
- `Sources/GohMenuBar/GohMenuViewModel.swift` — `@MainActor final class`; `@Published public private(set) var state`; `refreshClipboard()` as model for an off-main load; `makeAddDownloadViewModel` as model for a factory.

**Step 1 — No unit test** (wires existing view + model types). Build validation is the gate.

**Step 2 — Implementation (GohMenuViewModel)**

ADD to `Sources/GohMenuBar/GohMenuViewModel.swift`:

1. A new `@Published public private(set) var trustOverview: GohTrustOverview = .empty` property.
2. An injected `trustReader: (any ProvenanceReading)?` parameter in `init` (optional so existing callers don't break — default `nil`).
3. A `loadTrustOverview()` method that reads off-main and publishes.
4. Call `Task { await loadTrustOverview() }` at the end of `start()`.

Key: the `GohMenuViewModel` is `@MainActor`; the off-main read uses the same `Task.detached(priority:)` pattern as `TrustWindowViewModel.loadOverview()`.

**Exact changes to `GohMenuViewModel.swift`:**

Add after `private var clipboardURL: URL?`:
```swift
    private let trustReader: (any ProvenanceReading)?
```

Update `init(...)` to add `trustReader: (any ProvenanceReading)? = nil` parameter and assign it.

Add new published property after `@Published public private(set) var state`:
```swift
    @Published public private(set) var trustOverview: GohTrustOverview = .empty
```

Add new method:
```swift
    public func loadTrustOverview() async {
        guard let reader = trustReader else { return }
        let outcome = await Task.detached(priority: .utility) { reader.read() }.value
        trustOverview = GohTrustPresenter().present(outcome).0
    }
```

In `start()`, after the existing `stop()` + task setup, add:
```swift
        Task { await loadTrustOverview() }
```

**Step 3 — Implementation (GohMenuView)**

ADD a `trustSection` computed view to `GohMenuView`:

```swift
    @ViewBuilder
    private var trustSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.trustOverview {
            case .empty:
                Text("No downloads recorded yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unavailable:
                Text("Trust data unavailable")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .summary(let s):
                // AC1: explicitly "last recorded" — not a live check
                Text("\(s.tracked) tracked · last recorded: \(s.verified) verified · \(s.downloadOnly) download-only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "trust")
            } label: {
                Label("Trust…", systemImage: "checkmark.shield")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Open Trust window")
            .help("Open the Trust window to see provenance details and verify file integrity")
        }
    }
```

Insert `trustSection` + `Divider()` in `body` between `addDownloadButton` and the jobs `Divider()`:

```swift
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            recoveryAction
            primaryAction
            addDownloadButton
            trustSection          // <-- new
            Divider()
            jobs
            Divider()
            footer
        }
        ...
    }
```

**Step 4 — Build validation**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: clean. If `init` parameter addition breaks existing `GohMenuViewModelTests`, add `trustReader: nil` to the test initializer calls (the parameter is optional with default `nil`).

**Step 5 — Commit**

```
git add Sources/GohMenuBar/GohMenuView.swift \
        Sources/GohMenuBar/GohMenuViewModel.swift
git commit -m "feat(trust-tray): add popover trust summary section and Trust button (Approach A — THE BET)"
```

---

### Task 9 — MODIFY `Sources/goh-menu/main.swift`

**Files**
- MODIFY `Sources/goh-menu/main.swift`

**AC ownership:** AC1 (live ProvenanceReading impl), AC3 (TrustWindowViewModel wired with live reader), AC4 (read-only — no record/recordVerified calls anywhere in goh-menu trust path)

**Pre-task reads (completed in Phase 0)**
- `Sources/goh-menu/main.swift` — full file: `AddDownloadWindowRoot` + `Window(id:"add-download")` + `@StateObject` root pattern (lines 250–283); `GohMenuAppDelegate` init of `model`; `GohMenuApp.body` `Scene` composition.
- `Sources/GohCore/Provenance/ProvenanceStoreLocation.swift` — `defaultURL(create: false)` for the live path resolution.

**Step 1 — No unit test** (composition root with AppKit + disk). Build validation is the gate.

**Step 2 — Implementation**

ADD to `main.swift`:

1. **Live `ProvenanceReading` impl** (nonisolated, `@unchecked Sendable` since the path string is immutable):

```swift
/// Live implementation of ProvenanceReading — reads provenance.plist directly.
/// Unsandboxed; same access pattern as the CLI (goh which / goh verify --all).
/// Read-only: never calls record/recordVerified.
nonisolated private struct LiveProvenanceReader: ProvenanceReading, @unchecked Sendable {
    private let path: String

    init(path: String) { self.path = path }

    nonisolated func read() -> ProvenanceReadOutcome {
        ProvenanceLedgerReader.read(at: path)
    }
}
```

2. **`TrustWindowRoot`** mirroring `AddDownloadWindowRoot`:

```swift
/// Owns TrustWindowViewModel via @StateObject so it is built exactly once and its state
/// persists across scene re-evaluation.
struct TrustWindowRoot: View {
    @StateObject private var viewModel: TrustWindowViewModel

    init(makeViewModel: @autoclosure @escaping () -> TrustWindowViewModel) {
        _viewModel = StateObject(wrappedValue: makeViewModel())
    }

    var body: some View {
        TrustWindowView(viewModel: viewModel)
    }
}
```

3. **Resolve `provenancePath`** in `GohMenuAppDelegate` (or at the composition root):

The live path is `(try? ProvenanceStoreLocation.defaultURL(create: false))?.path ?? ""`. Pass this to `LiveProvenanceReader` and to `TrustWindowViewModel`. If resolution fails (no `~/Library/Application Support`), the reader returns `.absent` gracefully.

4. **Wire `trustReader` into `GohMenuViewModel`** — update the `GohMenuViewModel` init call in `GohMenuAppDelegate` to pass `trustReader: LiveProvenanceReader(path: provenancePath)`.

5. **Add `Window(id: "trust")` scene** in `GohMenuApp.body`:

```swift
Window("Trust", id: "trust") {
    TrustWindowRoot(
        makeViewModel: TrustWindowViewModel(
            reader: LiveProvenanceReader(path: provenancePath),
            provenanceStorePath: provenancePath))
}
.windowResizability(.contentSize)
.defaultPosition(.center)
```

Note: `provenancePath` must be computed once and shared (stored in a let at the call site or as a computed property on `GohMenuAppDelegate`).

**Step 3 — Build validation**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: clean.

**Manual smoke note:**
- On launch: popover shows a trust summary line (or "No downloads recorded yet" if no ledger exists).
- Opening the Trust window (clicking "Trust…"): shows the per-file list if entries exist. Empty state shows "No downloads recorded yet".
- "Verify now" is enabled only when entries are present. Clicking it starts a progress bar; cancel works.
- On completion: OK/FAILED/MISSING counts shown; at-rest chips and live chips are visually distinct.
- Closing the popover does not cancel an in-flight verify.

**Step 4 — Full regression suite**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1
```

Expected: all pre-existing 758+ tests pass + new tests from Phases 1–2. Zero regressions.

**Step 5 — Commit**

```
git add Sources/goh-menu/main.swift
git commit -m "feat(trust-tray): wire LiveProvenanceReader + TrustWindowRoot + Window(id:trust) in main.swift"
```

---

## Final health check (post-Phase 3)

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1
```

Both must exit 0. Report any failures before marking the feature branch ready for PR.

---

## Summary table

| Phase | Task | File(s) | Type | AC |
|-------|------|---------|------|----|
| P1 | T1 | `GohCore/Provenance/ProvenanceLedgerReader.swift` | CREATE | AC1,4,5 |
| P1 | T2 | `GohCore/CLI/VerifyAllRunner.swift` | CREATE | AC3,4,5 |
| P1 | T3 | `GohCore/CLI/GohVerifyAllCommand.swift` | MODIFY | AC4,5 |
| P2 | T4 | `GohMenuBar/GohTrustModels.swift` | CREATE | AC1,2,4 |
| P2 | T5 | `GohMenuBar/GohTrustPresenter.swift` | CREATE | AC1,2,5 |
| P3 | T6 | `GohMenuBar/TrustWindowViewModel.swift` | CREATE | AC1,3,5 |
| P3 | T7 | `GohMenuBar/TrustWindowView.swift` | CREATE | AC1,2,3 |
| P3 | T8 | `GohMenuBar/GohMenuView.swift` + `GohMenuViewModel.swift` | MODIFY | AC1,4 |
| P3 | T9 | `goh-menu/main.swift` | MODIFY | AC1,3,4 |
