# P3 Artifact — Governor Wiring + Observation-Gate Redesign + Warm-Start

Phase 3 of the in-flight adaptive parallelism slice. Built via subagent-driven-development on branch
`design/in-flight-parallelism`, TDD per task, two-stage review (Opus quality/concurrency on the two
data-path/concurrency tasks). **Status: COMPLETE.** This phase makes the governor **functional** — it now
adjusts the live connection count during a download and feeds its converged N back to the per-host bandit.
**503 tests pass**, warning-clean under `-warnings-as-errors`, strict-concurrency-clean.

## Architectural gap found + resolved (user gate "build it right")

The original plan wired the governor onto P2's "N big pieces" queue — but the governor can only *add* a
worker if there is spare unclaimed work, and N pieces are claimed up front, so it would have been **inert**.
The spec §6.1 mandates **fixed-size chunks**. The user chose **"build it right."** This added **Task 11A**
(the fixed-size-chunk pool) as a prerequisite before the governor wiring. Without 11A, P3 would have shipped
a governor that couldn't converge (SM1/SM4 would be vacuous).

## What was built

- **Task 10** (`af6e728`) — `SelectionReason.warmStart`; `ObservationRequest` parameter struct; the
  observation gate now keys off `GovernorOutcome` (`effectiveN != nil && stabilized`) instead of
  `actualConnectionCount == requestedConnectionCount`; `recordObservationIfEligible`; all 7 gate tests + the
  `gohd` site migrated (`d5GateConnectionMismatchRejected` → `d5GateOffCandidateRejected`).
- **Task 11** (`bcb0ece`) — `JobStore.setActualConnectionCount` is peak-max (`max(existing, min(count,16))`,
  cap 16 not requestedN). The wire field is unchanged; only its meaning ("peak concurrent used") shifts.
- **Task 11A** (`a0160df`, **Opus-reviewed ✅**) — **fixed-size chunk pool**: `chunkSize` daemon constant
  (8 MiB default, **injectable** so tests pass a small value for multi-chunk coverage); `ChunkQueue` seeded
  with `ceil(total/chunkSize)` fixed-size chunks; **byte-based progress** (a `ByteCounter` ref type replacing
  the per-piece-index `RangeProgress`); **connection-slot indexing** (workers carry a slot in `0..<16`, freed
  on reap — the `withThrowingTaskGroup` element type is the returned slot `Int`). Behaviour-equivalent at
  fixed N (byte-identical output / SHA-256). Unblocks the governor.
- **Task 12** (`df35c8d`, **Opus-reviewed ✅**) — **the governor is wired and functional.** Per-flush rate
  deltas (slot-tagged) flow worker→control-loop via a `Mutex`-guarded `RateSampleSink`; the control loop
  drains them, calls `governor.record`/`decide` at each reap, and applies the decision to `targetN` (clamped
  [1,16]); `GovernorOutcome` flows to the 4-arg `completedDownloadHandler` → the bandit gate; the
  explicit-`--connections` **governor-off channel** is an ephemeral daemon-internal `ExplicitConnectionCounts`
  jobID→N table (NOT a `JobSummary` field); kill-switch `static let governorEnabled`. The governor `var` is
  mutated only synchronously in the control loop (no race); cooperative drop loses no bytes.
- **Task 13** (`090af0a`) — SM4 warm-start: `CommandDispatcher` emits `reason=warmStart` **iff** exploit +
  no-explicit-N + governor-on (never for every exploit). SM4 tests (exploit picks the best arm; predicate
  truth table).
- **Task 15** (`d82ad98`) — `EngineDiagnostics.recordGovernorDecision` + `ParallelismGovernor.phaseLabel`;
  the control loop emits `governor phase=… decision=… N=… host=…` under `GOH_ENGINE_TRACE=1` (SM1
  prerequisite). No-op when disabled (default).
- **Task 14** (`5b28652`) — DESIGN.md §Adaptive host scheduling (governor-gate redesign, throttle-pin
  per-download divergence) + §Observability (governor trace + warmStart annotation).

## Two review-caught issues (don't re-introduce)

1. **`Mutex` is noncopyable** — the plan's `Mutex<[UInt64:UInt8]>`/`Mutex<[WorkerRateSample]>` as optional
   params/struct properties won't compile. Resolved with the project's own reference-type idiom
   (`ExplicitConnectionCounts`, `RateSampleSink`, mirroring `ByteCounter`).
2. **11A slot force-unwrap** (`availableSlots.min()!`) was a latent crash if `targetN` ever exceeded 16 —
   closed in Task 12 by clamping `targetN` to [1,16] on every decision branch and guarding the slot
   allocation (`guard let slot = availableSlots.min() else { return }`).

## SM gates discharged in P3

- **SM3** (governor never backs off while derivative high) — P1 unit tests (held).
- **SM4** (governor-converged candidate N recorded → warm-start trace) — Task 12 (`GovernorOutcome` →
  candidate-only gate) + Task 13 (warmStart predicate). Unit-tested.
- **SM1** trace prerequisite (probe→cruise observable) — Task 15. The *numeric* SM1/SM2/SM5a targets are
  **benchmark gates for P4** (the governor's actual convergence to N≤4 saturated / N>8 LFN is proven on the
  dummynet harness + the sourced LFN target, not in unit tests).

## Invariants held

`protocolVersion` 3, `JobCatalog.version` 1, `JobSummary` wire shape, `host-scheduling.plist` v1,
`DownloadCheckpoint` v1 — all unchanged. `GovernorOutcome` + `ExplicitConnectionCounts` + `RateSampleSink`
are all daemon-internal; nothing crossed the wire.

## Open items for P4

1. **Benchmark the governor (SM1/SM2/SM5a — the headline).** Use the confirmed dummynet harness
   ([[dummynet-macos26-confirmed]]) for the deterministic gate and `sin-speed.hetzner.com/1GB.bin` for the
   real LFN proof. Tune `Config.default` (steadyStateWindow, kneeGainThreshold, rttBufferbloatFactor,
   reproBeCadence, **and `chunkSize`**) against measured convergence — these are first-cut values.
2. **Per-chunk rate-sample granularity** (Opus advisory, Task 12): `lastBytes`/`lastElapsed` reset per
   `consumeRange` invocation, so the first sample of each chunk on a reused slot measures ramp-up, not
   cruise. Acceptable (EWMA α=0.3 damps it); if convergence is jittery in the bench, seed `lastElapsed` from
   the prior chunk on the same slot or drop the first per-chunk sample.
3. **Global per-host `ConnectionBudget` (Task 17).** Insert the budget gate into `fillToTarget` + a
   worker-`defer` release into the structure 11A/12 built (the control loop is ready for it).
4. **`peakWorkers`/`actualConnectionCount` display** reports the high-water mark, not the converged cruise N
   (cosmetic for `goh top`/`ls`) — revisit if it matters for the launch story.
5. **Kill-switch is a compile-time `static let`** (spec §10 permits env *or* constant). If a runtime toggle
   is wanted for faster SM2 rollback, make it injectable.
