---
date: 2026-06-05
feature: verify-json
REQUIRED_SKILL: superpowers:subagent-driven-development
Goal: Add `--json` presentation mode to `goh verify --all`, backed by a frozen `VerifyAllReport` contract, without changing any human output or exit code.
Architecture: Compute Once, Render Twice
Tech Stack: Swift 6.2/6.3 (Swift 6 language mode, nonisolated-default on GohCore), macOS 26.0+; Foundation JSONEncoder; Swift Testing; CI -warnings-as-errors on macos-26; local needs DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
---

# Implementation Plan — `goh verify --all --json`

## Acceptance criteria map

| AC | Metric | Owning task |
|----|--------|-------------|
| AC1 | Mixed-ledger JSON: `reportVersion:1`, `entries[]`, `summary` derived from fold | Task 3 |
| AC2 | `--json` exit code == human exit code for same ledger state | Task 3 |
| AC3 | Human output byte-identical; existing tests pass unmodified | Task 2 (regression gate) |
| AC4 | Error envelopes on exit-6 conditions; empty→valid empty report | Task 3 |
| AC5 | Golden fixture + encode-equals-fixture test pins schema | Task 1 (fixture) + Task 1 (test) |

## Phase structure

> 9 tasks → segmented at deployment-independence boundaries into 3 phases.
> Phase artifacts: `docs/superpowers/progress/2026-06-05-verify-json-phase{1,2,3}.md`

- **Phase 1 (Tasks 1–3):** Frozen types + golden fixture + their encode-equals test. No behavior change; compiles standalone.
- **Phase 2 (Tasks 4–5):** Refactor `GohVerifyAllCommand.run()` to compute-once-render-twice. Existing human tests are the regression gate.
- **Phase 3 (Tasks 6–9):** Parse/dispatch wiring + all integration tests + usage text.

---

## Phase 1 — Frozen types, golden fixture, schema pin

### Task 1 — Create `VerifyReportTypes.swift` (frozen contract)

**Files**
- CREATE `Sources/GohCore/CLI/VerifyReportTypes.swift`

**Pre-task reads**
- [x] `Sources/GohCore/CLI/DiagnoseTypes.swift` — struct/enum pattern to mirror
- [x] `Sources/GohCore/Model/CommandCoding.swift` — `CommandCoding.encoder` settings

**Step 1 — Failing test (Swift Testing)**

File: `Tests/GohCoreTests/VerifyReportTypesTests.swift` (CREATE)

```swift
import Foundation
import Testing
@testable import GohCore

@Suite("VerifyReportTypes")
struct VerifyReportTypesTests {

    // AC5 — raw values are the frozen --json contract; do NOT rename.
    @Test("AC5: VerifyStatus raw values are frozen")
    func verifyStatusRawValuesFrozen() {
        // If any raw value is renamed, the golden fixture + downstream scripts break.
        #expect(VerifyStatus.ok.rawValue == "ok")
        #expect(VerifyStatus.failed.rawValue == "failed")
        #expect(VerifyStatus.missing.rawValue == "missing")
    }

    // AC5 — error-envelope raw values frozen.
    @Test("AC5: VerifyErrorCode raw values are frozen")
    func verifyErrorCodeRawValuesFrozen() {
        #expect(VerifyErrorCode.ledgerUnreadable.rawValue == "ledgerUnreadable")
        #expect(VerifyErrorCode.ledgerCorrupt.rawValue == "ledgerCorrupt")
        #expect(VerifyErrorCode.ledgerVersionUnknown.rawValue == "ledgerVersionUnknown")
    }

    // AC1 — summary is derived by folding over entries (not maintained as parallel tallies).
    @Test("AC1: VerifySummary counts match per-status filter of entries")
    func summaryCounts() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_714_262_400)
        let entries: [VerifyEntryResult] = [
            VerifyEntryResult(path: "/a", url: "https://x.com/a", status: .ok,
                              expectedSha256: "sha256:aa", actualSha256: nil),
            VerifyEntryResult(path: "/b", url: "https://x.com/b", status: .failed,
                              expectedSha256: "sha256:bb", actualSha256: "sha256:cc"),
            VerifyEntryResult(path: "/c", url: "https://x.com/c", status: .missing,
                              expectedSha256: "sha256:dd", actualSha256: nil),
        ]
        let summary = VerifySummary(
            total: entries.count,
            ok: entries.filter { $0.status == .ok }.count,
            failed: entries.filter { $0.status == .failed }.count,
            missing: entries.filter { $0.status == .missing }.count)

        // Each count MUST equal its per-status filter — not just that they sum.
        #expect(summary.total == entries.count)
        #expect(summary.ok == entries.filter { $0.status == .ok }.count)
        #expect(summary.failed == entries.filter { $0.status == .failed }.count)
        #expect(summary.missing == entries.filter { $0.status == .missing }.count)
    }

    // AC5 — encode-equals golden fixture (compact, CommandCoding.encoder).
    @Test("AC5: VerifyAllReport encodes to golden fixture byte-for-byte")
    func encodeEqualsGoldenFixture() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_714_262_400)
        let report = VerifyAllReport(
            reportVersion: 1,
            generatedAt: fixedDate,
            summary: VerifySummary(total: 3, ok: 1, failed: 1, missing: 1),
            entries: [
                VerifyEntryResult(
                    path: "/private/tmp/goh-fixture/ok.bin",
                    url: "https://example.com/ok.bin",
                    status: .ok,
                    expectedSha256: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    actualSha256: nil),
                VerifyEntryResult(
                    path: "/private/tmp/goh-fixture/failed.bin",
                    url: "https://example.com/failed.bin",
                    status: .failed,
                    expectedSha256: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    actualSha256: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
                VerifyEntryResult(
                    path: "/private/tmp/goh-fixture/missing.bin",
                    url: "https://example.com/missing.bin",
                    status: .missing,
                    expectedSha256: "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                    actualSha256: nil),
            ])

        let data = try CommandCoding.encoder.encode(report)
        let actualJSON = String(decoding: data, as: UTF8.self)

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/verify-all-report-v1.json")

        try #require(
            FileManager.default.fileExists(atPath: fixtureURL.path),
            "Golden fixture missing at \(fixtureURL.path). It is a committed baseline; restore it (or, for an intentional wire change, bump reportVersion and regenerate).")

        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixtureJSON = String(decoding: fixtureData, as: UTF8.self)
        #expect(
            actualJSON == fixtureJSON,
            "VerifyAllReport --json output differs from golden fixture. If this is intentional, bump reportVersion and delete the fixture to regenerate.")
    }

    // AC5 — error envelope encodes correctly.
    @Test("AC5: VerifyErrorReport encodes reportVersion and error code")
    func errorReportEncodesCorrectly() throws {
        let r = VerifyErrorReport(reportVersion: 1, error: .ledgerCorrupt)
        let data = try CommandCoding.encoder.encode(r)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"reportVersion\":1"))
        #expect(json.contains("\"error\":\"ledgerCorrupt\""))
    }
}
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VerifyReportTypesTests 2>&1
```

