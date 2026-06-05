# Implementation Plan — provenance-sync-skip-fold

**REQUIRED SUB-SKILL:** superpowers:subagent-driven-development

**Goal:** Record provenance for `goh sync` files that are already present on disk (skipped
downloads). `goh which` and `goh verify --all` are currently blind to half a synced manifest
because those files never enter `provenance.plist`. This plan adds an additive `verifiedAt` field
to `ProvenanceEntry`, a new `Command.recordVerifiedProvenance` batch XPC verb (bumping
`protocolVersion` 3 → 4), best-effort batch recording in `GohSyncCommand.run`, and a
ledger-first ordering in `goh which` with a three-way date rendering.

**Architecture — "The Courier" approach:** The CLI collects verified-skip entries in memory and
sends one `recordVerifiedProvenance` batch command to the daemon after the per-entry loop. The
daemon is the sole writer; the in-memory `Mutex<Inner>` cache stays coherent. One batch = one
read-modify-write inside `Mutex.withLock` + one atomic plist rewrite (O(n) total, not O(n²)). The
CLI sends best-effort: any failure prints a warning and never changes the sync exit code.

**Tech Stack:** Swift 6.2/6.3 (Swift 6 language mode; nonisolated-default on `GohCore`/`gohd`),
macOS 26.0+, XPC via modern low-level API, binary plist persistence, Swift Testing (NOT XCTest),
CI `-warnings-as-errors` on `macos-26` runner.

---

## Phase 1 — Value/format layer

**Deployment boundary:** pure value-type + store changes; no wire, no daemon wiring. All Phase 1
work compiles and tests in isolation. Phases 2–3 depend on it.

**Phase artifact:** `docs/superpowers/progress/2026-06-05-provenance-sync-skip-fold-phase1.md`

---

### Task 1 — Add `verifiedAt: Date?` to `ProvenanceEntry` (AC5/M4)

**AC ownership:** AC5 (format unchanged; nil → omitted; golden round-trip stays green)

**Files:**
- Modify: `Sources/GohCore/Provenance/ProvenanceRecord.swift`
- Test: `Tests/GohCoreTests/ProvenanceRecordTests.swift` (extend existing golden test)

**Pre-task reads:** `ProvenanceRecord.swift` (read above — confirmed), `ProvenanceRecordTests.swift`
(read above — confirmed), `Tests/GohCoreTests/Fixtures/provenance-v1.plist` (binary, assumed
present — confirmed by fixture list).

#### Step 1 — Write the failing test

Add to `ProvenanceRecordTests.swift` inside the existing `@Suite`:

```swift
// AC5: verifiedAt is additive-optional — nil encodes identically to no key;
// re-decoded verifiedAt is nil; existing golden fixture bytes decode unchanged.
@Test("AC5: verifiedAt nil round-trips stably; existing entries decode with verifiedAt==nil")
func verifiedAtNilRoundTrip() throws {
    // AC5: ProvenanceRecord.currentVersion stays 1.
    #expect(ProvenanceRecord.currentVersion == 1)

    // An entry with verifiedAt nil encodes and decodes with verifiedAt == nil.
    let entry = ProvenanceEntry(
        url: "https://example.com/f.bin",
        sha256: "sha256:" + String(repeating: "a", count: 64),
        size: 512,
        downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
        destinationPath: "/tmp/f.bin",
        verifiedAt: nil)
    let record = ProvenanceRecord(version: 1, entries: [entry])
    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
    let data = try encoder.encode(record)
    let decoded = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
    #expect(decoded.entries[0].verifiedAt == nil)

    // An entry with verifiedAt set round-trips the date.
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let entryWithDate = ProvenanceEntry(
        url: "https://example.com/f.bin",
        sha256: "sha256:" + String(repeating: "a", count: 64),
        size: 512,
        downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
        destinationPath: "/tmp/f.bin",
        verifiedAt: now)
    let record2 = ProvenanceRecord(version: 1, entries: [entryWithDate])
    let data2 = try encoder.encode(record2)
    let decoded2 = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data2)
    #expect(decoded2.entries[0].verifiedAt == now)
}
```

Also verify that the existing `goldenFixtureRoundTrip` test still compiles (it does not set
`verifiedAt`; the new field has a default of `nil` so the round-trip is unaffected).

#### Step 2 — Confirm FAIL

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ProvenanceRecordTests/verifiedAtNilRoundTrip
```

Expected: compile error (`ProvenanceEntry.init` does not yet have `verifiedAt` parameter).

#### Step 3 — Implement

In `Sources/GohCore/Provenance/ProvenanceRecord.swift`:

**Add field to `ProvenanceEntry`** (after `destinationPath`):

```swift
/// When `goh sync` confirmed these exact bytes present WITHOUT downloading them.
/// `nil` for entries recorded by the download engine (download-only entries).
/// When non-nil and `downloadedAt == verifiedAt`, goh never downloaded these bytes —
/// `downloadedAt` is the best "first observed" time.
/// Additive-optional: absent from old records (decodes to nil); nil entries
/// serialize without this key (synthesized Codable omits nil optionals in binary plist).
/// `ProvenanceRecord.currentVersion` stays 1 — no format bump.
public var verifiedAt: Date?
```

**Update `ProvenanceEntry.init`** (add `verifiedAt: Date? = nil` parameter, assign `self.verifiedAt = verifiedAt`):

```swift
public init(
    url: String,
    sha256: String,
    size: Int,
    downloadedAt: Date,
    destinationPath: String,
    verifiedAt: Date? = nil
) {
    self.url = url
    self.sha256 = sha256
    self.size = size
    self.downloadedAt = downloadedAt
    self.destinationPath = destinationPath
    self.verifiedAt = verifiedAt
}
```

No other changes needed. Synthesized `Codable` handles `Date?` correctly (omits `nil` key in
binary plist). `ProvenanceRecord.currentVersion` stays `1`. The golden fixture contains no
`verifiedAt` key; decoding it gives `nil` — the round-trip test asserts `redecoded == decoded`
(value equality, not byte identity), which remains correct.

#### Step 4 — Confirm PASS

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ProvenanceRecordTests
```

All `ProvenanceRecordTests` must pass including the new `verifiedAtNilRoundTrip` and the
existing `goldenFixtureRoundTrip`.

Also confirm `ProvenanceStoreTests` still pass (they construct `ProvenanceEntry` with the
positional init; the `verifiedAt: Date? = nil` default keeps them valid):

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ProvenanceStoreTests
```

#### Step 5 — Commit

```
feat(provenance): add additive-optional verifiedAt field to ProvenanceEntry (currentVersion stays 1)
```

---

### Task 2 — Add `ProvenanceStore.recordVerified(entries:)` (AC2/AC3/M2)

**AC ownership:** AC2 (verified entries appear in provenance), AC3 (canonical-path dedup, no
double-entry), M2 (same-path twice → one entry)

**BET CHECK:** "Keeping the daemon the sole writer is worth a protocolVersion bump; best-effort
skip recording is acceptable because the download path already treats provenance as never-fatal."
The merge rule below executes entirely inside one `Mutex.withLock` + one atomic write — the O(n)
single-rewrite bet holds at personal scale (thousands of entries). Do not break the batch into
per-entry writes here; that is the O(n²) path explicitly avoided.

**Files:**
- Modify: `Sources/GohCore/Provenance/ProvenanceStore.swift`
- Test: `Tests/GohCoreTests/ProvenanceStoreTests.swift` (add merge tests)

**Pre-task reads:** `ProvenanceStore.swift` (read above — confirmed: `Mutex<Inner>`,
`writeAtomically`, `record(entry:)` pattern), `ProvenanceStoreTests.swift` (read above).

#### Step 1 — Write failing tests

Add to `ProvenanceStoreTests.swift`:

```swift
// AC3/M2: same sha256 + same path → preserve downloadedAt, set verifiedAt, refresh url/size.
@Test("AC3/M2: recordVerified with same sha256 preserves downloadedAt and sets verifiedAt")
func recordVerifiedSameHashPreservesDownloadedAt() throws {
    // AC2: verified entries appear in provenance.
    // AC3: canonical path dedup; same-hash → preserve downloadedAt.
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
    _ = store.load()

    let originalDate = Date(timeIntervalSince1970: 1_740_000_000)
    let path = "/Users/u/Downloads/match.bin"
    let sha = "sha256:" + String(repeating: "a", count: 64)
    // First: record a downloaded entry.
    try store.record(entry: ProvenanceEntry(
        url: "https://old.example.com/match.bin",
        sha256: sha, size: 100,
        downloadedAt: originalDate,
        destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path))

    // Then: recordVerified for the same path + same sha (the skip path).
    let verifyTime = Date(timeIntervalSince1970: 1_750_000_000)
    let veEntries = [VerifiedProvenanceEntry(
        url: "https://new.example.com/match.bin",
        sha256: sha, size: 100,
        destinationPath: path,
        verifiedAt: verifyTime)]
    try store.recordVerified(entries: veEntries)

    let all = store.allEntries()
    // AC3: still exactly one entry (no double-entry).
    #expect(all.count == 1)
    // downloadedAt is preserved (it was a real download).
    #expect(all[0].downloadedAt == originalDate)
    // verifiedAt is set to the verify time.
    #expect(all[0].verifiedAt == verifyTime)
    // url/size are refreshed to the new values from the batch.
    #expect(all[0].url == "https://new.example.com/match.bin")
}

