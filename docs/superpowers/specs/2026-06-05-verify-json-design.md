---
date: 2026-06-05
feature: verify-json
type: spec
status: draft
approach: Compute Once, Render Twice
---

# Spec — `goh verify --all --json`

## 1. Problem

`goh verify --all` re-hashes every file in the provenance ledger and reports OK / FAILED / MISSING,
but only as human-readable text. To make the trust ledger usable in automation — the workflow that
gives an offline lockfile its value ("a nightly cron re-verifies `~/datasets` and fails the build /
alerts on drift") — a caller needs a stable, machine-parseable output and a documented exit-code
contract it can branch on. Today a script must scrape lines like `FAILED <path> expected … actual …`,
which is brittle and unversioned. This slice adds a `--json` presentation mode to `verify --all` and
formalizes the exit-code contract, without changing the existing human output or any exit code.

## 2. Success metrics

Each maps to an acceptance criterion; all are observable via the shipped CLI + Swift Testing.

- **M1 (AC1):** `goh verify --all --json` against a mixed ledger emits exactly one JSON document
  (parses with a standard JSON parser; no leading/trailing non-JSON) with `reportVersion: 1`, an
  `entries[]` array (each: `path`, `url`, `status`, `expectedSha256`, and `actualSha256` on FAILED),
  and a `summary` block. Because `summary` is **derived by folding over the final `entries[]`** (§6),
  the decode test must assert each count against the per-status filter of `entries` — `summary.total
  == entries.count`, `summary.ok == entries.filter { $0.status == .ok }.count`, and likewise for
  `failed` / `missing` — NOT merely that the four numbers sum. (Asserting only `ok+failed+missing ==
  total` would pass even if the tallies were mis-attributed.)
- **M2 (AC2):** the `--json` exit code equals the non-JSON exit code for the identical ledger state,
  honoring precedence **9 > 2 > 0** (0 all-ok; 2 any FAILED & no MISSING; 9 any MISSING). Verified
  by a test running both forms against one temp ledger for the all-ok, failed-only, and
  missing-present cases and asserting equal codes.
- **M3 (AC3 — the regression gate):** the human `goh verify --all` (no `--json`) output is
  byte-identical to today and its exit codes unchanged. **A change here is a release blocker.**
  Verified by every existing `GohVerifyAllCommandTests` / `GohVerifyAllParseTests` assertion passing
  unmodified, plus a new test asserting the human rendering for a mixed (FAILED + MISSING) ledger is
  byte-identical to the pre-refactor strings. That new test must assert the **full joined output
  string** (the exact concatenation, capturing line order == ledger order, the per-line trailing
  `\n`, and `lines.joined()` with no separator) — NOT `.contains()` (which would miss a line-order or
  separator regression). Preservation points the renderer must hold exactly: per-line trailing `\n`;
  line order == `record.entries` iteration order; empty AND absent ledger both emit the identical
  `"0 recorded entries\n"`; the exact `"FAILED <path> expected <sha> actual <sha>\n"` spacing.
- **M4 (AC4):** on an unreadable / corrupt / unknown-version ledger, `--json` emits a single JSON
  error envelope (`{ reportVersion: 1, error: <stable code> }`) on stdout — never mixed text+JSON —
  and returns exit 6; an empty/absent ledger emits a valid JSON document with `entries: []` and a
  zeroed summary, exit 0. Verified by per-condition tests.
- **M5 (AC5):** the schema is pinned by `Tests/GohCoreTests/Fixtures/verify-all-report-v1.json` +
  an encode-equals-fixture test; any change to the serialized schema fails the test.

## 3. Data model (the frozen JSON contract)

A new CLI-layer type (a new file, mirroring `DiagnoseTypes.swift`) — NOT a change to
`ProvenanceEntry` / `ProvenanceRecord` (`currentVersion` stays 1).

```swift
/// Frozen `--json` contract for `goh verify --all`. reportVersion bumps on ANY
/// breaking change to this shape. Field names and `status` raw values are FROZEN — do NOT rename.
public struct VerifyAllReport: Codable, Equatable, Sendable {
    public var reportVersion: Int          // = 1
    public var generatedAt: Date           // INJECTED by run() (see §6); ISO-8601 on the wire
    public var summary: VerifySummary
    public var entries: [VerifyEntryResult]
}
public struct VerifySummary: Codable, Equatable, Sendable {
    public var total: Int
    public var ok: Int
    public var failed: Int
    public var missing: Int
}
public struct VerifyEntryResult: Codable, Equatable, Sendable {
    public var path: String                // entry.destinationPath (canonical, as stored)
    public var url: String                 // entry.url
    public var status: VerifyStatus
    public var expectedSha256: String      // entry.sha256, verbatim "sha256:"-prefixed
    public var actualSha256: String?       // present ONLY when status == .failed; nil otherwise
}
/// FROZEN raw values — do NOT rename (scripts switch on these).
public enum VerifyStatus: String, Codable, Equatable, Sendable {
    case ok, failed, missing
}
```

**Error envelope** (ledger unreadable/corrupt/unknown-version):

```swift
public struct VerifyErrorReport: Codable, Equatable, Sendable {
    public var reportVersion: Int          // = 1
    public var error: VerifyErrorCode
}
/// FROZEN raw values — do NOT rename.
public enum VerifyErrorCode: String, Codable, Equatable, Sendable {
    case ledgerUnreadable     // file present but unreadable
    case ledgerCorrupt        // present, undecodable
    case ledgerVersionUnknown // decoded, version != currentVersion
}
```

The three `VerifyErrorCode` cases map 1:1 to the three real exit-6 producers in
`GohVerifyAllCommand` (unreadable / corrupt / unknown-version); the empty/absent ledger is NOT an
error (→ valid empty report, exit 0). **Deliberate asymmetry:** the human `ledgerVersionUnknown`
string carries the offending version number (`"version N is unknown"`); the JSON envelope drops it
(minimal frozen surface). This is intentional — adding a `ledgerVersion: N` field later would be a
`reportVersion` bump, not a bug fix.

- **Encoder:** `CommandCoding.encoder` (the canonical encoder: `dateEncodingStrategy = .iso8601`,
  `outputFormatting = [.sortedKeys]`, no pretty-print). One compact line + `\n`. This deliberately
  uses the canonical encoder over `goh diagnose`'s bare `JSONEncoder()` (a pre-existing inconsistency);
  the choice is documented in DESIGN.md. **Fixture note (do not copy diagnose's shape):** the
  `verify-all-report-v1.json` golden fixture is a **single compact line** — the `diagnose-report-v1.json`
  fixture is pretty-printed (`[.sortedKeys, .prettyPrinted]`) and is NOT the byte-comparison template
  here. The encode-equals test must compare the committed fixture against `CommandCoding.encoder`
  output (not a fresh `JSONEncoder()`/pretty-printed encoder). Note also `.iso8601` emits whole-second
  `…Z` and the encoder escapes `/` → `\/`, so the fixture will contain `\/` in paths/URLs.
- **`expectedSha256` / `actualSha256`** carry the stored `"sha256:<hex>"` form verbatim (matches the
  ledger and `FileDigest.sha256WithSize`). `actualSha256` is present only on `.failed` (on `.missing`
  there is nothing to hash; on `.ok` it equals expected and is omitted to keep the surface minimal).
- **Excluded from v1 on purpose** (minimal frozen surface): per-entry `downloadedAt` / `verifiedAt`
  (that is `goh which`'s concern, not verification); file size; a per-entry human message.

## 4. Exit-code contract (unchanged; now documented)

Preserved exactly from `GohVerifyAllCommand` today; `--json` returns the IDENTICAL code:

| Code | Meaning | Condition |
|---|---|---|
| 0 | all OK | every entry OK, or zero / absent / empty ledger |
| 2 | drift — hash MISMATCH | ≥1 FAILED and 0 MISSING |
| 9 | drift — file MISSING | ≥1 MISSING (precedence 9 > 2 > 0) |
| 6 | ledger error | unreadable / corrupt / unknown-version |
| 64 | usage error | bad flags/args (parse layer, `EX_USAGE`) |

Documented in `--help`/DESIGN.md: a plain `if [ $? -ne 0 ]` CI gate treats 2/9/6 alike (intended
"fail on any problem"); a script that must separate *drift* (2/9) from *tool error* (6), or *changed*
(2) from *gone* (9), checks the specific code. `2`/`9` do not collide with `sysexits.h` (which starts
at 64); this is a deliberate, documented divergence from `sha256sum -c` (which collapses all failures
to exit 1).

## 5. CLI surface

- `ParsedCommand.verifyAll` → `verifyAll(json: Bool)`. **Exact accepted grammar (B2):** the ONLY
  form that sets `json = true` is `goh verify --all --json` (in that order). The change is localized
  to the existing `--all` parse branch (`GohCommandLine.swift:289–301`): when `rest.first == "--all"`,
  the remainder may be empty (→ `verifyAll(json:false)`, unchanged) or exactly `["--json"]` (→
  `verifyAll(json:true)`); any other remainder (`--strict-untracked`, an unknown flag, a positional,
  or `--json` appearing more than once) is still rejected → exit 64.
  - **The frozen `verify` arm is NOT modified.** Therefore `goh verify --json --all` (json before
    `--all`) and `goh verify --json` (no `--all`) both fall through the existing non-`--all` path and
    are rejected as an unknown/usage error → exit 64. This is intended; do not add a special case that
    would alter the frozen `verify`/lockfile behavior.
  - **Parse tests to pin the boundary:** `verify --all --json` → `verifyAll(json:true)`;
    `verify --all` → `verifyAll(json:false)`; `verify --json --all` → exit 64; `verify --json` →
    exit 64; `verify --all --strict-untracked` → exit 64 (unchanged); `verify --all --json --json` → exit 64.
- Dispatch passes `json` to `GohVerifyAllCommand.run`. The `provenanceStorePathResolver` seam is
  unchanged.
- Usage/help text gains `goh verify --all [--json]` and a one-line exit-code summary (0/2/9/6/64).

## 6. Command structure (Compute Once, Render Twice)

`GohVerifyAllCommand.run(provenanceStorePath:json:generatedAt:)`:
1. Read the ledger exactly as today (same read-only path, same exit-6 conditions). On an error/empty
   condition: if `json`, return the JSON error envelope / empty report; else return today's exact human
   string. Same exit code either way.
2. Re-hash each entry once into the final `[VerifyEntryResult]`. Then **derive `summary` by folding
   over that final array** — `total = entries.count`, `ok/failed/missing = entries.filter { … }.count`
   per status — so `summary` has a single source of truth and cannot drift from `entries[]` (B1). The
   exit code is likewise computed from the final array via the existing precedence (9 > 2 > 0): any
   `.missing` → 9, else any `.failed` → 2, else 0. Do NOT maintain parallel `hasMissing/hasFailed`
   tallies for the JSON path that could diverge from the `entries[]` truth.
3. Render: if `json`, encode a `VerifyAllReport` (with the injected `generatedAt`) via
   `CommandCoding.encoder`; else join the existing human lines. **The human renderer must reproduce
   today's strings byte-for-byte** (see M3 preservation points). (The existing human path may keep its
   current `hasMissing/hasFailed` booleans for line emission, but the JSON path's status/summary/exit
   derive from the `entries[]` array.)
- `generatedAt` is **injected**: production stamps the current time at the call site; tests (and the
  golden fixture) pass a FIXED instant — an **integer epoch second** (e.g. `Date(timeIntervalSince1970:
  1_714_262_400)`, no fractional component, since `.iso8601` truncates to whole seconds) — so the
  encoded bytes are deterministic. `run`'s existing 2-arg signature is preserved via defaults
  (`json: Bool = false`, `generatedAt:` defaulted) so current callers/tests compile unchanged.

## 7. Out of scope

- Path-scoped `goh verify <dir>` subtree mode (no path-scoped provenance verify exists today) — its own slice.
- Any change to the human `verify --all` output (no summary line added).
- Streaming / NDJSON — the report is a single buffered document (personal scale).
- `goh verify` (lockfile verify) — frozen, untouched.
- Any `ProvenanceRecord` / on-disk format change; any new exit codes; non-SHA-256 hashes.
- `--json` on other commands (`ls`/`diagnose` already have their own; this slice is verify only).

## 8. Security surface

Local, read-only CLI; no network, no XPC, no new auth/authz surface. Reads only the user's own 0600
`provenance.plist` and re-hashes the user's own files — the same data class `goh which` already
exposes; no new disclosure. Hostile data in the ledger (e.g. a `destinationPath` containing newlines
or control characters) is safely escaped by `JSONEncoder`, so the JSON cannot be broken or
line-spoofed — strictly safer than the (unchanged) human text. No PII class beyond what the ledger
already holds (source URLs, local paths). Output size is bounded by the user's own ledger; no
attacker-controlled amplification.

## 9. Rollout & backward compatibility

Purely additive: a new flag + a new CLI-layer struct + a golden fixture. **Rollback** = revert the
flag/dispatch/struct; nothing persisted, no migration, no data touched. No rolling-deploy concern
(CLI-local; no daemon/XPC change; `protocolVersion` untouched). `reportVersion: 1` is the forward
signal: any future breaking change to the JSON shape bumps it, and the golden fixture forces that to
be a deliberate act.

## 10. Edge cases

- **Empty / absent ledger:** `--json` → `{ reportVersion:1, generatedAt, summary:{0,0,0,0}, entries:[] }`, exit 0; human → `"0 recorded entries\n"`, exit 0.
- **Unreadable / corrupt / unknown-version:** `--json` → error envelope with the matching `error` code, exit 6; human → today's exact string, exit 6. Never mixed text+JSON.
- **All OK:** every entry `status:"ok"`, `actualSha256` omitted, exit 0.
- **Mismatch only:** the mismatched entry `status:"failed"` with `expectedSha256` + `actualSha256`; exit 2.
- **Any missing:** missing entries `status:"missing"` (no `actualSha256`); exit 9 even if others also failed (precedence).
- **Mixed failed + missing:** both statuses present in `entries[]`; summary counts each; exit 9.
- **Semantically-odd-but-decodable entry** (malformed sha256 string, nonsense path): enters the
  re-hash loop and reports `failed`/`missing` — NOT exit 6 (corruption boundary is structural
  decodability, per the existing A4 rule); the JSON reflects that exactly.
- **Hostile path characters:** escaped by the encoder; JSON stays valid and unambiguous.
- **Large ledger:** buffered single document; acceptable at personal scale (documented non-goal: streaming).
- **`--json` without `--all`:** usage error, exit 64 (does not silently fall through to lockfile verify).