Expected: compile error — `VerifyAllReport`, `VerifyStatus`, `VerifyEntryResult`, `VerifySummary`, `VerifyErrorReport`, `VerifyErrorCode` do not exist yet.

**Step 3 — Implementation**

CREATE `Sources/GohCore/CLI/VerifyReportTypes.swift`:

```swift
import Foundation

// MARK: - VerifyAllReport (frozen --json v1 contract)
//
// reportVersion bumps on ANY breaking change to this shape.
// Field names and `status` / `error` raw values are FROZEN — do NOT rename.
// The golden fixture Tests/GohCoreTests/Fixtures/verify-all-report-v1.json
// enforces this: any schema change will fail the encode-equals test.

/// Root document for `goh verify --all --json`. Frozen at reportVersion 1.
public struct VerifyAllReport: Codable, Equatable, Sendable {
    /// Always 1 for v1; bump only if a field name/type or enum raw value changes.
    public var reportVersion: Int          // = 1 — do NOT rename
    /// Injected by run(); ISO-8601 UTC on the wire via CommandCoding.encoder.
    public var generatedAt: Date           // do NOT rename
    /// Derived by folding over entries[]; never maintained as a parallel tally.
    public var summary: VerifySummary      // do NOT rename
    /// One element per provenance-ledger entry, in ledger order.
    public var entries: [VerifyEntryResult] // do NOT rename

    public init(
        reportVersion: Int = 1,
        generatedAt: Date,
        summary: VerifySummary,
        entries: [VerifyEntryResult]
    ) {
        self.reportVersion = reportVersion
        self.generatedAt = generatedAt
        self.summary = summary
        self.entries = entries
    }
}

/// Aggregate counts block. Each field is derived by folding over entries[].
public struct VerifySummary: Codable, Equatable, Sendable {
    public var total: Int    // do NOT rename
    public var ok: Int       // do NOT rename
    public var failed: Int   // do NOT rename
    public var missing: Int  // do NOT rename

    public init(total: Int, ok: Int, failed: Int, missing: Int) {
        self.total = total
        self.ok = ok
        self.failed = failed
        self.missing = missing
    }
}

/// Per-entry result in the `entries[]` array.
public struct VerifyEntryResult: Codable, Equatable, Sendable {
    /// entry.destinationPath (canonical, as stored in the ledger).
    public var path: String              // do NOT rename
    /// entry.url exactly as stored.
    public var url: String               // do NOT rename
    /// ok / failed / missing — FROZEN raw values.
    public var status: VerifyStatus      // do NOT rename
    /// entry.sha256 verbatim ("sha256:"-prefixed).
    public var expectedSha256: String    // do NOT rename
    /// Present ONLY when status == .failed. Nil is OMITTED (no key in JSON).
    public var actualSha256: String?     // do NOT rename; nil → key absent

    public init(
        path: String,
        url: String,
        status: VerifyStatus,
        expectedSha256: String,
        actualSha256: String?
    ) {
        self.path = path
        self.url = url
        self.status = status
        self.expectedSha256 = expectedSha256
        self.actualSha256 = actualSha256
    }
}

/// Per-entry verification status.
/// FROZEN raw values — do NOT rename (scripts branch on these).
public enum VerifyStatus: String, Codable, Equatable, Sendable {
    case ok       // do NOT rename
    case failed   // do NOT rename
    case missing  // do NOT rename
}

// MARK: - Error envelope

/// Emitted on stdout by `--json` when the ledger is unreadable / corrupt /
/// unknown-version. Exit code remains 6. Never mixed with plain-text output.
public struct VerifyErrorReport: Codable, Equatable, Sendable {
    public var reportVersion: Int  // = 1 — do NOT rename
    public var error: VerifyErrorCode  // do NOT rename

    public init(reportVersion: Int = 1, error: VerifyErrorCode) {
        self.reportVersion = reportVersion
        self.error = error
    }
}

/// Stable machine codes for the three ledger-level error conditions.
/// FROZEN raw values — do NOT rename.
public enum VerifyErrorCode: String, Codable, Equatable, Sendable {
    case ledgerUnreadable     // file present but cannot be read as Data — do NOT rename
    case ledgerCorrupt        // Data present but PropertyListDecoder fails — do NOT rename
    case ledgerVersionUnknown // decoded OK but version != ProvenanceRecord.currentVersion — do NOT rename
}
```

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VerifyReportTypesTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: `verifyStatusRawValuesFrozen`, `verifyErrorCodeRawValuesFrozen`, `summaryCounts`, `errorReportEncodesCorrectly` pass; `encodeEqualsGoldenFixture` fails (fixture file not yet committed). That is correct — the fixture is created in Task 2.

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/VerifyReportTypes.swift Tests/GohCoreTests/VerifyReportTypesTests.swift
git commit -m "feat(verify): add frozen VerifyAllReport / VerifyErrorReport types (reportVersion=1)"
```

---

### Task 2 — Commit golden fixture `verify-all-report-v1.json`

**Files**
- CREATE `Tests/GohCoreTests/Fixtures/verify-all-report-v1.json`

**Pre-task reads**
- [x] `Tests/GohCoreTests/Fixtures/diagnose-report-v1.json` — note it is pretty-printed; the verify fixture is NOT pretty-printed
- [x] `Sources/GohCore/Model/CommandCoding.swift` — confirms `.sortedKeys` but NOT `.prettyPrinted`; encoder escapes `/` → `\/`

**Step 1 — Failing test (already in Task 1)**

The `encodeEqualsGoldenFixture` test from Task 1 is already written. It currently fails with `"Golden fixture missing"`. This task makes it pass by committing the correct fixture.

**Step 2 — Confirm current failure**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "VerifyReportTypesTests/encodeEqualsGoldenFixture" 2>&1
```

