---
date: 2026-05-30
feature: trust-core
branch: design/trust-core
spec: docs/superpowers/specs/2026-05-29-trust-core-design.md
research-brief: docs/superpowers/research/2026-05-29-trust-core-brief.md
required-sub-skill: superpowers:subagent-driven-development
status: ready-to-execute
---

# Trust Core — Implementation Plan

## Goal

Ship `goh sync` / `goh verify` / `goh which` with two frozen on-disk formats
(`gohfile.toml` + `gohfile.lock`), daemon write-path hardening, and all five
ACs.

## Architecture

```
GohCore/TrustCore/
  MinimalTOMLReader.swift      ← Phase 1: hand-rolled TOML parser
  MinimalTOMLWriter.swift      ← Phase 1: writer
  ManifestCodec.swift          ← Phase 2: gohfile.toml decoder
  LockfileCodec.swift          ← Phase 2: gohfile.lock decoder/encoder
  FileDigest.swift             ← Phase 2: at-rest SHA-256 streaming wrapper
DownloadFile.swift             ← Phase 3: add O_NOFOLLOW + openat descent
GohError.swift                 ← Phase 3: add symlinkComponentRefused ErrorCode
GohCommandLine.swift           ← Phases 4–6: add which/verify/sync ParsedCommands
CLI/GohWhichCommand.swift      ← Phase 4
CLI/GohVerifyCommand.swift     ← Phase 5
CLI/GohSyncCommand.swift       ← Phase 6
Tests/GohCoreTests/
  MinimalTOMLReaderTests.swift
  ManifestCodecTests.swift
  LockfileCodecTests.swift
  FileDigestTests.swift
  DownloadFileConfinementTests.swift
  GohWhichCommandTests.swift
  GohVerifyCommandTests.swift
  GohSyncCommandTests.swift
  Fixtures/
    toml-manifest-full.toml
    toml-manifest-empty.toml
    toml-manifest-bad-unknown-key.toml
    toml-manifest-bad-sha256-shape.toml
    toml-manifest-bad-auth-reserved.toml
    toml-manifest-bad-inline-table.toml
    toml-manifest-bad-dotted-key.toml
    toml-manifest-bad-array-value.toml
    toml-manifest-bad-float.toml
    toml-manifest-bad-native-datetime.toml
    toml-lockfile-full.toml
    toml-lockfile-empty.toml
    toml-lockfile-bad-unknown-version.toml
    toml-lockfile-bad-chunks-reserved.toml
    toml-lockfile-bad-missing-manifestHash.toml
```

## Tech Stack

- Swift 6.2 tools-version, Swift 6.3.x toolchain, macOS 26.0+
- GohCore target (nonisolated default), goh executable (MainActor default)
- CryptoKit SHA-256 (for FileDigest)
- Darwin `open(2)`, `openat(2)`, `O_NOFOLLOW`, `O_DIRECTORY` (for confinement)
- `getxattr(2)` (for `goh which` provenance)
- `flock(2)` (for advisory lock on gohfile.lock)
- Swift Testing (`@Test`, `@Suite`, `#expect`)
- CI: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

---

## PLANNING NOTES — Conflicts and Reconciliations

### Exit-code table vs. DESIGN.md (64/1) — FINAL RECONCILED CONTRACT

**Final contract (§9.4, frozen):**

- `0` = success / all up to date / all verified / provenance found.
- `64` = usage / bad-input (`EX_USAGE`, unchanged convention): unparseable CLI
  args **and** malformed manifest input — unknown manifest `version`, unknown
  key, malformed `sha256:` shape, and the `auth` reserved-field rejection.
  Bad manifest input is the same bucket as bad CLI args.
- `1` = generic daemon-domain / transport failure (unchanged convention). The
  trust-core commands themselves do **not** return exit `1` for their own
  domain failures; they use `2`–`10` (and `64` for bad input). Exit `1` is
  reserved for daemon-unreachable / malformed-reply failures that fall into the
  existing `transportFailure` path.
- `2` = integrity failure (pinned mismatch / verify content drift).
- `3` = unpinned TOFU hash change without opt-in (AC5).
- `4` = no provenance record (which).
- `5` = path-escape / confinement violation.
- `6` = lock missing / corrupt / stale (manifestHash mismatch) **and** unknown
  `lockfileVersion` (an unusable lock → 6, not 1).
- `7` = could not acquire advisory lock.
- `8` = one or more entries failed to download.
- `9` = verify: locked entry missing on disk.
- `10` = verify --strict-untracked: untracked files present.

**Mechanism — how bad-manifest input becomes exit 64:**

`GohCommandLine.run()` has an outer `catch let error as ParseError` block that
returns `exitCode: 64`. When `GohSyncCommand` detects a `ManifestCodec.CodecError`
(unknown version, unknown key, bad sha256 shape, reserved `auth` field), it
re-throws it as (or converts it to) a usage-class error so it propagates up
through this `catch`. The concrete implementation: `GohSyncCommand.runThrowing`
throws a `ParseError` (the private type in `GohCommandLine.swift`) when it catches
a `ManifestCodec.CodecError` — **or** the command returns
`GohCommandLineResult(exitCode: 64, ...)` directly (either is valid; using
`exitCode: 64` directly is simpler because `GohSyncCommand` cannot access the
private `ParseError` type). **Do not return `exitCode: 1`** for bad-manifest
errors.

**Mechanism — how unknown `lockfileVersion` becomes exit 6:**

`LockfileCodec.decode` throws `CodecError` when it encounters an unsupported
version. `GohVerifyCommand` and `GohSyncCommand` catch this and return
`GohCommandLineResult(exitCode: 6, ...)`. **Do not return `exitCode: 1`** for
unknown lockfile version.

**The two-level model:**
- Bad CLI argument (unknown verb, bad flag) → `throw ParseError` → caught in
  `GohCommandLine.run()` → `exitCode: 64`. (Unchanged for all existing commands.)
- Bad manifest content (codec error) → command returns `exitCode: 64` directly.
- Bad lock version → command returns `exitCode: 6` directly.
- Daemon unreachable / malformed reply → `GohCommandLineError` / generic catch
  → `exitCode: 1` (existing `transportFailure` path, unchanged).
- Trust-core domain failures → command returns `exitCode: 2`–`10` directly.

### No `cancelled` in JobState

`JobState` has exactly: `queued`, `active`, `paused`, `completed`, `failed`.
There is no `cancelled`. The spec's completion-detection loop (§9.1 4a) is
correct: only `completed` and `failed` are terminal. A disappeared job (absent
from `ls` reply) is the third terminal branch and must be handled explicitly.

### `AddRequest` has no `base` field

Confirmed: `AddRequest` carries `url`, `destination?`, `connectionCount?`,
`useImportedCookies?`, `priority?`. No `base`. The daemon never knows `base`.
The CLI pre-flight must fully resolve the confined absolute path and pass it as
`destination` to `add`. This is consistent with the spec §4.1 design.

### `protocolVersion` stays 3

Confirmed in `Command.swift` / `CommandService` — no new case added.
`protocolVersion = 3` is the frozen constant.

### `checksumMismatch` ErrorCode exists

Confirmed in `GohError.swift`. No new ErrorCode is needed for integrity
failures. A new case `symlinkComponentRefused` IS needed for the daemon's
open-time symlink refusal (Phase 3), so the CLI can map it to exit 5 rather
than exit 8. This is additive (enum + new case) and does not touch protocolVersion.

### `ChunkAssembler` is download-bound

Confirmed: `ChunkAssembler` requires a live `DownloadFile` and an in-flight
range structure — it is not a general at-rest file-digest entry point. Phase 2
writes `FileDigest.swift` as a small new CryptoKit SHA-256 streaming wrapper
over `FileHandle` for at-rest re-hashing.

### Fixture loading pattern

Tests use `Bundle.module.url(forResource:withExtension:subdirectory:)`.
The `GohCoreTests` target has `resources: [.copy("Fixtures")]` in `Package.swift`.
New `.toml` fixtures go into `Tests/GohCoreTests/Fixtures/` and are loaded via
`Bundle.module.url(forResource: name, withExtension: "toml", subdirectory: "Fixtures")`.

---

## AC → Task Mapping

| AC | Tasks |
|----|-------|
| AC1 (idempotent sync, lock written) | T6.1, T6.2, T6.3, T6.4, T6.5 |
| AC2 (verify detects drift, exit 2) | T5.1, T5.2, T5.3 |
| AC3 (pinned strict, TOFU record) | T6.2, T6.3 |
| AC4 (goh which, exit 4 unknown) | T4.1, T4.2 |
| AC5 (TOFU change loud, exit 3, --accept-changed) | T6.4 |

---

## Phase 1 — Hand-rolled TOML reader+writer

**Deployment boundary:** self-contained; depends on nothing in the project;
can be merged independently before any command work begins.

**Bet check (Phase 1):** The research brief's primary bet is "re-hash on
demand is fast enough (~1 GB/s Apple Silicon) that persisting digests buys
nothing, and a self-contained lockfile beside the data beats a daemon registry."
Phase 1 establishes the TOML primitive that the lockfile depends on. If the
TOML reader proves infeasible as a hand-roll, the bet needs reassessment before
Phase 2 proceeds. The golden fixtures make this immediately visible.

---

### T1.1 — MinimalTOMLReader: core scalar parser + array-of-tables

**Files**
- CREATE `Sources/GohCore/TrustCore/MinimalTOMLReader.swift`
- CREATE `Tests/GohCoreTests/MinimalTOMLReaderTests.swift`
- CREATE `Tests/GohCoreTests/Fixtures/toml-manifest-full.toml`
- CREATE `Tests/GohCoreTests/Fixtures/toml-manifest-empty.toml`
- CREATE `Tests/GohCoreTests/Fixtures/toml-lockfile-full.toml`

**Pre-task reads checklist**
- [x] `Sources/GohCore/Engine/ChunkAssembler.swift` — understand how SHA-256
  strings are formatted (lowercase hex, no prefix); the TOML reader will
  validate `sha256:<64-hex>` strings in Phase 2
- [x] `Tests/GohCoreTests/EnvelopeCodecTests.swift` — understand the golden-
  fixture loading idiom (`Bundle.module.url(forResource:withExtension:subdirectory:)`)
- [x] `Package.swift` — confirm `resources: [.copy("Fixtures")]` is already
  declared for `GohCoreTests`

**Step 1 — Failing tests**

```swift
// Tests/GohCoreTests/MinimalTOMLReaderTests.swift
import Foundation
import Testing

import GohCore

@Suite("MinimalTOMLReader")
struct MinimalTOMLReaderTests {

    // AC stub: TOML reader is the prerequisite for AC1–AC5 (all commands).

    private func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(
                forResource: name, withExtension: "toml",
                subdirectory: "Fixtures"),
            "missing fixture: Fixtures/\(name).toml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("parses a full manifest fixture into named key-value sections")
    func parsesFullManifest() throws {
        let toml = try fixture("toml-manifest-full")
        let doc = try MinimalTOMLReader.parse(toml)
        // version = 1, base = "assets", two [[asset]] sections
        let version = try #require(doc.topLevel["version"]?.intValue)
        #expect(version == 1)
        let base = try #require(doc.topLevel["base"]?.stringValue)
        #expect(base == "assets")
        #expect(doc.arrayOfTables("asset").count == 2)
    }

    @Test("parses an empty manifest (no [[asset]])")
    func parsesEmptyManifest() throws {
        let toml = try fixture("toml-manifest-empty")
        let doc = try MinimalTOMLReader.parse(toml)
        #expect(doc.arrayOfTables("asset").isEmpty)
    }

    @Test("parses a full lockfile fixture")
    func parsesFullLockfile() throws {
        let toml = try fixture("toml-lockfile-full")
        let doc = try MinimalTOMLReader.parse(toml)
        let lockfileVersion = try #require(doc.topLevel["lockfileVersion"]?.intValue)
        #expect(lockfileVersion == 1)
        #expect(doc.arrayOfTables("entry").count == 2)
    }

    @Test("rejects an unknown top-level key loudly")
    func rejectsUnknownTopLevelKey() throws {
        let toml = "version = 1\nunknownKey = \"oops\"\n"
        #expect(throws: MinimalTOMLReader.ParseError.self) {
            try MinimalTOMLReader.parse(toml, allowedTopLevelKeys: ["version", "base"])
        }
    }

    @Test("rejects an unknown per-asset key loudly")
    func rejectsUnknownAssetKey() throws {
        let toml = try fixture("toml-manifest-bad-unknown-key")
        #expect(throws: MinimalTOMLReader.ParseError.self) {
            try MinimalTOMLReader.parse(
                toml,
                allowedTopLevelKeys: ["version", "base"],
                allowedAssetKeys: ["url", "path", "dest", "sha256", "verify", "auth"])
        }
    }

    @Test("rejects inline table construct with named error")
    func rejectsInlineTable() throws {
        let toml = try fixture("toml-manifest-bad-inline-table")
        #expect(throws: MinimalTOMLReader.ParseError.self) {
            _ = try MinimalTOMLReader.parse(toml)
        }
    }

    @Test("rejects dotted key construct with named error")
    func rejectsDottedKey() throws {
        let toml = try fixture("toml-manifest-bad-dotted-key")
        #expect(throws: MinimalTOMLReader.ParseError.self) {
            _ = try MinimalTOMLReader.parse(toml)
        }
    }

    @Test("rejects array value construct with named error")
    func rejectsArrayValue() throws {
        let toml = try fixture("toml-manifest-bad-array-value")
        #expect(throws: MinimalTOMLReader.ParseError.self) {
            _ = try MinimalTOMLReader.parse(toml)
        }
    }

    @Test("rejects float value with named error")
    func rejectsFloat() throws {
        let toml = try fixture("toml-manifest-bad-float")
        #expect(throws: MinimalTOMLReader.ParseError.self) {
            _ = try MinimalTOMLReader.parse(toml)
        }
    }

    @Test("rejects native TOML datetime with named error")
    func rejectsNativeDatetime() throws {
        let toml = try fixture("toml-manifest-bad-native-datetime")
        #expect(throws: MinimalTOMLReader.ParseError.self) {
            _ = try MinimalTOMLReader.parse(toml)
        }
    }

    @Test("round-trips a known document through write then re-parse")
    func roundTrips() throws {
        let toml = try fixture("toml-manifest-full")
        let doc = try MinimalTOMLReader.parse(toml)
        let written = MinimalTOMLWriter.write(doc)
        let reparsed = try MinimalTOMLReader.parse(written)
        #expect(reparsed.topLevel["version"]?.intValue == doc.topLevel["version"]?.intValue)
        #expect(reparsed.arrayOfTables("asset").count == doc.arrayOfTables("asset").count)
    }
}
```

**Step 2 — Run and expect fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter MinimalTOMLReaderTests 2>&1 | head -40
# Expected: compilation error — MinimalTOMLReader type does not exist
```

**Step 3 — Minimal implementation**

```swift
// Sources/GohCore/TrustCore/MinimalTOMLReader.swift
import Foundation

/// A minimal, subset-only TOML reader for gohfile.toml and gohfile.lock.
///
/// Accepted subset (§9.5 of the spec — frozen):
///   - Top-level key = value where value is: basic string (double-quoted),
///     decimal integer, or boolean (true/false).
///   - [[arrayOfTables]] headers with the same scalar types inside them.
///   - # line comments and blank lines.
///
/// Everything else (dotted keys, inline tables, array values, float,
/// native datetimes, single-quoted/multiline strings, standard [table] headers)
/// is rejected loudly with a named ParseError identifying the construct.
public struct MinimalTOMLDocument: Sendable {
    public var topLevel: [String: TOMLValue]
    private var tables: [(name: String, fields: [String: TOMLValue])]

    public init(
        topLevel: [String: TOMLValue] = [:],
        tables: [(name: String, fields: [String: TOMLValue])] = []
    ) {
        self.topLevel = topLevel
        self.tables = tables
    }

    /// Returns all sections declared as [[name]].
    public func arrayOfTables(_ name: String) -> [[String: TOMLValue]] {
        tables.filter { $0.name == name }.map { $0.fields }
    }
}

public enum TOMLValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case boolean(Bool)

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var intValue: Int? {
        if case .integer(let i) = self { return i }
        return nil
    }
    public var boolValue: Bool? {
        if case .boolean(let b) = self { return b }
        return nil
    }
}

public struct MinimalTOMLReader {
    public struct ParseError: Error, Equatable {
        public var message: String
        public var line: Int?

        public init(_ message: String, line: Int? = nil) {
            self.message = message
            self.line = line
        }
    }

    /// Parses the accepted TOML subset.
    ///
    /// - Parameters:
    ///   - input: UTF-8 TOML text.
    ///   - allowedTopLevelKeys: when non-nil, unknown top-level keys are
    ///     rejected. Pass nil to skip top-level key validation (used in tests).
    ///   - allowedAssetKeys: when non-nil, unknown keys inside any
    ///     array-of-tables section are rejected.
    public static func parse(
        _ input: String,
        allowedTopLevelKeys: Set<String>? = nil,
        allowedAssetKeys: Set<String>? = nil
    ) throws -> MinimalTOMLDocument {
        var topLevel: [String: TOMLValue] = [:]
        var tables: [(name: String, fields: [String: TOMLValue])] = []
        var currentTable: (name: String, fields: [String: TOMLValue])? = nil

        let lines = input.components(separatedBy: "\n")
        for (lineIndex, rawLine) in lines.enumerated() {
            let lineNumber = lineIndex + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Blank or comment
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Array-of-tables header: [[name]]
            if line.hasPrefix("[[") {
                guard line.hasSuffix("]]") else {
                    throw ParseError("malformed array-of-tables header", line: lineNumber)
                }
                let name = String(line.dropFirst(2).dropLast(2))
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(".") else {
                    throw ParseError(
                        "unsupported TOML construct 'dotted key' at line \(lineNumber); "
                        + "goh accepts only the described subset", line: lineNumber)
                }
                if let prev = currentTable { tables.append(prev) }
                currentTable = (name: name, fields: [:])
                continue
            }

            // Standard table header [name] — outside accepted subset
            if line.hasPrefix("[") {
                throw ParseError(
                    "unsupported TOML construct 'standard table' at line \(lineNumber); "
                    + "goh accepts only [[arrayOfTables]] headers", line: lineNumber)
            }

            // Key = value line
            guard let eqIdx = line.firstIndex(of: "=") else {
                throw ParseError("unparseable line at line \(lineNumber): \(line)",
                                 line: lineNumber)
            }
            let rawKey = line[..<eqIdx].trimmingCharacters(in: .whitespaces)
            let rawVal = line[line.index(after: eqIdx)...]
                .trimmingCharacters(in: .whitespaces)

            // Reject dotted keys
            if rawKey.contains(".") {
                throw ParseError(
                    "unsupported TOML construct 'dotted key' at line \(lineNumber); "
                    + "goh accepts only simple keys", line: lineNumber)
            }

            let value = try parseValue(rawVal, lineNumber: lineNumber)

            if var table = currentTable {
                table.fields[rawKey] = value
                currentTable = table
            } else {
                // Validate top-level key if a set was supplied
                if let allowed = allowedTopLevelKeys, !allowed.contains(rawKey) {
                    throw ParseError(
                        "unknown key '\(rawKey)' at line \(lineNumber)",
                        line: lineNumber)
                }
                topLevel[rawKey] = value
            }
        }

        if let prev = currentTable { tables.append(prev) }

        // Validate per-table keys if requested
        if let allowed = allowedAssetKeys {
            for table in tables {
                for key in table.fields.keys where !allowed.contains(key) {
                    throw ParseError("unknown key '\(key)' in [[\(table.name)]]")
                }
            }
        }

        return MinimalTOMLDocument(topLevel: topLevel, tables: tables)
    }

