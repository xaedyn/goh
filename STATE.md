# STATE.md — goh current state

Where the project is right now. Read after `CLAUDE.md` at the start of every
session; update at the start of every PR and at the end of every session.

## Current state

### 2026-06-03 (session) — Governor **REDESIGNED + fixed** (was inert/regressing); LFN headline unprovable on this link; strategic **pivot to the trust layer**; `goh diagnose` scoped next

**Branch `design/in-flight-parallelism`. Commit `38be1b0` (`fix(governor): redesign convergence around aggregate delivery rate`). 507 tests pass, `-warnings-as-errors` clean. NOT pushed yet.**

**1. The governor was broken — now fixed (committed).** Running Task 19's benchmark caught it: the in-flight
governor was **inert** and *regressed* ~20% vs static-8 on a real LFN. Root cause (confirmed via field
instrumentation, 0/120 evaluations ever "steady"): the per-worker steady-state detector (`allWorkersInSteadyState`,
"all connections within 5%") could never pass on a real network — real per-flush rates jitter 10–206%, slot 0 was
sample-starved, and `decide()` was called on `liveWorkers` (N−1, an off-by-one). Governor sat at the seed N the
whole download.
  - **Fix (commit `38be1b0`):** replaced the per-worker gate with a **BBR-style hill-climb on the AGGREGATE
    delivery rate**. Governor now takes one aggregate sample per control window via
    `record(aggregateBytesPerSecond:)`; the engine measures aggregate over **≥0.25 s windows** (per-reap intervals
    were too short → jitter) from the shared `ByteCounter` (added a `.value` getter) and passes the **operating
    `targetN`** to `decide()` (off-by-one fixed). Dwell `settleSamples` windows at each N, keep a step up the
    `{2,4,8,16}` ladder only when aggregate gain ≥ `kneeGainThreshold`, else settle lower; periodic cruise
    re-probe. `Config.default` tuned: `settleSamples 8, kneeGainThreshold 0.07, reprobeCadence 40, rateAlpha 0.3`.
    Removed `RateSampleSink`/`WorkerRateSample`/per-worker machinery. Files: `ParallelismGovernor.swift` (rewrite),
    `DownloadEngine.swift` (aggregate sampling + operating-N), `ParallelismGovernorTests.swift` (rewritten, 7 tests).
  - **Validated:** trace now shows correct convergence (dwell@8 → addWorkers → dwell@16 → commit(16) → cruise@16,
    no detour) and **no regression** (governed ≈ static-8).

**2. The SM5a "headline win" is UNPROVABLE on this connection — and that's an environment limit, not a bug.**
  - Original target `sin-speed.hetzner.com` **rate-limits parallel connections** (6/8 → HTTP 429). Unusable. Note:
    the engine currently **hard-fails (httpStatus)** when a server 429s a parallel range — a real product-robustness
    gap worth a future design pass (governor should back off, not abort).
  - Switched to **OVH France** (`https://proof.ovh.net/files/1Gb.dat` — 8/8 parallel 206, ~105 ms RTT, https,
    honors Range). Good LFN target. Results in `docs/bench/lfn-results-worksheet.md` (full before/after recorded).
  - **n=9: governed 20.36 s vs static-8 20.71 s — ~1.7 %, IQR overlaps.** Raw curl proved why: aggregate throughput
    is the SAME at 8 and 16 conns (~57 MB/s ceiling) AND two far sources combined ≤ one source. **The bottleneck is
    the user's last-mile (~50–57 MB/s to distant hosts over Wi-Fi), not the source.** 8 conns already saturate it;
    16 has no headroom; multi-source can't help either. A clean SM5a win needs higher RTT + uncapped + higher-ceiling
    (a self-hosted far VPS, e.g. Vultr Tokyo — researched, ~1¢/hr) or a faster link. User declined the VPS for now.
  - **Disposition:** the governor ships as **correct + adaptive + no-regression**; the *benchmarked* headline is
    deferred (needs a proper proving ground). Worksheet `OVERALL: NEEDS-TUNING/defer headline`.

**3. STRATEGIC PIVOT — speed is at the physics ceiling for this user; the moat is the trust layer.** Ran the
`product-vision` skill (parallel codebase + market analysis, both Opus). New memo: **`docs/vision/VISION-2026-06-03.md`**
(supersedes the trust-layer sections of `VISION-2026-05-26.md`). Sharpened thesis: don't pitch "trust layer" (too
close to OpenSSF signing) or "integrity for downloads" (HF/Ollama do per-source already). The **unowned, defensible
wedge goh already built**: a **vendor-neutral, offline lockfile** — *"is this still exactly what I downloaded?"*
verified against YOUR frozen record, across any source, even if upstream is deleted (HF's `hf cache verify` checks
the LIVE hub; the TRELLIS-deletion case proves upstream isn't a reliable oracle). Evidence: aria2 #173 (open since
2013), HF #3298/#3643, Ollama #14554. Platform risk: ~12 mo before HF could close the HF-only slice.

**4. `hf://` adapter — proposed then DECLINED by the user.** The vision's top "bet" was smart-URL adapters
(`hf://`, `kaggle://`). User **declined**: doesn't want to couple goh to an external service's API (breakage +
maintenance) or build any login/token path. New memory saved: **[[goh-prefers-self-contained]]** — favor
self-contained trust-layer work, don't pitch external-service integrations.

**5. NEXT ACTION — build `goh diagnose <url>` (self-contained; scoped, not started).** Surface the engine's existing
diagnostics (`EngineDiagnostics`/`GOH_ENGINE_TRACE`, `Sources/GohCore/Engine/EngineDiagnostics.swift`) as a clean
plain-English CLI verb. **Confirmed behavior:** quick ~10 s sample by default, `--full` flag for the whole file;
discards the bytes; CLI-local (no daemon, no new XPC/wire surface — mirror `goh verify`/`which`). Report shape (user
approved): server + range support, negotiated protocol (h2/h3/1.1), #connections opened & how many the server
accepted (catch 429 rate-limiting), throughput estimate, bottleneck (last-mile vs source), one-line verdict.
  - **THE DESIGN WRINKLE to solve first:** to report *"server rejected 6 of 8 connections"*, diagnose **cannot**
    reuse the normal download path (it aborts on the first non-206 — the Hetzner httpStatus failure). Needs a
    **probe mode that opens connections and records each outcome WITHOUT aborting**. Everything else is
    straightforward reuse (DownloadEngine + EngineDiagnostics, run in-process, temp/throwaway sink, ~10 s
    cancel, structured summary instead of stderr-scraping → extend EngineDiagnostics to retain structured data).
  - Files likely touched: new `GohDiagnoseCommand.swift`, `EngineDiagnostics.swift` (structured capture),
    `GohCommandLine.swift` (verb + usage), tests. ~3–5 files. Start with `enterprise-pipeline` (it has the
    probe-without-abort design decision) — or `quick-plan` if the wrinkle resolves trivially on inspection.

**Session-end housekeeping for next time:** `38be1b0` is unpushed on `design/in-flight-parallelism`. The
in-flight-parallelism P1–P4 work is functionally done + correct but the SM5a headline benchmark is deferred — decide
whether to (a) PR P1–P4 as "correct adaptive governor, no regression" (drop the headline claim), or (b) hold for a
VPS/faster-link proof. The `goh diagnose` work is a fresh, self-contained slice — could be its own branch off this
one or off `main` after deciding the P1–P4 PR question.

---

### 2026-05-31 (impl session) — In-flight adaptive parallelism **P4 code done (Tasks 17–18)**; only Task 19 (the manual benchmark run) remains before the headline ships

- **P4 Tasks 17 + 18 shipped on `design/in-flight-parallelism`** (the autonomous code parts). **508 tests
  pass**, warning-clean. Task 19 (running the benchmarks) is the **you-in-the-loop** step — see below.
  - `24d4cb6` + `d45934d` — **Task 17:** global per-host `ConnectionBudget` (spec §8) gated into the control
    loop (budget request before each spawn, worker-`defer` release, leak-proof). **Opus-reviewed ✅.** It's a
    **soft cap with a liveness floor**: a download that would seed zero workers (siblings hold the budget)
    force-admits exactly one un-budgeted connection so it always progresses — peak per-host bounded at
    `16 + (D−1)`. Default-nil in the engine (no behavior change for existing tests); gohd creates one shared
    16-budget. DESIGN.md §Adaptive host scheduling documents the soft-cap.
  - `fe08c5a` — **Task 18:** `goh-bench lfn` subcommand (governed vs `--static-n`, median + IQR seconds,
    JSON out) + `docs/bench/lfn-runbook.md` (SM5a/SM2 commands + quarantine policy). The static control arm
    uses the explicit-connection-count channel to disable the governor. Builds; not run (real network).
- **NEXT ACTION — Task 19 (manual, you-in-the-loop): run the benchmarks + tune + write the P4 artifact.**
  This is the only thing between here and shipping the single-edge headline. **The fill-in worksheet is
  `docs/bench/lfn-results-worksheet.md`** (copy-paste commands + result slots + a RESULTS SUMMARY block the
  next session reads first; embeds a `Range`-honoring server for the local SM2 test). Rationale is in
  `docs/bench/lfn-runbook.md`. When the user says "results are in the worksheet," read its summary block and
  either write the P4 artifact + prep the P1–P4 PR, or iterate on tuning if a gate failed. Two gotchas the
  smoke test caught: `GOH_ENGINE_TRACE` needs the built binary (not `swift run`), and the governor only
  engages on a `Range`-honoring server (`python3 -m http.server` returns 200 → single-connection). Steps:
  (1) **SM5a** — `swift run goh-bench lfn --url https://sin-speed.hetzner.com/1GB.bin --runs 5 --output
  governed.json` vs `--static-n 8 --output static8.json`; accept = governed median < static8 median,
  non-overlapping IQR. (2) **SM2** — saturated target via dummynet ([[dummynet-macos26-confirmed]], needs
  sudo via `!`) or a throttling CDN; accept = governed median ≤ 1.05× static8 (≤5% regression = rollback
  trigger). (3) Confirm **SM1** probe→cruise via `GOH_ENGINE_TRACE=1 ... | grep '^governor '`. (4) If the
  win is marginal or SM2 regresses, **tune `Config.default` + `chunkSize`** against the medians and re-run.
  (5) Write `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase4.md` with the numbers.
  **Then P1–P4 is the proven single-edge headline → one PR.** P5 (NWConnection multi-edge) is a separate
  later PR behind its feasibility spike + dedicated security review.
- **Do NOT PR yet:** the governor is default-on but UNPROVEN on real networks until Task 19 passes SM5a/SM2;
  the PR's CI can't run the LFN benchmarks. Merge a *proven* feature.