Expected: `"Golden fixture missing at …/verify-all-report-v1.json"` (the `#require` guard fails).

**Step 3 — Create the fixture**

The fixture is a **single compact line** (no trailing newline; the test compares raw `String(decoding:as:)` from encoder output which has no trailing newline). The content below is byte-exact for `CommandCoding.encoder` (`.iso8601`, `.sortedKeys`, no pretty-print) with `Date(timeIntervalSince1970: 1_714_262_400)`, paths `/private/tmp/goh-fixture/{ok,failed,missing}.bin`, and the 64-hex-char placeholder hashes:

```
{"entries":[{"expectedSha256":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","path":"\/private\/tmp\/goh-fixture\/ok.bin","status":"ok","url":"https:\/\/example.com\/ok.bin"},{"actualSha256":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","expectedSha256":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","path":"\/private\/tmp\/goh-fixture\/failed.bin","status":"failed","url":"https:\/\/example.com\/failed.bin"},{"expectedSha256":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","path":"\/private\/tmp\/goh-fixture\/missing.bin","status":"missing","url":"https:\/\/example.com\/missing.bin"}],"generatedAt":"2024-04-28T00:00:00Z","reportVersion":1,"summary":{"failed":1,"missing":1,"ok":1,"total":3}}
```

Write this single line (no trailing newline) to `Tests/GohCoreTests/Fixtures/verify-all-report-v1.json`.

> IMPORTANT: Write the file using the exact bytes above. Do NOT add a trailing newline. The `String(decoding:as:)` round-trip from `CommandCoding.encoder.encode(_:)` produces no trailing newline; the fixture must match.

To generate programmatically (safest — avoids editor newline insertion):

```swift
// One-shot Swift snippet to write the fixture; run once, then commit.
// DEVELOPER_DIR=... swift -e '...'
import Foundation

struct VerifyAllReport: Codable {
    var reportVersion: Int = 1
    var generatedAt: Date
    var summary: VerifySummary
    var entries: [VerifyEntryResult]
}
struct VerifySummary: Codable {
    var total: Int; var ok: Int; var failed: Int; var missing: Int
}
struct VerifyEntryResult: Codable {
    var path: String; var url: String; var status: String
    var expectedSha256: String; var actualSha256: String?
}

let report = VerifyAllReport(
    generatedAt: Date(timeIntervalSince1970: 1_714_262_400),
    summary: VerifySummary(total: 3, ok: 1, failed: 1, missing: 1),
    entries: [
        VerifyEntryResult(path: "/private/tmp/goh-fixture/ok.bin",
                          url: "https://example.com/ok.bin", status: "ok",
                          expectedSha256: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        VerifyEntryResult(path: "/private/tmp/goh-fixture/failed.bin",
                          url: "https://example.com/failed.bin", status: "failed",
                          expectedSha256: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                          actualSha256: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
        VerifyEntryResult(path: "/private/tmp/goh-fixture/missing.bin",
                          url: "https://example.com/missing.bin", status: "missing",
                          expectedSha256: "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"),
    ])

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.sortedKeys]
let data = try encoder.encode(report)
let dest = URL(fileURLWithPath: "Tests/GohCoreTests/Fixtures/verify-all-report-v1.json")
try data.write(to: dest)
print("Written \(data.count) bytes")
'
```

(Run from the repo root, without `--filter` so Swift picks up the cwd properly.)

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "VerifyReportTypesTests" 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

All 5 tests in `VerifyReportTypesTests` should now pass, including `encodeEqualsGoldenFixture`.

**Step 5 — Commit**

```
git add Tests/GohCoreTests/Fixtures/verify-all-report-v1.json
git commit -m "test(verify): add golden fixture verify-all-report-v1.json (compact, CommandCoding.encoder)"
```

---

## Phase 2 — Refactor `run()` to compute-once-render-twice

### Task 3 — Refactor `GohVerifyAllCommand.run()` (compute-once-render-twice)

> **Bet check:** Deriving both renderings from one result model keeps the JSON and human verdicts + exit codes consistent at zero ongoing cost; the existing byte-exact regression tests prove the human output stayed identical after the refactor.

**Files**
- MODIFY `Sources/GohCore/CLI/GohVerifyAllCommand.swift`