// AC2/M2: different sha256 → new entry with downloadedAt = verifiedAt.
@Test("AC2/M2: recordVerified with different sha256 creates entry with downloadedAt=verifiedAt")
func recordVerifiedDifferentHashCreatesNewEntry() throws {
    // AC2: verified entries appear in provenance.
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
    _ = store.load()

    let path = "/Users/u/Downloads/changed.bin"
    let oldSha = "sha256:" + String(repeating: "1", count: 64)
    let newSha = "sha256:" + String(repeating: "2", count: 64)

    // First: record a downloaded entry with oldSha.
    try store.record(entry: ProvenanceEntry(
        url: "https://example.com/changed.bin",
        sha256: oldSha, size: 100,
        downloadedAt: Date(timeIntervalSince1970: 1_740_000_000),
        destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path))

    // recordVerified: same path, different sha (accepted tofu-change).
    let verifyTime = Date(timeIntervalSince1970: 1_750_000_000)
    let veEntries = [VerifiedProvenanceEntry(
        url: "https://example.com/changed.bin",
        sha256: newSha, size: 200,
        destinationPath: path,
        verifiedAt: verifyTime)]
    try store.recordVerified(entries: veEntries)

    let all = store.allEntries()
    #expect(all.count == 1)
    // New sha.
    #expect(all[0].sha256 == newSha)
    // downloadedAt == verifiedAt (goh never downloaded the new bytes).
    #expect(all[0].downloadedAt == verifyTime)
    #expect(all[0].verifiedAt == verifyTime)
}

// AC2: completely new path (firstUse / no prior entry) → new entry with downloadedAt=verifiedAt.
@Test("AC2: recordVerified for a brand-new path creates entry with downloadedAt=verifiedAt")
func recordVerifiedNewPathCreatesEntry() throws {
    // AC2: verified entries appear in provenance (firstUse path).
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
    _ = store.load()

    let verifyTime = Date(timeIntervalSince1970: 1_750_000_000)
    let sha = "sha256:" + String(repeating: "f", count: 64)
    let veEntries = [VerifiedProvenanceEntry(
        url: "https://example.com/new.bin",
        sha256: sha, size: 512,
        destinationPath: "/Users/u/Downloads/new.bin",
        verifiedAt: verifyTime)]
    try store.recordVerified(entries: veEntries)

    let all = store.allEntries()
    #expect(all.count == 1)
    #expect(all[0].sha256 == sha)
    #expect(all[0].downloadedAt == verifyTime)
    #expect(all[0].verifiedAt == verifyTime)
    // Path was canonicalized.
    #expect(all[0].destinationPath ==
        URL(fileURLWithPath: "/Users/u/Downloads/new.bin").standardizedFileURL.path)
}

// AC3: batch with two entries → both present; count == 2 (no duplicate paths in this batch).
@Test("AC3: recordVerified batch with distinct paths writes both entries")
func recordVerifiedBatchDistinctPaths() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
    _ = store.load()

    let t = Date(timeIntervalSince1970: 1_750_000_000)
    let batch = [
        VerifiedProvenanceEntry(
            url: "https://a.example.com/a.bin",
            sha256: "sha256:" + String(repeating: "a", count: 64),
            size: 1, destinationPath: "/tmp/a.bin", verifiedAt: t),
        VerifiedProvenanceEntry(
            url: "https://b.example.com/b.bin",
            sha256: "sha256:" + String(repeating: "b", count: 64),
            size: 2, destinationPath: "/tmp/b.bin", verifiedAt: t),
    ]
    try store.recordVerified(entries: batch)
    #expect(store.allEntries().count == 2)
}
```

#### Step 2 — Confirm FAIL

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ProvenanceStoreTests/recordVerified
```

Expected: compile error — `VerifiedProvenanceEntry` and `ProvenanceStore.recordVerified` do not
exist yet.

#### Step 3 — Implement

`VerifiedProvenanceEntry` will live in `Sources/GohCore/Model/Command.swift` (Task 3). For Task 2
to compile stand-alone without Task 3, declare `VerifiedProvenanceEntry` in `ProvenanceStore.swift`
or a shared file. **Decision: add it to `Command.swift` in Task 3 and do Task 2 after Task 3.**

Alternatively (to preserve phase ordering) — Task 2 is authored and committed AFTER Task 3
completes Phase 2. Adjust: move Task 2's tests to run after Task 3's `VerifiedProvenanceEntry`
is present.

**Revised sequencing within Phase 1:** Task 1 only. Task 2 runs after Task 3 (Phase 2, first
task) because `VerifiedProvenanceEntry` is defined in `Command.swift`. The plan marks Task 2 as
"Phase 1, but depends on Task 3's type definitions." In practice: execute Task 1, then Task 3
(type definitions), then Task 2 (store method), then Task 4 (protocol/fixtures), then Task 5
(dispatcher/wiring), then Tasks 6–7 (CLI). Dependency order below is authoritative.

**`ProvenanceStore.recordVerified(entries:)` implementation** (add after `record(entry:)` in
`ProvenanceStore.swift`):

```swift
/// Merges a batch of sync-verified entries into the ledger in a single
/// `Mutex.withLock` + one atomic write (O(n) total — not O(n²) per-entry).
///
/// Merge rule per entry (§3.2):
///   - If an existing entry exists for the canonical path AND existing.sha256 == entry.sha256:
///     preserve `downloadedAt`, set `verifiedAt`, refresh `url` and `size`.
///   - Otherwise (new path OR sha256 changed): new entry with `downloadedAt = entry.verifiedAt`
///     AND `verifiedAt = entry.verifiedAt` (goh never downloaded these bytes, or the bytes
///     changed — in both cases the stored `downloadedAt` would be fabricated as a transfer
///     that did not happen).
///
/// An empty `entries` array is a no-op (no plist rewrite).
public func recordVerified(entries: [VerifiedProvenanceEntry]) throws {
    guard !entries.isEmpty else { return }

    var snapshot: ProvenanceRecord = inner.withLock { inner in
        for entry in entries {
            let canonical = URL(fileURLWithPath: entry.destinationPath)
                .standardizedFileURL.path
            if let idx = inner.record.entries.firstIndex(where: {
                $0.destinationPath == canonical
            }) {
                let existing = inner.record.entries[idx]
                if existing.sha256 == entry.sha256 {
                    // Same hash: preserve downloadedAt (it was a real download);
                    // set verifiedAt; refresh url and size.
                    inner.record.entries[idx].verifiedAt = entry.verifiedAt
                    inner.record.entries[idx].url = entry.url
                    inner.record.entries[idx].size = entry.size
                } else {
                    // Different hash: bytes changed; new entry with downloadedAt = verifiedAt.
                    inner.record.entries[idx] = ProvenanceEntry(
                        url: entry.url,
                        sha256: entry.sha256,
                        size: entry.size,
                        downloadedAt: entry.verifiedAt,
                        destinationPath: canonical,
                        verifiedAt: entry.verifiedAt)
                }
            } else {
                // New path: first observation; downloadedAt = verifiedAt.
                inner.record.entries.append(ProvenanceEntry(
                    url: entry.url,
                    sha256: entry.sha256,
                    size: entry.size,
                    downloadedAt: entry.verifiedAt,
                    destinationPath: canonical,
                    verifiedAt: entry.verifiedAt))
            }
        }
        return inner.record
    }
    try writeAtomically(&snapshot)
}
```

