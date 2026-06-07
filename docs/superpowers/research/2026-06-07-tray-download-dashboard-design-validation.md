---
date: 2026-06-07
feature: tray-download-dashboard
type: design-validation
---

# Design Validation — Professional Download Dashboard (Approach A: engine-side speed)

## Acceptance Criteria (from Step 2.5)
- AC1 downloads visible (collapse fixed). AC2 rolling honest speed (5s window, everywhere). AC3 rich
  per-download info (progress bar, sizes/%, speed, ETA, elapsed, connections, state). AC4 completed/failed
  stay + verify status. AC5 no contract/governor regression.

## Dependency Enumeration
**Modified interface:** the *value* of `JobProgress.bytesPerSecond` (computed in `DownloadEngine.progress`)
changes from cumulative-average to a 5s rolling rate. The wire SHAPE is unchanged (still a present,
non-optional `UInt64`). Consumers of that value: the live `JobSummary` in `ProgressBroker` → snapshots →
(a) the tray, (b) `goh ls`, (c) `goh top`. None break (all read a bytes/sec integer); all three now show a
rolling rate (the intended consistency win). No XPC `Command`/envelope/`protocolVersion` change. The
GohMenuBar additions (rich rows, dashboard window, ledger join) modify no existing interface.

## Questions Asked & Answers

### Zero Silent Failures
- **Existing users?** The displayed speed changes (rolling, not climbing) in tray + CLI. No data/format
  change, no migration. Behavior is strictly better.
- **Existing data/integrations?** `bytesPerSecond` wire field unchanged; the broker/snapshot/CLI consume it
  as before. No golden-fixture change (fixtures carry empty `snapshot: []`; JobProgress shape unchanged).
- **Partial failure?** N/A — single code change, no multi-step deploy.

### Failure at Scale
- **10x?** Each job owns one bounded ring (~50 samples at 5s/100ms) → O(1) memory/job; many concurrent
  jobs = many small rings. No shared global state.
- **Concurrent?** The `Self.progress(...)` call sites span single/ranged/resume. The per-job sampler MUST
  be safe against the actual concurrency of those sites: in `fetchRanged` multiple workers run, but the
  CCB shows the aggregate progress is published from the control loop / a single aggregation point (the
  governor's `ByteCounter` is the multi-worker accumulator; progress publication reads the aggregate). The
  plan MUST verify each of the 6 call sites' execution context and either confine the sampler to a single
  task or guard it with a `Mutex`. This is the load-bearing correctness question of Approach A.
- **Dependency unavailable?** N/A (in-process). The tray's ledger join reuses `trustReader` (read-only,
  already degrades to "unavailable").

### Simplest Attack
- **Cheapest abuse?** None new — read-only display; no new input/IPC. The rolling sampler consumes the
  engine's own byte counts; the dashboard renders the user's own jobs + their own ledger.
- **New endpoint?** None — no new XPC command; the dashboard reads the existing snapshot stream + the
  local ledger (read-only).

## Gaps Found
1. **Sampler location + threading** across the 6 `Self.progress` sites (single/ranged/resume) — must be a
   per-job object created in `download(job:)`, threaded alongside the existing `clock`/`started`.
2. **Concurrency of the call sites** — must confirm whether any site runs on a concurrent worker; if so,
   guard the sampler (`Mutex`) or confine it to the single publish point. (The governor's separate sampler
   stays untouched.)
3. **Clock injection** — the sampler must use the engine's existing injected `ContinuousClock` for
   deterministic unit tests (feed a synthetic time + byte sequence → assert windowed rate).
4. **Pause/resume + stall** — wall-clock window: samples older than 5s evicted; resume/new `download()`
   starts an empty ring; a stall decays the rate toward 0 as samples age (correct). Warm-up: return 0 until
   ≥2 samples spanning a minimum interval, to avoid a first-sample spike.
5. **`bytesPerSecond` contract** — present/non-optional; only value changes. No engine test pins the rate
   numerically (CCB); the plan must still grep `goh ls`/`top`/presenter tests for any speed-value assertion
   to update.
6. **Completed/failed display** — a completed row shows final size + finished-time, NOT a live speed; the
   presenter must suppress live speed/ETA for non-active states. Failed shows error/retry.
7. **ETA + warm-up display** — ETA = remaining/rolling-rate, computed menu-side; "unknown" when
   `bytesTotal == nil`; show "—"/"starting…" when the rate is 0/warming.
8. **No-row collapse fix** — give the list real height (`minHeight`, or `VStack` for the compact popover);
   the dedicated dashboard `Window` is resizable so it isn't height-starved.

## Fixes Applied (folded into the spec)
1-2. Spec specifies a per-job `RollingRateSampler` created in `download(job:)`, threaded to the sub-paths;
   the plan's pre-task reads must verify each call site's concurrency and the spec mandates `Mutex` guarding
   if any site is concurrent (default assumption: guard it, since correctness > a micro-optimization).
3. Sampler takes the injected `ContinuousClock`; unit-tested deterministically.
4. Window = 5s sliding; evict-older-than-window; empty-ring/warm-up returns 0 until ≥2 samples over a min
   span; resume starts fresh.
5. Wire field unchanged; plan greps for and updates any speed-value test/golden.
6. Presenter renders live speed/ETA only for `.active`; completed → size + finished-at; failed → error.
7. ETA/elapsed/warm-up handled menu-side from the (now-rolling) rate + timestamps.
8. Popover list gets real height (collapse fixed); the full dashboard lives in a resizable `Window(id:"downloads")`.

No gap requires a user decision; all resolved at design time (the concurrency point is flagged as the
load-bearing item for the plan to verify against the real call sites).