**Pre-task reads**
- [x] `Sources/GohCore/CLI/GohVerifyAllCommand.swift` — the WHOLE file (lines 1–114): exact `run(provenanceStorePath:)` structure; the two catch arms (both → MISSING); exit-code precedence (`hasMissing→9`, `hasFailed→2`, else 0); exact output strings; `GohCommandLineResult` usage
- [x] `Sources/GohCore/CLI/VerifyReportTypes.swift` (just created) — all types
- [x] `Sources/GohCore/Model/CommandCoding.swift` — `CommandCoding.encoder`
- [x] `Sources/GohCore/Provenance/ProvenanceRecord.swift` — `ProvenanceEntry` fields
- [x] `Sources/GohCore/TrustCore/FileDigest.swift` — `sha256WithSize(path:)` return; `DigestError.cannotOpen`

**Step 1 — Failing tests (AC1–AC5)**

File: `Tests/GohCoreTests/GohVerifyAllCommandJSONTests.swift` (CREATE)

```swift
import Foundation
import Testing
@testable import GohCore

@Suite("GohVerifyAllCommand — --json mode")
struct GohVerifyAllCommandJSONTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-verifyall-json-\(UUID().uuidString)")
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

    // AC1 — Mixed ledger: parses, reportVersion:1, entries count, status values, summary fold.
    @Test("AC1: mixed ledger emits valid JSON with reportVersion:1 and per-status summary counts")
    func mixedLedgerJSON() throws {
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
        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: failed))
        try FileManager.default.removeItem(atPath: missing)

        let fixedDate = Date(timeIntervalSince1970: 1_714_262_400)
        let r = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: true,
            generatedAt: fixedDate)

        #expect(r.exitCode == 9)  // MISSING present — precedence 9

        // Must parse as JSON — no leading/trailing non-JSON.
        let data = Data(r.standardOutput.utf8)
        let report = try JSONDecoder().decode(VerifyAllReport.self, from: data)

        // reportVersion must be 1.
        #expect(report.reportVersion == 1)

        // Entries count matches ledger.
        #expect(report.entries.count == 3)

        // AC1 summary fold invariant: each count == per-status filter of entries[].
        #expect(report.summary.total == report.entries.count)
        #expect(report.summary.ok == report.entries.filter { $0.status == .ok }.count)
        #expect(report.summary.failed == report.entries.filter { $0.status == .failed }.count)
        #expect(report.summary.missing == report.entries.filter { $0.status == .missing }.count)

        // Entry statuses are correct.
        let statuses = Dictionary(uniqueKeysWithValues:
            report.entries.map { ($0.path, $0.status) })
        #expect(statuses[URL(fileURLWithPath: ok).standardizedFileURL.path] == .ok)
        #expect(statuses[URL(fileURLWithPath: failed).standardizedFileURL.path] == .failed)
        #expect(statuses[URL(fileURLWithPath: missing).standardizedFileURL.path] == .missing)

        // Failed entry has actualSha256; missing and ok entries do not.
        let failedEntry = try #require(report.entries.first { $0.status == .failed })
        #expect(failedEntry.actualSha256 != nil)
        let okEntry = try #require(report.entries.first { $0.status == .ok })
        #expect(okEntry.actualSha256 == nil)
        let missingEntry = try #require(report.entries.first { $0.status == .missing })
        #expect(missingEntry.actualSha256 == nil)
    }

    // AC2 — --json exit code == human exit code for every ledger state.
    @Test("AC2: --json exit code equals human exit code (all-ok, failed-only, missing-present)")
    func jsonExitCodeEqualsHuman() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // All-OK
        let okPath = dir.appendingPathComponent("allok.bin").path
        let (storeOK, _) = try storeWithEntries(in: dir, entries: [(okPath, Data("data".utf8))])
        let humanOK = GohVerifyAllCommand.run(provenanceStorePath: storeOK.path)
        let jsonOK = GohVerifyAllCommand.run(provenanceStorePath: storeOK.path, json: true)
        #expect(humanOK.exitCode == jsonOK.exitCode)
        #expect(humanOK.exitCode == 0)

        // Failed-only (mismatch, no missing)
        let dir2 = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir2) }
        let failPath = dir2.appendingPathComponent("fail.bin").path
        let (storeF, _) = try storeWithEntries(in: dir2, entries: [(failPath, Data("orig".utf8))])
        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: failPath))
        let humanF = GohVerifyAllCommand.run(provenanceStorePath: storeF.path)
        let jsonF = GohVerifyAllCommand.run(provenanceStorePath: storeF.path, json: true)
        #expect(humanF.exitCode == jsonF.exitCode)
        #expect(humanF.exitCode == 2)

        // Missing present (exit 9)
        let dir3 = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir3) }
        let missingPath = dir3.appendingPathComponent("miss.bin").path
        let (storeM, _) = try storeWithEntries(in: dir3, entries: [(missingPath, Data("x".utf8))])
        try FileManager.default.removeItem(atPath: missingPath)
        let humanM = GohVerifyAllCommand.run(provenanceStorePath: storeM.path)
        let jsonM = GohVerifyAllCommand.run(provenanceStorePath: storeM.path, json: true)
        #expect(humanM.exitCode == jsonM.exitCode)
        #expect(humanM.exitCode == 9)
    }

    // AC3 — M3 regression gate: human output is byte-identical for mixed ledger.
    // This NEW test asserts the FULL joined output string (not .contains())
    // to catch line-order or separator regressions after the refactor.
    @Test("AC3: human output is byte-identical after compute-once-render-twice refactor")
    func humanOutputByteIdentical() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ok = dir.appendingPathComponent("ok.bin").path
        let failed = dir.appendingPathComponent("failed.bin").path
        let missing = dir.appendingPathComponent("missing.bin").path

        let (storeURL, sha256s) = try storeWithEntries(in: dir, entries: [
            (ok, Data("unchanged".utf8)),
            (failed, Data("original".utf8)),
            (missing, Data("willbedeleted".utf8)),
        ])
        // sha256s[0] = ok hash, sha256s[1] = original hash, sha256s[2] = missing hash

        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: failed))
        try FileManager.default.removeItem(atPath: missing)

        let (mutatedHash, _) = try FileDigest.sha256WithSize(path: failed)

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path)

        // Canonicalized paths (as stored by storeWithEntries)
        let okCanon = URL(fileURLWithPath: ok).standardizedFileURL.path
        let failedCanon = URL(fileURLWithPath: failed).standardizedFileURL.path
        let missingCanon = URL(fileURLWithPath: missing).standardizedFileURL.path

        // Pre-refactor exact strings (per-line \n, lines.joined() no separator):
        let expectedOutput = [
            "OK \(okCanon)\n",
            "FAILED \(failedCanon) expected \(sha256s[1]) actual \(mutatedHash)\n",
            "MISSING \(missingCanon) (expected \(sha256s[2]))\n",
        ].joined()

        // Assert FULL joined string — not .contains() — to catch line-order/separator regressions.
        #expect(r.standardOutput == expectedOutput)
        #expect(r.exitCode == 9)
    }

    // AC4 — Empty ledger → valid empty report, exit 0.
    @Test("AC4: absent ledger with --json emits valid empty report, exit 0")
    func absentLedgerJSON() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let r = GohVerifyAllCommand.run(
            provenanceStorePath: dir.appendingPathComponent("absent.plist").path,
            json: true)

        #expect(r.exitCode == 0)
        let data = Data(r.standardOutput.utf8)
        let report = try JSONDecoder().decode(VerifyAllReport.self, from: data)
        #expect(report.reportVersion == 1)
        #expect(report.entries.isEmpty)
        #expect(report.summary.total == 0)
        #expect(report.summary.ok == 0)
        #expect(report.summary.failed == 0)
        #expect(report.summary.missing == 0)
    }

    // AC4 — Unreadable ledger → error envelope, exit 6.
    @Test("AC4: unreadable ledger with --json emits error envelope {reportVersion:1, error:\"ledgerUnreadable\"}, exit 6")
    func unreadableLedgerEnvelope() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        // Create a file but make it unreadable.
        try Data("dummy".utf8).write(to: storeURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: storeURL.path)
        defer { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: storeURL.path) }

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path, json: true)
        #expect(r.exitCode == 6)

        let data = Data(r.standardOutput.utf8)
        let envelope = try JSONDecoder().decode(VerifyErrorReport.self, from: data)
        #expect(envelope.reportVersion == 1)
        #expect(envelope.error == .ledgerUnreadable)
    }

    // AC4 — Corrupt ledger → error envelope, exit 6.
    @Test("AC4: corrupt ledger with --json emits error envelope {error:\"ledgerCorrupt\"}, exit 6")
    func corruptLedgerEnvelope() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        try Data("not a plist at all".utf8).write(to: storeURL)

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path, json: true)
        #expect(r.exitCode == 6)

        let data = Data(r.standardOutput.utf8)
        let envelope = try JSONDecoder().decode(VerifyErrorReport.self, from: data)
        #expect(envelope.reportVersion == 1)
        #expect(envelope.error == .ledgerCorrupt)
    }

    // AC4 — Unknown-version ledger → error envelope, exit 6.
    @Test("AC4: unknown-version ledger with --json emits error envelope {error:\"ledgerVersionUnknown\"}, exit 6")
    func unknownVersionEnvelope() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        // Build a valid-format plist with a future version number.
        let record = ProvenanceRecord(version: 9999, entries: [])
        let data = try PropertyListEncoder().encode(record)
        try data.write(to: storeURL)

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path, json: true)
        #expect(r.exitCode == 6)

        let jsonData = Data(r.standardOutput.utf8)
        let envelope = try JSONDecoder().decode(VerifyErrorReport.self, from: jsonData)
        #expect(envelope.reportVersion == 1)
        #expect(envelope.error == .ledgerVersionUnknown)
    }

    // AC4 — Empty store record (entries: []) → valid empty report, exit 0.
    @Test("AC4: empty store (entries:[]) with --json emits valid empty report, exit 0")
    func emptyStoreJSON() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        let emptyRecord = ProvenanceRecord(version: ProvenanceRecord.currentVersion, entries: [])
        let data = try PropertyListEncoder().encode(emptyRecord)
        try data.write(to: storeURL)

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path, json: true)
        #expect(r.exitCode == 0)
        let jsonData = Data(r.standardOutput.utf8)
        let report = try JSONDecoder().decode(VerifyAllReport.self, from: jsonData)
        #expect(report.entries.isEmpty)
        #expect(report.summary.total == 0)
    }
}
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllCommandJSONTests 2>&1
```