#### Step 4 — Confirm PASS

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ProvenanceStoreTests
```

All provenance store tests pass.

#### Step 5 — Commit

```
feat(provenance): add ProvenanceStore.recordVerified(entries:) batch merge
```

---

## Phase 2 — Daemon XPC surface

**Deployment boundary:** new Command case + protocolVersion bump + dispatcher injection + gohd
wiring. Depends on Phase 1 (verifiedAt field, recordVerified). Tests compile and pass at the end
of this phase without Phase 3 CLI changes.

**Phase artifact:** `docs/superpowers/progress/2026-06-05-provenance-sync-skip-fold-phase2.md`

---

### Task 3 — New wire types: `VerifiedProvenanceEntry`, `RecordVerifiedProvenanceRequest`, `AckReply`, `CommandOutcome.ack`, `Command.recordVerifiedProvenance`

**AC ownership:** plumbing for AC1/AC2/AC3

**Files:**
- Modify: `Sources/GohCore/Model/Command.swift`
- Modify: `Sources/GohCore/Model/CommandReply.swift`
- Modify: `Sources/GohCore/Model/CommandOutcome.swift`
- Test: `Tests/GohCoreTests/CommandTests.swift` (update `commandRoundTrip` literal)

**Pre-task reads:** `Command.swift` (read above — confirmed current cases), `CommandReply.swift`
(read above — `LsReply`, `RmReply`), `CommandOutcome.swift` (read above — current cases),
`CommandTests.swift` (read above — `commandRoundTrip` literal list at line 97–108).

**Hash-form invariant (CRITICAL — no double-prefix):** `VerifiedProvenanceEntry.sha256` carries
the value EXACTLY as `FileDigest.sha256WithSize` returns it — already `"sha256:"`-prefixed.
The CLI forwards it verbatim. The daemon stores/compares it verbatim. Do NOT add `"sha256:"` again
in the daemon. (The download completion handler at `gohd/main.swift:175` prepends because the
*engine* returns raw hex — sync's path uses `FileDigest.sha256WithSize`, which already returns the
prefixed form. Confirmed by reading `FileDigest.swift`.)

#### Step 1 — Write failing tests

Add to `CommandTests.swift`, inside `@Suite("Command schema wire forms")`:

```swift
// commandRoundTrip now includes recordVerifiedProvenance.
// NOTE: also add the new case to the existing commandRoundTrip literal (Step 3).

@Test("RecordVerifiedProvenanceRequest and VerifiedProvenanceEntry round-trip")
func recordVerifiedProvenancePayloadRoundTrip() throws {
    let entry = VerifiedProvenanceEntry(
        url: "https://example.com/f.bin",
        sha256: "sha256:" + String(repeating: "a", count: 64),
        size: 1024,
        destinationPath: "/Users/u/Downloads/f.bin",
        verifiedAt: Date(timeIntervalSince1970: 1_750_000_000))
    let request = RecordVerifiedProvenanceRequest(entries: [entry])
    #expect(try roundTrip(request) == request)

    let reply = AckReply()
    #expect(try roundTrip(reply) == reply)
}
```

Also ADD to the `commandRoundTrip` test's `commands` array (modify the existing test body — this
is the literal list at line 97–108 of `CommandTests.swift`):

```swift
.recordVerifiedProvenance(request: RecordVerifiedProvenanceRequest(entries: [
    VerifiedProvenanceEntry(
        url: "https://example.com/f.bin",
        sha256: "sha256:" + String(repeating: "c", count: 64),
        size: 512,
        destinationPath: "/tmp/f.bin",
        verifiedAt: Date(timeIntervalSince1970: 1_750_000_000))
])),
```

#### Step 2 — Confirm FAIL

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter CommandTests
```

Expected: compile errors — types and case do not exist yet.

#### Step 3 — Implement

**`Sources/GohCore/Model/Command.swift`** — add new case and payload types:

```swift
// Add to the Command enum (after .subscribe):
case recordVerifiedProvenance(request: RecordVerifiedProvenanceRequest)

// Add new structs (after AuthImportSafariReply):

/// The `recordVerifiedProvenance` command's request payload.
/// Carries all sync-verified-skip entries for one `goh sync` run as a single batch.
/// `sha256` values carry the ALREADY-"sha256:"-prefixed form from `FileDigest.sha256WithSize`.
/// The daemon stores them verbatim — it must NOT add the "sha256:" prefix again.
public struct RecordVerifiedProvenanceRequest: Codable, Sendable, Equatable {
    public var entries: [VerifiedProvenanceEntry]

    public init(entries: [VerifiedProvenanceEntry]) {
        self.entries = entries
    }
}

/// One entry in a `recordVerifiedProvenance` batch.
public struct VerifiedProvenanceEntry: Codable, Sendable, Equatable {
    /// Source URL from the manifest asset.
    public var url: String
    /// ALREADY "sha256:"-prefixed — exactly as `FileDigest.sha256WithSize` returns it.
    /// The daemon stores this verbatim. Never re-prefix.
    public var sha256: String
    /// File size in bytes.
    public var size: Int
    /// Raw destination path (CLI-resolved); the daemon canonicalizes via
    /// `URL(fileURLWithPath:).standardizedFileURL.path`.
    public var destinationPath: String
    /// When `goh sync` confirmed these exact bytes present.
    public var verifiedAt: Date

    public init(
        url: String,
        sha256: String,
        size: Int,
        destinationPath: String,
        verifiedAt: Date
    ) {
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.destinationPath = destinationPath
        self.verifiedAt = verifiedAt
    }
}
```

**`Sources/GohCore/Model/CommandReply.swift`** — add `AckReply`:

```swift
/// The `recordVerifiedProvenance` command's success reply — zero-payload acknowledgement.
public struct AckReply: Codable, Sendable, Equatable {
    public init() {}
}
```

**`Sources/GohCore/Model/CommandOutcome.swift`** — add `.ack` case:

```swift
/// `recordVerifiedProvenance` — zero-payload acknowledgement.
case ack
```

**`Tests/GohCoreTests/CommandTests.swift`** — modify `commandRoundTrip` to add the new case
(edit the `let commands: [Command] = [...]` literal to include the `.recordVerifiedProvenance`
entry shown in Step 1).

#### Step 4 — Confirm PASS

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter CommandTests
```

#### Step 5 — Commit

```
feat(ipc): add Command.recordVerifiedProvenance, VerifiedProvenanceEntry, AckReply, CommandOutcome.ack
```

---

### Task 4 — Bump `protocolVersion` 3 → 4; `encodeReply` `.ack` arm; envelope-v4 fixtures; EnvelopeCodecTests

**AC ownership:** wire-format correctness; version-mismatch tests auto-follow the constant

**Files:**
- Modify: `Sources/GohCore/Model/CommandService.swift`
- Create: `Tests/GohCoreTests/Fixtures/envelope-v4-record-verified-provenance-request.json`
- Create: `Tests/GohCoreTests/Fixtures/envelope-v4-record-verified-provenance-reply.json`
- Modify: `Tests/GohCoreTests/EnvelopeCodecTests.swift`

**Pre-task reads:** `CommandService.swift` (read above — confirmed: `protocolVersion: UInt32 = 3`,
`encodeReply` exhaustive switch at lines 208–221), `EnvelopeCodecTests.swift` (read above —
pattern for v3 fixtures), existing fixture files (confirmed naming pattern).

**RETAIN envelope-v3-* fixtures unchanged.** Do not modify or delete any `envelope-v3-*` files.

**Version-mismatch tests auto-follow:** `CommandServiceTests` references
`CommandService.protocolVersion` symbolically (`protocolVersion: CommandService.protocolVersion + 1`
etc.) — they stay valid after the bump with no changes needed.

#### Step 1 — Write failing tests

Add to `EnvelopeCodecTests.swift`:

```swift
@Test("decodes the protocolVersion=4 recordVerifiedProvenance request fixture")
func decodesV4RecordVerifiedProvenanceRequestFixture() throws {
    let envelope = try CommandCoding.decoder.decode(
        GohEnvelope<Command>.self,
        from: fixtureData("envelope-v4-record-verified-provenance-request"))

    #expect(envelope.protocolVersion == 4)
    #expect(envelope.requestID == UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
    #expect(envelope.messageType == .request)
    if case .recordVerifiedProvenance(let req) = envelope.payload {
        #expect(req.entries.count == 1)
        #expect(req.entries[0].url == "https://example.com/f.bin")
        #expect(req.entries[0].sha256 == "sha256:" + String(repeating: "a", count: 64))
        #expect(req.entries[0].size == 1024)
        #expect(req.entries[0].destinationPath == "/Users/testuser/Downloads/f.bin")
        #expect(req.entries[0].verifiedAt == Date(timeIntervalSince1970: 1_714_262_400))
    } else {
        Issue.record("expected .recordVerifiedProvenance payload")
    }
}