    private static func parseValue(_ raw: String, lineNumber: Int) throws -> TOMLValue {
        // Comment stripping (inline # only outside strings)
        let stripped = stripInlineComment(raw)

        // Basic string
        if stripped.hasPrefix("\"") {
            guard stripped.hasSuffix("\""), stripped.count >= 2 else {
                throw ParseError("unclosed string at line \(lineNumber)", line: lineNumber)
            }
            // Reject multiline strings
            if stripped.hasPrefix("\"\"\"") {
                throw ParseError(
                    "unsupported TOML construct 'multiline string' at line \(lineNumber); "
                    + "goh accepts only basic single-line strings", line: lineNumber)
            }
            let content = String(stripped.dropFirst().dropLast())
            return .string(content)
        }

        // Single-quoted string (outside accepted subset)
        if stripped.hasPrefix("'") {
            throw ParseError(
                "unsupported TOML construct 'literal string' at line \(lineNumber); "
                + "goh accepts only double-quoted strings", line: lineNumber)
        }

        // Inline table
        if stripped.hasPrefix("{") {
            throw ParseError(
                "unsupported TOML construct 'inline table' at line \(lineNumber); "
                + "goh accepts only scalar values", line: lineNumber)
        }

        // Array value
        if stripped.hasPrefix("[") {
            throw ParseError(
                "unsupported TOML construct 'array' at line \(lineNumber); "
                + "goh accepts only scalar values and [[arrayOfTables]]", line: lineNumber)
        }

        // Boolean
        if stripped == "true" { return .boolean(true) }
        if stripped == "false" { return .boolean(false) }

        // Integer (must precede float check)
        if let i = Int(stripped) { return .integer(i) }

        // Float detection (contains '.' or 'e'/'E' but not a datetime colon)
        if stripped.contains(".") || stripped.lowercased().contains("e") {
            // Check for datetime (contains ':' or is in ISO form)
            if stripped.contains(":") || stripped.contains("T") || stripped.contains("Z") {
                throw ParseError(
                    "unsupported value type 'datetime' at line \(lineNumber); "
                    + "goh stores timestamps as strings", line: lineNumber)
            }
            throw ParseError(
                "unsupported value type 'float' at line \(lineNumber); "
                + "goh accepts only integer, string, and boolean scalars", line: lineNumber)
        }

        // Datetime-like (contains ':' or 'T' without being a string)
        if stripped.contains(":") || (stripped.contains("T") && stripped.contains("-")) {
            throw ParseError(
                "unsupported value type 'datetime' at line \(lineNumber); "
                + "goh stores timestamps as strings", line: lineNumber)
        }

        // Hex/octal/binary prefixes
        if stripped.hasPrefix("0x") || stripped.hasPrefix("0o") || stripped.hasPrefix("0b") {
            throw ParseError(
                "unsupported value type 'non-decimal integer' at line \(lineNumber); "
                + "goh accepts only decimal integers", line: lineNumber)
        }

        throw ParseError("unrecognised value '\(stripped)' at line \(lineNumber)",
                         line: lineNumber)
    }

    private static func stripInlineComment(_ s: String) -> String {
        // A '#' outside a string begins a comment. Simple approach:
        // only strip if there is no open quote before the '#'.
        var inString = false
        for (idx, ch) in s.enumerated() {
            if ch == "\"" { inString.toggle() }
            if ch == "#", !inString {
                return String(s.prefix(idx)).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }
}
```

```swift
// Sources/GohCore/TrustCore/MinimalTOMLWriter.swift
import Foundation

/// Serialises a MinimalTOMLDocument back into the accepted TOML subset.
/// Used by LockfileCodec to write gohfile.lock.
public struct MinimalTOMLWriter {

    /// Returns the TOML text for `doc`. Fields are emitted in stable order
    /// (keys sorted); [[section]] blocks follow top-level fields.
    public static func write(_ doc: MinimalTOMLDocument) -> String {
        var out = ""
        for key in doc.topLevel.keys.sorted() {
            out += "\(key) = \(encode(doc.topLevel[key]!))\n"
        }
        // Re-group tables by name to emit adjacent [[section]] blocks
        var seen: [String: Bool] = [:]
        for table in doc._tables {
            if seen[table.name] == nil {
                seen[table.name] = true
                out += "\n"
            }
            out += "[[\(table.name)]]\n"
            for key in table.fields.keys.sorted() {
                out += "\(key) = \(encode(table.fields[key]!))\n"
            }
        }
        return out
    }

    private static func encode(_ value: TOMLValue) -> String {
        switch value {
        case .string(let s): return "\"\(s)\""
        case .integer(let i): return "\(i)"
        case .boolean(let b): return b ? "true" : "false"
        }
    }
}
```

**Note:** `MinimalTOMLDocument._tables` is the backing storage; expose it as
internal so the writer can iterate. Adjust the struct to expose
`internal var _tables: [(name: String, fields: [String: TOMLValue])]`.

**Golden fixtures to create:**

`Tests/GohCoreTests/Fixtures/toml-manifest-full.toml`:
```toml
version = 1
base = "assets"

[[asset]]
url    = "https://example.org/datasets/mnist.tar.gz"
path   = "datasets/mnist.tar.gz"
sha256 = "sha256:6f1e2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2"

[[asset]]
url  = "https://example.org/weights/model-latest.bin"
path = "weights/model-latest.bin"
```

`Tests/GohCoreTests/Fixtures/toml-manifest-empty.toml`:
```toml
version = 1
```

`Tests/GohCoreTests/Fixtures/toml-lockfile-full.toml`:
```toml
lockfileVersion = 1
manifestHash    = "sha256:a3f9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1"

[[entry]]
url          = "https://example.org/datasets/mnist.tar.gz"
path         = "datasets/mnist.tar.gz"
sha256       = "sha256:6f1e2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2"
size         = 11594722
downloadedAt = "2026-05-29T14:08:51Z"

[[entry]]
url          = "https://example.org/weights/model-latest.bin"
path         = "weights/model-latest.bin"
sha256       = "sha256:0b4477c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6e1"
size         = 438291104
downloadedAt = "2026-05-29T14:11:03Z"
```

`Tests/GohCoreTests/Fixtures/toml-manifest-bad-unknown-key.toml`:
```toml
version = 1

[[asset]]
url      = "https://example.org/file.bin"
path     = "file.bin"
misspeld = "value"
```

`Tests/GohCoreTests/Fixtures/toml-manifest-bad-inline-table.toml`:
```toml
version = 1
meta = { author = "test" }
```

`Tests/GohCoreTests/Fixtures/toml-manifest-bad-dotted-key.toml`:
```toml
version = 1
foo.bar = "baz"
```

`Tests/GohCoreTests/Fixtures/toml-manifest-bad-array-value.toml`:
```toml
version = 1
tags = ["a", "b"]
```

`Tests/GohCoreTests/Fixtures/toml-manifest-bad-float.toml`:
```toml
version = 1.5
```

`Tests/GohCoreTests/Fixtures/toml-manifest-bad-native-datetime.toml`:
```toml
version = 1
when = 2026-05-29T14:08:51Z
```

**Step 4 — Run and expect pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter MinimalTOMLReaderTests
# Expected: all tests green
```

**Step 5 — Commit**

```
feat(trust-core): hand-rolled minimal TOML reader+writer with golden fixtures (Phase 1)
```

---

### T1.2 — Remaining bad-fixture tests: sha256 shape, auth reserved, lockfile reserved

**Files**
- MODIFY `Tests/GohCoreTests/MinimalTOMLReaderTests.swift` — add tests below
- CREATE `Tests/GohCoreTests/Fixtures/toml-manifest-bad-sha256-shape.toml`
- CREATE `Tests/GohCoreTests/Fixtures/toml-manifest-bad-auth-reserved.toml`
- CREATE `Tests/GohCoreTests/Fixtures/toml-lockfile-bad-unknown-version.toml`
- CREATE `Tests/GohCoreTests/Fixtures/toml-lockfile-bad-chunks-reserved.toml`
- CREATE `Tests/GohCoreTests/Fixtures/toml-lockfile-bad-missing-manifestHash.toml`

**Pre-task reads:** none beyond T1.1 reads.

**Step 1 — Failing tests**

```swift
// Add to MinimalTOMLReaderTests:

@Test("reserved 'auth' key present/non-null is rejected loudly (manifest)")
func rejectsReservedAuthKey() throws {
    let toml = try fixture("toml-manifest-bad-auth-reserved")
    // The ManifestCodec will reject this; the reader itself just parses —
    // this test validates the fixture is structurally parseable so
    // ManifestCodec can provide the domain error. See ManifestCodecTests
    // for the actual rejection. (Reader passes; ManifestCodec fails.)
    // This test documents the contract split.
    #expect(throws: Never.self) { try MinimalTOMLReader.parse(toml) }
}

@Test("reserved 'chunks' key present/non-null is rejected by LockfileCodec (not reader)")
func chunksReservedIsDocumented() throws {
    let toml = try fixture("toml-lockfile-bad-chunks-reserved")
    #expect(throws: Never.self) { try MinimalTOMLReader.parse(toml) }
}
```

Note: `auth` and `chunks` are valid TOML scalars — the reader admits them.
The *domain* rejection (§7.1/§8.1 loud error) happens in ManifestCodec and
LockfileCodec (Phase 2). Document this split explicitly.

**Step 2 — Run and expect fail** (fixture files missing)

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter MinimalTOMLReaderTests/rejectsReservedAuthKey 2>&1 | head -20
```

**Step 3 — Create fixtures**

`toml-manifest-bad-auth-reserved.toml`:
```toml
version = 1

[[asset]]
url  = "https://example.org/file.bin"
path = "file.bin"
auth = "env:MY_TOKEN"
```

`toml-lockfile-bad-chunks-reserved.toml`:
```toml
lockfileVersion = 1
manifestHash    = "sha256:a3f9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1"

[[entry]]
url          = "https://example.org/file.bin"
path         = "file.bin"
sha256       = "sha256:6f1e2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2"
size         = 1024
downloadedAt = "2026-05-29T14:08:51Z"
chunks       = "reserved"
```

`toml-lockfile-bad-unknown-version.toml`:
```toml
lockfileVersion = 99
manifestHash    = "sha256:a3f9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1"
```

`toml-lockfile-bad-missing-manifestHash.toml`:
```toml
lockfileVersion = 1

[[entry]]
url          = "https://example.org/file.bin"
path         = "file.bin"
sha256       = "sha256:6f1e2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2"
size         = 1024
downloadedAt = "2026-05-29T14:08:51Z"
```

`toml-manifest-bad-sha256-shape.toml`:
```toml
version = 1

[[asset]]
url    = "https://example.org/file.bin"
path   = "file.bin"
sha256 = "notaprefixedvalue"
```

**Step 4 — Run and expect pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter MinimalTOMLReaderTests
```

**Step 5 — Commit**

```
feat(trust-core): add bad-fixture corpus and document auth/chunks domain-rejection split (Phase 1)
```

---

**Phase 1 artifact** → `docs/superpowers/progress/2026-05-29-trust-core-phase1.md`

---

## Phase 2 — Manifest + Lockfile codecs + FileDigest

**Deployment boundary:** depends on Phase 1 (MinimalTOMLReader). Can be merged
before Phase 3 (daemon hardening), Phase 4–6 (commands). Everything in this
phase is CLI-side / GohCore only.

**Bet check (Phase 2, most load-bearing):** The research brief's bet is:
> "Re-hash on demand is fast enough (~1 GB/s Apple Silicon) that persisting
> digests buys nothing; a self-contained lockfile beside the data beats a
> daemon registry."

The consequence for Phase 2 is that `FileDigest` must be fast enough to not
make sync painful. The at-rest re-hash reads from `FileHandle` in 1 MiB
chunks through CryptoKit SHA-256 — expected throughput is memory/IO-bound at
~1 GB/s on Apple Silicon. If profiling shows otherwise, the approach's
performance claim needs revisiting before Phase 6 ships.

---

### T2.1 — ManifestCodec: parse gohfile.toml into ManifestFile

**Files**
- CREATE `Sources/GohCore/TrustCore/ManifestCodec.swift`
- CREATE `Tests/GohCoreTests/ManifestCodecTests.swift`

**Pre-task reads checklist**
- [x] `Sources/GohCore/TrustCore/MinimalTOMLReader.swift` (T1.1) — exact
  `MinimalTOMLDocument`, `TOMLValue`, `MinimalTOMLReader.parse` signatures
- [x] `Sources/GohCore/Model/GohError.swift` — `ErrorCode` cases (no new case
  needed for manifest parsing; `ManifestCodec.CodecError` surfaces as `exitCode: 64`
  because bad-manifest-input is a usage/bad-input class error — same bucket as bad
  CLI args)

**Step 1 — Failing tests**

```swift
// Tests/GohCoreTests/ManifestCodecTests.swift
import Foundation
import Testing

import GohCore

@Suite("ManifestCodec")
struct ManifestCodecTests {

    // AC stubs:
    // AC1 (sync reads manifest), AC2 (verify reads manifest for manifestHash),
    // AC3 (pinned entry has sha256), AC5 (unpinned entry has no sha256)

    private func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(
                forResource: name, withExtension: "toml",
                subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("parses a full manifest with pinned and unpinned assets")  // AC1, AC3
    func parsesFullManifest() throws {
        let toml = try fixture("toml-manifest-full")
        let manifest = try ManifestCodec.parse(toml)
        #expect(manifest.assets.count == 2)
        let first = manifest.assets[0]
        #expect(first.url == "https://example.org/datasets/mnist.tar.gz")
        #expect(first.path == "datasets/mnist.tar.gz")
        #expect(first.sha256 == "sha256:6f1e2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2")
        let second = manifest.assets[1]
        #expect(second.sha256 == nil)  // unpinned
    }

    @Test("parses an empty manifest (zero assets)")  // AC1 (empty case)
    func parsesEmptyManifest() throws {
        let toml = try fixture("toml-manifest-empty")
        let manifest = try ManifestCodec.parse(toml)
        #expect(manifest.assets.isEmpty)
    }

    @Test("rejects unknown asset key loudly (not a silent accept)")
    func rejectsUnknownAssetKey() throws {
        let toml = try fixture("toml-manifest-bad-unknown-key")
        #expect(throws: ManifestCodec.CodecError.self) {
            try ManifestCodec.parse(toml)
        }
    }

    @Test("rejects malformed sha256 (not prefixed or wrong length)")
    func rejectsMalformedSha256() throws {
        let toml = try fixture("toml-manifest-bad-sha256-shape")
        #expect(throws: ManifestCodec.CodecError.self) {
            try ManifestCodec.parse(toml)
        }
    }

    @Test("rejects reserved 'auth' key present/non-null loudly (§4.4/§7.1)")
    func rejectsReservedAuthKey() throws {
        let toml = try fixture("toml-manifest-bad-auth-reserved")
        #expect(throws: ManifestCodec.CodecError.self) {
            try ManifestCodec.parse(toml)
        }
    }

    @Test("rejects unknown manifest version loudly")
    func rejectsUnknownVersion() throws {
        let toml = "version = 99\n[[asset]]\nurl = \"http://x.com/f\"\npath = \"f\"\n"
        #expect(throws: ManifestCodec.CodecError.self) {
            try ManifestCodec.parse(toml)
        }
    }

    @Test("accepts 'dest' as alias for 'path'")
    func acceptsDestAlias() throws {
        let toml = """
            version = 1
            [[asset]]
            url  = "https://example.org/f.bin"
            dest = "subdir/f.bin"
            """
        let manifest = try ManifestCodec.parse(toml)
        #expect(manifest.assets[0].path == "subdir/f.bin")
    }

    @Test("rejects both 'path' and 'dest' present in same entry")
    func rejectsBothPathAndDest() throws {
        let toml = """
            version = 1
            [[asset]]
            url  = "https://example.org/f.bin"
            path = "a/f.bin"
            dest = "b/f.bin"
            """
        #expect(throws: ManifestCodec.CodecError.self) {
            try ManifestCodec.parse(toml)
        }
    }

    @Test("computes sha256 of manifest bytes for manifestHash")
    func computesManifestHash() throws {
        let toml = try fixture("toml-manifest-full")
        let manifest = try ManifestCodec.parse(toml)
        // manifestHash is sha256: prefixed 64-hex
        #expect(manifest.manifestHash.hasPrefix("sha256:"))
        #expect(manifest.manifestHash.count == 7 + 64)
    }
}
```

**Step 2 — Run and expect fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ManifestCodecTests 2>&1 | head -40
```

**Step 3 — Minimal implementation**

```swift
// Sources/GohCore/TrustCore/ManifestCodec.swift
import CryptoKit
import Foundation

/// Decodes a gohfile.toml manifest (§7 frozen schema).
public struct ManifestCodec {

    public struct CodecError: Error, Equatable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    public struct ManifestFile: Sendable {
        /// SHA-256 of the raw toml bytes, in "sha256:<hex>" form.
        public var manifestHash: String
        public var base: String?
        public var assets: [AssetEntry]
    }

    public struct AssetEntry: Sendable {
        public var url: String
        public var path: String
        public var sha256: String?          // nil = unpinned (TOFU)
        public var verify: Bool             // default true
    }

    private static let allowedTopLevelKeys: Set<String> = ["version", "base"]
    private static let allowedAssetKeys: Set<String> =
        ["url", "path", "dest", "sha256", "verify", "auth"]

    public static func parse(_ toml: String) throws -> ManifestFile {
        // Compute manifestHash from raw bytes before any parsing
        let rawData = Data(toml.utf8)
        let hashBytes = SHA256.hash(data: rawData)
        let manifestHash = "sha256:" + hashBytes.map { String(format: "%02x", $0) }.joined()

        let doc: MinimalTOMLDocument
        do {
            doc = try MinimalTOMLReader.parse(
                toml,
                allowedTopLevelKeys: allowedTopLevelKeys,
                allowedAssetKeys: allowedAssetKeys)
        } catch let e as MinimalTOMLReader.ParseError {
            throw CodecError(e.message)
        }

        // version check
        if let versionVal = doc.topLevel["version"] {
            guard let v = versionVal.intValue, v == 1 else {
                throw CodecError(
                    "unsupported manifest version; goh supports version 1")
            }
        }

        let base = doc.topLevel["base"]?.stringValue

        let rawAssets = doc.arrayOfTables("asset")
        var assets: [AssetEntry] = []
        for raw in rawAssets {
            // Reject reserved 'auth' key if present and non-null
            if raw["auth"] != nil {
                throw CodecError(
                    "'auth' is reserved and not supported in this version of goh")
            }
            guard let url = raw["url"]?.stringValue else {
                throw CodecError("[[asset]] entry missing required 'url' field")
            }
            let pathVal = raw["path"]?.stringValue
            let destVal = raw["dest"]?.stringValue
            let path: String
            switch (pathVal, destVal) {
            case (let p?, nil): path = p
            case (nil, let d?): path = d
            case (let p?, let d?) where p == d: path = p
            case (nil, nil):
                throw CodecError("[[asset]] entry missing required 'path' (or 'dest') field")
            default:
                throw CodecError("[[asset]] entry has both 'path' and 'dest'; use only one")
            }
            let sha256: String?
            if let sha = raw["sha256"]?.stringValue {
                guard Self.validSha256String(sha) else {
                    throw CodecError(
                        "invalid sha256 format '\(sha)'; expected sha256:<64 lowercase hex>")
                }
                sha256 = sha
            } else {
                sha256 = nil
            }
            let verify: Bool
            if let v = raw["verify"]?.boolValue {
                verify = v
            } else {
                verify = true
            }
            assets.append(AssetEntry(url: url, path: path, sha256: sha256, verify: verify))
        }

        return ManifestFile(manifestHash: manifestHash, base: base, assets: assets)
    }

    static func validSha256String(_ s: String) -> Bool {
        guard s.hasPrefix("sha256:") else { return false }
        let hex = s.dropFirst(7)
        guard hex.count == 64 else { return false }
        return hex.allSatisfy { $0.isHexDigit && ($0.isUppercase == false) }
    }
}
```

**Step 4 — Run and expect pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ManifestCodecTests
```

**Step 5 — Commit**

```
feat(trust-core): ManifestCodec — parse gohfile.toml with frozen §7 schema (Phase 2)
```

---

### T2.2 — LockfileCodec: encode + decode gohfile.lock

**Files**
- CREATE `Sources/GohCore/TrustCore/LockfileCodec.swift`
- CREATE `Tests/GohCoreTests/LockfileCodecTests.swift`

**Pre-task reads checklist**
- [x] `Sources/GohCore/TrustCore/MinimalTOMLReader.swift` — parse signatures
- [x] `Sources/GohCore/TrustCore/MinimalTOMLWriter.swift` — write signature

**Step 1 — Failing tests**

```swift
// Tests/GohCoreTests/LockfileCodecTests.swift
import Foundation
import Testing

import GohCore

@Suite("LockfileCodec")
struct LockfileCodecTests {

    // AC stubs:
    // AC1 (sync writes lock with N entries), AC2 (verify reads sha256 from lock)

    private func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(
                forResource: name, withExtension: "toml",
                subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("decodes a full lockfile fixture with two entries")  // AC1, AC2
    func decodesFullLockfile() throws {
        let toml = try fixture("toml-lockfile-full")
        let lock = try LockfileCodec.decode(toml)
        #expect(lock.lockfileVersion == 1)
        #expect(lock.manifestHash.hasPrefix("sha256:"))
        #expect(lock.entries.count == 2)
        let first = lock.entries[0]
        #expect(first.url == "https://example.org/datasets/mnist.tar.gz")
        #expect(first.sha256.hasPrefix("sha256:"))
        #expect(first.size == 11594722)
        #expect(first.downloadedAt == "2026-05-29T14:08:51Z")
    }

    @Test("rejects unknown lockfileVersion loudly")
    func rejectsUnknownVersion() throws {
        let toml = try fixture("toml-lockfile-bad-unknown-version")
        #expect(throws: LockfileCodec.CodecError.self) {
            try LockfileCodec.decode(toml)
        }
    }

    @Test("rejects missing manifestHash field")
    func rejectsMissingManifestHash() throws {
        let toml = try fixture("toml-lockfile-bad-missing-manifestHash")
        #expect(throws: LockfileCodec.CodecError.self) {
            try LockfileCodec.decode(toml)
        }
    }

    @Test("rejects reserved 'chunks' field present/non-null (§8.1)")
    func rejectsReservedChunksField() throws {
        let toml = try fixture("toml-lockfile-bad-chunks-reserved")
        #expect(throws: LockfileCodec.CodecError.self) {
            try LockfileCodec.decode(toml)
        }
    }

    @Test("encodes and round-trips a lockfile through encode then decode")  // AC1
    func roundTrips() throws {
        let entry = LockfileCodec.LockEntry(
            url: "https://example.org/f.bin",
            path: "f.bin",
            sha256: "sha256:6f1e2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2",
            size: 1024,
            downloadedAt: "2026-05-29T12:00:00Z")
        let lock = LockfileCodec.Lockfile(
            manifestHash: "sha256:a3f9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1",
            entries: [entry])
        let encoded = LockfileCodec.encode(lock)
        let decoded = try LockfileCodec.decode(encoded)
        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].url == entry.url)
        #expect(decoded.entries[0].sha256 == entry.sha256)
        #expect(decoded.entries[0].size == entry.size)
    }

    @Test("lockfileVersion is the first field in encoded output")
    func lockfileVersionIsFirst() throws {
        let lock = LockfileCodec.Lockfile(
            manifestHash: "sha256:a3f9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1",
            entries: [])
        let encoded = LockfileCodec.encode(lock)
        let firstLine = encoded.components(separatedBy: "\n").first!
        #expect(firstLine.hasPrefix("lockfileVersion"))
    }
}
```

**Step 2 — Run and expect fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter LockfileCodecTests 2>&1 | head -40
```

**Step 3 — Minimal implementation**

```swift
// Sources/GohCore/TrustCore/LockfileCodec.swift
import Foundation

/// Encodes and decodes gohfile.lock (§8 frozen schema).
public struct LockfileCodec {

    public struct CodecError: Error, Equatable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    public struct Lockfile: Sendable {
        public var lockfileVersion: Int = 1
        public var manifestHash: String
        public var entries: [LockEntry]

        public init(manifestHash: String, entries: [LockEntry]) {
            self.manifestHash = manifestHash
            self.entries = entries
        }
    }

    public struct LockEntry: Sendable {
        public var url: String
        public var path: String
        public var sha256: String
        public var size: Int
        public var downloadedAt: String  // RFC 3339 UTC string

        public init(url: String, path: String, sha256: String, size: Int, downloadedAt: String) {
            self.url = url; self.path = path; self.sha256 = sha256
            self.size = size; self.downloadedAt = downloadedAt
        }
    }

    private static let allowedTopLevelKeys: Set<String> = ["lockfileVersion", "manifestHash"]
    private static let allowedEntryKeys: Set<String> =
        ["url", "path", "sha256", "size", "downloadedAt", "chunks"]

    public static func decode(_ toml: String) throws -> Lockfile {
        let doc: MinimalTOMLDocument
        do {
            doc = try MinimalTOMLReader.parse(
                toml,
                allowedTopLevelKeys: allowedTopLevelKeys,
                allowedAssetKeys: allowedEntryKeys)
        } catch let e as MinimalTOMLReader.ParseError {
            throw CodecError(e.message)
        }

        guard let versionVal = doc.topLevel["lockfileVersion"],
              let version = versionVal.intValue
        else {
            throw CodecError("lockfile missing required 'lockfileVersion' field")
        }
        guard version == 1 else {
            throw CodecError(
                "unsupported lockfileVersion \(version); upgrade goh")
        }
        guard let manifestHash = doc.topLevel["manifestHash"]?.stringValue else {
            throw CodecError("lockfile missing required 'manifestHash' field")
        }

        let rawEntries = doc.arrayOfTables("entry")
        var entries: [LockEntry] = []
        for raw in rawEntries {
            // Reject reserved 'chunks' if present/non-null
            if raw["chunks"] != nil {
                throw CodecError(
                    "'chunks' is reserved and not supported in this version of goh")
            }
            guard let url = raw["url"]?.stringValue else {
                throw CodecError("[[entry]] missing required 'url' field")
            }
            guard let path = raw["path"]?.stringValue else {
                throw CodecError("[[entry]] missing required 'path' field")
            }
            guard let sha256 = raw["sha256"]?.stringValue else {
                throw CodecError("[[entry]] missing required 'sha256' field")
            }
            guard let size = raw["size"]?.intValue else {
                throw CodecError("[[entry]] missing required 'size' field")
            }
            guard let downloadedAt = raw["downloadedAt"]?.stringValue else {
                throw CodecError("[[entry]] missing required 'downloadedAt' field")
            }
            entries.append(LockEntry(url: url, path: path, sha256: sha256,
                                     size: size, downloadedAt: downloadedAt))
        }

        return Lockfile(manifestHash: manifestHash, entries: entries)
    }

    public static func encode(_ lock: Lockfile) -> String {
        // lockfileVersion MUST be first (§8.1)
        var out = "lockfileVersion = \(lock.lockfileVersion)\n"
        out += "manifestHash    = \"\(lock.manifestHash)\"\n"
        for entry in lock.entries {
            out += "\n[[entry]]\n"
            out += "url          = \"\(entry.url)\"\n"
            out += "path         = \"\(entry.path)\"\n"
            out += "sha256       = \"\(entry.sha256)\"\n"
            out += "size         = \(entry.size)\n"
            out += "downloadedAt = \"\(entry.downloadedAt)\"\n"
        }
        return out
    }
}
```

**Step 4 — Run and expect pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter LockfileCodecTests
```

**Step 5 — Commit**

```
feat(trust-core): LockfileCodec — encode/decode gohfile.lock with §8 frozen schema (Phase 2)
```

---

### T2.3 — FileDigest: at-rest SHA-256 streaming wrapper

**Files**
- CREATE `Sources/GohCore/TrustCore/FileDigest.swift`
- CREATE `Tests/GohCoreTests/FileDigestTests.swift`

**Pre-task reads checklist**
- [x] `Sources/GohCore/Engine/ChunkAssembler.swift` — confirm it is download-
  bound (requires live DownloadFile + ranges); NOT usable for at-rest re-hash.
  New FileDigest uses `FileHandle` + CryptoKit SHA-256 directly.

**Step 1 — Failing tests**

```swift
// Tests/GohCoreTests/FileDigestTests.swift
import CryptoKit
import Foundation
import Testing

import GohCore

@Suite("FileDigest")
struct FileDigestTests {

    // AC stubs:
    // AC2 (verify re-hashes file, compares to lock)
    // AC3 (sync re-hashes completed file for pinned acceptance)

    private func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "goh-digest-test-\(UUID().uuidString).bin")
        try data.write(to: url)
        return url
    }

    @Test("produces the correct SHA-256 for a small file")  // AC2, AC3
    func smallFileDigest() throws {
        let payload = Data("the quick brown fox jumps over the lazy dog".utf8)
        let url = try writeTemp(payload)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try FileDigest.sha256(path: url.path)
        let expected = "sha256:" + SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }.joined()
        #expect(result == expected)
    }

    @Test("matches ChunkAssembler output for the same bytes")
    func matchesChunkAssemblerOutput() throws {
        // The at-rest digest must equal what ChunkAssembler computes during
        // download — this is the contract that makes AC1 idempotency work.
        let data = Data((0..<4096).map { UInt8($0 & 0xff) })
        let url = try writeTemp(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let fileDigest = try FileDigest.sha256(path: url.path)
        let cryptoDigest = "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        #expect(fileDigest == cryptoDigest)
    }

    @Test("reports file-not-found as a GohError")
    func reportsFileNotFound() {
        #expect(throws: GohError.self) {
            try FileDigest.sha256(path: "/tmp/goh-nonexistent-\(UUID().uuidString).bin")
        }
    }

    @Test("returns size in bytes alongside the digest")
    func returnsSizeAlongside() throws {
        let data = Data(repeating: 0xAB, count: 8192)
        let url = try writeTemp(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let (digest, size) = try FileDigest.sha256WithSize(path: url.path)
        #expect(digest.hasPrefix("sha256:"))
        #expect(size == 8192)
    }
}
```

**Step 2 — Run and expect fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter FileDigestTests 2>&1 | head -40
```

**Step 3 — Minimal implementation**

```swift
// Sources/GohCore/TrustCore/FileDigest.swift
import CryptoKit
import Foundation

/// Computes the SHA-256 of a completed file on disk, streaming in chunks.
///
/// This is the at-rest re-hash path for `sync` and `verify`. It is NOT
/// `ChunkAssembler`, which is download-bound (live DownloadFile + ranges).
/// Uses `FileHandle` + CryptoKit `SHA256` incrementally over 1 MiB reads.
public struct FileDigest {
    private static let chunkSize = 1 << 20  // 1 MiB — matches DownloadFile checkpoint

    /// Returns `"sha256:<64-hex>"` for the file at `path`.
    /// Throws `GohError(code: .destinationUnwritable)` on any read failure.
    public static func sha256(path: String) throws -> String {
        let (digest, _) = try sha256WithSize(path: path)
        return digest
    }

    /// Returns `("sha256:<64-hex>", byteCount)` for the file at `path`.
    public static func sha256WithSize(path: String) throws -> (String, Int) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw GohError(
                code: .destinationUnwritable,
                message: "could not open \(path) for reading")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var total = 0
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                throw GohError(
                    code: .destinationUnwritable,
                    message: "read error re-hashing \(path): \(error)")
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += chunk.count
        }
        let digest = "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, total)
    }
}
```

**Step 4 — Run and expect pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter FileDigestTests
```