Expected: compile errors — `GohVerifyAllCommand.run` has no `json:` or `generatedAt:` parameters yet.

**Step 3 — Implementation**

REPLACE the entire content of `Sources/GohCore/CLI/GohVerifyAllCommand.swift`:

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
    /// - Parameters:
    ///   - provenanceStorePath: Absolute path to `provenance.plist`.
    ///     Resolved by the caller from `ProvenanceStoreLocation.defaultURL(create: false)`.
    ///   - json: When `true`, render output as JSON (`VerifyAllReport` or `VerifyErrorReport`).
    ///     Defaults to `false` so existing callers and tests compile unchanged.
    ///   - generatedAt: The timestamp to embed in the JSON `generatedAt` field.
    ///     Defaults to `Date()` (current time) in production; inject a fixed instant in tests
    ///     and for the golden-fixture encode-equals test. Ignored when `json` is false.
    public static func run(
        provenanceStorePath: String,
        json: Bool = false,
        generatedAt: Date = Date()
    ) -> GohCommandLineResult {
        let storeURL = URL(fileURLWithPath: provenanceStorePath)

        // ── Step 1: Read the ledger (read-only; never creates a sidecar or resets) ──
        guard FileManager.default.fileExists(atPath: provenanceStorePath) else {
            if json {
                return jsonResult(
                    exitCode: 0,
                    report: emptyReport(generatedAt: generatedAt))
            }
            return GohCommandLineResult(
                exitCode: 0,
                standardOutput: "0 recorded entries\n")
        }

        guard let data = try? Data(contentsOf: storeURL) else {
            if json {
                return jsonErrorResult(.ledgerUnreadable)
            }
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "provenance ledger unreadable\n")
        }

        let record: ProvenanceRecord
        do {
            record = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
        } catch {
            // CLI does NOT copy-to-sidecar or reset — the daemon owns recovery.
            if json {
                return jsonErrorResult(.ledgerCorrupt)
            }
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "provenance ledger corrupt\n")
        }

        guard record.version == ProvenanceRecord.currentVersion else {
            if json {
                return jsonErrorResult(.ledgerVersionUnknown)
            }
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "provenance ledger version \(record.version) is unknown\n")
        }

        // A4 — corruption boundary is "decodable + version-matched". A plist that decodes
        // cleanly with version == currentVersion is treated as VALID even if individual
        // entries are semantically odd (e.g. a malformed sha256 string or a nonsense path).
        // Such entries enter the re-hash loop below and report FAILED/MISSING — NOT exit 6.
        // Exit 6 is reserved for an unreadable/undecodable/unknown-version file.

        // ── Step 2: Empty store ────────────────────────────────────────────────
        if record.entries.isEmpty {
            if json {
                return jsonResult(
                    exitCode: 0,
                    report: emptyReport(generatedAt: generatedAt))
            }
            return GohCommandLineResult(
                exitCode: 0,
                standardOutput: "0 recorded entries\n")
        }

        // ── Step 3: Re-hash each entry — compute ONCE into [VerifyEntryResult] ─
        //
        // Bet: deriving both renderings from one result model keeps the JSON and
        // human verdicts + exit codes consistent at zero ongoing cost; the existing
        // byte-exact regression tests prove the human output stayed identical after
        // the refactor.
        var entries: [VerifyEntryResult] = []
        var lines: [String] = []
        var hasMissing = false
        var hasFailed = false

        for entry in record.entries {
            let hash: String
            do {
                (hash, _) = try FileDigest.sha256WithSize(path: entry.destinationPath)
            } catch FileDigest.DigestError.cannotOpen {
                entries.append(VerifyEntryResult(
                    path: entry.destinationPath,
                    url: entry.url,
                    status: .missing,
                    expectedSha256: entry.sha256,
                    actualSha256: nil))
                lines.append("MISSING \(entry.destinationPath) (expected \(entry.sha256))\n")
                hasMissing = true
                continue
            } catch {
                entries.append(VerifyEntryResult(
                    path: entry.destinationPath,
                    url: entry.url,
                    status: .missing,
                    expectedSha256: entry.sha256,
                    actualSha256: nil))
                lines.append("MISSING \(entry.destinationPath) (expected \(entry.sha256))\n")
                hasMissing = true
                continue
            }

            if hash == entry.sha256 {
                entries.append(VerifyEntryResult(
                    path: entry.destinationPath,
                    url: entry.url,
                    status: .ok,
                    expectedSha256: entry.sha256,
                    actualSha256: nil))
                lines.append("OK \(entry.destinationPath)\n")
            } else {
                entries.append(VerifyEntryResult(
                    path: entry.destinationPath,
                    url: entry.url,
                    status: .failed,
                    expectedSha256: entry.sha256,
                    actualSha256: hash))
                lines.append(
                    "FAILED \(entry.destinationPath) expected \(entry.sha256) actual \(hash)\n")
                hasFailed = true
            }
        }

        // ── Step 4: Derive exit code from the SAME entries[] array ────────────
        // (hasMissing/hasFailed booleans mirror entries[] — they are in sync by construction.)
        let exitCode: Int32
        if hasMissing {
            exitCode = 9
        } else if hasFailed {
            exitCode = 2
        } else {
            exitCode = 0
        }

        // ── Step 5: Render — JSON or human ────────────────────────────────────
        if json {
            // Summary is DERIVED by folding over the final entries[] array.
            // This is the single source of truth — no parallel tally that could drift.
            let summary = VerifySummary(
                total: entries.count,
                ok: entries.filter { $0.status == .ok }.count,
                failed: entries.filter { $0.status == .failed }.count,
                missing: entries.filter { $0.status == .missing }.count)
            let report = VerifyAllReport(
                reportVersion: 1,
                generatedAt: generatedAt,
                summary: summary,
                entries: entries)
            return jsonResult(exitCode: exitCode, report: report)
        }

        return GohCommandLineResult(exitCode: exitCode, standardOutput: lines.joined())
    }

    // MARK: - Private helpers

    private static func emptyReport(generatedAt: Date) -> VerifyAllReport {
        VerifyAllReport(
            reportVersion: 1,
            generatedAt: generatedAt,
            summary: VerifySummary(total: 0, ok: 0, failed: 0, missing: 0),
            entries: [])
    }

    private static func jsonResult(exitCode: Int32, report: VerifyAllReport) -> GohCommandLineResult {
        guard let data = try? CommandCoding.encoder.encode(report) else {
            // Defensive: encoding a value type should never fail.
            return GohCommandLineResult(exitCode: exitCode, standardOutput: "")
        }
        return GohCommandLineResult(
            exitCode: exitCode,
            standardOutput: String(decoding: data, as: UTF8.self) + "\n")
    }

    private static func jsonErrorResult(_ code: VerifyErrorCode) -> GohCommandLineResult {
        let envelope = VerifyErrorReport(reportVersion: 1, error: code)
        guard let data = try? CommandCoding.encoder.encode(envelope) else {
            return GohCommandLineResult(exitCode: 6, standardOutput: "")
        }
        return GohCommandLineResult(
            exitCode: 6,
            standardOutput: String(decoding: data, as: UTF8.self) + "\n")
    }
}
```

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllCommandJSONTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllCommandTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected:
- `GohVerifyAllCommandJSONTests`: all new tests pass
- `GohVerifyAllCommandTests`: all existing tests pass UNMODIFIED (M3 regression gate)

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/GohVerifyAllCommand.swift Tests/GohCoreTests/GohVerifyAllCommandJSONTests.swift
git commit -m "feat(verify): refactor run() to compute-once-render-twice; add --json param and JSON render path"
```

