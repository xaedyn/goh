---
date: 2026-06-05
feature: verify-json
type: codebase-context-brief
---

# Codebase Context Brief — `goh verify --all --json`

## STACK
Swift 6.2/6.3 (Swift 6 language mode, nonisolated-default on `GohCore`), macOS 26.0+. CLI is
synchronous (no async in verify). JSON via `Foundation.JSONEncoder`. Swift Testing; CI
`-warnings-as-errors`. Binary-plist provenance store.

## EXISTING PATTERNS
- **CLI parse/dispatch** — hand-rolled in `GohCommandLine.parse(_:)` (`GohCommandLine.swift:251–349`).
  The `verify` arm branches on `rest.first == "--all"` (289–301); `ParsedCommand.verifyAll` is a
  **no-associated-value** case (228). Extra flags after `--all` are rejected → exit 64 (`ParseError`,
  174–177). Dispatch at 126–129.
- **JSON precedent (canonical)** — `goh ls --json` via `GohCommandLine.json(_:)` (536–545) using
  `CommandCoding.encoder` (`CommandCoding.swift:10–15`: `dateEncodingStrategy = .iso8601`,
  `outputFormatting = [.sortedKeys]`, no prettyPrint), one compact line + `\n`.
- **JSON precedent (versioned shape)** — `goh diagnose --json` (`GohDiagnoseCommand.jsonString`,
  188–191) emits a `DiagnosisReport` with `reportVersion: Int = 1` (`DiagnoseTypes.swift:67`) and a
  frozen golden fixture `Tests/GohCoreTests/Fixtures/diagnose-report-v1.json`. Diagnose emits JSON
  on ALL termination paths (115–128). NOTE inconsistency: diagnose uses a **bare `JSONEncoder()`**
  (no settings) while ls uses `CommandCoding.encoder`. **Decision for this slice: use
  `CommandCoding.encoder`** (canonical) for both production output and the test fixture.
- **Golden-fixture test pattern** (`DiagnoseTypesTests.swift:71–116`): load committed fixture from
  `#filePath`-relative `Fixtures/…json`, `#expect(actualJSON == fixtureJSON)`. Fixture is committed,
  not auto-regenerated. Mirror as `verify-all-report-v1.json`.

## RELEVANT FILES

| File | Purpose | Key signatures |
|---|---|---|
| `Sources/GohCore/CLI/GohVerifyAllCommand.swift` | `verify --all` runner | `run(provenanceStorePath: String) -> GohCommandLineResult` (28). Exit codes in header 14–21. |
| `Sources/GohCore/CLI/GohCommandLine.swift` | parse + dispatch + json helper | `ParsedCommand.verifyAll` (228); `--all` parse (289–301); dispatch (126–129); `json<Payload:Encodable>(_:)` (536–545) |
| `Sources/GohCore/CLI/GohDiagnoseCommand.swift` + `DiagnoseTypes.swift` | `--json` + versioned-struct precedent | `reportVersion: Int = 1` (DiagnoseTypes 67); `Verdict` frozen raw values "do NOT rename" (51) |
| `Sources/GohCore/Provenance/ProvenanceRecord.swift` | on-disk model surfaced in JSON | `ProvenanceEntry {url, sha256 (\"sha256:\"-prefixed, 39–40), size, downloadedAt, destinationPath, verifiedAt: Date?}` |
| `Sources/GohCore/TrustCore/FileDigest.swift` | re-hash | `sha256WithSize(path:) -> (String, Int)` returns `"sha256:<hex>"` |
| `Sources/GohCore/Model/CommandCoding.swift` | canonical encoder | `CommandCoding.encoder`: iso8601, `[.sortedKeys]` |
| `Tests/GohCoreTests/GohVerifyAllCommandTests.swift` / `GohVerifyAllParseTests.swift` | verify-all behavior + parse tests | assert exact strings + exit codes + the `provenanceStorePathResolver` seam |

## Current `verify --all` output + exit-code contract (de-facto frozen — must NOT change)
Strings (`GohVerifyAllCommand.swift`): `"OK <path>\n"` (94); `"FAILED <path> expected <sha> actual <sha>\n"` (96–98);
`"MISSING <path> (expected <sha>)\n"` (84,88); `"0 recorded entries\n"` (35,70);
`"provenance ledger unreadable\n"` (41); `"provenance ledger corrupt\n"` (51);
`"provenance ledger version N is unknown\n"` (57).
Exit codes: `0` all-ok (109); `2` any FAILED/MISSING (106); `6` unreadable/corrupt/unknown-version (42,50,57);
`9` (104) — verify the exact meaning in the file; precedence among 9/2/0. Parse errors → `64`.

## CONSTRAINTS (must not change)
1. Human `verify --all` output strings + exit codes are a de-facto contract — `--json` is **additive**.
2. `GohVerifyCommand` (lockfile verify, `run(lockPath:strictUntracked:)`) is **frozen** — do not touch.
3. CLI verify is **read-only / daemon-down-capable** — reads `provenance.plist` directly with
   `PropertyListDecoder()`, never creates sidecars/resets the store. Preserve on the JSON path.
4. The `provenanceStorePathResolver` test seam (GohCommandLine 40–52) must survive a new `json:` param.
5. `ProvenanceRecord.currentVersion = 1` is frozen — the JSON is a **separate CLI-layer struct**, not a
   `ProvenanceEntry` change.
6. `ParsedCommand.verifyAll` → `verifyAll(json: Bool)`; the `--all` extra-flag rejection (291–296) must
   newly allow `--json` while still rejecting `--strict-untracked`/positionals.

## OPEN QUESTIONS (resolved at clarity check / to confirm in design)
- **Scope (user-decided):** `--all --json` only; no path-scoped subtree verify (none exists today). Human
  output unchanged (summary counts live only in JSON).
- **Encoder:** use `CommandCoding.encoder` (canonical); document over diagnose's bare-encoder inconsistency.
- **Schema version:** include `reportVersion: Int = 1` (mirror diagnose) as the contract-bump signal; frozen
  field names (a "do NOT rename" comment like `Verdict`).
- **Always-JSON on error paths:** in `--json` mode, corrupt/unreadable/unknown-version/empty ledger must emit
  a single JSON document (error envelope), never mixed text — matching diagnose's always-JSON behavior — and
  must preserve the existing exit code for that condition.
- **sha256 form:** surface the stored `"sha256:<hex>"` verbatim in JSON (matches ledger + FileDigest).