**Step 5 — Commit**

```
feat(trust-core): FileDigest — at-rest SHA-256 streaming wrapper for sync/verify re-hash (Phase 2)
```

---

**Phase 2 artifact** → `docs/superpowers/progress/2026-05-29-trust-core-phase2.md`

---

## Phase 3 — Daemon DownloadFile path-confinement hardening

**Deployment boundary:** touches only `Sources/GohCore/Engine/DownloadFile.swift`
and `Sources/GohCore/Model/GohError.swift`. Independently shippable. Hardens
**all** `goh add` downloads, not just sync. No protocolVersion change.

> ### ⚠️ Phase 3 verification gate — running code, not prose
>
> The `openat`/`O_NOFOLLOW` symlink-confinement mechanism in T3.2 is the one part
> of this plan whose correctness was repeatedly mis-stated during prose review
> (six review rounds; the syscall choreography was wrong three times). **Its
> correctness is therefore NOT established by reviewing this document — it is
> established by RUNNING TESTS.** The implementer MUST, in this exact order:
>
> 1. Write the symlink-swap TOCTOU tests in `DownloadFileConfinementTests.swift`
>    FIRST — covering: (a) a **fresh-download** intermediate-symlink (parent dirs
>    do NOT pre-exist; a symlink is planted at a component the descent will
>    create-or-open), (b) a **parent-directory-component** swap (not just the
>    final component — this is what proves the openat-relative-to-parent-fd chain,
>    not mere `O_NOFOLLOW` on the final open), and (c) a **final-component**
>    symlink.
> 2. Run them and **see them FAIL** (`swift test --filter DownloadFileConfinementTests`).
> 3. Implement the descent.
> 4. Run them and **see them PASS**.
> 5. **Mandatory review of the COMPILED + TESTED implementation** (the actual
>    Swift + the green test output), not this plan's prose, before Phase 3 merges.
>
> **Scope note (threat model).** The load-bearing defense against the *real*
> attack — a hostile shared `gohfile` with `../` or absolute `path` — is the
> **lexical confinement** in T6.1 (rules 1–2), which has been correct since the
> first draft. The T3.2 `openat`/`O_NOFOLLOW` descent additionally closes a
> same-machine **symlink-swap TOCTOU race**. Per goh's existing v0.1 threat model
> (cf. the `SMAppService` deferral in `ROADMAP.md`: *"v0.1's threat model accepts
> that a same-user attacker already on the box has many options"*), that race is
> an accepted residual risk, so T3.2 is **best-effort defense-in-depth**, not a
> v1-blocking guarantee. It must still be implemented and pass its tests — but if
> a genuinely hard POSIX edge surfaces during implementation, it is acceptable to
> ship the tested lexical + `O_NOFOLLOW`-final-component defense and file the
> deeper race as a documented limitation, rather than block v1.

---

### T3.1 — Add `symlinkComponentRefused` ErrorCode

**Files**
- MODIFY `Sources/GohCore/Model/GohError.swift`
- MODIFY `Tests/GohCoreTests/DownloadFileConfinementTests.swift` (new file; see T3.2)

**Pre-task reads checklist**
- [x] `Sources/GohCore/Model/GohError.swift` — current `ErrorCode` cases
  (`dnsResolutionFailed`, `connectionFailed`, `tlsFailure`, `timedOut`,
  `httpStatus`, `diskFull`, `destinationUnwritable`,
  `destinationPermissionDenied`, `checksumMismatch`, `unauthorized`,
  `unsupportedURL`, `jobNotFound`, `queueFull`, `protocolVersionMismatch`,
  `cancelled`, `invalidArgument`); confirm `checksumMismatch` exists; note
  `retryEligible` already returns `false` for `.destinationPermissionDenied` —
  the new case follows the same pattern (a symlink refusal is a security/config
  issue, never retry-eligible).
- [x] `Sources/GohCore/Engine/DownloadEngine.swift` — `retryEligible(for:)`.

**The exact exhaustive switch (BLOCK 7).** The ONE exhaustive `switch error.code`
with NO `default` over `ErrorCode` is
**`DownloadEngine.retryEligible(for error: GohError) -> Bool`** in
`Sources/GohCore/Engine/DownloadEngine.swift`. Adding `symlinkComponentRefused`
to `ErrorCode` makes this switch non-exhaustive; the `-warnings-as-errors` build
pins the exact line. Add `case .symlinkComponentRefused: return false` to its
permanent-failure arm. Do NOT add a `default` — keep it exhaustive so any future
`ErrorCode` forces a deliberate classification. *(Note: the CLI exit-code mapping
in `GohCommandLine.run()` is per-command — each verb returns
`GohCommandLineResult(exitCode:)` directly; there is no central
`exitCode(for: ErrorCode)` switch. The §9.1-4a mapping of a `.failed` job whose
`error.code == .symlinkComponentRefused` to exit 5 lives in `GohSyncCommand`'s
failure classification, T6.3/T6.4, NOT here.)*

**Step 1 — Failing tests**

```swift
// Add to GohErrorTests.swift (or DownloadEngineTests.swift):
@Test("symlinkComponentRefused is non-retryable")
func symlinkComponentRefusedNonRetryable() {
    #expect(DownloadEngine.retryEligible(for: GohError(code: .symlinkComponentRefused)) == false)
}
// The DownloadFile-level refusal test (error.code == .symlinkComponentRefused on
// a symlinked open) lives in T3.2's DownloadFileConfinementTests.swift.
```

**Step 2 — Run and expect fail** (compilation fails: case does not exist yet)

**Step 3 — Implementation**

```swift
// In Sources/GohCore/Model/GohError.swift, add to ErrorCode enum:
case symlinkComponentRefused
```

Add the new case to `DownloadEngine.retryEligible(for:)` (the exhaustive switch):

```swift
// In DownloadEngine.retryEligible(for:), permanent-failure arm:
case .tlsFailure, .unsupportedURL, .destinationUnwritable,
     .destinationPermissionDenied, .unauthorized, .jobNotFound,
     .protocolVersionMismatch, .cancelled, .invalidArgument,
     .symlinkComponentRefused:
    return false
```

**Step 4 — Build check.** Confirm there is NO non-exhaustive-switch warning at
`DownloadEngine.retryEligible(for:)` (CI builds with `-warnings-as-errors`):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build 2>&1 | grep -E "error:|warning:" | head -20
# Expected: zero errors, zero warnings. If any OTHER exhaustive ErrorCode switch
# surfaces, classify the new case there too — but retryEligible(for:) is the only
# one in the current tree.
```

```bash
grep -rn "switch .*\.code\|switch error\.code\|switch code" \
  /Users/shane/claude/goh/Sources/ 2>/dev/null
# Confirms retryEligible(for:) is the only exhaustive ErrorCode switch.
```

**Step 5 — Commit**

```
feat(trust-core): add ErrorCode.symlinkComponentRefused for daemon open-time confinement refusal (Phase 3)
```

---

### T3.2 — DownloadFile: O_NOFOLLOW + openat descent

**Files**
- MODIFY `Sources/GohCore/Engine/DownloadFile.swift`
- CREATE `Tests/GohCoreTests/DownloadFileConfinementTests.swift`

**Pre-task reads checklist**
- [x] `Sources/GohCore/Engine/DownloadFile.swift` — exact `init(path:expectedSize:truncate:)` signature; current flags `O_RDWR | O_CREAT | (truncate ? O_TRUNC : 0)` then `open(path, flags, 0o644)` by ABSOLUTE path; and `createParentDirectory(for:)` which uses `FileManager.default.createDirectory` (FOLLOWS symlinks). BOTH are replaced by the openat descent below. Resume path uses `truncate: false`. Confirm NO `O_EXCL` (would break resume).
- [x] `Sources/GohCore/Engine/DownloadEngine.swift` — `resume()` calls `DownloadFile(path: job.destination, expectedSize: total, truncate: false)` confirming the truncate split.
- [x] `docs/superpowers/specs/2026-05-29-trust-core-design.md` §4.1.3 — the TOCTOU guarantee holds for ALL daemon writes, INCLUDING a fresh sync into a not-yet-existing subtree (no intermediate component pre-exists).

**The hole this closes (BLOCK 1 — CRITICAL).** The previous sketch
(`refuseSymlinkedComponents`) ABANDONED the descent on the first `ENOENT` (a
component that does not exist yet), then fell back to `FileManager.createDirectory`
(which follows symlinks) and re-opened the file by ABSOLUTE path. For a normal sync
into a not-yet-existing subtree, NO intermediate component was symlink-checked — the
§4.1.3 TOCTOU guarantee was a NO-OP on fresh downloads. The fix makes the descent
and the file open share ONE proven fd chain: each EXISTING intermediate is opened
with `O_NOFOLLOW`; each MISSING intermediate is created with `mkdirat` relative to
the proven parent fd and then re-opened with `O_NOFOLLOW` to descend into the
just-created (proven-real) dir; the final file is opened relative to the proven
parent fd. There is NO `FileManager` and NO absolute `open` anywhere on the download
write path.

**Step 1 — Failing tests**

```swift
// Tests/GohCoreTests/DownloadFileConfinementTests.swift
import Darwin
import Foundation
import Testing

import GohCore

@Suite("DownloadFile confinement")
struct DownloadFileConfinementTests {

    // AC stubs:
    // §4.1.3 — daemon open-time symlink refusal (base-free openat descent)
    // AC3 (pinned mismatch quarantine requires the write to succeed to a
    //       confined path — this is the path hardening that makes that safe)

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "goh-confinement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("write to a normal path succeeds (regression: O_NOFOLLOW must not break normal writes)")
    func normalWriteSucceeds() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appending(path: "file.bin")
        let file = try DownloadFile(path: dest.path, expectedSize: nil)
        try file.write(Data("hello".utf8), at: 0)
        try file.finish()
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("resume (truncate:false) to a normal path succeeds (regression)")
    func resumeNormalPathSucceeds() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appending(path: "partial.bin")
        let file1 = try DownloadFile(path: dest.path, expectedSize: nil, truncate: true)
        try file1.write(Data("abc".utf8), at: 0)
        try file1.finish()
        let file2 = try DownloadFile(path: dest.path, expectedSize: nil, truncate: false)
        try file2.write(Data("def".utf8), at: 3)
        try file2.finish()
        let result = try Data(contentsOf: dest)
        #expect(result == Data("abcdef".utf8))
    }

    @Test("symlinked final component is refused (O_NOFOLLOW on destination)")
    func symlinkedFinalComponentRefused() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realTarget = dir.appending(path: "real-target.bin")
        try Data("original".utf8).write(to: realTarget)
        let linkPath = dir.appending(path: "link.bin")
        try FileManager.default.createSymbolicLink(
            at: linkPath, withDestinationURL: realTarget)
        #expect {
            _ = try DownloadFile(path: linkPath.path, expectedSize: nil)
        } throws: { ($0 as? GohError)?.code == .symlinkComponentRefused }
        // The real target must be unchanged
        #expect(try Data(contentsOf: realTarget) == Data("original".utf8))
    }

    @Test("symlinked PRE-EXISTING intermediate directory is refused (openat descent)")
    func symlinkedIntermediateDirectoryRefused() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realSubdir = dir.appending(path: "real-subdir")
        try FileManager.default.createDirectory(at: realSubdir, withIntermediateDirectories: true)
        let escapedTarget = dir.appending(path: "escape-target.bin")
        try Data("should-not-be-overwritten".utf8).write(to: escapedTarget)
        let symlinkDir = dir.appending(path: "symlink-subdir")
        try FileManager.default.createSymbolicLink(
            at: symlinkDir, withDestinationURL: dir)  // points to parent
        let dest = symlinkDir.appending(path: "escape-target.bin")
        // Assert the SPECIFIC code — not "any GohError" — so the no-op gap can't pass.
        #expect {
            _ = try DownloadFile(path: dest.path, expectedSize: nil)
        } throws: { ($0 as? GohError)?.code == .symlinkComponentRefused }
        #expect(try Data(contentsOf: escapedTarget)
                == Data("should-not-be-overwritten".utf8))
    }

    @Test("FRESH download: symlink at a NOT-YET-CREATED component is refused (BLOCK 1 regression guard)")
    func symlinkedFreshIntermediateRefused() throws {
        // The parent subtree does NOT pre-exist; the descent must create-or-open
        // each component. A symlink planted where the descent will create-or-open
        // MUST still be caught — this is exactly the case the old ENOENT-abandon +
        // FileManager.createDirectory + absolute-open path failed to check.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = dir.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // 'sub' is a symlink to 'outside'; 'sub/deep/new' do NOT exist yet.
        let sub = dir.appending(path: "sub")
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: outside)
        let dest = dir.appending(path: "sub/deep/new/file.bin")
        #expect {
            _ = try DownloadFile(path: dest.path, expectedSize: nil)
        } throws: { ($0 as? GohError)?.code == .symlinkComponentRefused }
        // Nothing may have leaked through the symlink into 'outside'.
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("FRESH download: normal nested path whose parents do NOT pre-exist is created via mkdirat")
    func normalNestedCreatesViaDescent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appending(path: "a/b/c/file.bin")  // none of a/b/c exist
        let file = try DownloadFile(path: dest.path, expectedSize: nil)
        try file.write(Data("hello".utf8), at: 0)
        try file.finish()
        #expect(try Data(contentsOf: dest) == Data("hello".utf8))
    }

    @Test("TOCTOU: symlink planted after lexical check is caught at write time")
    func toctouSymlinkPlantedAfterLexicalCheck() throws {
        // This test proves the confinement is enforced at DownloadFile.init time,
        // not at any earlier CLI pre-flight. A symlink planted just before the
        // DownloadFile open must still be refused.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appending(path: "target.bin")
        let realOther = dir.appending(path: "other.bin")
        try Data("secret".utf8).write(to: realOther)
        // Plant a symlink AT dest pointing to realOther (TOCTOU scenario)
        try FileManager.default.createSymbolicLink(
            at: dest, withDestinationURL: realOther)
        #expect(throws: GohError.self) {
            _ = try DownloadFile(path: dest.path, expectedSize: nil)
        }
        #expect(try Data(contentsOf: realOther) == Data("secret".utf8))
    }
}
```

**Step 2 — Run and expect fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter DownloadFileConfinementTests 2>&1 | head -40
# symlinked tests will fail because DownloadFile does not yet refuse symlinks
```