---

## Phase 3 — Parse/dispatch wiring, parse tests, usage text

### Task 4 — Update `ParsedCommand.verifyAll` associated value + parse branch

**Files**
- MODIFY `Sources/GohCore/CLI/GohCommandLine.swift`

**Pre-task reads**
- [x] `Sources/GohCore/CLI/GohCommandLine.swift` — `ParsedCommand.verifyAll` case (line 228); the `verify --all` parse branch (lines 289–301, exact `after` check logic); the frozen `verify` arm (lines 303–322, untouched); the dispatch site (lines 126–129); the `provenanceStorePathResolver` seam (lines 40–52); `json<Payload:Encodable>(_:)` helper (lines 536–545); the usage text (lines 548–574)
- [x] `Sources/GohCore/CLI/GohVerifyAllCommand.swift` — new `run(provenanceStorePath:json:generatedAt:)` signature

**Step 1 — Failing tests**

File: `Tests/GohCoreTests/GohVerifyAllParseJSONTests.swift` (CREATE)

```swift
import Foundation
import Testing
import XPC
@testable import GohCore

@Suite("GohCommandLine — verify --all --json parse boundary")
struct GohVerifyAllParseJSONTests {

    private struct TestTransportError: Error {}

    private func emptyTempStorePath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-verifyall-parsejson-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("provenance.plist").path
    }

    // AC5 (parse boundary) — `verify --all --json` sets json=true.
    @Test("AC5/parse: 'verify --all --json' routes to verifyAll with json=true")
    func verifyAllJsonParsesAndDispatches() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all", "--json"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        // With an empty store, --json emits a valid empty report, exit 0.
        #expect(r.exitCode == 0)
        // Output must parse as JSON with an empty entries array.
        let data = Data(r.standardOutput.utf8)
        let report = try JSONDecoder().decode(VerifyAllReport.self, from: data)
        #expect(report.entries.isEmpty)
    }

    // AC5 (parse boundary) — `verify --all` (no --json) still works as before.
    @Test("AC5/parse: 'verify --all' (no --json) still routes to verifyAll with json=false")
    func verifyAllNoJsonStillWorks() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("0 recorded"))
    }

    // AC5 (parse boundary) — `verify --json --all` (wrong order) → exit 64.
    @Test("AC5/parse: 'verify --json --all' is a parse error (exit 64)")
    func verifyJsonBeforeAllIsError() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--json", "--all"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        // Falls through to frozen verify arm → unknown option --json → exit 64.
        #expect(r.exitCode == 64)
    }

    // AC5 (parse boundary) — `verify --json` (no --all) → exit 64.
    @Test("AC5/parse: 'verify --json' is a parse error (exit 64)")
    func verifyJsonAloneIsError() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--json"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
    }

    // AC5 (parse boundary) — `verify --all --json --json` (duplicate) → exit 64.
    @Test("AC5/parse: 'verify --all --json --json' (duplicate flag) is a parse error (exit 64)")
    func verifyAllJsonDuplicateIsError() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all", "--json", "--json"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
    }

    // AC5 (parse boundary) — `verify --all --strict-untracked` → exit 64 (unchanged).
    @Test("AC5/parse: 'verify --all --strict-untracked' is still a parse error (exit 64)")
    func verifyAllStrictUntrackedStillError() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all", "--strict-untracked"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
    }

    // AC5 (parse boundary) — `verify --all <path>` → exit 64 (unchanged).
    @Test("AC5/parse: 'verify --all <path>' is still a parse error (exit 64)")
    func verifyAllWithPositionalStillError() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all", "/some/path"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
    }

    // Usage text includes --json in the verify --all line.
    @Test("usage text includes 'verify --all [--json]'")
    func usageTextIncludesJsonFlag() {
        let r = GohCommandLine(
            arguments: ["--help"],
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.standardOutput.contains("--json"))
        #expect(r.standardOutput.contains("--all"))
    }
}
```

