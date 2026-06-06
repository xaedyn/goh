---
date: 2026-06-05
feature: verify-json
type: research-brief
---

# Research Brief — `goh verify --all --json`

## The problem in one line
`goh verify --all` detects ledger drift but prints human text only; to drop into CI/cron
("re-verify ~/datasets nightly, fail the build / alert on drift") it needs a stable
machine-readable surface + a documented exit-code contract. Scope (user-decided): `--all --json`
only; human output unchanged; no path-scoped subtree mode.

## Finding 1 — Schema shape: versioned object, not a bare array

Industry survey (Agent A):

- **Versioned root object is the norm for serious machine output** — trivy (`SchemaVersion: 2`
  int at root), SARIF (`version: "2.1.0"`), CycloneDX (`specVersion`) all carry an explicit version
  field `[VERIFIED]`. Bare arrays (pip-audit, osv-scanner) are the "didn't think about it" default
  `[VERIFIED]`. → use an object with `reportVersion: Int = 1` (mirrors goh's own `DiagnosisReport`).
- **A `summary{}` counts block is standard** — trivy, restic (`num_errors`), SARIF include
  aggregates so a parser need not iterate to decide pass/fail `[VERIFIED]`. → include
  `summary{ total, ok, failed, missing }`.
- **Three-way `status` enum (`ok|failed|missing`) is load-bearing** — a cron that pages differently
  on `missing` vs `failed` is a real use case; `sha256sum` collapses both to exit 1 but still
  distinguishes them in text `[VERIFIED]`. → per-entry `status` enum with frozen raw values
  (a "do NOT rename" comment, like `Verdict`).
- **Surface expected + actual hashes** on `failed` entries (omit actual on `missing`) — enough to
  diff without a re-run `[UNVERIFIED norm, but obvious given the data]`.
- **Recommended shape:**
  ```jsonc
  { "reportVersion": 1,
    "generatedAt": "2026-06-05T03:14:15Z",        // ISO-8601 UTC; injected for test determinism
    "summary": { "total": 42, "ok": 40, "failed": 1, "missing": 1 },
    "entries": [ { "path": "/p/f.bin", "url": "https://…", "status": "ok",
                   "expectedSha256": "sha256:…", "actualSha256": "sha256:…",  // actual omitted on missing
                   "downloadedAt": "…", "verifiedAt": "…" } ] }
  ```
  Use `entries[]` (matches goh's ledger vocabulary, avoids the `results[]` collision). `generatedAt`
  must be **injectable** so the golden-fixture encode test is byte-stable (a fixed instant in the test).

## Finding 2 — Exit-code contract: keep 0/2/6/64, document deliberately

- goh's contract is **already shipped** (slice 1): `0` all-ok, `2` any failed/missing, `6`
  ledger unreadable/corrupt/unknown-version, `64` usage. Constraint #1 forbids changing it, and the
  research **validates keeping it**:
  - `2 = verification failure` does NOT collide with `sysexits.h` (which starts at `64 = EX_USAGE`)
    `[VERIFIED]`; the "2 = misuse" meaning is a Bash-builtin convention, not a general-CLI one. It
    mirrors `diff` (1 differ / 2 trouble) and grype's deliberate `--fail-on` (2 = policy, 1 = tool
    error) `[VERIFIED]`. Advantage: a caller distinguishes "ran and found drift" (2) from "tool/ledger
    error" (6) in one `case`.
  - Caveat to document: the closest analog `sha256sum -c` uses **exit 1** for any failure (mismatch
    OR missing), no distinction `[VERIFIED]`. So goh's 2 is a deliberate, documented divergence.
  - `64 = EX_USAGE` is the most standards-aligned code in the table `[VERIFIED]`.
- **`--json` must return the SAME code as the human path for the same ledger state** (AC2). The flag
  is presentation-only; it never alters the exit code.
- **Always-JSON on error paths:** in `--json` mode, corrupt/unreadable/unknown-version emit a single
  JSON **error envelope** `{ reportVersion, error: <stable code> }` (never mixed text+JSON), keeping
  exit 6 — matching diagnose's always-JSON behavior `[VERIFIED in-repo]`. Empty ledger → valid JSON
  with empty `entries` + zeroed summary, exit 0.
- **Document the contract** in `--help` and DESIGN.md: a plain `if [ $? -ne 0 ]` CI gate treats 2/6
  alike (intended "fail on any problem"); scripts needing to separate drift from error check the code.

## Dependency enumeration (interfaces this feature modifies)
- **`ParsedCommand.verifyAll`** → `verifyAll(json: Bool)` (additive assoc value); consumers: the parse
  branch (allow `--json`, still reject `--strict-untracked`/positionals), the dispatch site, and
  `GohVerifyAllParseTests`. The `provenanceStorePathResolver` test seam must survive.
- **`GohVerifyAllCommand.run`** gains a `json: Bool` param (default false keeps callers valid); the CLI
  encoder is `CommandCoding.encoder`.
- **New CLI-layer types** (`VerifyAllReport`, `VerifyEntryResult`, `status` enum, error envelope) — no
  existing interface modified; `ProvenanceRecord.currentVersion` untouched (the JSON is a separate
  struct). New golden fixture `verify-all-report-v1.json`.

## Risks to carry into design validation
- **Golden-fixture determinism:** `generatedAt` (and any date field) makes encode-equals-fixture
  non-deterministic unless injected — the command stamps `now`, the type/test takes a fixed instant.
- **Frozen human path:** computing results once and rendering two ways must keep the human output
  byte-identical (guarded by the existing string/exit-code tests).
- **`reportVersion` is a frozen contract** the moment it ships — field names get a "do NOT rename"
  comment + the golden fixture forces a deliberate bump on any schema change.