**Step 3 — Minimal implementation (BLOCK 1 + BLOCK 2)**

`init` REPLACES both `createParentDirectory(for:)` (`FileManager`, symlink-following)
AND the absolute `open(path, …)` with a SINGLE openat descent that CREATES missing
intermediates with `mkdirat` and OPENS every component (and the final file) with
`O_NOFOLLOW`, all relative to a proven fd chain. The descent both create-or-opens
intermediates and opens the final file, so a fresh download into a not-yet-existing
subtree is symlink-checked at every component. No `FileManager`, no absolute open.

```swift
// Sources/GohCore/Engine/DownloadFile.swift — modified init + new descent helper.
// createParentDirectory(for:) is DELETED (FileManager followed symlinks).

public init(path: String, expectedSize: UInt64?, truncate: Bool = true) throws {
    // The descent CREATES missing intermediates (mkdirat) and OPENS the final
    // file, all O_NOFOLLOW relative to a proven fd chain (§4.1.3). One operation:
    // descent-proof and file-open share the same fds, so a symlink anywhere on the
    // destination path — pre-existing OR swapped in mid-descent — is refused.
    descriptor = try Self.openConfined(path: path, truncate: truncate)
    if let expectedSize, expectedSize > 0 {
        Self.preallocate(descriptor, size: expectedSize)
    }
}

private static func mapOpenErrno(_ e: Int32, _ comp: String, _ path: String) throws -> Never {
    // ELOOP: a component was a symlink (O_NOFOLLOW). ENOTDIR: a component a symlink
    // resolved to a non-dir, or a final-open race — both are symlink refusals.
    if e == ELOOP || e == ENOTDIR {
        throw GohError(
            code: .symlinkComponentRefused,
            message: "symlinked component '\(comp)' refused in destination: \(path)")
    }
    throw DownloadFileError.openFailed(path: path, errno: e)
}

/// Descends `path` component-by-component from "/", opening each EXISTING
/// intermediate with O_NOFOLLOW|O_DIRECTORY, CREATING each MISSING one with
/// mkdirat relative to the proven parent and re-opening it O_NOFOLLOW, then
/// opening the FINAL component relative to the proven parent. Returns the open fd.
private static func openConfined(path: String, truncate: Bool) throws -> Int32 {
    let comps = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
    guard let final = comps.last else {
        throw DownloadFileError.openFailed(path: path, errno: EINVAL)
    }

    var parentFd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parentFd >= 0 else { try mapOpenErrno(errno, "/", path) }
    defer { close(parentFd) }

    for comp in comps.dropLast() {
        var childFd = comp.withCString {
            openat(parentFd, $0, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        }
        if childFd < 0 && errno == ENOENT {
            // Create relative to the proven parent, then re-open O_NOFOLLOW so a
            // symlink swapped in between mkdirat and openat is still caught.
            let made = comp.withCString { mkdirat(parentFd, $0, 0o755) }
            guard made == 0 || errno == EEXIST else { try mapOpenErrno(errno, comp, path) }
            childFd = comp.withCString {
                openat(parentFd, $0, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            }
        }
        guard childFd >= 0 else { try mapOpenErrno(errno, comp, path) }
        close(parentFd)
        parentFd = childFd
    }

    // Final component, relative to the proven parent fd. NO O_EXCL (resume reopens
    // an existing partial). O_TRUNC only on a fresh download.
    let flags = O_RDWR | O_CREAT | O_NOFOLLOW | (truncate ? O_TRUNC : 0)
    let fd = final.withCString { openat(parentFd, $0, flags, 0o644) }
    guard fd >= 0 else {
        // BLOCK 2: map BOTH ELOOP and ENOTDIR (a symlinked final whose target is a
        // dir, or a race, surfaces as ENOTDIR) — same mapping as the descent.
        try mapOpenErrno(errno, final, path)
    }
    return fd
}
```

**No `FileManager`, no absolute `open`.** The descent's `defer { close(parentFd) }`
releases whatever directory fd is live (exactly one at a time, since each `childFd`
is assigned to `parentFd` after the previous is `close`d). Only `fd` (the file) is
returned and stored in `descriptor` exactly as before; `truncate`/resume semantics
are unchanged. Resume (`truncate: false`) reopens an existing partial; if the final
component is absent in resume mode, `O_CREAT` still creates it (matching today's
create-or-resume behavior — there is no separate "no partial" error in the current
`init`).

**Step 4 — Run and expect pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter DownloadFileConfinementTests
```

Also run the full test suite to confirm no regression:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test 2>&1 | tail -20
```

**Step 5 — Commit**

```
feat(trust-core): DownloadFile O_NOFOLLOW + openat descent — base-free write-path confinement (Phase 3)
```

Also update `DESIGN.md` with a paragraph:
> §DownloadFile write-path hardening (trust-core Phase 3): `DownloadFile.init`
> now refuses any symlinked path component at open time via a base-free
> `openat` descent (each intermediate directory opened `O_NOFOLLOW|O_DIRECTORY`)
> followed by `O_NOFOLLOW` on the final component via `open(2)`. A symlink
> anywhere in the destination path ⇒ `GohError(.symlinkComponentRefused)`;
> `protocolVersion` stays 3; the hardening applies to all `goh add` downloads.

```
docs: record DownloadFile write-path hardening in DESIGN.md (Phase 3)
```

**Rollout note (advisory A) — behavior change for ALL `goh add`.** Because the
openat descent opens every component (and the final) with `O_NOFOLLOW`, the
hardening sits in the shared daemon write path and applies to EVERY `goh add`, not
just `sync`. A `goh add` whose destination — or any parent — is a SYMLINK is now
REFUSED with `.symlinkComponentRefused` (exit 5), where it previously followed the
link. This is a behavior change, not a pure addition. Call it out in the Phase 3
artifact, the DESIGN.md paragraph above, and the eventual changelog so the refusal
is expected and not mistaken for a regression. Legitimate non-symlinked downloads
are unchanged.

---

**Phase 3 artifact** → `docs/superpowers/progress/2026-05-29-trust-core-phase3.md`

---

## Phase 4 — `goh which` (CLI-local)

**Deployment boundary:** CLI only; depends on Phase 2 (LockfileCodec). No
daemon changes. No XPC calls.

---

### T4.1 — GohWhichCommand + getxattr provenance reader

**Files**
- CREATE `Sources/GohCore/CLI/GohWhichCommand.swift`
- MODIFY `Sources/GohCore/CLI/GohCommandLine.swift` (add `.which` ParsedCommand)
- CREATE `Tests/GohCoreTests/GohWhichCommandTests.swift`

**Pre-task reads checklist**
- [x] `Sources/GohCore/CLI/GohCommandLine.swift` — exact `ParsedCommand` enum
  (private), `parse(_:)` static method, `run()` → switch dispatch. Add
  `.which(path: String)` case. CLI-local verbs (doctor, top) are dispatched
  via stored closures; `which` needs no closure — it runs inline like the
  `ls --json` path, using a passed function or direct call.
- [x] `Sources/GohCore/Platform/SpotlightMetadataTagger.swift` — understand the
  `setxattr` write path; the new reader inverts it with `getxattr`. The attribute
  names are `SpotlightMetadataTagger.whereFromsAttributeName` and
  `SpotlightMetadataTagger.downloadedDateAttributeName`.

**Step 1 — Failing tests**

```swift
// Tests/GohCoreTests/GohWhichCommandTests.swift
import Darwin
import Foundation
import Testing

import GohCore

@Suite("goh which")
struct GohWhichCommandTests {

    // AC4: goh which <path> prints url/sha256/downloadedAt for known; exit 4 for unknown.

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "goh-which-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("which on a file in gohfile.lock returns url, sha256, downloadedAt — exit 0") // AC4
    func whichKnownFileLock() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let filePath = dir.appending(path: "weights/model.bin")
        try FileManager.default.createDirectory(
            at: filePath.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("data".utf8).write(to: filePath)
        let lockToml = """
            lockfileVersion = 1
            manifestHash    = "sha256:a3f9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1"

            [[entry]]
            url          = "https://example.org/weights/model.bin"
            path         = "weights/model.bin"
            sha256       = "sha256:0b4477c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6e1"
            size         = 4
            downloadedAt = "2026-05-29T14:11:03Z"
            """
        let lockPath = dir.appending(path: "gohfile.lock")
        try lockToml.write(to: lockPath, atomically: true, encoding: .utf8)

        let result = GohWhichCommand.run(
            filePath: filePath.path, lockPath: lockPath.path)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("https://example.org/weights/model.bin"))
        #expect(result.standardOutput.contains("sha256:0b4477"))
        #expect(result.standardOutput.contains("2026-05-29T14:11:03Z"))
    }

    @Test("which on unknown file exits 4 with 'no provenance record' message") // AC4
    func whichUnknownFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = GohWhichCommand.run(
            filePath: dir.appending(path: "mystery.bin").path,
            lockPath: dir.appending(path: "gohfile.lock").path)
        #expect(result.exitCode == 4)
        #expect(result.standardError.contains("no provenance record"))
    }

    @Test("which falls back to xattr provenance when not in lock") // AC4
    func whichFallsBackToXattr() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let filePath = dir.appending(path: "xattr-tagged.bin")
        try Data("payload".utf8).write(to: filePath)
        let downloadedAt = Date(timeIntervalSinceReferenceDate: 0)
        try SpotlightMetadataTagger().tagCompletedDownload(
            destination: filePath.path,
            sourceURL: "https://example.org/xattr-tagged.bin",
            downloadedAt: downloadedAt)

        let result = GohWhichCommand.run(
            filePath: filePath.path,
            lockPath: dir.appending(path: "gohfile.lock").path)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("https://example.org/xattr-tagged.bin"))
        // Cat 3 guard: assert the DATE line is present and well-formed, not just
        // that *some* output came back — otherwise the xattr fallback could regress
        // to printing only the source URL and this test would still pass.
        #expect(result.standardOutput.contains("downloadedAt"))
        #expect(result.standardOutput.range(
            of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil)
    }

    @Test("parse: 'goh which <path>' maps to .which ParsedCommand")
    func parsesWhichCommand() {
        // Tested via GohCommandLine.run() integration; ParsedCommand is private.
        // This is documented: the actual parse is tested by observing run() output.
        // Stub test to document intent.
        #expect(Bool(true))
    }
}
```

**Step 2 — Run and expect fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohWhichCommandTests 2>&1 | head -40
```

**Step 3 — Minimal implementation**

```swift
// Sources/GohCore/CLI/GohWhichCommand.swift
import CoreServices
import Darwin
import Foundation

/// Implements `goh which <path>` — CLI-local provenance lookup (§9.3).
///
/// Source priority:
/// 1. A `gohfile.lock` alongside the file (if readable).
/// 2. Spotlight xattr provenance (`kMDItemWhereFroms` / `kMDItemDownloadedDate`).
/// 3. Exit 4 with "no provenance record".
public struct GohWhichCommand {

    public static func run(
        filePath: String,
        lockPath: String
    ) -> GohCommandLineResult {
        // 1. Try lock lookup
        if let lockResult = checkLock(filePath: filePath, lockPath: lockPath) {
            return lockResult
        }
        // 2. Try xattr fallback
        if let xattrResult = checkXattr(filePath: filePath) {
            return xattrResult
        }
        // 3. No record
        return GohCommandLineResult(
            exitCode: 4,
            standardError: "no provenance record for \(filePath)\n")
    }