**Step 2 — Confirm FAIL**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllParseJSONTests 2>&1
```

Expected: compile errors — `ParsedCommand.verifyAll` takes no associated value yet; the `--json` remainder check does not exist.

**Step 3 — Implementation**

Four targeted changes to `Sources/GohCore/CLI/GohCommandLine.swift`:

**Change A** — `ParsedCommand.verifyAll` → `verifyAll(json: Bool)`

Replace (line 228):
```swift
    case verifyAll
```
With:
```swift
    case verifyAll(json: Bool)
```

**Change B** — `verify --all` parse branch (lines 289–301)

Replace the block:
```swift
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
```
With:
```swift
            if rest.first == "--all" {
                // Accepted grammar: `verify --all` or `verify --all --json` only.
                // Any other remainder (--strict-untracked, a positional, --json twice,
                // or an unknown flag) is rejected → exit 64.
                let after = Array(rest.dropFirst())
                let jsonFlag: Bool
                if after.isEmpty {
                    jsonFlag = false
                } else if after == ["--json"] {
                    jsonFlag = true
                } else {
                    throw ParseError(
                        message: "--all is incompatible with \(after.joined(separator: " "))")
                }
                // BLOCK-1: do NOT resolve the store path here. `parse()` is static and the
                // resolver is not in scope; resolving the real default at parse time would make
                // every parse test read the user's real provenance ledger. The path is resolved
                // at DISPATCH (run()) via the injected `provenanceStorePathResolver`.
                return .verifyAll(json: jsonFlag)
            }