### 2026-05-31 (impl session) — In-flight adaptive parallelism **P3 COMPLETE** (governor functional + fed back to bandit); next = P4 (benchmarks + per-host budget)

- **P3 of 5 shipped on `design/in-flight-parallelism`.** **503 tests pass**, warning-clean,
  strict-concurrency-clean. **The in-flight governor is now functional** — it adjusts the live connection
  count during a download and feeds its converged candidate-aligned N back into the per-host bandit. Full
  breakdown in the P3 artifact (`docs/superpowers/progress/...-phase3.md`) and the detailed in-progress entry
  below. Commits: Task 10 `af6e728`, Task 11 `bcb0ece`, **Task 11A `a0160df`** (fixed-size chunk pool,
  Opus-reviewed), **Task 12 `df35c8d`** (governor wired + explicit-N off channel + GovernorOutcome,
  Opus-reviewed), Task 13 `090af0a` (warm-start trace), Task 15 `d82ad98` (governor trace), Task 14 `5b28652`
  (DESIGN.md), P3 artifact (next commit).
- **The architectural gap (build-it-right):** the plan would have wired an inert governor onto P2's "N big
  pieces"; **Task 11A** (the spec §6.1 fixed-size-chunk pool + byte progress + connection slots) was added as
  the prerequisite that makes the governor actually converge. Both 11A and 12 (the data-path + concurrency
  cores) passed dedicated **Opus concurrency/data-integrity reviews** (no blocks; the governor never overrides
  an explicit `--connections` pin; the bandit can't be polluted; no data race; cooperative drop loses no bytes).
- **Two review-caught issues (don't re-introduce):** (1) `Mutex` is noncopyable → used the project's
  reference-type idiom (`ExplicitConnectionCounts`, `RateSampleSink`, like `ByteCounter`); (2) the 11A slot
  force-unwrap was a latent crash → closed in Task 12 (clamp `targetN`∈[1,16] + guard slot allocation).
- **Invariants held:** `protocolVersion` 3, `JobCatalog.version` 1, `JobSummary` wire shape,
  `host-scheduling.plist` v1, `DownloadCheckpoint` v1 — all unchanged. `GovernorOutcome`/`ExplicitConnection
  Counts`/`RateSampleSink` are daemon-internal.
- **NEXT ACTION — P4 (Tasks 17–19): the headline benchmarks + per-host budget.** (1) **Task 17** — global
  per-host `ConnectionBudget` (deliberately deferred from P2/P3; insert the budget gate into the control
  loop's `fillToTarget` + a worker-`defer` release — the structure is ready). (2) **Task 18** — `goh-bench`
  LFN subcommand + runbook (path is `Benchmarks/goh-bench/`, NOT `Sources/`). (3) **Task 19** — prove **SM5a**
  (governed > static N=8 on a sourced LFN target, non-overlapping IQR) and **SM2** (≤5% saturated regression)
  using the **confirmed dummynet harness** ([[dummynet-macos26-confirmed]]) + `sin-speed.hetzner.com/1GB.bin`;
  **tune `Config.default` + `chunkSize`** against measured convergence (first-cut values). P4 **ships the
  single-edge headline.** Then P5 (NWConnection multi-edge, behind a feasibility spike + security review).
  Continue with `subagent-driven-development`, real `swift test`
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). Do **not** re-run design/spec/plan review.

### 2026-05-31 (impl session) — In-flight adaptive parallelism **P3 detail** (Tasks 10–11 + architectural gap → Task 11A)

- **P3 started on `design/in-flight-parallelism`.** Tasks 10 + 11 shipped (497 tests pass, warning-clean):
  - `af6e728` — **Task 10:** `SelectionReason.warmStart` + `ObservationRequest` parameter struct; the
    observation gate now keys off the governor outcome (`effectiveN != nil && stabilized`) instead of the
    old `actualConnectionCount == requestedConnectionCount`. `recordObservationIfEligible` added. All 7
    gate tests + the `gohd` call site migrated. **`d5GateConnectionMismatchRejected` → `d5GateOffCandidate
    Rejected`** (the actual==requested condition no longer exists).
  - `bcb0ece` — **Task 11:** `JobStore.setActualConnectionCount` is now peak-max
    (`max(existing, min(count,16))`, cap 16 not requestedN). DESIGN.md note added.
- **⚠️ WIP CAVEAT (don't merge mid-P3):** after Task 10, `gohd/main.swift` builds the `ObservationRequest`
  with `governorOutcome: .governorOff` (a `// TODO(P3 Task 12)` placeholder), so the daemon currently
  records **NO** bandit observations until Task 12 passes the real `GovernorOutcome` through a 4-arg
  `completedDownloadHandler`. This is an intentional intermediate state on the WIP branch; the end state
  (Task 12) restores observation recording with the governor's converged N.
- **ARCHITECTURAL GAP FOUND + RESOLVED (user gate "build it right", 2026-05-31):** the plan's P3 wired the
  governor onto P2's "N big pieces" queue — but the governor can only *add* a worker if there is spare
  unclaimed work, and N pieces are all claimed up front, so the governor would be **inert**. The spec §6.1
  mandates **fixed-size chunks** (a daemon constant, independent of N) that workers pull one at a time —
  that is what enables live add/drop. P2 used N-pieces for behaviour-equivalence; P3 must switch. Added
  **Task 11A** to the plan (`docs/plans/...-plan.md`, before Task 12): fixed-size chunk pool + byte-based
  progress (replacing the per-piece-index `RangeProgress`) + connection-slot indexing (`0..<targetN`,
  reused; the governor's `WorkerRateSample.workerIndex` must be a stable slot, not the chunk index).
  Behaviour-equivalent at fixed N (identical bytes/SHA-256). This is the prerequisite that unblocks the
  governor. **The user chose "build it right" over "wire structurally only" or "re-plan with full review."**
- **NEXT ACTION — Task 11A (the heavy, sensitive rework; do with an Opus implementer + Opus concurrency +
  data-integrity review).** Design is written in the plan's Task 11A section. Key points: `chunkSize`
  daemon constant (≈8 MiB) made **injectable** on `DownloadEngine` (default 8 MiB) so tests can pass a
  small value (e.g. 1 MiB) to exercise multi-chunk parallelism; the `withThrowingTaskGroup` element type
  becomes the **slot id** (`Int`) so reaps free the slot; `consumeRange`/`downloadRange` swap
  `progress: RangeProgress` → a `Mutex<UInt64>` byte counter and take the slot as their trace index; the
  first chunk `[0, chunkSize)` reuses `firstRangeStream`; expect to fix tests that asserted a specific
  piece/connection count (pass a small chunkSize or adjust). THEN Task 12 (wire the governor — now
  functional), 13 (warm-start trace), 14 (DESIGN.md), 15 (governor trace), 16 (kill-switch + artifact).
  Continue with `subagent-driven-development`, real `swift test`
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). Do **not** re-run design/spec/plan review.

### 2026-05-31 (impl session) — In-flight adaptive parallelism **P2 COMPLETE** (dynamic chunk pool + interval-set assembler); next = P3

- **P2 of 5 shipped on `design/in-flight-parallelism`** via `subagent-driven-development` (TDD, two-stage
  review incl. Opus quality/concurrency). **493 tests pass** (was 483 at P1 end; +10), warning-clean,
  strict-concurrency-clean. **Behaviour-equivalent at fixed N — no functional change**; this is the
  structural rework enabling P3's live-N governor. Four atomic commits + artifact:
  - `efe69cf` — `ChunkQueue` + `ByteInterval` (`Sources/GohCore/Engine/ChunkQueue.swift`).
  - `b99fdd1` — interval-set `ChunkAssembler` rework: `complete(interval:)` additive-merge, coalesce,
    byte-0 frontier, `[0,total)` end-condition; SHA-256 in-order invariant preserved; `advance`/`fixedLength`
    deleted; all callers migrated (incl. `goh-bench/main.swift`).
  - `9a02981` — fix: empty (`Content-Length: 0`) downloads digest the canonical empty SHA-256 instead of
    failing (regression caught by Opus quality review).
  - `b41136a` — control-loop worker pool in `fetchRanged`: single-control-loop-inside-`TaskGroup`
    (sole `addTask` caller), `ChunkQueue`-seeded, range-0 `firstRangeStream` reuse preserved. Opus
    concurrency review APPROVED (single-adder safe, behaviour-equivalent, no race/hang/lost-cancellation).
  - P2 artifact: `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase2.md`.
- **Two defects caught by review & fixed (don't re-introduce):** (1) the plan's `init(totalBytes: UInt64)`
  + `fetchSingle` `?? UInt64.max` was a bug for unknown-length downloads → corrected to
  **`init(file:totalBytes: UInt64?)`** (nil = unknown, skips end-condition); (2) the empty-file regression
  above. Both have regression tests.
- **`ConnectionBudget` is a P4 deliverable** — deliberately NOT referenced in P2's control loop (the plan's
  Task 8 text mentioned it prematurely). P4 inserts the budget gate + worker-`defer`-release into the
  structure P2 built. **`setActualConnectionCount` peak-max is Task 11/P3** — P2 calls it with peakWorkers
  (== ranges.count at fixed N); the JobStore method body is unchanged.
- **Invariants held:** `protocolVersion` 3, `JobCatalog.version` 1, `JobSummary` wire shape,
  `host-scheduling.plist` v1, `DownloadCheckpoint` v1 — all unchanged (checkpoint `recordCompletedPiece`
  called identically per-flush).
- **NEXT ACTION — P3 (Tasks 11–18):** wire the governor to the pool. `setActualConnectionCount` peak-max
  semantics (Task 11); `ObservationRequest`/`SelectionReason.warmStart` (Task 10/11); the explicit-N
  governor-off channel (ephemeral `Mutex<[UInt64:UInt8]>` jobID→N table in gohd — NOT a JobSummary field);
  compute per-flush rate **deltas + per-worker EWMA** from `consumeRange`'s accumulator (currently
  cumulative `(bytes,elapsed)`, unconsumed) and feed `WorkerRateSample`s to the governor; apply
  `GovernorDecision` via `targetN` + `fillToTarget`; emit candidate-only `GovernorOutcome` to the bandit;
  warm-start (SM4); `GOH_ENGINE_TRACE` governor lines; DESIGN.md §Persistence/§Observability reconciliation.
  Continue with `subagent-driven-development`, real `swift test`
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). Do **not** re-run design/spec/plan review.

### 2026-05-31 (impl session) — In-flight adaptive parallelism **P1 COMPLETE** (governor + clock + dummynet confirmed); next = P2

- **P1 of 5 shipped on `design/in-flight-parallelism`** via `subagent-driven-development` (TDD per task,
  two-stage review). **483 tests pass** (was ~481), warning-clean under `-warnings-as-errors`,
  strict-concurrency-clean. **No behaviour change** — the governor is a pure value type, unit-tested
  only; nothing is wired to the engine yet. Six atomic commits + artifact:
  - `bf0aca6` — inject `ContinuousClock` into `fetchRanged` (deterministic testability; defaulted param,
    callers unchanged).
  - `b451823` — per-chunk rate accumulator at the `consumeRange` `flush()` chokepoint (**P1 placeholder**,
    `_ = rateSamples`; not yet consumed).
  - `6875bd9` + `6c75420` — pure `ParallelismGovernor` (three-phase: probe / knee / cruise+re-probe,
    gain-only RTT fallback) + **strengthened SM3 tests**. Review caught that the first-cut SM3 tests
    passed via a degenerate `allWorkersInSteadyState`-false early-return; they were rewritten to genuinely
    drive the probe-up, RTT-bufferbloat, and gain-only-knee branches.
  - `3f57db2` — `GovernorOutcome` daemon-internal struct (`{effectiveN: UInt8?, stabilized: Bool}` +
    `.governorOff`); **never on the wire**.
  - `e3cfe9d` — P1 progress artifact.
- **dummynet spike CONFIRMED (spec §12.1 top `[UNVERIFIED]` risk — now closed):** `dnctl`+`pfctl` work on
  **macOS 26.5 / arm64** (live `dnctl pipe 1 config bw 50Mbit/s delay 150 plr 0.005` → `DUMMYNET_OK`).
  **P4's hermetic benchmark gate uses `dnctl`+`pfctl` directly; the Linux-VM `tc netem` fallback is not
  needed.** See [[dummynet-macos26-confirmed]].
- **Open items carried to P2/P3** (full list in the P1 artifact): the rate-sample tuple is a placeholder
  (P3 must compute per-flush deltas + per-worker EWMA, not cumulative bytes/total-elapsed);
  `.dropWorkers`/`Phase.pinned` are forward-API reserved for P3 wiring; `Config.default` values are
  first-cut, tuned against the dummynet harness in P4; the RNG is stored-for-later (revisit in P3).
- **Invariants held:** `protocolVersion` 3, `JobCatalog.version` 1, `JobSummary` wire shape,
  `host-scheduling.plist` v1, `DownloadCheckpoint` v1 — all unchanged.
- **NEXT ACTION — P2 (Tasks 6–10):** the highest-risk phase. Replace the static `ByteRange.split` +
  `TaskGroup` with a dynamic `ChunkQueue` + **interval-set frontier `ChunkAssembler`** (the SHA-256
  in-order invariant + `[0,total)` end-condition + additive-merge `complete(interval:)` — round-2 plan
  review's compile-break fix migrated `verifyHash`/`fetchSingle`/`consumeRange` callers off the deleted
  `advance`) + the **single control-loop-inside-the-`TaskGroup`** live worker pool with worker-owned
  `defer` budget release (Block-2 fix). Behaviour-equivalent at fixed N until P3 drives it. Continue with
  `subagent-driven-development`, one task at a time, real `swift test`
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). Do **not** re-run design/spec/plan review.