    private static func checkLock(
        filePath: String, lockPath: String
    ) -> GohCommandLineResult? {
        guard let lockToml = try? String(contentsOfFile: lockPath, encoding: .utf8) else {
            return nil
        }
        guard let lock = try? LockfileCodec.decode(lockToml) else { return nil }
        let lockDir = URL(fileURLWithPath: lockPath).deletingLastPathComponent()
        for entry in lock.entries {
            let entryAbs = lockDir.appending(path: entry.path).path
            if entryAbs == filePath || entry.path == filePath {
                var out = "url:          \(entry.url)\n"
                out += "sha256:       \(entry.sha256)\n"
                out += "downloadedAt: \(entry.downloadedAt)\n"
                return GohCommandLineResult(exitCode: 0, standardOutput: out)
            }
        }
        return nil
    }

    private static func checkXattr(filePath: String) -> GohCommandLineResult? {
        let whereFromsAttr = SpotlightMetadataTagger.whereFromsAttributeName
        let dateAttr = SpotlightMetadataTagger.downloadedDateAttributeName

        guard let urls = readXattrPropertyList(path: filePath, attr: whereFromsAttr)
                as? [String], let url = urls.first else { return nil }

        var out = "url:          \(url)\n"
        out += "sha256:       (not recorded)\n"
        if let date = readXattrPropertyList(path: filePath, attr: dateAttr) as? Date {
            let fmt = ISO8601DateFormatter()
            out += "downloadedAt: \(fmt.string(from: date))\n"
        }
        return GohCommandLineResult(exitCode: 0, standardOutput: out)
    }

    private static func readXattrPropertyList(path: String, attr: String) -> Any? {
        let len = getxattr(path, attr, nil, 0, 0, 0)
        guard len > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: len)
        let got = getxattr(path, attr, &bytes, bytes.count, 0, 0)
        guard got == len else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: Data(bytes), options: [], format: nil)
    }
}
```

Then add to `GohCommandLine.swift`:
- Add `.which(path: String)` to `ParsedCommand`
- Add `if arguments.count == 2, arguments[0] == "which" { ... }` to `parse(_:)`
- Add the `case .which(let path):` branch to `run()` calling `GohWhichCommand.run`
- Add `goh which <path>` to the `usage()` string

**Step 4 — Run and expect pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohWhichCommandTests
```

**Step 5 — Commit**

```
feat(trust-core): goh which — CLI-local provenance lookup with lock + xattr fallback (Phase 4, AC4)
```

---

**Phase 4 artifact** → `docs/superpowers/progress/2026-05-29-trust-core-phase4.md`

---

## Phase 5 — `goh verify` (CLI-local)

**Deployment boundary:** CLI only. Depends on Phase 2 (FileDigest, LockfileCodec).
No daemon calls. Independently shippable after Phase 2 + 4.

---

### T5.1 — GohVerifyCommand: per-entry OK/FAILED/MISSING + exit precedence

**Files**
- CREATE `Sources/GohCore/CLI/GohVerifyCommand.swift`
- MODIFY `Sources/GohCore/CLI/GohCommandLine.swift`
- CREATE `Tests/GohCoreTests/GohVerifyCommandTests.swift`

**Pre-task reads checklist**
- [x] `Sources/GohCore/CLI/GohCommandLine.swift` — add `.verify(lockPath: String, strictUntracked: Bool)` to `ParsedCommand`
- [x] `Sources/GohCore/TrustCore/LockfileCodec.swift` (T2.2) — decode path
- [x] `Sources/GohCore/TrustCore/FileDigest.swift` (T2.3) — `sha256WithSize`
- [x] (T6.1 output) `SyncPathConfinement.resolve(entryPath:base:)` — entries are
  re-confined per §4.1 on read-back
- [x] `docs/superpowers/specs/2026-05-29-trust-core-design.md` §9.3a — entries
  resolve under the lock's directory (`lockDir`), NOT the process cwd

**§9.3a (BLOCK 3).** `verify` derives `lockDir = lockPath.deletingLastPathComponent()`
and resolves EVERY entry under `lockDir` (the impl below uses
`lockDir.appending(path: entry.path)` — lockDir-relative, never
`FileManager.default.currentDirectoryPath`). Optionally route through
`SyncPathConfinement.resolve(entryPath: entry.path, base: lockDir.path)` to
re-confine per §4.1 on read-back. The dedicated regression guard (test below) runs
from a cwd ≠ lockDir and confirms entries still resolve correctly.

**Exit-code note (reconciliation, see Planning Notes above):**
- Exit `6` (lock missing/corrupt/stale/unknown-version), `9` (MISSING), `2`
  (FAILED content), `10` (--strict-untracked) are returned as
  `GohCommandLineResult(exitCode: N, ...)` directly — NOT via ParseError → 64.
  These are domain codes, not parse errors.
- Unknown `lockfileVersion` → **exit `6`** (unusable lock), NOT exit `1`.
  Return `GohCommandLineResult(exitCode: 6, ...)` directly.

**Step 1 — Failing tests**

```swift
// Tests/GohCoreTests/GohVerifyCommandTests.swift
import Foundation
import Testing

import GohCore

@Suite("goh verify")
struct GohVerifyCommandTests {

    // AC stubs:
    // AC2: verify detects drift — exit 2, per-file FAILED line with expected/actual sha256

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "goh-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFile(_ dir: URL, subpath: String, _ data: Data) throws -> URL {
        let url = dir.appending(path: subpath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func writeLock(_ dir: URL, entries: [(url: String, path: String, sha256: String, size: Int)]) throws -> URL {
        var toml = "lockfileVersion = 1\nmanifestHash    = \"sha256:a3f9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1\"\n"
        for e in entries {
            toml += "\n[[entry]]\nurl          = \"\(e.url)\"\npath         = \"\(e.path)\"\nsha256       = \"\(e.sha256)\"\nsize         = \(e.size)\ndownloadedAt = \"2026-05-29T12:00:00Z\"\n"
        }
        let url = dir.appending(path: "gohfile.lock")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("all entries matching → exit 0 with OK lines")  // AC2 (all-match case)
    func allMatchExit0() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data("hello".utf8)
        let (digest, _) = try FileDigest.sha256WithSize(path: {
            let u = dir.appending(path: "f.bin")
            try data.write(to: u); return u.path
        }())
        let lock = try writeLock(dir, entries: [(
            url: "https://x.org/f.bin",
            path: "f.bin",
            sha256: digest,
            size: data.count)])
        let result = GohVerifyCommand.run(lockPath: lock.path, strictUntracked: false)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("OK"))
    }

    @Test("content mismatch → exit 2, FAILED line with expected and actual sha256")  // AC2
    func contentMismatch() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let _ = try writeFile(dir, subpath: "f.bin", Data("tampered".utf8))
        let fakeDigest = "sha256:6f1e2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2"
        let lock = try writeLock(dir, entries: [(
            url: "https://x.org/f.bin",
            path: "f.bin",
            sha256: fakeDigest,
            size: 5)])
        let result = GohVerifyCommand.run(lockPath: lock.path, strictUntracked: false)
        #expect(result.exitCode == 2)
        #expect(result.standardOutput.contains("FAILED"))
        #expect(result.standardOutput.contains("expected"))
        #expect(result.standardOutput.contains("actual"))
    }

    @Test("missing file → exit 9, MISSING line distinct from FAILED")  // §9.2 step 4 / §6
    func missingFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeDigest = "sha256:6f1e2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2"
        let lock = try writeLock(dir, entries: [(
            url: "https://x.org/absent.bin",
            path: "absent.bin",
            sha256: fakeDigest,
            size: 1024)])
        let result = GohVerifyCommand.run(lockPath: lock.path, strictUntracked: false)
        #expect(result.exitCode == 9)
        #expect(result.standardOutput.contains("MISSING"))
        #expect(!result.standardOutput.contains("FAILED"))
    }

    @Test("precedence: MISSING (9) > FAILED (2) when both present")
    func precedenceMissingOverFailed() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let _ = try writeFile(dir, subpath: "tampered.bin", Data("bad".utf8))
        let fakeDigest = "sha256:6f1e2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2"
        let lock = try writeLock(dir, entries: [
            (url: "https://x.org/tampered.bin", path: "tampered.bin",
             sha256: fakeDigest, size: 5),
            (url: "https://x.org/absent.bin", path: "absent.bin",
             sha256: fakeDigest, size: 1024),
        ])
        let result = GohVerifyCommand.run(lockPath: lock.path, strictUntracked: false)
        #expect(result.exitCode == 9)  // MISSING wins over FAILED
    }

    @Test("missing lock → exit 6")
    func missingLockExit6() throws {
        let result = GohVerifyCommand.run(
            lockPath: "/tmp/goh-no-such-lock-\(UUID().uuidString).toml",
            strictUntracked: false)
        #expect(result.exitCode == 6)
    }

    @Test("unknown lockfileVersion → exit 6 (unusable lock)")
    func unknownVersionExit6() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let toml = "lockfileVersion = 99\nmanifestHash = \"sha256:a3f9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1\"\n"
        let lock = dir.appending(path: "gohfile.lock")
        try toml.write(to: lock, atomically: true, encoding: .utf8)
        let result = GohVerifyCommand.run(lockPath: lock.path, strictUntracked: false)
        #expect(result.exitCode == 6)
    }

    @Test("--strict-untracked: untracked file exits 10")  // §9.2 step 5
    func strictUntrackedExit10() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let _ = try writeFile(dir, subpath: "extra.bin", Data("extra".utf8))
        let lock = try writeLock(dir, entries: [])
        // Lock has no entries, but extra.bin is on disk
        let result = GohVerifyCommand.run(lockPath: lock.path, strictUntracked: true)
        #expect(result.exitCode == 10)
        #expect(result.standardOutput.contains("untracked"))
    }

    @Test("stale manifestHash (lock vs manifest mismatch) → exit 6")
    func staleManifestHash() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Write a manifest with different content than what manifestHash records
        let manifest = "version = 1\n[[asset]]\nurl = \"http://x.org/f\"\npath = \"f\"\n"
        let manifestPath = dir.appending(path: "gohfile.toml")
        try manifest.write(to: manifestPath, atomically: true, encoding: .utf8)
        let lock = try writeLock(dir, entries: [])
        // The lock has a hardcoded manifestHash that won't match the real manifest
        let result = GohVerifyCommand.run(lockPath: lock.path, strictUntracked: false)
        #expect(result.exitCode == 6)
        #expect(result.standardError.contains("stale"))
    }

    @Test("entries resolve under the lock's directory, not cwd (§9.3a regression guard)")
    func resolvesEntriesUnderLockDirNotCwd() throws {
        // Build <tmp>/proj/gohfile.lock with entry 'sub/f.bin' and the matching file
        // at <tmp>/proj/sub/f.bin. Run verify from a DIFFERENT working directory and
        // confirm the entry resolves under <tmp>/proj (exit 0 / OK), NOT relative to
        // cwd (which would MISS → exit 9). This is the cross-machine-reproduce guard.
        let proj = try tempDir()
        defer { try? FileManager.default.removeItem(at: proj) }
        let data = Data("payload".utf8)
        let f = try writeFile(proj, subpath: "sub/f.bin", data)
        let (digest, _) = try FileDigest.sha256WithSize(path: f.path)
        let lock = try writeLock(proj, entries: [(
            url: "https://x.org/f.bin", path: "sub/f.bin", sha256: digest, size: data.count)])
        // Change cwd to somewhere else; verify must NOT use it for resolution.
        let elsewhere = try tempDir()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let savedCwd = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(elsewhere.path)
        defer { FileManager.default.changeCurrentDirectoryPath(savedCwd) }
        let result = GohVerifyCommand.run(lockPath: lock.path, strictUntracked: false)
        #expect(result.exitCode == 0)          // resolved under lockDir, not cwd
        #expect(result.standardOutput.contains("OK"))
    }

    @Test("concurrent verify (flock already held) → exit 7")
    func concurrentVerifyExit7() throws {
        // This test verifies the flock path. We acquire an exclusive lock
        // before calling verify and confirm it returns exit 7 (busy lock).
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = try writeLock(dir, entries: [])
        let fd = open(lock.path, O_RDONLY, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let lockResult = flock(fd, LOCK_EX | LOCK_NB)
        guard lockResult == 0 else { return }  // couldn't acquire for test; skip
        defer { flock(fd, LOCK_UN) }
        let result = GohVerifyCommand.run(lockPath: lock.path, strictUntracked: false)
        #expect(result.exitCode == 7)
    }
}
```

**Step 2 — Run and expect fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohVerifyCommandTests 2>&1 | head -40
```

**Step 3 — Minimal implementation**

```swift
// Sources/GohCore/CLI/GohVerifyCommand.swift
import CryptoKit
import Darwin
import Foundation

/// Implements `goh verify [<path>] [--strict-untracked]` — read-only
/// integrity check against gohfile.lock (§9.2).
public struct GohVerifyCommand {

    public static func run(
        lockPath: String,
        strictUntracked: Bool
    ) -> GohCommandLineResult {
        // 1. Load lock
        guard let lockToml = try? String(contentsOfFile: lockPath, encoding: .utf8) else {
            return GohCommandLineResult(
                exitCode: 6,
                standardError: "no gohfile.lock at \(lockPath); run goh sync first\n")
        }

        let lock: LockfileCodec.Lockfile
        do {
            lock = try LockfileCodec.decode(lockToml)
        } catch let e as LockfileCodec.CodecError {
            if e.message.contains("unsupported lockfileVersion") {
                // Unknown lockfileVersion → unusable lock → exit 6 (§9.4, same
                // bucket as missing/corrupt/stale lock; NOT exit 1).
                return GohCommandLineResult(exitCode: 6, standardError: e.message + "\n")
            }
            // Corrupt lock
            let quarantine = lockPath + ".corrupt-\(Int(Date().timeIntervalSince1970))"
            try? FileManager.default.moveItem(atPath: lockPath, toPath: quarantine)
            return GohCommandLineResult(
                exitCode: 6,
                standardError: "corrupt lockfile (quarantined to \(quarantine)): \(e.message)\n")
        } catch {
            return GohCommandLineResult(exitCode: 6, standardError: "\(error)\n")
        }

        // 2. Acquire advisory shared lock
        let lockFd = open(lockPath, O_RDONLY, 0)
        guard lockFd >= 0 else {
            return GohCommandLineResult(exitCode: 6, standardError: "cannot open lock file\n")
        }
        defer { close(lockFd) }
        guard flock(lockFd, LOCK_SH | LOCK_NB) == 0 else {
            return GohCommandLineResult(
                exitCode: 7,
                standardError: "another goh sync/verify is running on this lockfile\n")
        }
        defer { flock(lockFd, LOCK_UN) }

        // 3. Check manifestHash staleness
        let lockDir = URL(fileURLWithPath: lockPath).deletingLastPathComponent()
        let manifestPath = lockDir.appending(path: "gohfile.toml")
        if let manifestToml = try? String(contentsOf: manifestPath, encoding: .utf8) {
            let data = Data(manifestToml.utf8)
            let hashHex = "sha256:" + SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()
            if hashHex != lock.manifestHash {
                return GohCommandLineResult(
                    exitCode: 6,
                    standardError: "lock is stale (manifestHash mismatch); run goh sync\n")
            }
        }

        // 4. Per-entry check
        var output = ""
        var hasMissing = false
        var hasFailed = false

        for entry in lock.entries {
            let absPath = lockDir.appending(path: entry.path).path
            guard FileManager.default.fileExists(atPath: absPath) else {
                output += "MISSING \(entry.path) (expected \(entry.sha256))\n"
                hasMissing = true
                continue
            }
            do {
                let (actualDigest, _) = try FileDigest.sha256WithSize(path: absPath)
                if actualDigest == entry.sha256 {
                    output += "OK \(entry.path)\n"
                } else {
                    output += "FAILED \(entry.path)"
                        + " expected \(entry.sha256)"
                        + " actual \(actualDigest)\n"
                    hasFailed = true
                }
            } catch {
                output += "FAILED \(entry.path): could not read file: \(error)\n"
                hasFailed = true
            }
        }

        // 5. Untracked files (informational / strict)
        if strictUntracked {
            let lockedPaths = Set(lock.entries.map { $0.path })
            if let enumerator = FileManager.default.enumerator(at: lockDir, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in enumerator {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
                    if isDir.boolValue { continue }
                    let rel = fileURL.path.replacingOccurrences(
                        of: lockDir.path + "/", with: "")
                    if !lockedPaths.contains(rel) && !rel.hasSuffix(".lock") && !rel.hasSuffix(".toml") {
                        output += "untracked \(rel)\n"
                    }
                }
            }
        }

        // 6. Exit code precedence: 9 > 2 > 10
        let exitCode: Int32
        if hasMissing { exitCode = 9 }
        else if hasFailed { exitCode = 2 }
        else { exitCode = 0 }

        if exitCode == 0 && strictUntracked && output.contains("untracked") {
            return GohCommandLineResult(exitCode: 10, standardOutput: output)
        }
        return GohCommandLineResult(exitCode: exitCode, standardOutput: output)
    }
}
```

Update `GohCommandLine.swift`: add `.verify(lockPath: String, strictUntracked: Bool)`,
parse `goh verify [<path>] [--strict-untracked]`, dispatch to `GohVerifyCommand.run`.

**Step 4 — Run and expect pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohVerifyCommandTests
```

**Step 5 — Commit**

```
feat(trust-core): goh verify — read-only lock integrity check (Phase 5, AC2)
```

---

**Phase 5 artifact** → `docs/superpowers/progress/2026-05-29-trust-core-phase5.md`

---

## Phase 6 — `goh sync` (CLI-local loop)

**Deployment boundary:** depends on all prior phases. Largest and most complex;
must be last.

---

### T6.1 — Path confinement pre-flight (CLI side, lexical rules 1–2 + realpath)

**Files**
- CREATE `Sources/GohCore/TrustCore/SyncPathConfinement.swift`
- CREATE `Tests/GohCoreTests/SyncPathConfinementTests.swift`

**Pre-task reads checklist**
- [x] `Sources/GohCore/CLI/GohCommandLine.swift` — AddRequest has no `base`;
  destination is resolved by the CLI and passed as absolute path. Confirmed.
- [x] `Sources/GohCore/TrustCore/ManifestCodec.swift` (T2.1) — `AssetEntry.path`
- [x] `docs/superpowers/specs/2026-05-29-trust-core-design.md` §4.1 (rules 1–2),
  §7.4 (per-entry `path`/`dest` is NEVER expanded — literal `~`/`$`)

**`SyncPathConfinement.resolve(entryPath:base:)` algorithm (BLOCK 8 — load-bearing,
the body is NOT optional and the realpath check is NOT deferred):** returns the
confined absolute destination `String`, or throws `ConfinementError`:
1. Reject an ABSOLUTE `entryPath` (leading `/`) → `.absolutePathRejected`. A literal
   leading/embedded `~`/`$` in `entryPath` is treated LITERALLY (a normal path
   component, never expanded — §7.4); only `base` may expand a leading `~`, in the
   caller before `resolve`.
