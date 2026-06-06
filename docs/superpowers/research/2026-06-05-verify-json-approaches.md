---
date: 2026-06-05
feature: verify-json
type: approach-memos
---

# Approach Decision Memos — `goh verify --all --json`

The JSON schema and exit-code contract are settled by the research brief (versioned object +
`summary` + three-way `status` enum; keep 0/2/6/64; always-JSON error envelope; `CommandCoding.encoder`;
golden fixture). The remaining architectural decision is **how the command is structured** so the
JSON and the byte-frozen human output stay consistent without duplicating the verify loop.

---

## APPROACH 1 — Compute Once, Render Twice  *(recommended)*

CORE IDEA
`GohVerifyAllCommand.run` computes the per-entry results + summary + worst-exit ONCE into an
in-memory model, then renders either the existing human strings or the JSON report from that single
model.

MECHANISM
Refactor `run(provenanceStorePath:json:)` so the verify loop produces `[VerifyEntryResult]` (path,
url, status, expected/actual sha256, dates) and a derived `summary` + exit code. A `renderHuman()`
function reproduces today's exact strings (`OK …`, `FAILED … expected … actual …`, `MISSING … (expected …)`,
the empty/error lines); a `renderJSON()` encodes a `VerifyAllReport` via `CommandCoding.encoder`. The
exit code is computed once from the result set and returned identically on both paths. Error/empty
ledger states map to the same exit code on both paths (human strings vs JSON error envelope).

FIT ASSESSMENT
Scale fit: matches — same single pass over the ledger; no extra I/O.
Team fit: fits — mirrors `goh diagnose` (compute a report, render text or `--json`).
Operational: none new; read-only, daemon-down-capable preserved.
Stack alignment: fits — `CommandCoding.encoder`, Swift Testing golden fixture.

TRADEOFFS
Strong at: single source of truth — JSON and human output can never disagree; exit code computed
once; no duplicated verify logic to drift.
Sacrifices: touches the frozen human path's *code* (not its output) — requires the existing
string/exit-code regression tests to pin byte-identical output (they already do).

WHAT WE'D BUILD
`VerifyAllReport` + `VerifyEntryResult` + `status` enum + error-envelope type (new CLI-layer file,
à la `DiagnoseTypes`); refactored `run`; `renderHuman`/`renderJSON`; `verifyAll(json:)` parse +
dispatch; `verify-all-report-v1.json` golden fixture + tests.

THE BET
Deriving both renderings from one result model keeps them consistent at zero ongoing cost, and the
existing regression tests are sufficient to prove the human output stayed byte-identical after the
refactor.

REVERSAL COST
Easy — additive flag + an internal refactor; revert restores the prior `run`.

WHAT WE'RE NOT BUILDING
No subtree verify; no change to human output; no `ProvenanceRecord` change; no new exit codes.

INDUSTRY PRECEDENT
`goh diagnose` (in-repo): computes a `DiagnosisReport`, renders human or `--json` from it. Trivy/grype
likewise derive text and JSON from one scan model `[VERIFIED]`.

---

## APPROACH 2 — Bolt-on JSON Path  *(rejected — logic duplication)*

CORE IDEA
Leave `run`'s human path untouched; add a separate `runJSON` that re-iterates the ledger and emits the
report.

MECHANISM
`verifyAll(json:)` dispatches to either the existing `run` (unchanged) or a new `runJSON` that repeats
the load + per-entry re-hash + status classification and encodes the report.

FIT ASSESSMENT
Scale fit: matches volume but does the verify classification in two places.
Team fit: fits, but invites divergence.
Operational: none new.
Stack alignment: fits.

TRADEOFFS
Strong at: zero risk to the frozen human path (its code is literally untouched).
Sacrifices: **duplicated verify/classification logic** — two code paths that must stay in lockstep
on hash form, canonicalization, status precedence, and exit codes; a future fix to one can silently
skip the other. For a trust feature, two answers to "did it verify?" is the wrong kind of debt.

THE BET
The verify logic is stable enough that a duplicated second copy won't drift — which the project's own
history (review-caught divergences) argues against.

REVERSAL COST
Easy to revert, but the duplication is a standing maintenance cost while it lives.

WHAT WE'RE NOT BUILDING
n/a — not recommended.

INDUSTRY PRECEDENT
None that favors duplicating the core check to add an output format.

---

## Comparison matrix

| Criterion | A1 Compute Once, Render Twice | A2 Bolt-on JSON Path |
|---|---|---|
| AC1 (valid versioned JSON + summary that matches entries) | STRONG — one model feeds the encoder | STRONG (if kept in sync) |
| AC2 (same exit code as human path) | STRONG — exit computed once, shared | PARTIAL — two exit computations can drift |
| AC3 (human output byte-identical) | STRONG with the regression tests as the guard | STRONG — human code untouched |
| AC4 (always-JSON error envelope, exit preserved) | STRONG — error states mapped once, rendered two ways | PARTIAL — error mapping duplicated |
| AC5 (golden-fixtured schema) | STRONG | STRONG |
| Scale fit | STRONG | STRONG |
| Team fit | STRONG — mirrors diagnose | PARTIAL — divergence risk |
| Operational burden | STRONG — none | STRONG — none |
| Stack alignment | STRONG | STRONG |

**Recommendation: Approach 1 (Compute Once, Render Twice).** It is the only option that guarantees the
JSON and human verdicts — and their exit codes — cannot disagree, which is the whole point of a trust
command. The single risk it carries (refactoring the frozen human path's code) is fully covered by the
existing byte-exact string + exit-code regression tests. Approach 2 buys human-path safety at the price
of a duplicated verify loop — the wrong trade for a feature whose job is a single trustworthy answer.