@Test("decodes the protocolVersion=4 recordVerifiedProvenance reply fixture")
func decodesV4RecordVerifiedProvenanceReplyFixture() throws {
    let envelope = try CommandCoding.decoder.decode(
        GohEnvelope<AckReply>.self,
        from: fixtureData("envelope-v4-record-verified-provenance-reply"))

    #expect(envelope.protocolVersion == 4)
    #expect(envelope.messageType == .reply)
    #expect(envelope.payload == AckReply())
}
```

#### Step 2 — Confirm FAIL

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter EnvelopeCodecTests/decodesV4
```

Expected: missing fixture files → `#require` fails (fixtureData throws).

Also build to confirm `encodeReply` exhaustiveness fails without the `.ack` arm:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -Xswiftc -warnings-as-errors 2>&1 | grep -i "switch\|ack\|exhaustive"
```

Expected: compile error on the `encodeReply` switch (incomplete switch for `.ack`).

#### Step 3 — Implement

**Bump protocolVersion in `CommandService.swift`** (line 15):

```swift
public static let protocolVersion: UInt32 = 4
```

**Add `.ack` arm to `encodeReply` in `CommandService.swift`** (after the `.authImported` arm,
before the `.failure` arm):

```swift
case .ack:
    return try replyEnvelope(requestID: requestID, payload: AckReply())
```

**Create fixture** `Tests/GohCoreTests/Fixtures/envelope-v4-record-verified-provenance-request.json`:

```json
{
  "protocolVersion": 4,
  "requestID": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
  "messageType": "request",
  "payload": {
    "recordVerifiedProvenance": {
      "request": {
        "entries": [
          {
            "url": "https://example.com/f.bin",
            "sha256": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "size": 1024,
            "destinationPath": "/Users/testuser/Downloads/f.bin",
            "verifiedAt": "2024-04-28T00:00:00Z"
          }
        ]
      }
    }
  }
}
```

The `verifiedAt` field is an ISO-8601 string, matching the `CommandCoding.encoder` date strategy
(`.iso8601`). `"2024-04-28T00:00:00Z"` corresponds to Unix timestamp `1_714_262_400`, which is
the value the test asserts via `Date(timeIntervalSince1970: 1_714_262_400)`. The fixture must be
generated (or written) using `CommandCoding.encoder` so the golden bytes are the real wire bytes —
do NOT produce this file with a plain `JSONEncoder()`, which uses a different date encoding.

**Create fixture** `Tests/GohCoreTests/Fixtures/envelope-v4-record-verified-provenance-reply.json`:

```json
{
  "protocolVersion": 4,
  "requestID": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
  "messageType": "reply",
  "payload": {}
}
```

`AckReply` has no fields; it encodes as `{}`.

#### Step 4 — Confirm PASS

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter EnvelopeCodecTests
```

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -Xswiftc -warnings-as-errors
```

Both v3 and v4 fixture tests must pass. `envelope-v3-*` tests must still pass (untouched fixtures).

#### Step 5 — Commit

```
feat(ipc): bump protocolVersion to 4; add encodeReply .ack arm; add envelope-v4 fixtures
```

---

### Task 5 — `CommandDispatcher` `provenanceStore` injection + dispatch arm; `gohd/main.swift` wiring

**AC ownership:** AC1, AC2, AC3 (daemon records the batch)

**BET CHECK:** "Keeping the daemon the sole writer is worth a protocolVersion bump." This task
is the load-bearing wiring that enforces single-writer. The `provenanceStore: ProvenanceStore?`
injection pattern mirrors how `checkpointStore` is injected — optional so tests that don't need
it pass `nil` and the dispatch arm is safe. The do/catch+warn pattern mirrors the download
completion handler, so recording failure is never fatal.

**Files:**
- Modify: `Sources/GohCore/Model/CommandDispatcher.swift`
- Modify: `Sources/gohd/main.swift`
- Test: `Tests/GohCoreTests/CommandServiceTests.swift` (add roundtrip test for recordVerifiedProvenance over real XPC)

**Pre-task reads:** `CommandDispatcher.swift` (read above — confirmed: `init` params, exhaustive
`reply(to:)` switch), `gohd/main.swift` (read above — confirmed: `provenanceStore` constructed at
line 102–108; `CommandDispatcher` constructed at lines 196–202 without `provenanceStore`).

#### Step 1 — Write failing test

Add to `CommandServiceTests.swift`:

```swift
@Test("recordVerifiedProvenance returns AckReply over real XPC")
func recordVerifiedProvenanceReturnsAck() throws {
    // The dispatcher needs a ProvenanceStore to handle the command.
    // Use a temp-dir store so the test is self-contained.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("goh-dispatcher-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let pStore = ProvenanceStore(
        fileURL: dir.appendingPathComponent("provenance.plist"))
    _ = pStore.load()

    let service = CommandService(
        dispatcher: CommandDispatcher(store: JobStore(), provenanceStore: pStore))
    let listener = GohXPCListener(anonymousHandler: { service.handle($0) })
    let client = try GohXPCClient(endpoint: listener.endpoint)
    defer { listener.cancel(); client.cancel() }

    let t = Date(timeIntervalSince1970: 1_750_000_000)
    let entry = VerifiedProvenanceEntry(
        url: "https://example.com/f.bin",
        sha256: "sha256:" + String(repeating: "d", count: 64),
        size: 256,
        destinationPath: "/tmp/test-dispatcher-f.bin",
        verifiedAt: t)
    let command = Command.recordVerifiedProvenance(
        request: RecordVerifiedProvenanceRequest(entries: [entry]))

    let reply = try send(command, expecting: AckReply.self, over: client)
    #expect(reply.messageType == .reply)
    #expect(reply.payload == AckReply())

    // Verify the entry was actually written to the store.
    let canonical = URL(fileURLWithPath: "/tmp/test-dispatcher-f.bin")
        .standardizedFileURL.path
    let found = pStore.lookup(destinationPath: canonical)
    #expect(found != nil)
    #expect(found?.verifiedAt == t)
}
```

#### Step 2 — Confirm FAIL

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter CommandServiceTests/recordVerifiedProvenanceReturnsAck
```

Expected: compile error — `CommandDispatcher.init` does not yet accept `provenanceStore:`.

#### Step 3 — Implement

**`Sources/GohCore/Model/CommandDispatcher.swift`:**

Add stored property (after `private let importedCookies`):

```swift
private let provenanceStore: ProvenanceStore?
```

Add parameter to `init` (after `importedCookies:` and before `explicitConnectionCounts:`):

```swift
provenanceStore: ProvenanceStore? = nil,
```

Add assignment in `init` body:

```swift
self.provenanceStore = provenanceStore
```

Add arm to the `reply(to:)` switch (after the `.subscribe` arm, before the closing `}`):

```swift
case .recordVerifiedProvenance(let request):
    do {
        try provenanceStore?.recordVerified(entries: request.entries)
    } catch {
        // Best-effort: a store write failure is non-fatal for the daemon.
        // The caller (CLI best-effort path) already handles the error reply.
    }
    return .ack
```

**`Sources/gohd/main.swift`:**

Update the `CommandDispatcher` construction (lines 196–202) to pass `provenanceStore`:

```swift
let dispatcher = CommandDispatcher(
    store: store, control: downloadControl,
    checkpointStore: checkpointStore,
    hostProfileStore: hostProfileStore,
    importedCookies: importedCookies,
    provenanceStore: provenanceStore,
    explicitConnectionCounts: explicitConnectionCounts,
    queuedJobAdmission: { networkCoordinator.jobBecameQueued($0) })
```