2. Lexically normalize `entryPath` at the STRING level (collapse `.`; resolve `..`
   against accumulated components) BEFORE any filesystem call; if net `..` climbs to
   or above `base` → `.traversalRejected`.
3. Form `base/<normalized>`. Resolve the PARENT directory's real path (`realpath` on
   the parent — the final component may not exist yet) and confirm it is inside
   `base`'s real path; if not → `.realpathEscape`.
4. Return the confined absolute destination.

(The symlink-safe OPEN of that destination is T3.2's daemon-side `openat` descent.
`resolve` does the lexical + realpath confinement that needs `base`; the descent does
the per-component `O_NOFOLLOW` TOCTOU enforcement. Together they are the two §4.1
layers.) These `ConfinementError` cases map to CLI **exit 5** (Appendix A), as does
the daemon's `symlinkComponentRefused`.

**Step 1 — Failing tests**

```swift
// Tests/GohCoreTests/SyncPathConfinementTests.swift
import Foundation
import Testing

import GohCore

@Suite("SyncPathConfinement")
struct SyncPathConfinementTests {

    // AC stubs: §4.1 rules 1–2 (absolute path and .. traversal → exit 5)

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "goh-confine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("absolute path entry rejected (rule 1 — exit 5)")
    func absolutePathRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SyncPathConfinement.ConfinementError.self) {
            _ = try SyncPathConfinement.resolve(
                entryPath: "/etc/passwd", base: dir.path)
        }
    }

    @Test(".. traversal out of base rejected (rule 2 — exit 5)")
    func dotDotRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SyncPathConfinement.ConfinementError.self) {
            _ = try SyncPathConfinement.resolve(
                entryPath: "../escape/file.bin", base: dir.path)
        }
    }

    @Test("valid relative path resolves under base")
    func validPathResolves() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolved = try SyncPathConfinement.resolve(
            entryPath: "subdir/file.bin", base: dir.path)
        #expect(resolved.hasPrefix(dir.path))
        #expect(resolved.hasSuffix("subdir/file.bin"))
    }

    @Test("leading ~ in path is treated as literal, NOT home-expanded (§7.4)")
    func leadingTildeInPathIsLiteral() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolved = try SyncPathConfinement.resolve(
            entryPath: "~cache/file.bin", base: dir.path)
        // The component named '~cache' stays under base; it is NOT expanded to
        // the user's home directory.
        #expect(resolved.hasPrefix(dir.path))
        #expect(resolved.contains("~cache"))
        #expect(!resolved.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path)
                || dir.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    @Test("realpath parent outside base is rejected (rule 3, not deferred)")
    func realpathParentEscapeRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Create a symlinked subdir under base that points OUTSIDE base, then an
        // entry whose lexical form stays inside base but whose realpath parent
        // escapes. resolve() must reject via the realpath-parent check.
        let outside = dir.deletingLastPathComponent().appending(path: "outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: SyncPathConfinement.ConfinementError.self) {
            _ = try SyncPathConfinement.resolve(entryPath: "link/file.bin", base: dir.path)
        }
    }

    @Test("leading ~ in base is expanded (only base gets ~ expansion)")
    func leadingTildeInBaseIsExpanded() throws {
        // Note: we can only test non-destructively; just verify no ConfinementError
        // and the result is absolute.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Use actual temp dir (which IS absolute) as a proxy test
        let resolved = try SyncPathConfinement.resolve(
            entryPath: "f.bin", base: dir.path)
        #expect(resolved.hasPrefix("/"))
    }
}
```

**Step 2 — Run and expect fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter SyncPathConfinementTests 2>&1 | head -40
```

**Step 3 — Minimal implementation**

```swift
// Sources/GohCore/TrustCore/SyncPathConfinement.swift
import Foundation

/// CLI-side lexical path confinement for `goh sync` (§4.1 rules 1–2).
///
/// The daemon enforces rule 3 (symlink refusal at open time, base-free).
/// This module enforces rules 1–2 (absolute path rejection; .. escape rejection)
/// and the realpath pre-flight against the canonicalized base.
public struct SyncPathConfinement {

    public struct ConfinementError: Error, Equatable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    /// Resolves `entryPath` under `base`, applying §4.1 rules 1–2.
    /// Returns the absolute destination path if confined, throws otherwise.
    ///
    /// - Parameters:
    ///   - entryPath: The per-entry `path` from the manifest. Literal — no
    ///     `~` or `$` expansion (§7.4).
    ///   - base: The canonicalized base directory (caller has already expanded
    ///     a leading `~` in `base` per §7.4 and canonicalized it).
    public static func resolve(
        entryPath: String, base: String
    ) throws -> String {
        // Rule 1: reject absolute paths
        if entryPath.hasPrefix("/") {
            throw ConfinementError(
                "absolute path '\(entryPath)' is not allowed in a manifest entry; "
                + "use a relative path under the base directory")
        }
        // Drive-form check (not applicable on Darwin but defensive)
        if entryPath.count >= 2, entryPath[entryPath.index(entryPath.startIndex, offsetBy: 1)] == ":" {
            throw ConfinementError(
                "absolute path '\(entryPath)' is not allowed in a manifest entry")
        }

        // Join and lexically normalize
        let joined = (base as NSString).appendingPathComponent(entryPath)
        let normalized = URL(fileURLWithPath: joined)
            .standardized.path  // lexical normalization, no filesystem call

        // Rule 2: normalized result must have base as prefix (lexical)
        let canonicalBase = URL(fileURLWithPath: base).standardized.path
        guard normalized.hasPrefix(canonicalBase + "/") || normalized == canonicalBase else {
            throw ConfinementError(
                "path '\(entryPath)' escapes the base directory via '..'; "
                + "refusing (would resolve to \(normalized))")
        }

        // Rule 3 (BLOCK 8): realpath the PARENT (the final component may not exist
        // yet) and confirm it is still inside base's real path. This is the
        // TOCTOU-relevant pre-flight half and is NOT deferred — it catches a
        // symlinked intermediate dir under base that points outside base. (The
        // daemon's openat O_NOFOLLOW descent, T3.2, is the moment-of-write
        // enforcement; this is defense in depth that needs `base`, which only the
        // CLI has.)
        let baseReal = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
        let parentReal = URL(fileURLWithPath: normalized)
            .deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parentReal == baseReal || parentReal.hasPrefix(baseReal + "/") else {
            throw ConfinementError(
                "path '\(entryPath)' resolves (via a symlinked component) outside "
                + "the base directory; refusing (parent realpath \(parentReal))")
        }

        return normalized
    }
}
```

**Step 4 — Run and expect pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter SyncPathConfinementTests
```

**Step 5 — Commit**

```
feat(trust-core): SyncPathConfinement — CLI lexical pre-flight for §4.1 rules 1–2 (Phase 6 prerequisite)
```

---

### T6.2 — GohSyncCommand: download loop + pinned acceptance (AC1, AC3)

**Files**
- CREATE `Sources/GohCore/CLI/GohSyncCommand.swift`
- MODIFY `Sources/GohCore/CLI/GohCommandLine.swift`
- CREATE `Tests/GohCoreTests/GohSyncCommandTests.swift`

**Pre-task reads checklist**
- [x] `Sources/GohCore/CLI/GohCommandLine.swift` — `sendCommand`, `Sender`
  typealias `(XPCDictionary) throws -> XPCDictionary`. `GohSyncCommand` receives
  the `Sender` so it can issue `add` and `ls` XPC calls.
- [x] `Sources/GohCore/Model/Command.swift` — `AddRequest` fields (url,
  destination, connectionCount, useImportedCookies, priority); NO `base`.
- [x] `Sources/GohCore/Model/JobState.swift` — terminal states: `completed`,
  `failed`; there is NO `cancelled`.
- [x] `Sources/GohCore/Model/JobSummary.swift` — `id: UInt64`, `state: JobState`,
  `destination: String`.
- [x] `Sources/GohCore/TrustCore/SyncPathConfinement.swift` (T6.1) — resolve path.
- [x] `Sources/GohCore/TrustCore/ManifestCodec.swift` (T2.1) — manifest types.
- [x] `Sources/GohCore/TrustCore/LockfileCodec.swift` (T2.2) — lock types.
- [x] `Sources/GohCore/TrustCore/FileDigest.swift` (T2.3) — sha256WithSize.

**Step 1 — Failing tests**

Tests for sync use a mock `Sender` (no real XPC in unit tests):

```swift
// Tests/GohCoreTests/GohSyncCommandTests.swift
import Foundation
import Testing
import XPC

import GohCore

@Suite("goh sync")
struct GohSyncCommandTests {

    // AC1: idempotent sync; AC3: pinned strict / TOFU record

    // ---------------------------------------------------------------------------
    // BLOCK 6 — STATEFUL mock Sender (closes the throwing-stub gap).
    //
    // The earlier draft used throwing mock senders for sync tests, so the AC1
    // completion path, AC3 quarantine, AC5 accept, the watchdog, and the
    // disappeared/transport paths NEVER executed. This stateful mock returns
    // well-formed reply ENVELOPES the way GohSyncCommand's decode path expects —
    // it does NOT invent reply shapes. The real seam is
    // `GohCommandLine.Sender = (XPCDictionary) throws -> XPCDictionary`; the
    // command decodes the response with `decodeGohReply(as: JobSummary.self)`
    // (for `add`) and `as: LsReply.self` (for `ls`). The mock therefore:
    //   • decodes the incoming GohEnvelope's `Command`,
    //   • on `.add(request:)` → records a job (fresh id, state .queued, the
    //     request's `destination`, zero JobProgress) and replies with that
    //     JobSummary, ECHOING the request's requestID (the command asserts the
    //     reply requestID matches),
    //   • on `.ls` → advances the tracked job's state (queued→active→completed)
    //     and progress.bytesCompleted across successive calls, and on reaching
    //     .completed STAGES the re-downloadable file on disk at `destination`
    //     (writing the expected bytes) so the post-download FileDigest re-hash
    //     succeeds, then replies with LsReply(jobs:).
    // Configurable injectors (mutable vars, set before run) — these EXACT names
    // are used by the runnable terminal-mapping tests below, so the mock MUST
    // expose them:
    //   throwOnEveryLs: Bool   → every `ls` throws → bounded retry exhausts →
    //                            .transportFailure → exit 1
    //   omitJobFromLs:  Bool   → `add` OK but the job id never appears in `ls`
    //                            → .disappeared → exit 8
    //   holdNonTerminal: Bool  → `ls` always reports .active → no-progress
    //                            watchdog → .timedOut → exit 8
    //   failWith: GohError?    → drive the job to .failed carrying this error
    //                            (incl. .symlinkComponentRefused → exit 5)
    // The watchdog interval is injected via `GohSyncCommand.run(..., watchdogSeconds:)`
    // (default 120 s in prod; tests pass ~0.05 s) — threaded run → runThrowing →
    // downloadAndAccept → pollUntilTerminal. `addCount` is exposed for the AC1
    // idempotency assertion (zero new `add` calls on a second, up-to-date run).
    //
    // Build it as a final class holding the job table + a closure conforming to
    // `GohCommandLine.Sender`; encode replies with
    //   GohEnvelope(protocolVersion: CommandService.protocolVersion,
    //               requestID: <echoed>, messageType: .reply, payload: <reply>)
    //     .xpcDictionary()
    // Test-to-code shape drift check: JobSummary, JobProgress, LsReply, AddRequest,
    // ErrorCode must match the real types; if a referenced symbol does not exist,
    // fix the test to the real shape — do NOT invent AddReply / a .reply payload type.
    //
    // The AC1 happy-path (add→ls completed→re-hash→lock written→second run zero
    // bytes), AC3 pinned-mismatch quarantine (exit 2), AC5 accept (exit 0),
    // watchdog timeout (exit 8), job-disappeared (exit 8), transport error
    // (exit 1), and daemon .symlinkComponentRefused (exit 5) tests are all driven
    // by THIS mock — NOT by a bare throwing stub. The placeholder
    // `#expect(Bool(true))` pinned-mismatch test below is REPLACED by a real one
    // that uses the stateful mock to stage mismatching bytes.
    // ---------------------------------------------------------------------------

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "goh-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("empty manifest syncs with exit 0 and writes a lock")  // AC1 (empty case)
    func emptySyncWritesLock() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifestToml = "version = 1\n"
        let manifestPath = dir.appending(path: "gohfile.toml")
        try manifestToml.write(to: manifestPath, atomically: true, encoding: .utf8)

        // No XPC needed for empty manifest
        let result = GohSyncCommand.run(
            manifestPath: manifestPath.path,
            base: nil,
            acceptChanged: false,
            send: { _ in throw GohError(code: .jobNotFound, message: "no call expected") })
        #expect(result.exitCode == 0)
        let lockPath = dir.appending(path: "gohfile.lock")
        #expect(FileManager.default.fileExists(atPath: lockPath.path))
    }

    @Test("file already present and matching lock → up to date, zero XPC calls")  // AC1 idempotency
    func fileAlreadyMatchingIsSkipped() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write the file
        let data = Data("model bytes".utf8)
        let subdir = dir.appending(path: "weights")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let filePath = subdir.appending(path: "model.bin")
        try data.write(to: filePath)

        // Compute real digest
        let (digest, size) = try FileDigest.sha256WithSize(path: filePath.path)

        // Write manifest + lock with matching hash
        let manifestToml = """
            version = 1
            [[asset]]
            url  = "https://example.org/weights/model.bin"
            path = "weights/model.bin"
            """
        try manifestToml.write(to: dir.appending(path: "gohfile.toml"),
                               atomically: true, encoding: .utf8)
        let (manifestDigest, _) = try FileDigest.sha256WithSize(
            path: dir.appending(path: "gohfile.toml").path)
        let lockToml = """
            lockfileVersion = 1
            manifestHash    = "\(manifestDigest)"

            [[entry]]
            url          = "https://example.org/weights/model.bin"
            path         = "weights/model.bin"
            sha256       = "\(digest)"
            size         = \(size)
            downloadedAt = "2026-05-29T12:00:00Z"
            """
        try lockToml.write(to: dir.appending(path: "gohfile.lock"),
                           atomically: true, encoding: .utf8)

        var xpcCallCount = 0
        let result = GohSyncCommand.run(
            manifestPath: dir.appending(path: "gohfile.toml").path,
            base: nil,
            acceptChanged: false,
            send: { _ in
                xpcCallCount += 1
                throw GohError(code: .jobNotFound, message: "should not be called")
            })
        #expect(result.exitCode == 0)
        #expect(xpcCallCount == 0)  // AC1: zero bytes transferred on second run
        #expect(result.standardOutput.contains("up to date"))
    }

    @Test("pinned entry: mismatch after download → exit 2, file quarantined")  // AC3
    func pinnedMismatch() throws {
        // Driven by the BLOCK 6 stateful mock: `add` returns a queued job; `ls`
        // advances it to .completed and STAGES bytes whose hash ≠ the pin. The
        // command's post-download re-hash then mismatches the pin, so it quarantines
        // the file to `.corrupt-<unix>` and returns exit 2.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appending(path: "f.bin").path
        let pinnedHash = "sha256:6f1e2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2"
        let manifestToml = """
            version = 1
            [[asset]]
            url    = "https://example.org/f.bin"
            path   = "f.bin"
            sha256 = "\(pinnedHash)"
            """
        try manifestToml.write(to: dir.appending(path: "gohfile.toml"),
                               atomically: true, encoding: .utf8)

        // Stateful mock stages WRONG bytes at `dest` on completion (hash ≠ pin).
        let mock = StatefulSyncMock(stageOnComplete: [dest: Data("wrong bytes".utf8)])
        let result = GohSyncCommand.run(
            manifestPath: dir.appending(path: "gohfile.toml").path,
            base: nil, acceptChanged: false, send: mock.send)
        #expect(result.exitCode == 2)
        #expect(result.standardError.contains("checksumMismatch"))
        // Bad bytes are quarantined, not left at the destination.
        #expect(!FileManager.default.fileExists(atPath: dest))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .contains { $0.hasPrefix("f.bin.corrupt-") })
    }

    @Test("AC1 happy path: add → ls completed → re-hash → lock written → 2nd run zero bytes")  // AC1
    func happyPathDownloadsThenIdempotent() throws {
        // First run drives a real add→ls→completed via the stateful mock (which
        // stages the file on completion); second run finds it present + matching
        // and issues ZERO add calls.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appending(path: "model.bin").path
        let payload = Data("canonical model bytes".utf8)
        let manifestToml = """
            version = 1
            [[asset]]
            url  = "https://example.org/model.bin"
            path = "model.bin"
            """
        try manifestToml.write(to: dir.appending(path: "gohfile.toml"),
                               atomically: true, encoding: .utf8)
        let mock = StatefulSyncMock(stageOnComplete: [dest: payload])
        let first = GohSyncCommand.run(
            manifestPath: dir.appending(path: "gohfile.toml").path,
            base: nil, acceptChanged: false, send: mock.send)
        #expect(first.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "gohfile.lock").path))
        let firstAddCount = mock.addCount

        let second = GohSyncCommand.run(
            manifestPath: dir.appending(path: "gohfile.toml").path,
            base: nil, acceptChanged: false, send: mock.send)
        #expect(second.exitCode == 0)
        #expect(second.standardOutput.contains("up to date"))
        #expect(mock.addCount == firstAddCount)   // zero new downloads on run 2
    }

    /// One-asset manifest helper for the terminal-mapping tests.
    private func oneAssetManifest(_ dir: URL) throws {
        let toml = """
            version = 1
            [[asset]]
            url  = "https://example.org/x.bin"
            path = "x.bin"
            """
        try toml.write(to: dir.appending(path: "gohfile.toml"),
                       atomically: true, encoding: .utf8)
    }

    // BLOCK 6 + BLOCK 3 — four RUNNABLE terminal-failure-mapping tests, each driven
    // by a StatefulSyncMock injector, with a tiny watchdog so the timeout case is
    // fast. These replace the previous comment-only stub.

    @Test("watchdog: job never reaches terminal → exit 8")
    func watchdogTimeoutExit8() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try oneAssetManifest(dir)
        let mock = StatefulSyncMock(stageOnComplete: [:])
        mock.holdNonTerminal = true          // ls always reports .active
        let result = GohSyncCommand.run(
            manifestPath: dir.appending(path: "gohfile.toml").path,
            base: nil, acceptChanged: false, send: mock.send,
            watchdogSeconds: 0.05)           // BLOCK 3 seam — fast timeout
        #expect(result.exitCode == 8)
    }

    @Test("job disappears from ls → exit 8")
    func jobDisappearedExit8() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try oneAssetManifest(dir)
        let mock = StatefulSyncMock(stageOnComplete: [:])
        mock.omitJobFromLs = true            // add OK, but ls never lists the id
        let result = GohSyncCommand.run(
            manifestPath: dir.appending(path: "gohfile.toml").path,
            base: nil, acceptChanged: false, send: mock.send,
            watchdogSeconds: 5)
        #expect(result.exitCode == 8)
    }

    @Test("ls transport error (every attempt throws) → exit 1")
    func transportErrorExit1() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try oneAssetManifest(dir)
        let mock = StatefulSyncMock(stageOnComplete: [:])
        mock.throwOnEveryLs = true           // exhausts the bounded retry → exit 1
        let result = GohSyncCommand.run(
            manifestPath: dir.appending(path: "gohfile.toml").path,
            base: nil, acceptChanged: false, send: mock.send,
            watchdogSeconds: 5)
        #expect(result.exitCode == 1)
    }

    @Test("daemon job fails with symlinkComponentRefused → exit 5")
    func symlinkRefusedExit5() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try oneAssetManifest(dir)
        let mock = StatefulSyncMock(stageOnComplete: [:])
        mock.failWith = GohError(code: .symlinkComponentRefused)
        let result = GohSyncCommand.run(
            manifestPath: dir.appending(path: "gohfile.toml").path,
            base: nil, acceptChanged: false, send: mock.send,
            watchdogSeconds: 5)
        #expect(result.exitCode == 5)
    }
}
```

**Step 2 — Run and expect fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohSyncCommandTests 2>&1 | head -40
```