### 2026-05-31 (planning session) — In-flight adaptive parallelism: implementation plan **WRITTEN + 2-round adversarial review PASSED + USER-APPROVED at the gate**; P1 implementation starting

- **Plan written** via `custom-writing-plans` (Sonnet): `docs/plans/2026-05-31-in-flight-adaptive-parallelism-plan.md`
  — **25 TDD tasks segmented at the spec's P1–P5 boundaries** (P1: 5 / P2: 4 / P3: 7 / P4: 3 / P5: 6),
  every task with failing-test-first Swift Testing stubs, exact `DEVELOPER_DIR`-prefixed `swift test`
  commands, complete copy-pasteable Swift, and SM1–SM6/AC1–AC5 mapped to owning tasks. Five phase
  artifacts seeded under `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase{1..5}.md`.
- **Reviewed** via `adversarial-plan-review` (Opus), the **2-round cap reached**:
  - **Round 1 — 6 BLOCKs, all fixed:** (1) explicit `--connections` never disabled the governor (silent
    override of a user pin); (2) `actualConnectionCount` wasn't actually peak-max; (3) dual-writer clobber
    between the legacy `advance` shim and the new interval-set `complete(interval:)`; (4) under-specified
    per-host budget / `TaskGroup` single-adder ownership; (5) vacuous SM4 tests (`#expect(true)` / wrong
    assertion); (6) wrong `goh-bench` path (`Sources/` vs `Benchmarks/`).
  - **Round 2 — 3 BLOCKs, all fixed:** all were *second-order defects the round-1 fixes introduced* —
    (1) three legacy `ChunkAssembler` callers (`verifyHash`/`fetchSingle`/`consumeRange`) left unmigrated
    → compile break; (2) per-host budget **slot leak** on a worker-throw path; (3) the governor-off test
    under-asserted. Fixed with caller migration to `complete(interval:)` + `init(file:totalBytes:)`,
    worker-owned `defer` slot-release via a `fillToTarget` helper, and a strengthened test asserting peak
    N stays pinned. **No unresolved BLOCKs.** Remaining advisories: side-table not cleared on `rm`
    (harmless/bounded), kill-switch is a compile-time constant (spec permits env *or* constant).
  - **3rd review NOT authorized** (2-round cap); user accepted the mechanical round-2 fixes as the gate
    decision (the per-task `swift test` + review gates in subagent-driven-development are the real check).
- **USER GATE PASSED:** plan approved; proceed to implementation, **P1 first**.
- **Key design invariants the plan preserves** (verify they hold at every task): `protocolVersion` 3,
  `JobCatalog.version` 1, `JobSummary` wire shape, `host-scheduling.plist` v1 — **all unchanged**. The
  explicit-N governor-off channel is an *ephemeral daemon-internal* `Mutex<[UInt64:UInt8]>` jobID→N
  table in `gohd` (NOT a `JobSummary` wire field). `GovernorOutcome` is daemon-internal; off-candidate
  convergence records nothing (no EWMA bias). The pure `ParallelismGovernor` takes injected clock + RNG.