#### Step 4 — Confirm PASS

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter CommandServiceTests
```

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -Xswiftc -warnings-as-errors
```

#### Step 5 — Commit

```
feat(daemon): inject ProvenanceStore into CommandDispatcher; wire recordVerifiedProvenance dispatch
```

---

## Phase 3 — CLI emit + reader

**Deployment boundary:** GohSyncCommand batch-send + integration tests; GohWhichCommand
ledger-first + renderer rewrite. Depends on Phase 2 (AckReply, Command.recordVerifiedProvenance,
protocolVersion=4 all exist and daemon dispatches).

**Phase artifact:** `docs/superpowers/progress/2026-06-05-provenance-sync-skip-fold-phase3.md`

---

### Task 6 — `GohSyncCommand` `verifiedEntry` carrier + batch-send + integration tests (AC1/AC2/AC4)

**AC ownership:** AC1, AC2 (verified entries appear in provenance), AC4 (daemon-down exits 0,
recording never changes exit)

**BET CHECK:** "Best-effort skip recording (daemon may be down) is acceptable because the download
path already treats provenance as never-fatal." This is enforced by the `do/catch` in `run()`.
The CLI must use `GohCommandClient.send(_:expecting:)` (which `throws`), wrapped in a do/catch
that prints a non-fatal warning. Empty collection → no send at all (guard on count).

**Files:**
- Modify: `Sources/GohCore/CLI/GohSyncCommand.swift`
- Modify: `Tests/GohCoreTests/GohSyncCommandTests.swift`

**Pre-task reads:** `GohSyncCommand.swift` (read above — confirmed: `EntryOutcome` private struct
lines 151–155, `process()` static method, skip-return sites at lines 187/205/295/297/303/308,
`run()` loop lines 117–130, `sendAdd` helper, `GohCommandLine.Sender` type), `GohSyncCommandTests.swift`
(read above — `FakeSyncDaemon` at line 21; handles `.add` and `.ls`, throws `FakeError.badCommand`
for others — must extend to handle `.recordVerifiedProvenance`).

**Important:** `process()` is `static`; `dest` and `onDisk` are local to `process()`. The skip
helpers (`upToDate`, `firstUse`, `tofuChange`) do NOT receive `dest`. Therefore `verifiedEntry`
must be populated directly inside `process()` at each skip-return site, not inside the helpers.
The helpers' signatures are unchanged.

**Which skip paths contribute:**
- `upToDate` returns — `dest`, `onDisk.0` (prefixed sha256), `onDisk.1` (size) are in scope.
- `firstUse` returns — `dest`, `onDisk.0`, `onDisk.1` are in scope.
- `tofuChange` **accepted** branch (returns an entry with `exitContribution: 0`) — `dest`,
  `onDisk.0`, `onDisk.1` are in scope at the `tofuChange(...)` call site.

**Which do NOT contribute:**
- Confinement failures (early return before `dest` has final value, though dest is computed —
  but these set `entry: nil`, so excluding them from verifiedEntry is correct by logic).
- The actual download path — already recorded by the engine.
- `tofuChange` REJECTED (without `--accept-changed`, the drift is rejected: `exitContribution: 3`,
  entry keeps OLD hash — no `verifiedEntry` emitted for the new bytes).
- `tofuChange` with `verify == false` — this silently accepts as "up to date" with the NEW
  bytes. The spec says the accepted-tofuChange path contributes. `verify == false` returns an
  accepted result so it DOES contribute a verifiedEntry.

**FakeSyncDaemon extension for integration tests:** The tests must extend `FakeSyncDaemon.handle`
(or override via a subclass/wrapper) to handle `.recordVerifiedProvenance` by writing to a real
`ProvenanceStore`. Since `FakeSyncDaemon` is a non-final class in the test file, the cleanest
approach for integration tests is a wrapper closure that intercepts the XPC dictionary before
routing to the fake. Alternative: add a `onRecordVerified` callback property to `FakeSyncDaemon`
(like `onAdd`) so it returns `AckReply` and calls back.

**Revised `FakeSyncDaemon` extension strategy:** Add `var onRecordVerified:
(RecordVerifiedProvenanceRequest) throws -> Void` optional callback; in `handle`, route
`.recordVerifiedProvenance` to it (returning an `AckReply` envelope), else throw
`FakeError.badCommand`. This keeps the daemon-down test simple: use a sender that always throws
(simulating daemon unreachable) after any `.add`/`.ls` needed.

#### Step 1 — Write failing tests

Extend `FakeSyncDaemon` (add to the `handle` switch and add the callback property — edit
`GohSyncCommandTests.swift`):

In `FakeSyncDaemon`:
```swift
var onRecordVerified: ((RecordVerifiedProvenanceRequest) throws -> Void)?
```

In `FakeSyncDaemon.handle`, in the `switch envelope.payload` block (add after `.ls`):
```swift
case .recordVerifiedProvenance(let request):
    try onRecordVerified?(request)
    return try reply(requestID: requestID, payload: AckReply())
```

Then add the integration test suite to `GohSyncCommandTests.swift`:

```swift
@Suite("GohSyncCommand — provenance batch-send (AC1/AC2/AC4)")
struct GohSyncProvenanceBatchTests {

    // AC1/AC2: After sync of all-present manifest, all skipped entries are in provenance.
    @Test("AC1/AC2: all-present manifest sends all verified entries to provenance store")
    func allPresentSendsVerifiedEntries() throws {
        // AC1: upToDate entries appear in provenance.
        // AC2: firstUse entries appear in provenance.
        let dir = try SyncTestSupport.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let body1 = Data("file one".utf8)
        let body2 = Data("file two".utf8)
        let sha1 = try SyncTestSupport.digest(body1)
        let sha2 = try SyncTestSupport.digest(body2)

        // Stage both files on disk.
        try SyncTestSupport.stage(body1, at: dir + "/a.bin")
        try SyncTestSupport.stage(body2, at: dir + "/b.bin")

        let manifest = """
        version = 1

        [[asset]]
        url = "https://example.com/a.bin"
        path = "a.bin"
        sha256 = "\(sha1)"

        [[asset]]
        url = "https://example.com/b.bin"
        path = "b.bin"
        sha256 = "\(sha2)"
        """
        let manifestPath = dir + "/gohfile.toml"
        try manifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        // Wire a real ProvenanceStore so we can assert entries afterward.
        let storeURL = URL(fileURLWithPath: dir + "/provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()

        var capturedRequest: RecordVerifiedProvenanceRequest?
        let daemon = FakeSyncDaemon { _, _ in
            // Should never be called — no downloads needed.
            throw FakeSyncDaemon.FakeError.badCommand
        }
        daemon.onRecordVerified = { req in
            capturedRequest = req
            try store.recordVerified(entries: req.entries)
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: dir, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 1)

        // AC4: exits 0 (no download failures, no daemon errors).
        #expect(result.exitCode == 0)
        // Zero downloads — all were already present.
        #expect(daemon.addCount == 0)
        // AC1/AC2: batch was sent with exactly 2 entries.
        let req = try #require(capturedRequest)
        #expect(req.entries.count == 2)
        // AC1/AC2: both entries are now in the provenance store.
        #expect(store.allEntries().count == 2)
        // Verify sha values are the prefixed form (no double-prefix).
        for entry in store.allEntries() {
            #expect(entry.sha256.hasPrefix("sha256:"))
            #expect(!entry.sha256.hasPrefix("sha256:sha256:"))
        }
    }

    // AC4: daemon-down all-present sync still exits 0.
    @Test("AC4: sync exits 0 when daemon is unreachable for provenance recording")
    func daemonDownExits0() throws {
        // AC4: recording failure never changes sync exit code.
        let dir = try SyncTestSupport.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let body = Data("present".utf8)
        let sha = try SyncTestSupport.digest(body)
        try SyncTestSupport.stage(body, at: dir + "/p.bin")

        let manifest = """
        version = 1

        [[asset]]
        url = "https://example.com/p.bin"
        path = "p.bin"
        sha256 = "\(sha)"
        """
        let manifestPath = dir + "/gohfile.toml"
        try manifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        // A sender that always throws — simulates daemon unreachable.
        let daemonDownSender: GohCommandLine.Sender = { _ in
            throw NSError(domain: "goh.test", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "daemon not running"])
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: dir, acceptChanged: false,
            send: daemonDownSender, watchdogSeconds: 1)

        // AC4: must exit 0 — the file was present and matching; provenance record failure
        // is a non-fatal warning, not a sync error.
        #expect(result.exitCode == 0)
    }

    // Rejected tofuChange contributes no verifiedEntry.
    @Test("tofuChange rejected (no --accept-changed) contributes no verifiedEntry to batch")
    func rejectedTofuChangeNoVerifiedEntry() throws {
        let dir = try SyncTestSupport.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldBody = Data("old".utf8)
        let newBody = Data("new bytes changed".utf8)
        let oldSha = try SyncTestSupport.digest(oldBody)
        let newSha = try SyncTestSupport.digest(newBody)

        // Write the FIRST lock so sync sees a prior entry with oldSha.
        let lockEntry = """
        lockfileVersion = 1
        manifestHash = "sha256:\(String(repeating: "0", count: 64))"

        [[entry]]
        url = "https://example.com/drift.bin"
        path = "drift.bin"
        sha256 = "\(oldSha)"
        size = \(oldBody.count)
        downloadedAt = "2026-01-01T00:00:00Z"
        """
        try lockEntry.write(toFile: dir + "/gohfile.lock", atomically: true, encoding: .utf8)

        // Stage the NEW bytes on disk.
        try SyncTestSupport.stage(newBody, at: dir + "/drift.bin")

        // Manifest still pins the OLD hash → tofuChange detected.
        // Use an unpinned manifest entry so tofuChange triggers:
        let manifest = """
        version = 1

        [[asset]]
        url = "https://example.com/drift.bin"
        path = "drift.bin"
        """
        // Override the manifest hash so the prior lock is authoritative.
        // Actually: with no sha256 pin, the tofuChange path is triggered because
        // prior lock exists with oldSha and on-disk is newSha.
        let manifestPath = dir + "/gohfile.toml"
        try manifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        // Re-write the lock with the correct manifest hash.
        let manifestHash = try ManifestCodec.parse(manifest).manifestHash
        let lockWithHash = """
        lockfileVersion = 1
        manifestHash = "\(manifestHash)"

        [[entry]]
        url = "https://example.com/drift.bin"
        path = "drift.bin"
        sha256 = "\(oldSha)"
        size = \(oldBody.count)
        downloadedAt = "2026-01-01T00:00:00Z"
        """
        try lockWithHash.write(toFile: dir + "/gohfile.lock", atomically: true, encoding: .utf8)

        var batchSent = false
        let daemon = FakeSyncDaemon { _, _ in
            throw FakeSyncDaemon.FakeError.badCommand  // no downloads expected here
        }
        daemon.onRecordVerified = { _ in
            batchSent = true
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: dir, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 1)

        // exit 3: tofuChange rejected.
        #expect(result.exitCode == 3)
        // No batch sent — rejected tofuChange contributes no verifiedEntry.
        #expect(batchSent == false)
    }
}
```