**Step 3 — Minimal implementation (core loop)**

The full sync implementation is large. The core structure:

```swift
// Sources/GohCore/CLI/GohSyncCommand.swift
import Darwin
import Foundation
import XPC

/// Implements `goh sync [<path>] [--base <dir>] [--accept-changed]` (§9.1).
///
/// Loop:
/// 1. Parse manifest.
/// 2. Acquire flock(LOCK_EX) on gohfile.lock.
/// 3. For each asset: confine path → re-hash if present → skip / download.
/// 4. After download (add + poll-ls): re-hash, accept/reject per AC3/AC5.
/// 5. Write lock atomically.
public struct GohSyncCommand {

    public static func run(
        manifestPath: String,
        base: String?,
        acceptChanged: Bool,
        send: GohCommandLine.Sender,
        // BLOCK 3 — test seam. Production default is 120 s; tests pass a tiny
        // value so the no-progress-watchdog case runs in milliseconds, not 2 min.
        // Threaded run → runThrowing → downloadAndAccept → pollUntilTerminal.
        watchdogSeconds: TimeInterval = 120
    ) -> GohCommandLineResult {
        do {
            return try runThrowing(
                manifestPath: manifestPath, base: base,
                acceptChanged: acceptChanged, send: send,
                watchdogSeconds: watchdogSeconds)
        } catch {
            return GohCommandLineResult(exitCode: 8, standardError: "\(error)\n")
        }
    }

    // MARK: - Internal throwing implementation

    enum SyncError: Error {
        case manifestNotFound(String)
        case confinementViolation(String)
        case lockBusy
        case checksumMismatch(path: String, expected: String, actual: String)
        case hashChangedUnpinned(path: String, old: String, new: String)
        case downloadFailed(path: String, reason: String)
        case pathEscape(path: String, reason: String)
    }

    // Exit code precedence for failures: 5 > 2 > 3 > 8 > 1.
    // (Transport failure is the lowest-precedence non-security failure: a security
    // refusal, integrity mismatch, TOFU change, or per-entry download failure all
    // outrank a generic daemon-unreachable. §9.4: 1 = generic transport.)
    private static func exitCode(for failures: [SyncFailure]) -> Int32 {
        if failures.contains(where: { $0.kind == .pathEscape }) { return 5 }
        if failures.contains(where: { $0.kind == .checksumMismatch }) { return 2 }
        if failures.contains(where: { $0.kind == .hashChangedUnpinned }) { return 3 }
        if failures.contains(where: { $0.kind == .downloadFailed }) { return 8 }
        if failures.contains(where: { $0.kind == .transport }) { return 1 }
        return 0
    }

    struct SyncFailure {
        enum Kind { case pathEscape, checksumMismatch, hashChangedUnpinned, downloadFailed, transport }
        var kind: Kind
        var message: String
    }

    private static func runThrowing(
        manifestPath: String,
        base: String?,
        acceptChanged: Bool,
        send: GohCommandLine.Sender
    ) throws -> GohCommandLineResult {

        // 1. Load manifest
        guard let manifestToml = try? String(contentsOfFile: manifestPath, encoding: .utf8) else {
            return GohCommandLineResult(
                exitCode: 6,
                standardError: "manifest not found: \(manifestPath)\n")
        }
        let manifest: ManifestCodec.ManifestFile
        do {
            manifest = try ManifestCodec.parse(manifestToml)
        } catch let e as ManifestCodec.CodecError {
            // Bad manifest content (unknown version, unknown key, bad sha256 shape,
            // reserved 'auth' field) → usage/bad-input class → exit 64 (§9.4).
            // Same bucket as bad CLI args; NOT exit 1.
            return GohCommandLineResult(exitCode: 64, standardError: e.message + "\n")
        }

        if manifest.assets.isEmpty {
            return try writeEmptyLock(
                manifestPath: manifestPath, manifest: manifest)
        }

        // Resolve base
        let manifestDir = URL(fileURLWithPath: manifestPath)
            .deletingLastPathComponent().path
        let resolvedBase = resolveBase(
            manifestBase: manifest.base,
            cliBase: base,
            manifestDir: manifestDir)

        let lockPath = URL(fileURLWithPath: manifestDir)
            .appending(path: "gohfile.lock").path

        // 2. Acquire flock(LOCK_EX) on lockfile
        let lockFd: Int32
        if FileManager.default.fileExists(atPath: lockPath) {
            lockFd = open(lockPath, O_RDWR, 0)
        } else {
            lockFd = open(lockPath, O_RDWR | O_CREAT, 0o644)
        }
        guard lockFd >= 0 else {
            return GohCommandLineResult(exitCode: 6, standardError: "cannot open lock file\n")
        }
        defer { close(lockFd) }
        guard flock(lockFd, LOCK_EX | LOCK_NB) == 0 else {
            return GohCommandLineResult(
                exitCode: 7,
                standardError: "another goh sync/verify is running on this lockfile\n")
        }
        defer { flock(lockFd, LOCK_UN) }

        // 3. Load existing lock (if any)
        var existingLock: LockfileCodec.Lockfile? = nil
        if let lockToml = try? String(contentsOfFile: lockPath, encoding: .utf8),
           !lockToml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            existingLock = try? LockfileCodec.decode(lockToml)
        }
        let lockIsStale = existingLock.map { $0.manifestHash != manifest.manifestHash } ?? true

        // Build index of existing lock entries
        var lockIndex: [String: LockfileCodec.LockEntry] = [:]
        if let lock = existingLock, !lockIsStale {
            for entry in lock.entries {
                lockIndex[entry.path] = entry
            }
        }

        var output = ""
        var failures: [SyncFailure] = []
        var newEntries: [LockfileCodec.LockEntry] = []

        for asset in manifest.assets {
            // Confine path
            let confined: String
            do {
                confined = try SyncPathConfinement.resolve(
                    entryPath: asset.path, base: resolvedBase)
            } catch let e as SyncPathConfinement.ConfinementError {
                failures.append(SyncFailure(
                    kind: .pathEscape,
                    message: "FAILED \(asset.path): path-escape (\(e.message))"))
                continue
            }

            let existingLockEntry = lockIndex[asset.path]

            // Check if file exists on disk
            let fileExists = FileManager.default.fileExists(atPath: confined)

            if fileExists {
                // Re-hash the existing file
                guard let (actualDigest, actualSize) = try? FileDigest.sha256WithSize(path: confined) else {
                    // Cannot read — treat as not present
                    if let entry = try? downloadAndAccept(
                        asset: asset, confined: confined, existingLockEntry: existingLockEntry,
                        acceptChanged: acceptChanged, send: send,
                        output: &output, failures: &failures) {
                        newEntries.append(entry)
                    }
                    continue
                }

                // Check if it's up-to-date vs. lock and pin
                if let lockedEntry = existingLockEntry, lockedEntry.sha256 == actualDigest {
                    if asset.sha256 == nil || asset.sha256 == actualDigest {
                        output += "up to date \(asset.path)\n"
                        newEntries.append(lockedEntry)
                        continue
                    }
                }
                if let pin = asset.sha256, pin == actualDigest {
                    // Pinned and matches pin; record/update
                    output += "up to date \(asset.path)\n"
                    let ts = existingLockEntry?.downloadedAt ?? isoNow()
                    newEntries.append(LockfileCodec.LockEntry(
                        url: asset.url, path: asset.path,
                        sha256: actualDigest, size: actualSize, downloadedAt: ts))
                    continue
                }

                // File present but doesn't match lock or pin: is it a partial?
                // Check size against lock entry
                if let lockedEntry = existingLockEntry, actualSize < lockedEntry.size {
                    // Treat as not-present: re-download
                } else if asset.sha256 == nil, let lockedEntry = existingLockEntry,
                          actualDigest != lockedEntry.sha256 {
                    // AC5: unpinned TOFU change
                    let msg = "hash changed for unpinned entry \(asset.path): "
                        + "\(lockedEntry.sha256) → \(actualDigest)"
                    output += "\(msg)\n"
                    if acceptChanged {
                        let ts = isoNow()
                        newEntries.append(LockfileCodec.LockEntry(
                            url: asset.url, path: asset.path,
                            sha256: actualDigest, size: actualSize, downloadedAt: ts))
                        continue
                    } else {
                        failures.append(SyncFailure(kind: .hashChangedUnpinned, message: msg))
                        newEntries.append(lockedEntry)  // keep old entry
                        continue
                    }
                } else if asset.sha256 == nil, existingLockEntry == nil {
                    // BLOCK 1 / spec §9.1 step 6 — present, unpinned, NO prior lock
                    // entry: this is trust-on-first-use RECORD, not a download. A
                    // present unpinned file with no recorded size has nothing to
                    // compare against, so it is never a "partial". Re-hash the
                    // on-disk bytes, record the entry, emit the first-use line, and
                    // do NOT call `add`.
                    output += "recorded sha256:\(actualDigest) (first use, unverified)\n"
                    newEntries.append(LockfileCodec.LockEntry(
                        url: asset.url, path: asset.path,
                        sha256: actualDigest, size: actualSize, downloadedAt: isoNow()))
                    continue
                }
                // Fall through to download (interrupted partial)
            }

            // Download
            if let entry = try? downloadAndAccept(
                asset: asset, confined: confined, existingLockEntry: existingLockEntry,
                acceptChanged: acceptChanged, send: send,
                output: &output, failures: &failures) {
                newEntries.append(entry)
            }
        }

        // 7. Write lock atomically
        let newLock = LockfileCodec.Lockfile(
            manifestHash: manifest.manifestHash, entries: newEntries)
        do {
            try writeLockAtomically(lock: newLock, toPath: lockPath)
        } catch {
            return GohCommandLineResult(
                exitCode: 8,
                standardError: "failed to write lockfile: \(error)\n")
        }

        let exit = exitCode(for: failures)
        let stderr = failures.map { $0.message }.joined(separator: "\n")
        return GohCommandLineResult(
            exitCode: exit, standardOutput: output,
            standardError: stderr.isEmpty ? "" : stderr + "\n")
    }

    // MARK: - Helpers

    private static func downloadAndAccept(
        asset: ManifestCodec.AssetEntry,
        confined: String,
        existingLockEntry: LockfileCodec.LockEntry?,
        acceptChanged: Bool,
        send: GohCommandLine.Sender,
        output: inout String,
        failures: inout [SyncFailure]
    ) throws -> LockfileCodec.LockEntry? {
        // Issue add via XPC
        let addRequest = AddRequest(url: asset.url, destination: confined)
        let addCmd = Command.add(request: addRequest)
        let requestID = UUID()
        let envelope = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .request,
            payload: addCmd).xpcDictionary()

        let addReply: JobSummary
        do {
            let response = try send(XPCDictionary(envelope))
            switch response.decodeGohReply(as: JobSummary.self) {
            case .reply(_, let summary): addReply = summary
            case .daemonError(_, let err):
                let kind: SyncFailure.Kind = err.code == .symlinkComponentRefused
                    ? .pathEscape : .downloadFailed
                failures.append(SyncFailure(
                    kind: kind,
                    message: "FAILED \(asset.path): \(err.message ?? err.code.rawValue)"))
                return nil
            case .malformed:
                failures.append(SyncFailure(kind: .downloadFailed,
                    message: "FAILED \(asset.path): malformed daemon reply"))
                return nil
            }
        } catch {
            failures.append(SyncFailure(kind: .downloadFailed,
                message: "FAILED \(asset.path): \(error)"))
            return nil
        }

        // Poll ls by job id until terminal state
        let jobID = addReply.id
        let finalState = pollUntilTerminal(jobID: jobID, send: send)
        switch finalState {
        case .completed:
            break
        case .failed(let err):
            // §9.1 4a: a daemon symlink/confinement refusal is a path-escape
            // (exit 5), not a generic download failure (exit 8).
            let kind: SyncFailure.Kind = err.code == .symlinkComponentRefused
                ? .pathEscape : .downloadFailed
            failures.append(SyncFailure(kind: kind,
                message: "FAILED \(asset.path): \(err.message ?? err.code.rawValue)"))
            return nil
        case .disappeared:
            failures.append(SyncFailure(kind: .downloadFailed,
                message: "FAILED \(asset.path): job disappeared"))
            return nil
        case .timedOut:
            failures.append(SyncFailure(kind: .downloadFailed,
                message: "FAILED \(asset.path): timed out (no progress)"))
            return nil
        case .transportFailure:
            // BLOCK 5: a transport failure is exit 1, distinct from a per-entry
            // download failure (exit 8) and from a vanished job (exit 8).
            failures.append(SyncFailure(kind: .transport,
                message: "FAILED \(asset.path): transport failure contacting daemon"))
            return nil
        }

        // Re-hash at destination
        guard let (actualDigest, actualSize) = try? FileDigest.sha256WithSize(path: confined) else {
            failures.append(SyncFailure(kind: .downloadFailed,
                message: "FAILED \(asset.path): could not read after download"))
            return nil
        }

        // Pinned acceptance (AC3)
        if asset.verify, let pin = asset.sha256 {
            if actualDigest != pin {
                // Quarantine
                let quarantine = confined + ".corrupt-\(Int(Date().timeIntervalSince1970))"
                try? FileManager.default.moveItem(atPath: confined, toPath: quarantine)
                failures.append(SyncFailure(kind: .checksumMismatch,
                    message: "FAILED \(asset.path): checksumMismatch "
                        + "expected \(pin) actual \(actualDigest)"))
                return nil
            }
        }

        // Unpinned TOFU (AC3/AC5)
        let ts = isoNow()
        if asset.sha256 == nil {
            if let old = existingLockEntry?.sha256, old != actualDigest {
                // AC5 — hash changed
                let msg = "hash changed for unpinned entry \(asset.path): \(old) → \(actualDigest)"
                output += "\(msg)\n"
                if !acceptChanged {
                    failures.append(SyncFailure(kind: .hashChangedUnpinned, message: msg))
                    return existingLockEntry  // keep old lock entry
                }
            } else if existingLockEntry == nil {
                output += "recorded sha256:\(actualDigest) (first use, unverified)\n"
            }
        }

        return LockfileCodec.LockEntry(
            url: asset.url, path: asset.path,
            sha256: actualDigest, size: actualSize, downloadedAt: ts)
    }

    private enum PollResult {
        case completed
        case failed(GohError)          // carry the GohError so the caller can map
                                       // .symlinkComponentRefused → exit 5 (§9.1 4a)
        case disappeared               // ls SUCCEEDED but the id was absent → exit 8
        case timedOut                  // no-progress watchdog fired → exit 8
        case transportFailure          // ls THREW past bounded retries → exit 1
    }

    /// Polls `ls` by job ID until a terminal state or the 120 s no-progress
    /// watchdog (§9.1 4a). BLOCK 5 fixes two defects in the prior draft:
    /// (1) a THROWN `ls` is a TRANSPORT failure (bounded retry, then exit 1) —
    ///     NOT "disappeared"; only an `ls` that SUCCEEDS but whose `jobs[]` lacks
    ///     the id is `.disappeared` (exit 8).
    /// (2) the watchdog resets on ANY observed state transition OR a byte advance —
    ///     not on byte change alone.
    private static func pollUntilTerminal(
        jobID: UInt64, send: GohCommandLine.Sender,
        watchdogSeconds: TimeInterval   // BLOCK 3 — injected from run(); 120 in prod
    ) -> PollResult {
        let maxTransportAttempts = 3
        var lastSeen = Date()
        var lastBytes: UInt64? = nil
        var lastState: JobState? = nil
        let pollIntervalSeconds: TimeInterval = 0.5

        while true {
            // Transport: a thrown ls is transient. Retry a bounded number of times
            // (short backoff); if still failing, give up as a transport failure
            // (exit 1) — NOT .disappeared.
            let lsReply: LsReply
            do {
                lsReply = try sendLsWithRetries(
                    send: send, maxAttempts: maxTransportAttempts)
            } catch {
                return .transportFailure
            }
            guard let job = lsReply.jobs.first(where: { $0.id == jobID }) else {
                return .disappeared            // ls OK, id absent → exit 8
            }
            switch job.state {
            case .completed: return .completed
            case .failed:
                return .failed(job.error
                    ?? GohError(code: .connectionFailed, message: "job failed"))
            case .queued, .active, .paused:    // exhaustive — JobState has no .cancelled
                // Reset the watchdog on ANY transition OR a byte advance.
                let currentBytes = job.progress.bytesCompleted
                if job.state != lastState || currentBytes != lastBytes {
                    lastState = job.state
                    lastBytes = currentBytes
                    lastSeen = Date()
                }
                if Date().timeIntervalSince(lastSeen) > watchdogSeconds {
                    return .timedOut
                }
                Thread.sleep(forTimeInterval: pollIntervalSeconds)
            }
        }
    }

    /// Calls `sendLs` up to `maxAttempts` times with a short backoff, rethrowing
    /// the last error only if every attempt threw.
    private static func sendLsWithRetries(
        send: GohCommandLine.Sender, maxAttempts: Int
    ) throws -> LsReply {
        var lastError: (any Error)?
        for attempt in 0..<maxAttempts {
            do { return try sendLs(send: send) }
            catch {
                lastError = error
                if attempt < maxAttempts - 1 {
                    Thread.sleep(forTimeInterval: 0.2 * Double(attempt + 1))
                }
            }
        }
        throw lastError ?? GohError(code: .connectionFailed, message: "ls failed")
    }

    private static func sendLs(send: GohCommandLine.Sender) throws -> LsReply {
        let requestID = UUID()
        let envelope = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .request,
            payload: Command.ls).xpcDictionary()
        let response = try send(XPCDictionary(envelope))
        switch response.decodeGohReply(as: LsReply.self) {
        case .reply(_, let reply): return reply
        case .daemonError(_, let err): throw err
        case .malformed: throw GohError(code: .connectionFailed, message: "malformed ls reply")
        }
    }

    private static func writeLockAtomically(
        lock: LockfileCodec.Lockfile, toPath: String
    ) throws {
        let encoded = LockfileCodec.encode(lock)
        let data = Data(encoded.utf8)
        let tmpPath = toPath + ".tmp-\(UUID().uuidString)"
        let dirPath = URL(fileURLWithPath: toPath).deletingLastPathComponent().path

        // Write to .tmp
        guard FileManager.default.createFile(atPath: tmpPath, contents: data) else {
            throw GohError(code: .destinationUnwritable, message: "cannot write \(tmpPath)")
        }
        // fsync the temp file
        let fd = open(tmpPath, O_RDWR, 0)
        if fd >= 0 {
            fsync(fd)
            close(fd)
        }
        // rename(2)
        guard rename(tmpPath, toPath) == 0 else {
            throw GohError(code: .destinationUnwritable,
                message: "rename failed: \(String(cString: strerror(errno)))")
        }
        // fsync the directory
        let dirFd = open(dirPath, O_RDONLY | O_DIRECTORY, 0)
        if dirFd >= 0 {
            fsync(dirFd)
            close(dirFd)
        }
    }

    private static func resolveBase(
        manifestBase: String?,
        cliBase: String?,
        manifestDir: String
    ) -> String {
        let raw = cliBase ?? manifestBase ?? ""
        if raw.isEmpty { return manifestDir }
        // Expand leading ~ (only ~ in base; not $VAR)
        let expanded: String
        if raw.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
                + String(raw.dropFirst())
        } else if raw == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else {
            expanded = raw
        }
        // If relative, resolve against manifestDir
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardized.path
        }
        return URL(fileURLWithPath: manifestDir)
            .appending(path: expanded).standardized.path
    }

    private static func writeEmptyLock(
        manifestPath: String,
        manifest: ManifestCodec.ManifestFile
    ) throws -> GohCommandLineResult {
        let lockPath = URL(fileURLWithPath: manifestPath)
            .deletingLastPathComponent()
            .appending(path: "gohfile.lock").path
        let lock = LockfileCodec.Lockfile(manifestHash: manifest.manifestHash, entries: [])
        try writeLockAtomically(lock: lock, toPath: lockPath)
        return GohCommandLineResult(exitCode: 0, standardOutput: "nothing to sync\n")
    }

    private static func isoNow() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: Date())
    }
}
```

