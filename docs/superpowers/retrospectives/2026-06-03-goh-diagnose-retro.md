---
date: 2026-06-03
feature: goh-diagnose
type: pipeline-retrospective
---

# Pipeline Retrospective — `goh diagnose`

## Adversarial Review Categories That Fired

### Spec Review (2 rounds, cap reached; all fixed)
- **Round 1 (7 block):** Product Validity (verdict confidently-wrong over h2/h3 multiplexing); Completeness
  (missing shadow paths); Internal Consistency (deadline 14s vs AC 10s; protocol-at-Phase-0 contradiction);
  Testability (non-deterministic throughput ACs); Technical Feasibility (post-hoc protocol metrics);
  Security (`--json` URL persistence vs no-disk claim); Interface Contracts (`[Int:Int]` JSON, units, enum).
- **Round 2 (3 block):** Completeness/Feasibility (no async→sync bridge — the "doctor pattern" is synchronous);
  Testability (injected-clock exact-rate integration test not implementable); Completeness (`bestObserved`
  undefined). All resolved (DispatchSemaphore bridge confirmed against real code; pure-logic/IO test split;
  inline `max(...)`).

### Plan Review (2 rounds, cap reached; all fixed)
- **Round 1 (8 block):** stalled-server deadline gap; `wholeFileMBps` unpopulated; exit codes routed through
  unfrozen `verdictText`; `snap1==0` sentinel; `Duration.infinity` arithmetic; conn-0 accept double-count
  ambiguity; false bridge-precedent citation; exit-1 dead code + malformed-URL gate inconsistency.
- **Round 2 (4 block):** the round-1 deadline fix bounded **Phase 1 only** → default N≥2 path unbounded;
  `--full` regressed to stop at the window; **Tₙ mis-measured** (constant divisor + conn-0 excluded);
  bounding tests used N=1 and couldn't catch any of it. Fixed via a single-task-group concurrent-drain
  restructure with real boundary snapshots and N≥2 tests.

## Approach Selected

**Chosen:** Comparative Probe (1→N ramp).
**THE BET:** A single 1-vs-N comparison, hedged honestly, is enough signal to give a useful and trustworthy
bottleneck verdict for the common case — and "could not distinguish" is an acceptable, honest answer for the
ambiguous one.
**Rejected:** Snapshot Probe (descriptive-only — under-delivers on the bottleneck verdict, the feature's point);
Scaling-Curve Probe (richest, but can't fit the ~12s budget and is materially more complexity for a quick verb).

## Design Validation Changes (Step 4B)

Four gaps found and folded into the spec: guaranteed-terminating + always-report probe; insufficient-data
degradation (no garbage throughput number); no cookies/credentials by default (auth URL → "requires auth");
exit-code semantics (exit 0 = diagnosis completed; non-zero reserved for "could not complete").

## Open Risks Not Resolved

1. **The concurrent throughput sampler is intricate** — both plan-review rounds found defects in it. The plan is
   now structurally correct and well-specified, but its correctness is genuinely proven only by the
   implementation's TDD (which now exercises the deadline bound, `--full` EOF, and Tₙ boundary-snapshots with
   N≥2) plus a dedicated concurrency review on the probe task. Flagged for that review during implementation.
2. **The bottleneck verdict is novel** — no shipping download CLI does an automatic last-mile-vs-source verdict
   [UNVERIFIED]; the honesty mitigations (h2/h3 multiplexed branch, hedged language, "can't tell apart") are the
   defense against over-claiming. Real-world verdict quality is unprovable in CI (no live network).
3. **`networkProtocolName` nil path** — protocol is post-hoc and can be nil (cache/metrics absent); the verdict
   takes the conservative multiplexed branch then. Acceptable, documented.