#### Step 2 — Confirm FAIL

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohSyncProvenanceBatchTests
```

Expected: compile errors — `FakeSyncDaemon.onRecordVerified` property and the
`EntryOutcome.verifiedEntry` field do not exist yet; `GohSyncCommand.run` does not send
`recordVerifiedProvenance`.

#### Step 3 — Implement

**`Tests/GohCoreTests/GohSyncCommandTests.swift`** — extend `FakeSyncDaemon`:

Add property (after `private var jobs: [JobSummary] = []`):

```swift
var onRecordVerified: ((RecordVerifiedProvenanceRequest) throws -> Void)?
```

Extend the `handle` switch (add after the `.ls` case):

```swift
case .recordVerifiedProvenance(let request):
    try onRecordVerified?(request)
    return try reply(requestID: requestID, payload: AckReply())
```

**`Sources/GohCore/CLI/GohSyncCommand.swift`** — four changes:

**1. Add `verifiedEntry` field to `EntryOutcome`** (after `entry: LockfileCodec.LockEntry?`):

```swift
/// Verified-skip entry to record in provenance, or nil for download paths
/// and rejected tofuChange. Populated at the skip-return sites in `process()`
/// where dest and onDisk are in scope.
var verifiedEntry: VerifiedProvenanceEntry?
```

**2. Populate `verifiedEntry` at skip-return sites in `process()`.**

The current code at the upToDate site (line ~187):

```swift
if onDisk.0 == pin {
    return upToDate(asset: asset, digest: onDisk.0, size: onDisk.1)
}
```

Replace with:

```swift
if onDisk.0 == pin {
    var outcome = upToDate(asset: asset, digest: onDisk.0, size: onDisk.1)
    outcome.verifiedEntry = VerifiedProvenanceEntry(
        url: asset.url,
        sha256: onDisk.0,   // already "sha256:"-prefixed from FileDigest.sha256WithSize
        size: onDisk.1,
        destinationPath: dest,
        verifiedAt: Date())
    return outcome
}
```

The current firstUse site (line ~205):

```swift
} else {
    // Present, unpinned, no prior lock entry → trust on first use.
    return firstUse(asset: asset, digest: onDisk.0, size: onDisk.1)
}
```

Replace with:

```swift
} else {
    var outcome = firstUse(asset: asset, digest: onDisk.0, size: onDisk.1)
    outcome.verifiedEntry = VerifiedProvenanceEntry(
        url: asset.url,
        sha256: onDisk.0,
        size: onDisk.1,
        destinationPath: dest,
        verifiedAt: Date())
    return outcome
}
```

The upToDate site for the unpinned matching prior lock (inside the `prior.sha256 == onDisk.0`
branch — the `return upToDate(...)` call at ~line 193):

```swift
if onDisk.0 == prior.sha256 {
    return upToDate(asset: asset, digest: onDisk.0, size: onDisk.1)
}
```

Replace with:

```swift
if onDisk.0 == prior.sha256 {
    var outcome = upToDate(asset: asset, digest: onDisk.0, size: onDisk.1)
    outcome.verifiedEntry = VerifiedProvenanceEntry(
        url: asset.url,
        sha256: onDisk.0,
        size: onDisk.1,
        destinationPath: dest,
        verifiedAt: Date())
    return outcome
}
```

The `tofuChange` accepted branch — the call site in `process()` is:

```swift
return tofuChange(
    asset: asset, prior: prior, onDisk: onDisk,
    acceptChanged: acceptChanged)
```

The `tofuChange` helper returns `EntryOutcome` with `exitContribution: 0` for the accepted path.
Since `tofuChange` now returns an `EntryOutcome` (struct), and we need to attach `verifiedEntry`
for the accepted branches (but NOT the rejected branch), use a local post-process:

```swift
var tofuOutcome = tofuChange(
    asset: asset, prior: prior, onDisk: onDisk,
    acceptChanged: acceptChanged)
// Accepted branches have exitContribution 0 and an entry set.
// Rejected branch has exitContribution 3 — contributes no verifiedEntry.
if tofuOutcome.exitContribution == 0 {
    tofuOutcome.verifiedEntry = VerifiedProvenanceEntry(
        url: asset.url,
        sha256: onDisk.0,
        size: onDisk.1,
        destinationPath: dest,
        verifiedAt: Date())
}
return tofuOutcome
```

**3. Collect verified entries and batch-send in `run()`.** After the per-entry loop (after
`worstExit = combine(worstExit, outcome.exitContribution)`), collect into an array:

Before the for loop, declare:

```swift
var verifiedEntries: [VerifiedProvenanceEntry] = []
```

Inside the for loop, after the `outcome` line:

```swift
if let ve = outcome.verifiedEntry {
    verifiedEntries.append(ve)
}
```

After the for loop and before the lockfile write (between lines 131 and 133):

```swift
// ── Best-effort batch provenance record for skip paths ──────────────
// Best-effort: failure (daemon down, version mismatch, store error) prints
// a non-fatal warning and does NOT alter any entry's exit contribution or
// the overall exit code (AC4 / M3).
if !verifiedEntries.isEmpty {
    do {
        let client = GohCommandClient(send: send)
        _ = try client.send(
            .recordVerifiedProvenance(
                request: RecordVerifiedProvenanceRequest(entries: verifiedEntries)),
            expecting: AckReply.self)
    } catch {
        // Non-fatal warning — sync result is already determined.
        FileHandle.standardError.write(
            Data("goh sync: warning: could not record provenance for \(verifiedEntries.count) verified-skip entr\(verifiedEntries.count == 1 ? "y" : "ies") (\(error))\n".utf8))
    }
}
```

**4. Add `import Foundation` guard** — `GohSyncCommand.swift` already imports `Foundation` and
`Darwin` at line 1–2. `VerifiedProvenanceEntry` is in `GohCore` (same module), so no import
needed.

#### Step 4 — Confirm PASS

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohSyncProvenanceBatchTests
```

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohSyncCommandTests
```

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -Xswiftc -warnings-as-errors
```