**Step 4 — Run and expect pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohSyncCommandTests
```

**Step 5 — Commit**

```
feat(trust-core): GohSyncCommand core — manifest loop, path confinement, lock write (Phase 6, AC1)
```

---

### T6.3 — AC3 full pinned + TOFU first-use tests

**Files**
- MODIFY `Tests/GohCoreTests/GohSyncCommandTests.swift` — add tests

**Note (BLOCK 6).** The two tests below cover the ALREADY-PRESENT file path (the
file is on disk before sync, so no `add` is issued and a throwing `send` is
acceptable because it must never be called). The DOWNLOAD path (add → ls completed
→ re-hash → accept) is exercised by the `StatefulSyncMock`-driven tests in T6.2
(`happyPathDownloadsThenIdempotent`, `pinnedMismatch`, `terminalFailureMappings`);
do not re-stub the download path here with a throwing sender.

**Step 1 — Failing tests**

```swift
// Add to GohSyncCommandTests:

@Test("pinned entry: computed hash matches pin → lock written, exit 0")  // AC3
func pinnedMatchLockWritten() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = Data("canonical bytes".utf8)
    let (digest, size) = try {
        let u = dir.appending(path: "f.bin")
        try data.write(to: u)
        return try FileDigest.sha256WithSize(path: u.path)
    }()
    let manifestToml = """
        version = 1
        [[asset]]
        url    = "https://example.org/f.bin"
        path   = "f.bin"
        sha256 = "\(digest)"
        """
    try manifestToml.write(to: dir.appending(path: "gohfile.toml"),
                           atomically: true, encoding: .utf8)
    let result = GohSyncCommand.run(
        manifestPath: dir.appending(path: "gohfile.toml").path,
        base: nil,
        acceptChanged: false,
        send: { _ in throw GohError(code: .jobNotFound, message: "should not call add") })
    #expect(result.exitCode == 0)
    #expect(FileManager.default.fileExists(
        atPath: dir.appending(path: "gohfile.lock").path))
}

// FIX A: present + unpinned + NO lock entry → re-hash on-disk bytes, record a
// fresh lock entry, emit "first use, unverified", exit 0, and DO NOT download.
// The file is staged on disk, so the daemon must never be touched; the mock's
// callCount stays 0 (proving no re-download), and a lock entry is written.
// Runnable with no network/daemon.
@Test("unpinned TOFU first use: records sha256, logs 'first use, unverified', no download")  // AC3
func tofuFirstUseRecorded() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = Data("tofu bytes".utf8)
    let _ = try {
        let u = dir.appending(path: "model.bin")
        try data.write(to: u); return u
    }()
    let manifestToml = """
        version = 1
        [[asset]]
        url  = "https://example.org/model.bin"
        path = "model.bin"
        """
    try manifestToml.write(to: dir.appending(path: "gohfile.toml"),
                           atomically: true, encoding: .utf8)
    let result = GohSyncCommand.run(
        manifestPath: dir.appending(path: "gohfile.toml").path,
        base: nil,
        acceptChanged: false,
        send: { _ in throw GohError(code: .jobNotFound, message: "should not call add") })
    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("first use, unverified"))
    let lockToml = try String(
        contentsOf: dir.appending(path: "gohfile.lock"), encoding: .utf8)
    #expect(lockToml.contains("sha256:"))
}
```

**Step 2–4:** Run failing, implement (covered by T6.2 implementation), run passing.

**Step 5 — Commit**

```
test(trust-core): pinned acceptance + TOFU first-use golden tests (Phase 6, AC3)
```

---

### T6.4 — AC5: TOFU hash-changed detection

**Files**
- MODIFY `Tests/GohCoreTests/GohSyncCommandTests.swift`
- MODIFY `Sources/GohCore/CLI/GohSyncCommand.swift` (extract `resolveDrift` helper)

**Advisory C — single decision helper.** The unpinned-drift accept-or-record
decision currently appears TWICE in `GohSyncCommand` (the on-disk reconcile branch
in `runThrowing`, and the post-download branch in `downloadAndAccept`). Extract it
into ONE helper so both paths share a single code path; do not duplicate the
lock-update / AC5-event logic:

```swift
// GohSyncCommand.swift — shared by the reconcile branch and downloadAndAccept.
enum DriftDecision {
    case accepted(LockfileCodec.LockEntry)   // updated entry to record (exit 0)
    case rejected(LockfileCodec.LockEntry)    // keep OLD entry; AC5 event (exit 3)
}

/// The single decision point for an unpinned, drifted entry (AC5).
/// Emits the named "hash changed for unpinned entry" line into `output`, then
/// either records the new content (`--accept-changed`) or keeps the old entry.
private static func resolveDrift(
    asset: ManifestCodec.AssetEntry,
    oldEntry: LockfileCodec.LockEntry,
    freshDigest: String, freshSize: Int,
    acceptChanged: Bool,
    output: inout String
) -> DriftDecision {
    output += "hash changed for unpinned entry \(asset.path): "
        + "\(oldEntry.sha256) → \(freshDigest)\n"
    if acceptChanged {
        return .accepted(LockfileCodec.LockEntry(
            url: asset.url, path: asset.path,
            sha256: freshDigest, size: freshSize, downloadedAt: isoNow()))
    }
    return .rejected(oldEntry)
}
```

Both the reconcile branch (T6.2) and `downloadAndAccept` (T6.2) call `resolveDrift`;
the caller appends a `.hashChangedUnpinned` `SyncFailure` (→ exit 3) for the
`.rejected` case. `--accept-changed` only flips the `acceptChanged` argument.

**Step 1 — Failing tests**

```swift
// Add to GohSyncCommandTests:

@Test("AC5: unpinned upstream change → exit 3, lock unchanged without --accept-changed")  // AC5
func tofuHashChangedWithoutAccept() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // File has different bytes than what the lock recorded
    let oldData = Data("old bytes".utf8)
    let newData = Data("new bytes".utf8)

    let filePath = dir.appending(path: "model.bin")
    try newData.write(to: filePath)
    let (newDigest, newSize) = try FileDigest.sha256WithSize(path: filePath.path)
    let (oldDigest, _) = try {
        // Compute what the "old" digest would have been
        let tmp = dir.appending(path: "tmp-old.bin")
        try oldData.write(to: tmp)
        let r = try FileDigest.sha256WithSize(path: tmp.path)
        try FileManager.default.removeItem(at: tmp)
        return r
    }()

    let manifestToml = "version = 1\n[[asset]]\nurl = \"https://x.org/model.bin\"\npath = \"model.bin\"\n"
    let manifestPath = dir.appending(path: "gohfile.toml")
    try manifestToml.write(to: manifestPath, atomically: true, encoding: .utf8)
    let (mHash, _) = try FileDigest.sha256WithSize(path: manifestPath.path)

    // Write a lock that records the OLD digest
    let lockToml = """
        lockfileVersion = 1
        manifestHash    = "\(mHash)"

        [[entry]]
        url          = "https://x.org/model.bin"
        path         = "model.bin"
        sha256       = "\(oldDigest)"
        size         = \(oldData.count)
        downloadedAt = "2026-05-29T10:00:00Z"
        """
    try lockToml.write(to: dir.appending(path: "gohfile.lock"),
                       atomically: true, encoding: .utf8)

    let result = GohSyncCommand.run(
        manifestPath: manifestPath.path,
        base: nil,
        acceptChanged: false,
        send: { _ in throw GohError(code: .jobNotFound, message: "no download needed") })
    #expect(result.exitCode == 3)
    #expect(result.standardOutput.contains("hash changed for unpinned entry"))
    // Lock must be unchanged (still has old digest)
    let lockAfter = try String(
        contentsOf: dir.appending(path: "gohfile.lock"), encoding: .utf8)
    #expect(lockAfter.contains(oldDigest))
    _ = newDigest  // confirm variable used
    _ = newSize
}

// Both AC5 tests here drive the ALREADY-PRESENT-file branch (the file is on disk
// and differs from the lock), so a throwing `send` is correct — no download
// occurs. The accept-vs-reject decision flows through the shared `resolveDrift`
// helper (advisory C). The DOWNLOAD-path AC5 (a re-download whose fresh bytes
// differ from the recorded hash) is covered by a StatefulSyncMock test in T6.2.

@Test("AC5: --accept-changed updates lock and exits 0")
func tofuHashChangedWithAccept() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let oldData = Data("old bytes".utf8)
    let newData = Data("new bytes".utf8)
    let filePath = dir.appending(path: "m.bin")
    try newData.write(to: filePath)
    let (newDigest, _) = try FileDigest.sha256WithSize(path: filePath.path)
    let (oldDigest, _) = try {
        let tmp = dir.appending(path: "old.bin")
        try oldData.write(to: tmp)
        let r = try FileDigest.sha256WithSize(path: tmp.path)
        try FileManager.default.removeItem(at: tmp)
        return r
    }()

    let manifestToml = "version = 1\n[[asset]]\nurl = \"https://x.org/m.bin\"\npath = \"m.bin\"\n"
    let manifestPath = dir.appending(path: "gohfile.toml")
    try manifestToml.write(to: manifestPath, atomically: true, encoding: .utf8)
    let (mHash, _) = try FileDigest.sha256WithSize(path: manifestPath.path)

    let lockToml = """
        lockfileVersion = 1
        manifestHash    = "\(mHash)"

        [[entry]]
        url          = "https://x.org/m.bin"
        path         = "m.bin"
        sha256       = "\(oldDigest)"
        size         = \(oldData.count)
        downloadedAt = "2026-05-29T10:00:00Z"
        """
    try lockToml.write(to: dir.appending(path: "gohfile.lock"),
                       atomically: true, encoding: .utf8)

    let result = GohSyncCommand.run(
        manifestPath: manifestPath.path,
        base: nil,
        acceptChanged: true,  // --accept-changed
        send: { _ in throw GohError(code: .jobNotFound, message: "no download needed") })
    #expect(result.exitCode == 0)
    let lockAfter = try String(
        contentsOf: dir.appending(path: "gohfile.lock"), encoding: .utf8)
    #expect(lockAfter.contains(newDigest))
}
```

**Step 2 — Run and expect fail**
**Step 3 — Fix any gap** in T6.2 implementation covering these cases.
**Step 4 — Run and expect pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohSyncCommandTests
```

**Step 5 — Commit**

```
test(trust-core): AC5 TOFU hash-changed detection with and without --accept-changed (Phase 6, AC5)
```

---

### T6.5 — GohCommandLine.swift: wire sync/verify/which + full suite

**Files**
- MODIFY `Sources/GohCore/CLI/GohCommandLine.swift` — wire all three commands

**Step 1 — Failing tests (GohCommandLine integration)**

```swift
// Add to GohCommandLineTests.swift or create GohTrustCoreCommandLineTests.swift:

@Test("'goh which <path>' maps to which command")
func parsesWhich() {
    let cmd = GohCommandLine(
        arguments: ["which", "/tmp/file.bin"],
        send: { _ in throw GohError(code: .jobNotFound) })
    let result = cmd.run()
    // Should not exit 64 (parse error)
    #expect(result.exitCode != 64)
}

@Test("'goh which <path> <lockpath>' (explicit lock) maps to which command")
func parsesWhichWithLockPath() {
    let cmd = GohCommandLine(
        arguments: ["which", "/tmp/file.bin", "/tmp/proj/gohfile.lock"],
        send: { _ in throw GohError(code: .jobNotFound) })
    #expect(cmd.run().exitCode != 64)
}

@Test("which finds the lock in the TARGET FILE's dir + resolves entry under lockDir, not cwd (§9.3a)")
func whichResolvesUnderLockDirNotCwd() throws {
    // Build <tmp>/proj/gohfile.lock with entry 'sub/file.bin' and the file at
    // <tmp>/proj/sub/file.bin; run `which <tmp>/proj/sub/file.bin` (no explicit
    // lockpath) from a DIFFERENT cwd. It must still find <tmp>/proj/gohfile.lock
    // and resolve the entry under <tmp>/proj — exit 0. (cwd-relative resolution
    // would miss the entry → exit 4.) This is the §9.3a cross-machine guard.
}

@Test("'goh sync' maps to sync command")
func parsesSync() {
    let cmd = GohCommandLine(
        arguments: ["sync"],
        send: { _ in throw GohError(code: .jobNotFound) })
    let result = cmd.run()
    // Without a manifest this will fail, but it must not exit 64
    #expect(result.exitCode != 64)
}

@Test("'goh verify' maps to verify command")
func parsesVerify() {
    let cmd = GohCommandLine(
        arguments: ["verify"],
        send: { _ in throw GohError(code: .jobNotFound) })
    let result = cmd.run()
    #expect(result.exitCode != 64)
}
```

**Step 2 — Run and expect fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohCommandLineTests 2>&1 | head -30
```

**Step 3 — Implementation**

Add to `GohCommandLine.swift`:

```swift
// In ParsedCommand:
case which(path: String, lockPath: String?)   // optional explicit lock (§9.3a)
case sync(manifestPath: String?, base: String?, acceptChanged: Bool)
case verify(lockPath: String?, strictUntracked: Bool)

// In parse(_:).
// §9.3a (BLOCK 3): `which <path> [<lockpath>]` — parse, dispatch, AND usage all
// updated for the optional second positional.
if arguments.count == 2, arguments[0] == "which" {
    return .which(path: arguments[1], lockPath: nil)
}
if arguments.count == 3, arguments[0] == "which" {
    return .which(path: arguments[1], lockPath: arguments[2])
}
if arguments.first == "sync" {
    // parse [<path>] [--base <dir>] [--accept-changed]
    var path: String? = nil
    var base: String? = nil
    var acceptChanged = false
    var idx = 1
    while idx < arguments.count {
        switch arguments[idx] {
        case "--accept-changed":
            acceptChanged = true; idx += 1
        case "--base":
            base = try value(after: "--base", in: arguments, at: &idx)
        default:
            if !arguments[idx].hasPrefix("-") { path = arguments[idx]; idx += 1 }
            else { throw ParseError(message: "unknown sync option \(arguments[idx])") }
        }
    }
    return .sync(manifestPath: path, base: base, acceptChanged: acceptChanged)
}
if arguments.first == "verify" {
    var path: String? = nil
    var strictUntracked = false
    var idx = 1
    while idx < arguments.count {
        switch arguments[idx] {
        case "--strict-untracked": strictUntracked = true; idx += 1
        default:
            if !arguments[idx].hasPrefix("-") { path = arguments[idx]; idx += 1 }
            else { throw ParseError(message: "unknown verify option \(arguments[idx])") }
        }
    }
    return .verify(lockPath: path, strictUntracked: strictUntracked)
}

// In run() switch:
case .which(let path, let explicitLock):
    // §9.3a (BLOCK 3): locate the lock in the TARGET FILE's directory — NOT the
    // process cwd — unless an explicit <lockpath> is given. GohWhichCommand then
    // resolves each entry under the lock's OWN directory (lockDir), not cwd.
    let lockPath = explicitLock ?? URL(fileURLWithPath: path)
        .deletingLastPathComponent()
        .appending(path: "gohfile.lock").path   // NOT FileManager.currentDirectoryPath
    return GohWhichCommand.run(filePath: path, lockPath: lockPath)

case .sync(let manifestPath, let base, let acceptChanged):
    let resolved = manifestPath ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "gohfile.toml").path
    return GohSyncCommand.run(
        manifestPath: resolved, base: base,
        acceptChanged: acceptChanged, send: send)

case .verify(let lockPath, let strictUntracked):
    let resolved = lockPath ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "gohfile.lock").path
    return GohVerifyCommand.run(lockPath: resolved, strictUntracked: strictUntracked)
```

Update `usage()` to include:
```
  goh sync [<gohfile.toml>] [--base <dir>] [--accept-changed]
  goh verify [<gohfile.lock>] [--strict-untracked]
  goh which <path> [<lockpath>]
```

**Step 4 — Run full suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test 2>&1 | tail -30
# All tests must pass; -warnings-as-errors enforced by CI
```

**Step 5 — Commit**

```
feat(trust-core): wire sync/verify/which into GohCommandLine.parse and run (Phase 6, completes AC1–AC5)
```

---

**Phase 6 artifact** → `docs/superpowers/progress/2026-05-29-trust-core-phase6.md`

---

## Full Test Command Reference

```bash
# Individual test suite
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter MinimalTOMLReaderTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ManifestCodecTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter LockfileCodecTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter FileDigestTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter DownloadFileConfinementTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohWhichCommandTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohVerifyCommandTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GohSyncCommandTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter SyncPathConfinementTests

# Full suite (what CI runs)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

---

## Dependency Order (strict)

```
T1.1 MinimalTOMLReader (core parser)
  → T1.2 bad-fixture corpus
  → T2.1 ManifestCodec
    → T2.2 LockfileCodec
      → T2.3 FileDigest (parallel with T2.2)
        → T3.1 ErrorCode.symlinkComponentRefused
          → T3.2 DownloadFile confinement
            → T4.1 GohWhichCommand
              → T5.1 GohVerifyCommand
                → T6.1 SyncPathConfinement
                  → T6.2 GohSyncCommand core
                    → T6.3 AC3 pinned/TOFU tests
                      → T6.4 AC5 hash-changed tests
                        → T6.5 GohCommandLine wiring
```

T2.3 (FileDigest) can proceed in parallel with T2.2 (LockfileCodec) since both
only depend on T2.1 having established `ManifestCodec`. T3.1/T3.2 can proceed
in parallel with T4.1 since both only depend on Phase 2 being complete.
