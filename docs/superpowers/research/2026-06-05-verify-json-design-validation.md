---
date: 2026-06-05
feature: verify-json
type: design-validation
---

# Design Validation — `goh verify --all --json`

Chosen approach: **Compute Once, Render Twice** — the verify loop produces one result model;
the command renders either today's byte-identical human text or a versioned JSON report from it,
computing the exit code once.

## Acceptance Criteria (from Step 2.5)
- **AC1** — single valid JSON doc: `reportVersion:1` + `entries[]` (path, url, status, expected/actual sha256) + `summary{total,ok,failed,missing}` whose counts match the entries.
- **AC2** — `--json` exit code == human exit code for the same ledger state (0 all-ok / 2 any failed|missing).
- **AC3** — human `verify --all` output byte-identical + exit codes unchanged (existing tests pass unmodified).
- **AC4** — corrupt/unreadable/unknown-version → single JSON error envelope, exit 6; empty → valid empty JSON, exit 0.
- **AC5** — schema pinned by `verify-all-report-v1.json` golden fixture + encode test.

## Dependency Enumeration
- **`ParsedCommand.verifyAll` → `verifyAll(json: Bool)`** (additive assoc value). Consumers: the `--all`
  parse branch (must allow `--json`, still reject `--strict-untracked`/positionals), the dispatch site
  (`GohCommandLine.swift:126–129`), and `GohVerifyAllParseTests`. The `provenanceStorePathResolver` seam
  must survive.
- **`GohVerifyAllCommand.run` gains `json: Bool` (default false)** — existing callers/tests stay valid.
- **New CLI-layer types** (`VerifyAllReport`, `VerifyEntryResult`, `status` enum, error envelope) — no
  existing interface modified; `ProvenanceRecord.currentVersion` untouched. New golden fixture.
- **No external consumers** of any modified interface outside the CLI module.

## Questions Asked & Answers

### Zero Silent Failures
- **Existing users/data on ship?** `--json` additive; human output + exit codes byte-identical (guarded by
  existing string/exit-code tests + a new "human unchanged for mixed states" test). `provenance.plist`
  read-only; no on-disk format change (JSON is a separate CLI struct). No multi-step write → no partial state.
- **Existing callers of `run`?** `json: Bool = false` default keeps them compiling unchanged.
- **Parse change?** `verifyAll(json:)` is an internal enum; all consumers updated in-slice.

### Failure at Scale
- **10× volume?** A large ledger builds a large in-memory `entries[]` + one JSON string — same iteration
  order as today's human path; no new amplification. Report is **buffered, not streamed** (single JSON
  document) — acceptable at personal scale (provenance is personal-scale by the slice-1 bet); documented.
- **Concurrent ops?** Verify is read-only via `loadReadOnly()`; a concurrent daemon write is atomic
  (`rename(2)`), so the CLI reads either the whole old or whole new file — never torn.
- **Dependency unavailable?** The "dependency" is `provenance.plist`: unreadable/corrupt → exit 6 + JSON
  error envelope; missing/empty → valid empty JSON, exit 0. Daemon state irrelevant (direct read).

### Simplest Attack
- **Cheapest abuse?** Local, read-only, no network/XPC/auth surface; surfaces only the user's own 0600
  ledger data (same as `goh which`). No new disclosure.
- **Hostile data in the ledger (e.g. a path with newlines/control chars)?** `JSONEncoder` escapes all
  string values, so the JSON cannot be broken or injected — strictly safer than the (unchanged) human
  text, where an embedded newline could already spoof a line. No new risk; the human path is untouched.
- **DoS?** Output size is bounded by the user's own ledger; no attacker-controlled amplification.

## Gaps Found
1. **Golden-fixture non-determinism:** a `generatedAt` timestamp (and any per-entry date) would make the
   encode-equals-fixture test non-byte-stable.
2. **Frozen-surface creep:** every entry field becomes a frozen contract; the schema should stay minimal.
3. **Buffered (non-streamed) report** at very large ledger sizes.

## Fixes Applied
1. **`generatedAt` is injected**, not read from the clock inside the encoder path: `run` stamps the
   current time (or takes an injected clock/instant), passes it into `VerifyAllReport`; the golden-fixture
   test constructs the report with a FIXED instant so the serialized bytes are stable. (Mirrors how date
   fields are handled deterministically elsewhere.)
2. **Minimal entry surface:** `entries[]` carries `{ path, url, status, expectedSha256, actualSha256? }`
   only — `actualSha256` present on `failed`, omitted on `missing`/`ok`-without-need (decide exact omission
   rule in spec). Per-entry provenance dates (`downloadedAt`/`verifiedAt`) are **excluded** — they are
   `goh which`'s concern, not verification; keeping them out minimizes the frozen schema. `reportVersion`
   field names carry a "do NOT rename" comment; the golden fixture forces a deliberate bump on any change.
3. **Buffered report accepted + documented** (personal scale); streaming/NDJSON is an explicit non-goal,
   revisited only if a non-personal-scale use emerges.

No unresolved gaps.