#### Step 5 — Commit

```
feat(sync): collect and best-effort batch-send verified-skip provenance entries (AC1/AC2/AC4)
```

---

### Task 7 — `GohWhichCommand` ledger-first precedence + three-way `verifiedAt` renderer; rewrite `GohWhichLedgerTests.lockPrecedence`; add M5 output-assertion test

**AC ownership:** M5 (goh which distinguishes downloaded vs verified-present vs both)

**Files:**
- Modify: `Sources/GohCore/CLI/GohWhichCommand.swift`
- Modify: `Tests/GohCoreTests/GohWhichLedgerTests.swift`

**Pre-task reads:** `GohWhichCommand.swift` (read above — confirmed: `run()` line 30–48 lock-first
ordering; `lookupInLedger` lines 62–79 current renderer outputs only `downloadedAt`),
`GohWhichLedgerTests.swift` (read above — `lockPrecedence` test at lines 128–164 asserts
lock-first and MUST be rewritten to assert ledger-first; `storeWithEntry` helper does NOT
set `verifiedAt` — must be updated or overridden for M5 test).

**Behavior change (documented):** `goh which` now consults the provenance ledger BEFORE the
lockfile. Files in BOTH sources show ledger values. Files only in a lockfile (pre-feature entries,
or entries from a manifest whose sync never sent a batch) still show lock values via the fallback.
This is deliberate and recorded in `DESIGN.md §Persistence`.

**Three-way renderer rule:**
- `verifiedAt == nil` → "downloaded \<date\>" (unchanged for download-only entries).
- `verifiedAt != nil && downloadedAt == verifiedAt` → "verified present \<date\>" (goh did not
  download these bytes; `downloadedAt` is not a real fetch time, so do not emit "downloaded").
- `verifiedAt != nil && downloadedAt < verifiedAt` → both "downloaded \<date\>" AND
  "last verified \<date\>".

#### Step 1 — Write failing tests

In `GohWhichLedgerTests.swift`:

**Rewrite `lockPrecedence`** (lines 128–164) to assert ledger-first:

```swift
// Ledger-first precedence: when both ledger AND lock have an entry for the same file,
// goh which shows the LEDGER's values (ledger is now the authoritative source).
// The lock is the FALLBACK for files never in the ledger.
@Test("ledger takes precedence over lock when both have an entry for the same path")
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

    // Ledger-first: sha256 from the LEDGER is shown, not the lock's.
    #expect(r.exitCode == 0)
    #expect(r.standardOutput.contains(String(repeating: "2", count: 64)))
    #expect(!r.standardOutput.contains(String(repeating: "1", count: 64)))
    _ = store
}
```

**Add M5 three-way output tests:**

```swift
// M5: verifiedAt nil → "downloaded <date>" line.
@Test("M5: download-only entry (verifiedAt nil) shows 'downloaded' date line")
func whichDownloadOnlyShowsDownloadedDate() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let destPath = dir.appendingPathComponent("dl.bin").path
    try Data("dl".utf8).write(to: URL(fileURLWithPath: destPath))
    let downloadDate = Date(timeIntervalSince1970: 1_748_000_000)
    let store = try storeWithEntry(in: dir, destPath: destPath,
                                   downloadedAt: downloadDate)
    // verifiedAt is nil (storeWithEntry does not set it).
    let storePath = dir.appendingPathComponent("provenance.plist").path

    let r = GohWhichCommand.run(
        filePath: destPath,
        lockPath: dir.appendingPathComponent("gohfile.lock").path,
        provenanceStorePath: storePath)

    #expect(r.exitCode == 0)
    #expect(r.standardOutput.contains("downloaded"))
    #expect(!r.standardOutput.contains("verified present"))
    #expect(!r.standardOutput.contains("last verified"))
    _ = store
}

// M5: verifiedAt == downloadedAt → "verified present <date>" (no "downloaded" line).
@Test("M5: verified-present-only entry (downloadedAt==verifiedAt) shows 'verified present' line")
func whichVerifiedPresentShowsVerifiedDate() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let destPath = dir.appendingPathComponent("vp.bin").path
    try Data("vp".utf8).write(to: URL(fileURLWithPath: destPath))

    let verifyTime = Date(timeIntervalSince1970: 1_750_000_000)
    let storeURL = dir.appendingPathComponent("provenance.plist")
    let store = ProvenanceStore(fileURL: storeURL)
    _ = store.load()
    let canonical = URL(fileURLWithPath: destPath).standardizedFileURL.path
    try store.record(entry: ProvenanceEntry(
        url: "https://example.com/vp.bin",
        sha256: "sha256:" + String(repeating: "e", count: 64),
        size: 2,
        downloadedAt: verifyTime,   // == verifiedAt
        destinationPath: canonical,
        verifiedAt: verifyTime))

    let r = GohWhichCommand.run(
        filePath: destPath,
        lockPath: dir.appendingPathComponent("gohfile.lock").path,
        provenanceStorePath: storeURL.path)

    #expect(r.exitCode == 0)
    #expect(r.standardOutput.contains("verified present"))
    #expect(!r.standardOutput.contains("downloaded"))
    _ = store
}

// M5: verifiedAt > downloadedAt → both "downloaded" and "last verified" lines.
@Test("M5: entry with verifiedAt > downloadedAt shows both 'downloaded' and 'last verified' lines")
func whichBothShowsBothDates() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let destPath = dir.appendingPathComponent("both.bin").path
    try Data("both".utf8).write(to: URL(fileURLWithPath: destPath))

    let downloadDate = Date(timeIntervalSince1970: 1_740_000_000)
    let verifyDate  = Date(timeIntervalSince1970: 1_750_000_000)
    let storeURL = dir.appendingPathComponent("provenance.plist")
    let store = ProvenanceStore(fileURL: storeURL)
    _ = store.load()
    let canonical = URL(fileURLWithPath: destPath).standardizedFileURL.path
    try store.record(entry: ProvenanceEntry(
        url: "https://example.com/both.bin",
        sha256: "sha256:" + String(repeating: "c", count: 64),
        size: 4,
        downloadedAt: downloadDate,
        destinationPath: canonical,
        verifiedAt: verifyDate))

    let r = GohWhichCommand.run(
        filePath: destPath,
        lockPath: dir.appendingPathComponent("gohfile.lock").path,
        provenanceStorePath: storeURL.path)

    #expect(r.exitCode == 0)
    #expect(r.standardOutput.contains("downloaded"))
    #expect(r.standardOutput.contains("last verified"))
    _ = store
}

// Lock-fallback: file NOT in ledger falls through to lock entry.
@Test("lock-fallback: file absent from ledger is found via lock entry")
func lockFallbackWhenNotInLedger() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let lockText = """
        lockfileVersion = 1
        manifestHash = "sha256:\(String(repeating: "0", count: 64))"

        [[entry]]
        url = "https://lock.example.com/only-in-lock.bin"
        path = "only-in-lock.bin"
        sha256 = "sha256:\(String(repeating: "9", count: 64))"
        size = 1
        downloadedAt = "2026-06-01T00:00:00Z"
        """
    let lockURL = dir.appendingPathComponent("gohfile.lock")
    try lockText.write(to: lockURL, atomically: true, encoding: .utf8)
    let target = dir.appendingPathComponent("only-in-lock.bin")
    try Data("x".utf8).write(to: target)

    // Ledger is empty (no entry for this path).
    let storeURL = dir.appendingPathComponent("provenance.plist")
    let store = ProvenanceStore(fileURL: storeURL)
    _ = store.load()

    let r = GohWhichCommand.run(
        filePath: target.path,
        lockPath: lockURL.path,
        provenanceStorePath: storeURL.path)

    // Falls back to lock → exit 0, shows lock's sha256.
    #expect(r.exitCode == 0)
    #expect(r.standardOutput.contains(String(repeating: "9", count: 64)))
    _ = store
}
```

