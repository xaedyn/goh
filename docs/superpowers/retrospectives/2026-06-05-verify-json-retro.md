---
date: 2026-06-05
feature: verify-json
type: pipeline-retrospective
---

# Pipeline Retrospective — `goh verify --all --json`

## Adversarial Review Categories That Fired

### Spec Review (2 rounds)
- **Round 1 — 2 BLOCKs:**
  - Cat 1 (Product Validity): `summary` had no enforced single source of truth — its four `Int`
    counts could silently diverge from `entries[]`. Fixed: `summary` is **derived by folding over
    the final `entries[]`** (total = entries.count; ok/failed/missing = per-status filter), and M1's
    test asserts each count against its filter, not merely the sum.
  - Cat 3 (Completeness): the `--json` flag-position grammar was under-specified against the real
    parser. Fixed: only `verify --all --json` sets json=true (remainder empty OR exactly `["--json"]`);
    `--json` anywhere else → exit 64 via the unmodified frozen `verify` arm; explicit parse tests.
  - Plus 4 advisories folded in: compact (not pretty) fixture via `CommandCoding.encoder`; integer-epoch
    `generatedAt`; the deliberate `ledgerVersionUnknown` version-number-drop asymmetry; the new
    mixed-ledger human test asserts the full joined string (not `.contains()`).
- **Round 2 — APPROVED:** all 10 categories pass; both blocks resolved; no second-order defects; the
  exit-code fold proven byte-equivalent to the real `hasMissing/hasFailed` precedence.

### Plan Review (1 round)
- **Round 1 — APPROVED, 0 BLOCKs.** The reviewer byte-verified the golden fixture against live
  `CommandCoding.encoder` output (806 bytes, sorted keys, `\/` escaping, whole-second `Z`,
  `actualSha256` omitted on non-failed). 5 advisories, all non-blocking; one folded into Task 4 (the
  `--help` test must assert `"verify --all [--json]"`, not just `contains("--json")`, which already
  appears in other usage lines — otherwise the assertion is vacuous).

## Approach Selected

**Chosen:** Compute Once, Render Twice — the verify loop produces one result model; the command renders
either today's byte-identical human text or the JSON report from it, computing the exit code once.
**THE BET:** deriving both renderings from one result model keeps the JSON and human verdicts + exit
codes consistent at zero ongoing cost, and the existing byte-exact regression tests prove the human
output stayed identical after the refactor.
**Rejected:** Bolt-on parallel JSON path — keeps the human code untouched but duplicates the verify /
classification / exit-code logic, the wrong debt for a trust command (two answers to "did it verify?").

## Design Validation Changes

Two gaps found and fixed before the spec: golden-fixture non-determinism (→ `generatedAt` injected as a
fixed integer-epoch second) and frozen-surface creep (→ minimal entry surface; per-entry provenance
dates excluded as `goh which`'s concern).

## Open Risks Not Resolved

- The exit-code contract (`2` = changed, `9` = missing) is a deliberate, documented divergence from
  `sha256sum -c` (which collapses all failures to exit 1). It cannot be changed (already shipped in
  slice 1) and the research validated keeping it; documented in `--help`/DESIGN.md so scripts branch
  on the specific code.
- `reportVersion: 1` becomes a frozen contract the moment it ships; the golden fixture is the guard.

(No unresolved blocking risks.)