- **NEXT ACTION — implement P1** via `superpowers:subagent-driven-development`, one task at a time, TDD,
  real `swift test` (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`), two-stage review gate
  after each task. P1 = injected `ContinuousClock` into `fetchRanged`/`consumeRange` + per-chunk rate
  sampling at the `flush()` chokepoint + the pure `ParallelismGovernor` (geometric probe / knee / cruise,
  SM3 deterministic) + the `GovernorOutcome` struct + the **dummynet-on-macOS-26 verification spike**
  (fallback: Linux-VM `tc netem`) — one of the two MUST be confirmed in P1 so SM1/SM3 get a hermetic
  deterministic gate. No behaviour change ships in P1. Do **not** re-run design, spec review, or plan
  review — all closed.

### 2026-05-31 (design session) — In-flight adaptive parallelism: four-round design **APPROVED** + benchmark plan; **no code yet**

- **Slice started:** in-flight adaptive parallelism (the v0.2 performance headline), driven through
  `enterprise-pipeline`. This is a *design-only* session per the directive: four-round design + a
  benchmark-sourcing plan, **no code**.
- **Approach chosen (USER GATE):** **A3 — continuous in-flight governor + multi-edge fan-out** (the
  end-state path). A BBR-style governor lifted to *connection count*, driven by URLSession
  delivery-rate + coarse chunk-timing, with history-seeded warm-start unifying with the PR #77
  bandit.
- **Load-bearing finding (verified):** multi-edge fan-out is **infeasible on URLSession** — Apple
  documents no SNI override when connecting to a raw IP, and a trust-delegate can't fix the SNI byte
  on the wire. **Decision:** build multi-edge **correctly on NWConnection**
  (`sec_protocol_options_set_tls_server_name` for SNI + `sec_protocol_options_set_verify_block` for
  hostname-pinned trust) — a hand-rolled **HTTP/1.1 range client over `NWConnection<TLS>`** for the
  IP-pinned edge connections. This **revises the URLSession-only transport brief** (DESIGN.md
  §Transport — an *addition* for the one case URLSession can't serve, not a reversal). Bonus:
  NWConnection gives **separate real TCP connections** — the structural lever that beats HTTP/2
  multiplexing (the amenable gap).
- **Spec APPROVED** through **2 adversarial Opus rounds**. Round 1 found 4 real BLOCKs — the
  URLSession-SNI infeasibility, a hand-waved interval-frontier rework, `actualConnectionCount` wire
  semantics under a varying N, and live-`TaskGroup` add/drop concurrency — all resolved; round 2 =
  all 10 categories PASS. 5 advisories (the "10★" scrub actioned).
- **Phasing (deployment-independent; P1–P4 independent of P5):**
  1. **P1** — injected `ContinuousClock` + per-chunk rate instrumentation + the pure
     `ParallelismGovernor` (deterministic SM3 test). No behaviour change. Includes the **dummynet-on-
     macOS-26 verification spike** (fallback: Linux-VM `tc netem`).
  2. **P2** — dynamic chunk pool + **interval-set frontier** `ChunkAssembler` + the single-control-
     loop-inside-the-group worker pool (single edge, URLSession).
  3. **P3** — wire the governor; **observation-gate redesign** + **candidate-only** bandit feedback
     (off-candidate convergence records nothing — no EWMA bias) + warm-start; governor trace lines.
  4. **P4** — global per-host connection budget; LFN `goh-bench` harness + runbook → **ships the
     headline (SM5a)**.
  5. **P5** — NWConnection HTTP/1.1 multi-edge transport + the verify block + the **transport-brief
     revision**, behind a **feasibility spike** and a **dedicated security review** (trust-core
     Phase 3 precedent). Dormant behind a constant until then.
- **Invariants held:** `protocolVersion` 3, `JobCatalog.version` 1, `JobSummary` wire shape, and
  `host-scheduling.plist` v1 all **unchanged**; all governor feedback is daemon-internal (a
  `GovernorOutcome` struct on the completion sink, no wire field). `actualConnectionCount` keeps its
  wire shape; its meaning is re-documented as "peak concurrent connections used."
- **Benchmark-sourcing plan (2nd deliverable):** spec §12 + the research brief's options table.
  Local `dnctl`/`pfctl` dummynet (P1 verifies on macOS 26; `tc netem` VM fallback) as the **hermetic
  deterministic gate**; `sin-speed.hetzner.com/1GB.bin` for the real no-throttle LFN proof (SM5a);
  optional ~$5/mo Singapore VPS; Cloudflare `__down` for multi-edge (SM5b, best-effort, P5).
- **Artifacts** (all under `docs/superpowers/`): `research/2026-05-31-in-flight-adaptive-parallelism-{ccb,acceptance-criteria,brief,approaches,design-validation}.md`
  and `specs/2026-05-31-in-flight-adaptive-parallelism-design.md`. **Not yet committed** — no branch
  cut this session (design artifacts only).
- **Branch state:** `design/in-flight-parallelism` is **pushed** to origin (commit `ed48486`, all 6
  artifacts + this STATE.md). Work from this branch — do **not** branch off `main` again.
- **CLOSED — do NOT re-run:** the design pass is finished. Do not re-run `enterprise-pipeline`,
  approach generation, the approach gate, or `adversarial-spec-review` — the spec is **approved**
  (2 rounds, all 10 block categories pass) and the approach (A3, multi-edge via NWConnection) is a
  settled user decision. Do not re-litigate the URLSession-SNI finding (see the
  [[urlsession-no-sni-override-for-ip]] memory).
- **NEXT ACTION — kick off the implementation plan.** Go **straight to `custom-writing-plans`**
  (the CLAUDE.md override that replaces `writing-plans`), dispatched as a Sonnet subagent with:
  - `SPEC_FILE_PATH` = `docs/superpowers/specs/2026-05-31-in-flight-adaptive-parallelism-design.md`
  - `RESEARCH_BRIEF_PATH` = `docs/superpowers/research/2026-05-31-in-flight-adaptive-parallelism-brief.md`
  - `TECH_STACK` = from `CLAUDE.md` §Stack; `PROJECT_CONVENTIONS` = from `CLAUDE.md` (Test/Branch
    discipline, four-round, the recurring gotchas).
  - **Segment the plan at the spec's P1–P5 phase boundaries** (they are deployment-independent;
    P1–P4 ship the single-edge headline, P5 is the NWConnection multi-edge + security-review gate).
  Then **`adversarial-plan-review`** (the CLAUDE.md override; max 2 rounds; fix block issues between
  rounds). Then **USER GATE: spec+plan approval**, then `superpowers:subagent-driven-development`
  implementing **P1 first** (pure governor + injected clock + per-chunk instrumentation + the
  dummynet-on-macOS-26 verification spike), TDD, real `swift test`
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, see [[dev-toolchain-developer-dir]]).
  **Still no implementation code until the plan is approved at the gate.**

### 2026-05-31 (merge session) — Phase 2 adaptive scheduling **MERGED to `main`**; next = Phase 3 launch

- **Both PRs merged to `main` via squash** (branch protection: PRs required, self-merge OK; branches deleted on origin + local):
  - **PR #77** — adaptive per-host range scheduling — squash commit **`32efda1`**.
    The whole Phase 2 feature is now on `main`: a per-host ε-greedy bandit over
    `{2,4,8,16}` persisted in the daemon-owned `host-scheduling.plist`, D5/D8-gated
    observation recording, and a `GOH_ENGINE_TRACE` scheduling-decision line.
    **473 tests pass**, `-warnings-as-errors` clean. CI green at merge (Build &
    test, Package artifacts; signed-PKG skipped — needs Dev ID). CodeRabbit clean.
    `protocolVersion` 3 / `JobCatalog.version` 1 / `JobSummary` unchanged. DESIGN.md
    §Adaptive host scheduling documents the frozen v1 format.
  - **PR #78** — in-flight adaptive parallelism **design seed** + ROADMAP v0.2 entry
    — squash commit **`e048ec8`**. Docs-only; freezes nothing. The seed
    (`docs/design-notes/2026-05-31-in-flight-adaptive-parallelism.md`) designs a
    BBR-style governor on *connection count* for single-download optimization
    (multi-edge IP fan-out, protocol-aware connection-vs-stream, history-seeded
    start that unifies with the per-host bandit), plus the `URLSession`-signal
    constraint and a benchmark-sourcing gate. The v0.2 performance headline.
- **Squash was chosen deliberately for #77:** a personal email had leaked into an
  intermediate branch commit (`00c79ba`); squashing kept the redacted final
  `STATE.md` on `main` and the leaking commit out of `main`'s history. Residual:
  GitHub may retain that commit reachable by direct SHA / in the merged-PR commits
  view for a while (and it was transiently public). See the `cross-repo-email-audit`
  memory; GitHub Support purge or address rotation are the only full remediations.
- **NEXT ACTION — strategic arc Phase 3: public launch.** The one gate outside the
  code is **Apple Developer ID credentials**. Sequence (from the gitignored
  `docs/vision/VISION-2026-05-26.md` and the handoff at the bottom of this file):
  1. **Sign + notarize the PKG** via PR #36's `private-release-candidate` workflow
     (shape already verified by `Scripts/verify-private-release-workflow.sh`; what's
     missing is the secrets).
  2. **Open the `xaedyn/homebrew-goh` tap** and publish the PR #29/#30 formula.
  3. **Add `SECURITY.md` / `CONTRIBUTING.md` / `CODE_OF_CONDUCT.md`** (SECURITY.md
     first — disclosure address for a tool handling cookies + sensitive URLs).
  4. **Polish the launch post** (`docs/vision/LAUNCH-POST-DRAFT.md`, gitignored).
  5. **Post to HN + r/macapps + r/commandline + r/datahoarder.**
  - **Alternative track (no credential gate):** the in-flight-parallelism slice
    (PR #78 seed) as the v0.2 performance headline — needs its own four-round design
    pass + *sourced* long-fat-network / multi-edge-CDN benchmarks before it can claim
    a win (current benchmark hosts throttle and would mask it).

### 2026-05-31 (impl session) — Phase 2 (adaptive scheduling): IMPLEMENTED, PR #77 open

- **Branch:** `design/adaptive-scheduling`; PR **#77** open against `main`
  (https://github.com/xaedyn/goh/pull/77). All 9 plan tasks + 1 hardening
  follow-up shipped; **473 tests pass** (was 424 on `main`; +49), `swift build`
  warning-clean under `-warnings-as-errors`. Built with
  `superpowers:subagent-driven-development` — one task at a time, TDD, two-stage
  review (spec compliance + Opus stack-aware code quality) after each task, plus a
  final cross-cutting Opus review (✅ approved, zero block issues).
- **What shipped (10 atomic commits):**
  - **Phase 1 (pure value layer):** `hostKey(for:)` D1 normalizer
    (`Sources/GohCore/Scheduling/HostKey.swift`); the frozen v1 Codable on-disk
    types `HostScheduling`/`HostProfile`/`ConnObservation` + `foldingIn` EWMA fold
    + golden round-trip fixture (`HostScheduling.swift`,
    `Tests/.../Fixtures/host-scheduling-v1.plist`).
  - **Phase 2 (persistence + selection):** `HostProfileStore` (atomic versioned
    plist, 0600, 90-day TTL eviction, corrupt→sidecar, the begin/wasSolo/end
    contended-set active-job index, `recordObservation`, the pure D5/D8
    `shouldRecordObservation` gate, `selectN`); the pure ε-greedy `BanditSelector`.
  - **Phase 3 (engine + wiring):** widened `completedDownloadHandler` to carry the
    transfer-phase `Duration` + `isResume`; admission-time N resolution in
    `CommandDispatcher` (explicit honored, else bandit); the D5/D8-gated
    observation recording wired in `gohd/main.swift`; the engine begin/end
    active-job bracket; `GOH_ENGINE_TRACE` scheduling-decision line; CI-enforced
    pure selector regression tests + an optional env-gated `goh-bench
    regression-guard`.
- **Invariants held:** `protocolVersion` stays 3; `JobCatalog.version` stays 1;
  `JobSummary` struct unchanged. The new plist is daemon-internal — not in the XPC
  wire or the catalog. **DESIGN.md reconciled** this session (§Adaptive host
  scheduling documents the frozen v1 format, per the four-round discipline).
- **Review-caught & fixed during implementation (don't re-litigate):** the plan's
  punycode test paired two different domains (corrected to assert the real
  ASCII/deterministic/credential-free invariants); a `SeededRNG` xorshift64
  zero-trap (seed 0 → infinite loop) guarded; a hardcoded test date that would age
  past the TTL (made relative); a `Dictionary(uniqueKeysWithValues:)` that could
  trap the daemon at admission on a corrupt duplicate-arm plist (→
  `uniquingKeysWith:`); and the load-bearing D5 gate extracted from an inline gohd
  closure into the unit-tested pure `shouldRecordObservation` (7 cases).
- **NEXT ACTION:** PR #77 review. CodeRabbit triggered at feature-complete. When
  green + approved, merge to `main`. Then the strategic arc's **Phase 3 — public
  launch** (sign+notarize PKG via PR #36 workflow, open the brew tap, SECURITY/
  CONTRIBUTING/CODE_OF_CONDUCT, launch post) — see the launch sequence preserved in
  the older handoff below and the gitignored `docs/vision/VISION-2026-05-26.md`.
- **Order-correction note for the record:** the plan listed Task 3 (HostProfileStore)
  before Task 4 (BanditSelector), but Task 3's `selectN` references `BanditSelector`,
  so Task 4 was implemented first (the only deviation from plan order; plan content
  unchanged).

### 2026-05-31 (later session) — Phase 2 (adaptive scheduling): design + plan COMPLETE, ready to implement

- **Branch:** `design/adaptive-scheduling`, off `main` at `48ec675`. Not yet pushed.
- **What this is:** Phase 2 of the strategic arc — **adaptive per-host range
  scheduling**. The daemon learns the best parallel-connection count per host
  empirically (epsilon-greedy bandit over `{2,4,8,16}`) and persists it in a new
  daemon-owned `host-scheduling.plist` (versioned, atomic, 0600, mirrors
  `CheckpointStore`). Scope pinned this session: **adaptive scheduling only**
  (HTTP/3 deferred), **internal-only** (no new user command), bar = **measurable
  adaptation** (beating aria2c is a goal, not a ship gate — the amenable gap is
  structural). `protocolVersion` stays 3; `JobCatalog.version` stays 1 (no schema
  change — N is resolved at admission in `CommandDispatcher`, the engine's only
  touch is widening `completedDownloadHandler` to carry the transfer-phase
  `Duration`).
- **Connection ceiling decision:** keep **16**. Per-host count is governed by
  server tolerance + protocol dynamics (per-IP abuse limits, HTTP/2 multiplexing
  conflict, slow-start/TLS overhead, bufferbloat), NOT client bandwidth. Filling a
  fat pipe is mirror-racing's job (v0.2), not more sockets to one origin.
- **Where the work lives:**
  - Design spec (FROZEN on-disk format): `docs/superpowers/specs/2026-05-31-adaptive-scheduling-design.md`
    — 10 decisions (D1–D10); survived **2 adversarial spec-review rounds** (Opus).
  - Plan: `docs/plans/2026-05-31-adaptive-scheduling-plan.md` — **9 tasks, 3 phases**,
    TDD throughout; survived **2 adversarial plan-review rounds** (Opus).
  - Phase artifacts: `docs/superpowers/progress/2026-05-31-adaptive-scheduling-phase{1,2,3}.md`
- **The 3 phases (deployment-independent, implement in order):**
  1. **Pure value layer** — `HostKey` normalizer (strip credentials, nil→skip,
     IPv6 bracketed, punycode) + `HostScheduling`/`HostProfile`/`ConnObservation`
     Codable on-disk types + golden round-trip corpus & CI guard.
  2. **Persistence + selection** — `HostProfileStore` (atomic versioned plist,
     0600, TTL-on-load eviction, corrupt→sidecar, in-memory `begin/wasSolo/end`
     contended-set index) + epsilon-greedy `BanditSelector` (pure, seeded).
  3. **Engine + wiring** — widen `completedDownloadHandler` to carry transfer-phase
     `Duration`; admission-time N resolution in `CommandDispatcher`; D5-gated
     observation recording (success + ≥10s + ≥8MiB + actual==requested + solo +
     stable path; resume excluded per D8); regression guard (CI selector tests +
     optional env-gated `goh-bench regression-guard`); `GOH_ENGINE_TRACE` decision line.
- **Review caught (don't re-litigate):** the spec review fixed a nil-host bucket
  collapse, credential-at-rest, the missing regression detector, the D6 resolution
  timing, and the throughput clock provenance (the engine's `started` clock is
  phase-local and must be threaded to the sink — the "no engine change" claim was
  wrong). The plan review caught a **silent total-failure bug**: an inverted
  `activeCount` gate (the `run()` defer decrement fires AFTER the completion
  handler) — replaced with a per-job `contended`-flag faithful to D5's
  "solo for the whole duration"; plus a non-buildable AC11 benchmark, now split
  into CI-enforced selector tests + an optional manual harness.
- **NEXT ACTION (fresh session):** implement the plan with
  `superpowers:subagent-driven-development`, **Phase 1 first**, one phase at a time
  with real `swift test` runs. Do NOT re-run design or plan review — both are
  closed at the 2-round cap with all block issues resolved. Local `swift test`
  needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Push the branch
  + open the PR when a phase is green (the branch is unpushed at session close).
- **Side task done this session:** cross-repo identity audit — **DLXV (macvid)
  made private** (it was public with a personal email + real name in all 12
  commits). chronoscope has 40 public `Co-Authored-By: Claude` trailers (deferred,
  lower urgency); mirelo/crown-of-the-touched/lowest_listed are private landmines
  (personal email in history) to scrub before ever flipping public. See the
  `cross-repo-email-audit` memory.

### 2026-05-31 — Trust core: **MERGED to `main`** (PR #75), all 6 phases shipped

- **Status:** PR #75 **merged** to `main` 2026-05-31 as merge commit `fdb55e8`
  (https://github.com/xaedyn/goh/pull/75) — `--merge` (not squash), so all 25
  atomic phase-by-phase commits are preserved in `main` history. CI was green at
  merge (Build & test, Package artifacts); signed-PKG gate skipped (needs Developer
  ID). CodeRabbit findings all addressed (triage comment on the PR).
  The `design/trust-core` branch is merged; safe to delete (still present on origin
  at session close).
  Built with `superpowers:subagent-driven-development` — one phase at a time, TDD,
  a two-stage (spec + quality) review gate after each phase, plus a final
  cross-cutting review. **Test count 314 → 424, all green, `-warnings-as-errors`
  clean. `protocolVersion` stayed 3; catalog schema unchanged — purely additive,
  no migration.**
- **What shipped:** `gohfile.toml` (manifest) + `gohfile.lock` (lockfile) frozen
  on-disk formats, and `goh sync` / `goh verify` / `goh which`.
- **The 6 phases as built:**
  1. **TOML reader+writer** — `Sources/GohCore/TrustCore/MinimalTOMLReader.swift`
     (+`MinimalTOMLWriter.swift`): hand-rolled subset parser (§9.5), 14 golden
     fixtures, named errors for every out-of-subset construct. Review hardened the
     underscore-int + bare-string diagnostics and added message-content assertions.
  2. **Codecs + digest** — `ManifestCodec` (§7), `LockfileCodec` (§8, encode/decode),
     `FileDigest` (at-rest streaming SHA-256), shared `Sha256Format` validator.
  3. **Daemon write-path hardening** — `DownloadFile` now materializes paths via a
     base-free `openat` descent (`mkdirat` for missing dirs; `O_NOFOLLOW` on the
     final + immediate-parent + every created component; `O_CLOEXEC` throughout);
     new `ErrorCode.symlinkComponentRefused`. **Running-code gate passed:** 8
     symlink-swap/TOCTOU tests written first, seen fail, then pass. macOS forces
     following pre-existing prefix symlinks (`/var`→`/private/var`); an independent
     security review ruled the residual base-free-undecidable and the CLI realpath
     layer's + accepted-v0.1-residual's job — NO-OP on further daemon tightening.
     DESIGN.md §Persistence + §2.4 reconciled.
  4. **`goh which`** — `CLI/GohWhichCommand.swift`: lock lookup (entries resolved
     under the lock dir, symlink-resolved compare for `/var`, confined to the lock
     tree) then `getxattr` Spotlight provenance; exit 4 when neither. Default lock
     = cwd `./gohfile.lock`.
  5. **`goh verify`** — `CLI/GohVerifyCommand.swift`: read-only re-hash vs lock;
     `OK`/`FAILED`(2)/`MISSING`(9); `flock(LOCK_SH)` busy→7; stale manifestHash→6;
     unknown lockfileVersion→6 (NOT 1); `--strict-untracked`→10; precedence 9>2>10.
  6. **`goh sync`** — `CLI/GohSyncCommand.swift` + `TrustCore/SyncPathConfinement.swift`:
     lexical+realpath CLI confinement (rules 1–2, exit 5); loop `add` + poll `ls`
     by job id with an injectable no-progress watchdog; CLI-side re-hash only
     (never trusts a daemon hash); pinned acceptance with `.corrupt-<unix>`
     quarantine (exit 2); TOFU first-use + AC5 change event (exit 3 /
     `--accept-changed`; `verify=false` suppresses the drift event); atomic lock
     write (`.tmp`→fsync→`rename`→fsync dir); precedence 5>2>3>8. Also wired
     `which`/`verify`/`sync` into the real CLI parse/run/usage.
- **Final cross-cutting review** caught a frozen-format round-trip bug: the TOML
  codecs didn't escape `"`/`\` in url/path strings. Fixed — `LockfileCodec.encode`
  escapes, `MinimalTOMLReader` un-escapes `\"`/`\\` and preserves `#` inside quotes
  while still stripping a real trailing comment. A `TrustCoreRoundTripTests` corpus
  (`"`, `\`, `#`, `=`, `?`, spaces, unicode) is now a CI guard for both formats.
- **Exit-code contract (frozen §9.4):** 0; 2 integrity; 3 TOFU-change; 4
  no-provenance; 5 path-escape; 6 lock missing/corrupt/stale/unknown-version; 7
  lock-busy; 8 download-failed; 9 verify-missing; 10 strict-untracked; 64
  usage/bad-manifest (incl. `auth` reserved); 1 only generic daemon/transport.
- **NEXT ACTION:** **Phase 2 of the strategic arc — adaptive per-host range
  scheduling.** It freezes a per-host on-disk record, so per the ROADMAP design
  gate it starts with a **four-round design pass, not code**. Before starting:
  `git checkout main && git pull` (local was on a feature branch at session
  close), and delete the merged `design/trust-core` branch (local + origin).
- **Process notes:** Phase 3's running-code gate worked as designed — the spec's
  literal "O_NOFOLLOW every component" was caught as unshippable on macOS by the
  full suite (broke ~85 tests), corrected to the base-free boundary, confirmed by
  an independent security review. The hand-rolled TOML parser's missing string
  escaping was caught only by the final cross-cutting round-trip review, not the
  per-phase reviews — a reminder that frozen wire/disk formats need an explicit
  adversarial round-trip corpus, which now exists.

### 2026-05-30 — Trust core (Phase 1 of strategic arc): design + plan COMPLETE, ready to implement

- **Branch:** `design/trust-core`, off `main`, **pushed to origin**. Two commits:
  - `4976483` — approved design spec + research artifacts.
  - `fcf47ac` — the 6-phase implementation plan + spec exit-code reconciliation.
- **What this is:** the `gohfile.toml` + `gohfile.lock` manifest/lockfile and the
  `goh sync` / `goh verify` / `goh which` commands — the "trust core," Phase 1 of
  the ROADMAP strategic arc (reproducible, integrity-verified asset management).
  Approach 1: **lockfile-as-product, CLI-local, no XPC protocolVersion change**
  (stays 3), re-hash on demand. Trust-on-first-use by default, strict when pinned.
- **Where the work lives:**
  - Spec (FROZEN formats): `docs/superpowers/specs/2026-05-29-trust-core-design.md`
    — status `approved`; survived 4 adversarial spec-review rounds.
  - Plan: `docs/plans/2026-05-29-trust-core-plan.md` — 6 phases, TDD throughout;
    survived 2 adversarial plan-review rounds + targeted fixes.
  - Phase artifacts: `docs/superpowers/progress/2026-05-29-trust-core-phase{1..6}.md`
  - Research: `docs/superpowers/research/2026-05-29-trust-core-*.md`
- **The 6 phases (deployment-independent, implement in order):**
  1. Hand-rolled TOML reader+writer (+ golden fixtures) — depends on nothing.
  2. Manifest + Lockfile codecs + `FileDigest` (at-rest SHA-256 wrapper).
  3. **Daemon `DownloadFile` path-confinement hardening** (`O_NOFOLLOW` + base-free
     `openat` descent). ⚠️ Carries a **running-code verification gate**: its
     symlink-swap TOCTOU correctness is established by PASSING TESTS under TDD, not
     prose — write the symlink-swap tests first, see them fail, implement, see them
     pass, then a mandatory review of the COMPILED+TESTED code before merge. The
     residual same-machine symlink-race is an ACCEPTED v0.1 limitation (consistent
     with the SMAppService threat-model deferral); lexical confinement (Phase 6
     `SyncPathConfinement`) is the load-bearing defense against the real
     hostile-manifest attack.
  4. `goh which` (CLI-local; lock reader + new `getxattr` provenance reader).
  5. `goh verify` (CLI-local; re-hash vs lock; missing=9, strict-untracked=10).
  6. `goh sync` (CLI-local loop over `add`; ls-poll completion detection +
     watchdog; CLI lexical+realpath pre-flight; pinned/TOFU/AC5; atomic lock write).
- **Exit-code contract (reconciled with DESIGN.md):** 0 success; **64** usage/
  bad-input (incl. bad manifest input + `auth` reserved-field); **1** generic
  daemon/transport; 2 integrity; 3 TOFU-change; 4 no-provenance; 5 path-escape;
  6 lock missing/corrupt/stale + unknown lockfileVersion; 7 lock-acquire; 8
  download-failed; 9 verify missing-file; 10 verify strict-untracked.
- **NEXT ACTION (fresh session):** implement the plan with
  `superpowers:subagent-driven-development`, **Phase 1 first** (the TOML reader),
  one phase at a time with real `swift test` runs (NOT a big parallel fan-out).
  Do NOT re-run plan review — planning is closed; Phase 3's openat precision is
  deliberately deferred to TDD per its running-code gate. Local `swift test` needs
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (see memory).
- **Process note for next time:** the path-confinement mechanism ate ~6 review
  rounds because adversarial reviewers escalated an out-of-scope (per goh's own
  threat model) TOCTOU concern to a blocker; low-level POSIX syscall choreography
  is verified far better by running tests than by prose review. Lesson banked.

---

### 2026-05-29 — platform floor corrected; wordmark redesign parked

- **Branch:** `docs/macos-floor-26.0`, off `main`. Corrects the supported-OS
  claim from macOS 26.5+ to **26.0+** — the real floor, a hard requirement of
  the daemon's macOS 26.0 XPC peer-validation API (`XPCPeerRequirement`,
  `XPCRequirement.isFromSameTeam`, the requirement-carrying `XPCListener` /
  `XPCSession` initializers). Proven by building at a 15.0 floor and watching the
  compiler reject exactly those symbols. Docs-only plus a `Package.swift` comment;
  the `.macOS("26.0")` value is unchanged. Also fixed the `CLAUDE.md` IPC note
  that had mislabeled `XPCPeerRequirement` as macOS 14+. See `DESIGN.md`
  §Platform support.
- **Logo redesign parked:** a wordmark reconstruction effort (cormorant-italic /
  custom-cormorant / free-font drafts) is committed as WIP on branch
  `fix/smooth-wordmark-vector` (commit `5cf22a5`). Current logo kept as-is;
  direction to be revisited later. Leave that branch alone until then.
- **Prior context (code-review sweep):** branch
  `docs/state-after-code-review-sweep`, based on `main` at `06564af`.
- **Current state:** A full code-review sweep ran across `main` after the menu
  bar smoke pass landed. An LLM-driven Phase-1 codebase audit produced 17
  prioritized findings (S1–S7 significant, M1–M10 minor); the sweep merged
  fixes for the five load-bearing ones plus three minors, caught two
  reviewer-mistake findings via direct code spot-checks (S6 and M9 — both
  rejected), and deferred the remaining seven with documented rationales (a
  vision memo at `docs/vision/VISION-2026-05-26.md`, gitignored, captures the
  product-strategy synthesis). One flaky CI timing assertion surfaced by the
  sweep itself was also fixed, and the menu bar Terminal handoff was extended
  beyond Apple Terminal to auto-detect Ghostty / iTerm / WezTerm / Alacritty /
  kitty (running terminal preferred over merely-installed). Test count rose
  274 → 314.
- **Code-review sweep result (PRs #58–#66):**
  - **#58** — gitignored `docs/vision/` for private strategy memos.
  - **#59** — S1: extracted `XPCReplyDecoder` to collapse seven copies of the
    `withUnsafeUnderlyingDictionary { try? GohEnvelope<X>(...) ... }` decode
    dance into one tested helper. Net –109 / +216.
  - **#60** — M1+M2: centralized `formatBytes` / `progressText` into
    `JobDisplayFormatter` in `GohCore`; standardized percent clamping to
    `[0, 100]` across all four surfaces (CLI table, `goh top`, foreground,
    menu bar). Pre-existing inconsistency: menu bar clamped overruns to 100%
    while the other three rendered values like 200%.
  - **#61** — S3: replaced `_ = try? store.recordProgress(...)` and `_ = try?
    store.fail(...)` masking in `DownloadEngine` with an
    `unexpectedStoreError` reporter. `.jobNotFound` (the expected race when
    `rm` runs concurrently) is still dropped silently; every other store
    failure now lands in `goh.log` with job ID, operation name, and error.
  - **#62** — M5: `goh top` now uses the alternate screen buffer
    (`ESC[?1049h` / `ESC[?1049l`) and redraws in place (`ESC[H` + frame +
    `ESC[J`) instead of clearing + homing every notification. Kills the
    per-update flicker; preserves shell scrollback on exit.
  - **#63** — S2: closed the XPC peer-validation accept-path CI gap by
    testing `peerRequirement(for:)` directly (the factory function the
    production listener consults) plus a fresh `senderSatisfies` assertion
    against the production value. The OS-enforced session-accept path still
    requires a signed-build smoke run; that residual gap is now documented
    in code.
  - **#64** — M4 + M6: `expectedContentLength > 0` → `>= 0` so
    `Content-Length: 0` is a known empty body, not "unknown total." Added
    the missing `@unchecked Sendable` invariant comment on
    `GohXPCNotificationInbox` so it matches the rest of the codebase. M9
    skipped — `XPCReconnect.attempt` is only called from synchronous CLI
    contexts, not the `goh-menu` `Task.detached` path the reviewer cited.
  - **#65** — flaky-test fix: the 500 ms wall-clock bound in
    `removeRangeParallelActiveDownloadCancelsSiblingRanges` (
    `DownloadEngineTests.swift:559`) tripped at 548 ms on PR #59's CI attempt
    1 — three back-to-back local runs measured 88 / 89 / 91 ms, so 548 ms is
    ~6× local scheduling overhead. Raised to `< 2 s` (~22× local headroom,
    still meaningful as a "did not wait for siblings to finish naturally"
    sanity check). The behavioral assertions (partial file + checkpoint
    gone before reply) are the load-bearing checks.
  - **#66** — M10: `goh-menu` Terminal handoff now auto-detects across
    Ghostty (the user's terminal), iTerm2, WezTerm, Alacritty, kitty, and
    Apple Terminal. Two-phase pick: highest-priority **running** terminal
    first (strongest signal for "this is what the user actually uses"),
    then highest-priority **installed** terminal as fallback. Apple Terminal
    is the universal fallback. Each launcher emits a `Process`-ready
    invocation: `osascript` AppleScript for Apple Terminal and iTerm,
    `open -na <App>.app --args -e /bin/sh -c <command>` (xterm-convention)
    for the CLI-based terminals. 22 launcher tests cover priority, the
    running-vs-installed precedence, and AppleScript escaping. Verified
    live: Ghostty's bare `-e <command>` form makes it try to exec a binary
    literally named after the whole command string and fail; the
    `-e /bin/sh -c <command>` wrapping works.
- **Reviewer-mistake findings rejected via spot-check:**
  - **S6** — claim: `ProgressBrokerHub.deliver` holds the lock during
    synchronous `session.send`. Verified false: `deliver(state.withLock {
    ... })` evaluates the closure (acquires + releases the lock) before
    calling `deliver`, so sends already run outside the lock.
  - **M9** — claim: `XPCReconnect.attempt`'s `Thread.sleep` blocks a
    cooperative thread because `goh-menu` calls it from `Task.detached`.
    Grep showed `XPCReconnect.attempt` is only called from synchronous CLI
    contexts (`GohForegroundDownload`, `GohTop`). `Thread.sleep` is correct
    there.
- **Deferred findings (rationales captured in conversation):** S4 (improbable
  fsync-during-verifyHash edge), S5 (unused `NetworkPauseCoordinator` hook —
  dead extension point, harmless), S7 (`PendingDownloadStop` semaphore is
  stylistic), M3 (`JobSummary` encoder `encode` vs `encodeIfPresent` split
  is correct), M7 (`MockURLProtocol.stubs` static-but-guarded-by-UUID-URLs),
  M8 (`SafariCookieJar` intermediate arrays — perf non-issue for ~20
  cookies).
- **Menu bar state:** PR #54 merged the first private menu bar companion slice.
  `goh-menu` is now a SwiftPM-built, dogfood-installed MenuBarExtra backed by
  the same daemon XPC command and progress-subscription surfaces as the CLI. It
  shows daemon health, queue snapshots, active counts, aggregate speed,
  doctor-style recovery copy, clipboard quick-add,
  job controls, Finder reveal, and Terminal handoffs for `goh top` and
  `goh doctor`. PR #56 fixed the root-URL default-destination bug surfaced
  by the first logged-in smoke pass (`https://example.com/` produced
  `~/Downloads/`; now falls back to `~/Downloads/download`). PR #66 then
  taught the Terminal handoff to respect the user's actual terminal.
- **Post-sweep cleanups (PRs #68, #69):** PR #68 rewrote the README's "Why"
  section to lead with what `goh` *is* (architecture + capability list)
  instead of competitor name-drops, removed "10x" buzzwords from
  `ROADMAP.md` / `STATE.md` / the menu bar spec, and clarified that v0.1
  does not actively opt into HTTP/3. PR #69 redacted a home-directory
  path that had appeared in the post-sweep state refresh, reconciled
  DESIGN.md §6 (Observability) with the shipped implementation (`stderr`
  writes today, `os.Logger` migration framed as a v0.2 candidate), and
  tightened `.gitignore` for two local-only files (the Codex-style
  operating manual `AGENTS.md` and `Benchmarks/diagnose-*.log` engine
  traces). A separate `git config user.email` correction was applied
  outside the PR after a prior commit was authored under a personal
  email instead of the GitHub noreply.
- **GitHub account + repo settings hardened (browser-driven):** Enabled
  command-line push protection that rejects future commits authored from
  a personal email. Enabled repository-level Private vulnerability
  reporting, Dependency graph, Dependabot alerts / malware / security
  updates / grouped security updates, and Secret Protection (scanning +
  push protection). Created branch ruleset "Protect main" with basic
  protection: require PRs to merge, block force pushes, block deletions,
  0 required approvals (self-merge OK). 2FA verified enabled (read-only
  check; not modified).
- **Last roadmap merge:** PR #22 — Spotlight tagging and sleep assertions —
  `main` at `5b3884d`; PR #23 — one-shot CLI commands — `main` at `db9b82a`;
  PR #24 — CLI add options and JSON list — `main` at `58c2e73`; PR #25 — progress
  subscription contract — `main` at `c31283d`; PR #26 — backend progress
  subscription plumbing — `main` at `976775f`; PR #27 — foreground progress
  CLI — `main` at `076bfaf`; PR #28 — top progress dashboard — `main` at
  `0adf0a7`; PR #29 — release-packaging surface refresh — `main` at
  `2e1c3c7`; PR #30 — Homebrew formula validation in CI — `main` at
  `5ad60b6`; PR #31 — release artifact workflow — `main` at `e79c0bd`;
  PR #32 — release artifact verification — `main` at `b668aa0`; PR #33 —
  release signing prerequisites — `main` at `580b7c2`; PR #34 — unsigned PKG
  release artifact — `main` at `865d6aa`; PR #35 — private release posture —
  `main` at `33b1ea9`; PR #36 — private signed release gate — `main` at
  `b7e22e6`; PR #39 — menu bar companion roadmap/spec — `main` at `c2f4911`;
  PR #40 — local dogfood lane — `main` at `fd93b8d`; PR #47 — active `rm`
  cleanup hardening — `main` at `54317a9`; PR #49 — local health doctor —
  `main` at `ff45e99`; PR #50 — private dogfood acceptance gate — `main` at
  `cbe2c61`; PR #51 — state refresh after acceptance gate merge — `main` at
  `0aa3887`; PR #52 — dogfood performance evidence output — `main` at
  `befa10c`; PR #54 — menu bar companion MB1 — `main` at `56f9ad9`;
  PR #55 — state refresh after menu bar merge — `main` at `4e83522`; PR #56 —
  root-URL default destination fix — `main` at `7121e35`; PR #57 — state
  refresh after menu bar smoke — `main` at `b7bf03d`; PR #58 — gitignore
  `docs/vision/` — `main` at `f239591`; PR #59 — XPCReplyDecoder DRY —
  `main` at `d4a1857`; PR #60 — centralize byte/progress formatting —
  `main` at `5c16ec1`; PR #61 — surface daemon store errors — `main` at
  `4e24106`; PR #62 — `goh top` alternate-screen buffer — `main` at
  `e91b1cb`; PR #63 — XPC peer-requirement coverage — `main` at `a4a4236`;
  PR #64 — robustness sweep (content-length 0, inbox invariant) — `main`
  at `244e9a4`; PR #65 — relax flaky range-cancel timing bound — `main`
  at `dd7c021`; PR #66 — multi-terminal handoff w/ Ghostty — `main` at
  `06564af`; PR #68 — positioning language cleanup — `main` at `fa97d8d`;
  PR #69 — PII redaction + DESIGN §6 reconciliation — `main` at `b09616a`.
  Bookkeeping-only `STATE.md` refresh PRs may be newer than this entry; they do
  not advance the roadmap state.
- **Current slice:** Slice 9, Homebrew formula, signing, notarization, and the
  release pipeline. The first branch shipped the formula/README truth refresh in
  PR #29. PR #30 added CI validation for the in-repo Homebrew formula. The
  PR #31 added an unsigned release-artifact workflow and a reusable local
  packaging script. PR #32 added reusable artifact verification before upload.
  PR #33 documented signing/notarization prerequisites and the credential
  boundary for the remaining release work. PR #34 added an unsigned PKG
  release-candidate artifact and verifier so the direct-download path is
  exercised in CI before credential-backed signing/notarization lands. PR #35
  codified the private release posture: build every release gate, but do not
  publish an official install channel until the explicit public launch decision.
  PR #36 added the manual private signed/notarized/stapled PKG gate and a CI
  verifier for that workflow shape, while keeping official publication out of
  scope. PR #39 recorded the menu bar companion product direction in
  the roadmap and a design spec. PR #40 added the local dogfood lane so the
  product can be used and tested privately from source before any official
  install channel opens.
  PR #42 fixed dogfood-discovered destination parent-directory creation at
  `6506089`, PR #43 refreshed state at `5247964`, PR #44 fixed dogfood usability
  gaps in `goh top` at `34d8646`, PR #45 added the product catchphrase to
  restrained visible surfaces at `4c6a784`, and PR #47 fixed the dogfood-
  discovered active `rm` path where a resumed or range-parallel download could
  leave a visible partial file behind after the catalog row was removed. PR #47
  also tightened the file-ownership boundary so `rm` of a queued never-started
  job does not delete a pre-existing destination file. PR #49 added `goh
  doctor` as a read-only local health gate for private dogfood: it checks the
  dogfood binaries, LaunchAgent, launchd load state, XPC queue reachability,
  peer-relaxation setup, writable local paths, and daemon log posture, then
  prints exact recovery commands without adding daemon IPC surface. PR #50 added
  the private readiness acceptance gate above smoke: build/install, doctor,
  smoke, foreground download, JSON list, active pause/resume/remove cleanup,
  daemon restart, and opt-in competitive performance comparison. PR #52 made
  that `--performance` path evidence-grade by streaming the benchmark table and
  saving it under `.build/dogfood/logs`. PR #54 then brought the first native
  menu bar companion slice into private dogfood so non-terminal workflows can be
  exercised before any official install channel opens. PRs #58–#66 ran the
  post-merge code-review sweep and added Ghostty / iTerm / WezTerm /
  Alacritty / kitty support to the menu bar Terminal handoff (see the
  Current state section above for the per-PR breakdown). Test count 274 →
  314; CI green throughout. The remaining slice-9 work is the credential-
  backed signed/notarized PKG release-candidate (PR #36's workflow is
  ready to run with Developer ID secrets) and the Homebrew tap.
- **Slice 7 progress:** the first CLI implementation pass adds a testable
  `GohCore` command-line runner for the one-shot control verbs: `goh add`,
  `goh ls`, `goh pause`, `goh resume`, and `goh rm [--keep]`. `Sources/goh`
  is now thin process I/O plus the real XPC sender, and the existing
  `goh auth import safari` flow is routed through the same runner. The CLI
  returns `64` for local usage errors, `1` for daemon/transport failures, and
  prints `brew services start goh` guidance when the daemon is unreachable.
  Foreground `goh <url>` shipped in PR #27 as a live subscriber over the progress
  subscription path rather than a background-add alias.
  The follow-up CLI polish branch exposes already-frozen `add` options
  (`--output`, `--connections`, `--priority`, `--no-cookies`) and adds
  `goh ls --json` over the existing `LsReply` payload. PR #25 froze the
  load-bearing progress subscription contract: `Command.subscribe`,
  `SubscribeReply`, `ProgressEvent`, full in-scope progress snapshots,
  progress-model revisions, explicit `fullSnapshot` update events, 100 ms
  coalescing, foreground reconnect, and `goh top` subscription behavior. The
  PR #26 shipped the v3 wire schema, golden fixtures, protocol-version bump,
  session-aware XPC transport wrappers, broker-backed `subscribe` replies and
  notifications, `JobStore` progress publishing, and daemon composition through
  `ProgressBrokerHub`. PR #27 implemented foreground `goh <url>` as `add` plus
  `subscribe(scope: job, jobID:)` on one session. PR #28 shipped the first
  `goh top` dashboard over `subscribe(scope: all)`.
- **Slice 5 progress:** the first implementation step adds a pure in-memory
  `GohCore` Safari `Cookies.binarycookies` parser with Swift Testing coverage
  for page tables, offset-based strings, flags, Cocoa dates, and malformed
  inputs. The second step adds in-memory RFC 6265-style URL matching and
  `Cookie` header serialization with conservative host-only handling for bare
  Safari domains. The third step adds a download-engine cookie-header provider
  hook so initial, range-parallel, and resume requests can carry daemon-supplied
  cookies. The fourth step wires the frozen `add.useImportedCookies` field to a
  volatile per-job header snapshot and clears it on `rm`. No persistent
  cookie-store format or new IPC command has been added. The fifth step adds the
  Safari cookie-file locator for the modern container path plus legacy fallback.
  The sixth step composes one daemon-local `ImportedCookieStore` into both the
  dispatcher and `DownloadEngine`, so the already-built hooks are live in
  `gohd` without adding a new command. PR #19 shipped these non-wire
  foundations. PR #20 froze the load-bearing command/FDA contract for the
  remaining `goh auth import safari` surface. PR #21 implemented the
  `protocolVersion = 2` command, including XPC fd passing, daemon parse/import,
  and CLI Full Disk Access handling. PR #22 shipped Spotlight completion
  metadata and active-download sleep assertions. Slices 5 and 6 are shipped.
- **Last merged before #16:** PR #15 — core correctness gates — `dcdf709`.
- **Repository is public** (github.com/xaedyn/goh) — flipped 2026-05-22, which
  also made GitHub Actions free on the `macos-26` runner.

## Slice 3a — shipped (the milestone: `goh` moves bytes to disk)

- Engine job-store transitions — `start` (an atomic claim) / `recordProgress` /
  `complete` / `fail`, driving `queued → active → completed/failed`.
- `DownloadFile` — `pwrite` at offset, streaming SHA-256, the 1 MiB fsync
  checkpoint, best-effort `F_PREALLOCATE`.
- `DownloadEngine` — single-connection HTTP fetch over `URLSession`.
- Daemon wiring — `gohd` runs the engine on `add`, on `resume`, and for jobs
  still queued at startup.
- 84 tests; the engine path is tested over a `URLProtocol` mock.

## Slice 3b — range-parallel orchestration (shipped)

Built, tested (101 tests), pushed:

- `DownloadFile` reworked to pure positioned I/O (`pwrite`/`pread`, `Sendable`).
- `ChunkAssembler` — in-order hashing of out-of-order bytes via the
  contiguous-frontier read-back; single-connection runs through it as `N = 1`.
- `ByteRange.split` — file splitting capped by a minimum chunk size.
- The `HEAD` capability probe, `fetchRanged` with N writers in a `TaskGroup`,
  per-range failure cancelling siblings, the single-connection fallback,
  `actualConnectionCount` recorded and kept on completion.
- A default `User-Agent` — `goh/0.1 (+repo)` — on every download request, set
  via `GohCore.downloadSessionConfiguration()`.
- The `Benchmarks/` suite — `goh-bench` driver, `competitive.sh`, the hashing
  benchmark wired into CI. Default workloads rotated to Range-honoring URLs
  (amenable → an archive.org item; saturated → a `dl.google.com` asset, the
  synthetic Cloudflare endpoint having 403'd on `Range`). Each workload
  self-checks its structural assumption at run time — the amenability WARN
  joined by a saturation WARN.
- Engine diagnostics — `Benchmarks/diagnose.sh` plus `GOH_ENGINE_TRACE=1` emit
  per-range start / first-byte / completion timestamps, peak concurrent range
  count, and per-range critical-section time split between the `pwrite`+fsync
  phase and the assembler/progress/store mutex phase. Off in normal runs;
  release builds flip it on without recompiling.

Merged as PR #14. The final validated run accepted parity-for-v0.1 and moved the
remaining adaptive host scheduling work to v0.2.

## Roadmap from here

- **3c** — shipped in PR #17: checkpoint/resume implementation, error / retry /
  cancellation, live `pause` / `resume`, and `rm --keep` partial adoption.
- **4** — shipped in PR #18: `NWPathMonitor` cellular auto-pause (§12).
- **5** — shipped across PR #19, PR #20, and PR #21: Safari cookie import
  foundation, auth import command contract, and implementation.
- **6** — shipped in PR #22: Spotlight tagging and sleep assertions.
- **7** — shipped across PR #23, PR #24, and PR #27: the `goh` CLI client.
- **8** — shipped in PR #28: the TUI for `goh top`.
- **9** — in progress: Homebrew formula, signing, notarization, the release pipeline.
  PR #29 refreshed the pre-release formula/docs surfaces. PR #30 added formula
  validation to CI. PR #31 added unsigned release artifacts and checksums. PR #32
  added packaged-artifact verification. PR #33 documented signing and
  notarization prerequisites. PR #34 added an unsigned PKG artifact and verifier
  for the future direct-download channel. PR #35 removed premature public install
  guidance and recorded the private launch gate. PR #36 added a manual private
  signed/notarized PKG release-candidate workflow that can be run only with
  credentials and an explicit workflow-dispatch input. PR #49 added the local
  health doctor. PR #50 added the private dogfood acceptance gate. PRs #58–#66
  ran a post-merge code-review sweep and shipped multi-terminal handoff support
  in the menu bar.

## Recent 3b validation notes

- **3b validated — parity-for-v0.1 accepted.** See the validated-measurement
  comment on PR #14 for the full numbers and reasoning. Saturated criterion
  met with margin (`goh` 7.020s vs `aria2c` 7.293s vs `curl` 6.802s at the
  default 8 conn — slight win over `aria2c`, 3.2 % behind `curl`'s
  single-stream ceiling). Amenable parity confirmed (`goh` 10.915s vs
  `aria2c` 10.958s at 8 conn; 16-conn data point widens `aria2c`'s lead
  marginally — the gap is the structural HTTP/2-vs-N-TCP one we've been
  circling, not a `goh` code defect).

  The investigation that got here surfaced and resolved three URLSession
  behaviours, of which the first two are quirks documented in DESIGN.md
  §Transport (*URLSession quirks*):

  **#1 — HEAD's `expectedContentLength = -1`.** `URLSession` does not
  populate `expectedContentLength` from `Content-Length` for `HEAD`
  responses on the wire, even when the server sent the header. The probe's
  `expectedContentLength > 0` check therefore always failed and the engine
  always fell back to single-connection. **The range-parallel orchestration
  shipped in 3a/3b had never actually run on the wire** — `MockURLProtocol`
  builds its response from `headerFields:` and populates
  `expectedContentLength`, hiding the quirk in CI. Fixed by parsing
  `Content-Length` from the response header directly.

  **#2 — auto-decompression breaks ranged downloads.** `URLSession`'s
  default `Accept-Encoding: gzip, deflate, br` triggers transparent
  content-decoding. A `Range` over an encoded body returns a partial slice
  of the *encoded* stream, which the decoder can't start mid-stream for
  ranges past 0 (-1015) and over-decodes range 0 (proportional overshoot).
  Verified by isolating in a 4-variant Swift test program against the
  saturated host: the original HTTP/2-multiplexing hypothesis was falsified.
  Fixed by sending `Accept-Encoding: identity`.

  **#3 (engine hygiene) — byte-by-byte AsyncBytes replaced with chunked
  Data delivery.** `URLSession.bytes(for:)` was iterating one async
  suspension per byte (~70M per range on the amenable file). Replaced with
  a `URLSession.dataTask` + `URLSessionDataDelegate` bridge that yields
  `Data` chunks via an `AsyncThrowingStream`. Tested as the amenable-gap
  hypothesis; **falsified** — the asymmetric throughput pattern reproduces
  locally with the new chunked code at the same magnitude. The change
  ships anyway as engine hygiene (~70M async iterations per range becomes
  ~700-760).

  **Competitive re-run (post #1 + #2):**
  - **Saturated PARITY achieved.** `goh` 7.056s vs `aria2c` 7.300s vs `curl`
    6.223s. Saturation check PASS (`aria2c 0.85× curl`, converged). `goh`
    slightly faster than `aria2c`; both pay ~13-17% overhead vs single-conn
    `curl` — the intrinsic cost of parallelism. The slice's hardest target
    is met.
  - **Amenable check WARN'd as expected** (curl 0.3s cached at edge), and
    inside the WARN `goh` is ~5× slower than `aria2c` on the same ranged
    URL (164s vs 33s). The diagnostic trace shows asymmetric throughput
    (1-2 ranges fast, 6-7 throttled to ~430 KB/s) that reproduces locally
    against archive.org. Not a goh code issue — the leading hypothesis is
    archive.org's per-stream rate-limiting under sustained HTTP/2 multiplexed
    load, against which `aria2c`'s HTTP/1.1 + separate-TCP-connection model
    fares better. `URLSession` doesn't expose a clean way to force HTTP/1.1.

  Three of the four original diagnostic hypotheses are now ruled out:
  cap-throttling (cap is 16, observed peak=8); mutex contention
  (`writeMs`+`reportMs` per range stay single-digit milliseconds); and
  AsyncBytes byte-iteration (chunked Data fix didn't change the gap).

  **HTTP/3 trial reverted.** A first round of three optimizations
  (speculative ranged GET, per-request `URLRequest.assumesHTTP3Capable`,
  1 MiB flush buffer) regressed the saturated workload by ~45 %
  (`goh` 6.607s → 10.754s median, with run-to-run variance suggesting
  server-side rate-limiting against h3 traffic on this network path).
  `aria2c` and `curl` stayed flat. HTTP/3 reverted; skip-HEAD and 1 MiB
  buffer kept (they don't show the variance signature). The slice landed
  a per-range `protocol=` trace line so the next h3 attempt isn't blind.

  **Final state at merge:** speculative ranged GET (one RTT saved per
  download), 1 MiB flush buffer (~16× fewer pwrites), per-range protocol
  diagnostic, all URLSession quirks (HEAD `expectedContentLength = -1`
  and Range-incompatible auto-decompression) worked around, two committed
  default benchmark workloads with run-time amenability/saturation checks,
  the engine diagnostics that drove this slice's debugging cycles. 101
  tests; CI green.

## Next-session handoff

**MOST RECENT: see the top "Current state" entry (dated 2026-06-03).** The in-flight adaptive
parallelism governor has since been **redesigned + fixed and P1–P4 are functionally complete** on
`design/in-flight-parallelism` (now **PR #80**, CI green, headline-benchmark deferred). This
2026-05-31 design-session note is **historical**: the four-round design (spec
`docs/superpowers/specs/2026-05-31-in-flight-adaptive-parallelism-design.md`, approach **A3 —
continuous governor + NWConnection multi-edge** because URLSession can't override SNI for IP
connections) was approved over 2 adversarial Opus rounds and has been implemented through P4; the
branch is cut, committed, and pushed (no longer "uncommitted on `main`"). **Pick-up options:**
(a) review/merge PR #80, then **P5** (NWConnection multi-edge) behind its feasibility spike +
dedicated security review; or (b) the Phase-3 public-launch track below (credential-gated). The
detailed breakdown is the top "Current state" entry dated *2026-06-03*.

---

`main` now includes **Phase 2 — adaptive per-host range scheduling** (PR #77,
squash `32efda1`) and the **in-flight-parallelism design seed** (PR #78, squash
`e048ec8`). Both feature/docs branches are deleted. **473 tests pass**,
`swift build` warning-clean. See the top "Current state" entry, dated
*2026-05-31 (merge session)*, for the full breakdown (incl. the email-redaction
residual note).

**THE NEXT ACTION — strategic arc Phase 3: public launch.** The one gate outside the
code is **Apple Developer ID credentials**. The launch sequence is preserved just
below (sign+notarize PKG via PR #36 workflow → open the `xaedyn/homebrew-goh` tap →
add SECURITY/CONTRIBUTING/CODE_OF_CONDUCT → launch post → HN/r/macapps/r/commandline/
r/datahoarder). **Credential-free alternative:** start the **in-flight adaptive
parallelism** slice (its own four-round design pass off the PR #78 seed; needs
sourced long-fat-network / multi-edge-CDN benchmarks) as the v0.2 performance
headline.

**Doc-currency note (verified 2026-05-31, impl session):** The top "Current state"
entry and this handoff are current. `DESIGN.md` §Adaptive host scheduling now
documents the frozen v1 `host-scheduling.plist` format (reconciled this session per
the four-round discipline). The planning artifacts under `docs/plans/` and
`docs/superpowers/{specs,progress}/` are **frozen point-in-time records** of the
closed design/plan — they intentionally describe the plan *as planned*, so minor
divergences from the shipped code (e.g. the handler-arity revision, trace-emission
site, "byte-for-byte" vs decoded-value-equality wording) are expected; DESIGN.md +
this STATE.md + the code are authoritative. `ROADMAP.md` still frames Phase 2 as
"design pass first" (it tracks scope, not status — status lives here in STATE.md).

**Earlier session's launch sequence — still valid as Phase 3, AFTER Phase 2
implementation ships.** From the gitignored strategy memo at
`docs/vision/VISION-2026-05-26.md`:

1. **Sign and notarize the PKG** by running PR #36's
   `private-release-candidate` workflow with Developer ID credentials.
   The workflow shape is already verified by
   `Scripts/verify-private-release-workflow.sh` — what's missing is the
   secrets (`GOH_APP_SIGN_IDENTITY`, `GOH_INSTALLER_SIGN_IDENTITY`,
   notarization credentials).
2. **Open the brew tap** (`xaedyn/homebrew-goh`) and publish the formula
   that PR #29/#30 prepared.
3. **Polish the launch post draft** at
   `docs/vision/LAUNCH-POST-DRAFT.md` (gitignored). Needs a menu bar
   screenshot and a final tone pass. The narrative the vision memo
   lands on: "the macOS download daemon for the AI era — Personal
   Asset Manager, not a faster curl." Reference the buried capabilities
   — `goh diagnose` via `GOH_ENGINE_TRACE=1`, `goh doctor` health gate,
   Spotlight `kMDItemWhereFroms` provenance, sleep assertions, cellular
   auto-pause, the Safari cookie import via fd-passing.
4. **Add `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`** —
   ~30 minutes of writing right before the brew tap opens. `SECURITY.md`
   is the most important (responsible disclosure address for a tool
   that handles cookies and sensitive URLs).
5. **Submit to Hacker News + r/macapps + r/commandline + r/datahoarder.**

**Alternative pickup if v0.1 launch prep is blocked on credentials:**
Bet 2 from the memo — `gohfile.toml` + `goh sync` + `goh verify`.
This is the path to the "Personal Asset Manager" shape and is ~2–4
weeks of work; the persistence and integrity primitives the v0.1
engine already exposes are the foundation. Doesn't depend on signing.

**Note on the local-only files** `AGENTS.md` and
`Benchmarks/diagnose-saturated.log`: both are now properly gitignored
(PR #69). They will no longer appear as untracked in `git status`, but
they remain on disk and should still be left alone.