```

**Change C** — dispatch site (line 126–129)

Replace:
```swift
            case .verifyAll:
                // BLOCK-1: resolve at dispatch via the injected resolver (create:false in production).
                return GohVerifyAllCommand.run(
                    provenanceStorePath: provenanceStorePathResolver() ?? "")
```
With:
```swift
            case .verifyAll(let json):
                // BLOCK-1: resolve at dispatch via the injected resolver (create:false in production).
                return GohVerifyAllCommand.run(
                    provenanceStorePath: provenanceStorePathResolver() ?? "",
                    json: json)
```

**Change D** — usage text (line 567)

Replace:
```swift
          goh verify --all
```
With:
```swift
          goh verify --all [--json]
```

(The usage method is `private static func usage(error:)` at line ~549. Find the `goh verify --all` line and append ` [--json]`.)

**Step 4 — Confirm PASS + build**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllParseJSONTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllParseTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllCommandTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllCommandJSONTests 2>&1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

All four suites must pass. The `-warnings-as-errors` build must be clean.

**Step 5 — Commit**

```
git add Sources/GohCore/CLI/GohCommandLine.swift Tests/GohCoreTests/GohVerifyAllParseJSONTests.swift
git commit -m "feat(verify): wire verify --all --json parse, dispatch, and usage text"
```

---

### Task 5 — Full test run + final health check

**Files**
- No new source changes. This task runs the full suite and confirms no regressions.

**Pre-task reads** — none required (no edits)

**Step 1 — Run full test suite**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1
```

Expected: all tests pass (existing + new). Zero failures.

**Step 2 — Build with warnings-as-errors**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1
```

Expected: zero warnings, zero errors.

**Step 3 — Spot-check JSON output manually**

```
# From repo root (requires a local provenance ledger at the default path):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run goh verify --all --json 2>&1 | python3 -m json.tool
```

If no local ledger exists the output should be `{"entries":[],"generatedAt":"…","reportVersion":1,"summary":{"failed":0,"missing":0,"ok":0,"total":0}}`.

**Step 4 — Commit (if any fixups were needed)**

If Task 4 needed a fixup: `git add -p` the affected file and commit with `fix(verify): <description>`.

---

## File map summary

| Action | Path |
|--------|------|
| CREATE | `Sources/GohCore/CLI/VerifyReportTypes.swift` |
| CREATE | `Tests/GohCoreTests/Fixtures/verify-all-report-v1.json` |
| CREATE | `Tests/GohCoreTests/VerifyReportTypesTests.swift` |
| MODIFY | `Sources/GohCore/CLI/GohVerifyAllCommand.swift` |
| CREATE | `Tests/GohCoreTests/GohVerifyAllCommandJSONTests.swift` |
| MODIFY | `Sources/GohCore/CLI/GohCommandLine.swift` |
| CREATE | `Tests/GohCoreTests/GohVerifyAllParseJSONTests.swift` |

## Dependency order

```
Task 1 (types) → Task 2 (fixture) → Task 3 (refactor run()) → Task 4 (parse/dispatch)
                                    └─ Task 5 (full health check, no edits)
```

Tasks 1 → 2 are strictly ordered (fixture test exists after Task 1; fixture file committed in Task 2).
Tasks 3 and 4 depend on Task 2 (types must exist).
Task 5 depends on Task 4.

## Spec-vs-code discrepancies found during pre-write reads

1. **`GohDiagnoseCommand.jsonString` uses bare `JSONEncoder()`** — the spec notes this as a pre-existing inconsistency and documents the deliberate choice of `CommandCoding.encoder` for the verify output. No action needed; carry the note into DESIGN.md as part of this PR (not a plan blocker).

2. **`ParsedCommand.verifyAll` has no associated value** (currently `case verifyAll` at line 228). The plan adds `case verifyAll(json: Bool)`. The only consumer is the single dispatch site at lines 126–129 — one targeted change. The three existing `GohVerifyAllParseTests` tests use `GohCommandLine.run()` end-to-end and do not switch on `ParsedCommand` directly, so they require no modification.

3. **`GohVerifyAllCommandTests` line 61** calls `GohVerifyAllCommand.run(provenanceStorePath:)` (1-arg). The plan's new signature adds `json: Bool = false, generatedAt: Date = Date()` — Swift default arguments preserve the 1-arg call site. All five existing tests in that file compile unchanged. Same for `GohVerifyAllParseTests`.

4. **Human output paths (`ok`, `failed`, `missing`)** in `GohVerifyAllCommandTests` use `.contains()` checks (not full-string equality). The new M3 regression test in `GohVerifyAllCommandJSONTests` closes this gap by asserting the exact joined output string for a mixed ledger. The existing `.contains()` tests are NOT modified (per AC3).