#### Step 2 — Confirm FAIL

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohWhichLedgerTests
```

Expected: `lockPrecedence` fails (current code is lock-first, test now asserts ledger-first).
M5 tests fail (renderer does not yet output "verified present" or "last verified").

#### Step 3 — Implement

**`Sources/GohCore/CLI/GohWhichCommand.swift`:**

**Swap ordering in `run()` to ledger-first, lock-fallback** (lines 29–44). Replace the current
block:

```swift
// 1. Lock lookup (unchanged).
if let output = lookupInLock(targetURL: targetURL, lockPath: lockPath) {
    return GohCommandLineResult(exitCode: 0, standardOutput: output)
}

// 2. NEW: Provenance-ledger lookup (skipped when provenanceStorePath is nil).
if let storePath = provenanceStorePath,
   let output = lookupInLedger(targetURL: targetURL, storePath: storePath) {
    return GohCommandLineResult(exitCode: 0, standardOutput: output)
}
```

With:

```swift
// 1. Provenance-ledger lookup (ledger-first — the authoritative unified source).
//    Skipped when provenanceStorePath is nil (preserves backward compat for callers
//    that do not pass a store path).
if let storePath = provenanceStorePath,
   let output = lookupInLedger(targetURL: targetURL, storePath: storePath) {
    return GohCommandLineResult(exitCode: 0, standardOutput: output)
}

// 2. Lock fallback — for files present only in a lockfile (pre-feature entries).
if let output = lookupInLock(targetURL: targetURL, lockPath: lockPath) {
    return GohCommandLineResult(exitCode: 0, standardOutput: output)
}
```

**Rewrite `lookupInLedger` body** (lines 62–79) for three-way `verifiedAt` output:

```swift
private static func lookupInLedger(targetURL: URL, storePath: String) -> String? {
    let store = ProvenanceStore(fileURL: URL(fileURLWithPath: storePath))
    guard store.loadReadOnly() else { return nil }
    guard let entry = store.lookup(destinationPath: targetURL.path) else {
        return nil
    }

    let formatter = ISO8601DateFormatter()
    var out = "url:    \(entry.url)\n"
    out    += "sha256: \(entry.sha256)\n"
    out    += "size:   \(entry.size)\n"

    if let verifiedAt = entry.verifiedAt {
        if entry.downloadedAt == verifiedAt {
            // goh confirmed these bytes present; never downloaded them.
            out += "verified present \(formatter.string(from: verifiedAt))\n"
        } else {
            // goh both downloaded and later verified.
            out += "downloaded       \(formatter.string(from: entry.downloadedAt))\n"
            out += "last verified    \(formatter.string(from: verifiedAt))\n"
        }
    } else {
        // Download-only entry (no verification event).
        out += "downloaded       \(formatter.string(from: entry.downloadedAt))\n"
    }

    return out
}
```

Note: the existing test `whichReadsFromLedger` asserts `r.standardOutput.contains("https://…")`
and `r.standardOutput.contains(sha256)` — these pass because `url:` and `sha256:` are still
present. It also asserts `!r.standardOutput.contains("(not recorded)")` — passes. The test does
NOT assert the exact date-line label, so renaming from `downloadedAt:` to `downloaded` is safe
for all existing ledger tests. Verify by running the full `GohWhichLedgerTests` suite.

#### Step 4 — Confirm PASS

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohWhichLedgerTests
```

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -Xswiftc -warnings-as-errors
```

Full test suite:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

#### Step 5 — Commit

```
feat(which): ledger-first precedence + three-way verifiedAt renderer; rewrite lockPrecedence test
```

---

## Full test sweep before merge

Run the full test suite to confirm no regressions:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: all tests pass. Confirm:
- `ProvenanceRecordTests` (incl. `goldenFixtureRoundTrip` — `provenance-v1.plist` fixture unchanged)
- `ProvenanceStoreTests` (incl. all existing tests; new `recordVerified*` tests)
- `CommandTests` (incl. updated `commandRoundTrip` with `.recordVerifiedProvenance` case)
- `EnvelopeCodecTests` (v3 fixtures still pass; v4 fixtures pass)
- `CommandServiceTests` (version-mismatch tests reference `CommandService.protocolVersion` symbolically — auto-follow bump to 4)
- `GohSyncCommandTests` + `GohSyncCLIWiringTests`
- `GohSyncProvenanceBatchTests` (AC1/AC2/AC4 integration)
- `GohWhichLedgerTests` (rewritten `lockPrecedence` + M5 output tests)

---

## File map summary

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/GohCore/Provenance/ProvenanceRecord.swift` | Modify | Add `verifiedAt: Date?` to `ProvenanceEntry` |
| `Sources/GohCore/Provenance/ProvenanceStore.swift` | Modify | Add `recordVerified(entries:)` |
| `Sources/GohCore/Model/Command.swift` | Modify | Add `case recordVerifiedProvenance`, `RecordVerifiedProvenanceRequest`, `VerifiedProvenanceEntry` |
| `Sources/GohCore/Model/CommandReply.swift` | Modify | Add `AckReply` |
| `Sources/GohCore/Model/CommandOutcome.swift` | Modify | Add `.ack` case |
| `Sources/GohCore/Model/CommandService.swift` | Modify | Bump `protocolVersion` 3→4; add `.ack` arm in `encodeReply` |
| `Sources/GohCore/Model/CommandDispatcher.swift` | Modify | Add `provenanceStore: ProvenanceStore?` param + `.recordVerifiedProvenance` dispatch arm |
| `Sources/gohd/main.swift` | Modify | Pass `provenanceStore:` to `CommandDispatcher` |
| `Sources/GohCore/CLI/GohSyncCommand.swift` | Modify | Add `verifiedEntry` to `EntryOutcome`; populate at skip-returns; collect + batch-send in `run()` |
| `Sources/GohCore/CLI/GohWhichCommand.swift` | Modify | Ledger-first ordering in `run()`; rewrite `lookupInLedger` for three-way output |
| `Tests/GohCoreTests/Fixtures/envelope-v4-record-verified-provenance-request.json` | Create | Golden fixture for v4 request |
| `Tests/GohCoreTests/Fixtures/envelope-v4-record-verified-provenance-reply.json` | Create | Golden fixture for v4 reply |
| `Tests/GohCoreTests/ProvenanceRecordTests.swift` | Modify | Add `verifiedAtNilRoundTrip` test |
| `Tests/GohCoreTests/ProvenanceStoreTests.swift` | Modify | Add `recordVerified*` merge tests |
| `Tests/GohCoreTests/CommandTests.swift` | Modify | Extend `commandRoundTrip` literal + add payload round-trip test |
| `Tests/GohCoreTests/EnvelopeCodecTests.swift` | Modify | Add v4 fixture decode tests |
| `Tests/GohCoreTests/CommandServiceTests.swift` | Modify | Add `recordVerifiedProvenanceReturnsAck` XPC test |
| `Tests/GohCoreTests/GohSyncCommandTests.swift` | Modify | Extend `FakeSyncDaemon`; add `GohSyncProvenanceBatchTests` |
| `Tests/GohCoreTests/GohWhichLedgerTests.swift` | Modify | Rewrite `lockPrecedence`; add M5 output tests + lock-fallback test |

---

## Dependency order (authoritative)

1. Task 1 — `ProvenanceEntry.verifiedAt` (no dependents blocked)
2. Task 3 — Wire types (`VerifiedProvenanceEntry`, `AckReply`, `CommandOutcome.ack`,
   `Command.recordVerifiedProvenance`) — Task 2 and Task 5 depend on this
3. Task 2 — `ProvenanceStore.recordVerified(entries:)` — depends on Task 3
4. Task 4 — `protocolVersion=4`, `encodeReply .ack`, v4 fixtures — depends on Task 3
5. Task 5 — `CommandDispatcher` injection + `gohd/main.swift` wiring — depends on Tasks 2, 3, 4
6. Task 6 — `GohSyncCommand` batch-send — depends on Task 5
7. Task 7 — `GohWhichCommand` ledger-first + renderer — depends on Task 1 (verifiedAt field)

Tasks 6 and 7 are independent of each other and may run in parallel once Task 5 is done.
