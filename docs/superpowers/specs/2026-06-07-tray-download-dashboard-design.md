---
date: 2026-06-07
feature: tray-download-dashboard
type: spec
approach: A — engine-side rolling speed + dedicated dashboard window
status: draft
revision: 2 (post adversarial spec review round 1 — 2 block issues fixed: concurrent-underflow crash + resume-path coverage; + verify-join API corrected)
---

# Spec — Professional Download Dashboard (tray)

## 1. Problem

The tray's download display has three problems a tester hit immediately: (a) active downloads don't appear
at all (the "1 active" header has no matching row), (b) the speed number is the cumulative average since
start, so it climbs and reads as wrong, and (c) the per-download information is a terse one-line caption —
no progress bar, ETA, sizes, or the connection count that is goh's signature. This spec fixes the no-row
bug, replaces the speed metric with a correct rolling rate **at the engine** (so the tray and the CLI agree),
and adds a professional download dashboard: a compact glanceable popover plus a dedicated Downloads window
with rich per-download rows, completed downloads retained with their verify status.

## 2. Success metrics

Done = all five ACs (`docs/superpowers/research/2026-06-07-tray-download-dashboard-acceptance-criteria.md`)
hold, plus:
- `swift build -warnings-as-errors` clean; full suite green (currently ~780) + new tests.
- With ≥1 download in any state, a visible row renders per download (height > 0) — the popover no longer
  collapses; the header "N active" matches the visible active rows.
- `JobProgress.bytesPerSecond` is computed as a **5-second sliding-window rate** (not `completed/elapsed`):
  a unit test feeding a synthetic (clock, bytesCompleted) sequence asserts a windowed rate, and that a stall
  decays it toward 0 (it does not keep climbing). Both the tray and `goh ls`/`goh top` show this rolling rate.
- The Downloads window shows, per row: filename, a determinate progress bar (spinner when total unknown),
  downloaded/total + %, rolling speed, ETA (when total known) + elapsed, and the actual connection count;
  completed/failed rows remain (until removed) with final state + verify/recorded status (completed).
- **No frozen-contract change** (`protocolVersion`, XPC envelope, `JobProgress`/`JobSummary` wire shapes);
  the BBR governor's separate sampling is untouched; existing engine tests pass unchanged.

Rollback trigger: any existing test regresses, the governor's behavior changes, or the engine sampler
introduces a data race / wrong rate.

## 3. Out of scope
- **Per-connection breakdown** (that's `goh top`'s separate schema) — the dashboard shows the aggregate
  connection count, not per-connection rows.
- **New XPC command / daemon push** — the dashboard reads the existing `scope: .all` snapshot stream + the
  local provenance ledger; no protocol change.
- **Download history persistence** beyond what the daemon already retains (completed jobs stay until removed;
  we do not add a persistent history store).
- **Changing the governor** or its sampling.
- **Sorting/filtering UI, search, drag-reorder** in v1 — rows render in job-id order.

## 4. Engine: rolling-rate sampler (the speed fix)

- Introduce a per-job `RollingRateSampler` in `GohCore`. **Create it in `run(job:)` and pass it into BOTH
  `download(job:)` AND `resume(...)`** — these are **sibling** entry points off `run()` (the resume path is
  NOT a sub-path of `download()`), so a sampler created inside `download()` would never reach the resume
  `Self.progress` sites (lines 394, 440). The single sampler is threaded to all six call sites (resume
  394/440, single 527/555, ranged 885/981) alongside the existing injected `clock`.
- It records `(instant, bytesCompleted)` samples and returns the rate over the **last 5 seconds**, evicting
  samples older than the window. Each call site passes its own `clock.now` to `record(now:)` — the clock is
  injected on the ranged `download()` path and local (`ContinuousClock()`) on the single/resume paths; the
  sampler only compares the instants it is handed, so windowing is internally consistent at every site.
  (Sampler unit tests drive `record(...)` with a synthetic instant sequence — deterministic, no engine.)
- **Crash-safety (load-bearing — the ranged path is concurrent):** the ranged call site (line 981, inside
  `consumeRange.flush()`) runs in **multiple concurrent TaskGroup workers**, and `Self.progress(...)` is
  invoked *after* the shared `ByteCounter` lock is released, so samples can arrive **out of order** (a later
  call carrying a *smaller* cumulative `bytesCompleted` than an earlier one). Therefore the sampler MUST:
  1. be `Mutex`-guarded (mutual exclusion), AND
  2. **reject/ignore any sample whose `bytesCompleted` is less than the most-recent stored value**
     (monotonic guard — drops out-of-order/regressing samples), AND
  3. compute every window delta with **saturating subtraction** (`latest >= oldest ? latest − oldest : 0`)
     so a `UInt64` subtraction can **never underflow/trap**.
  A plain `Mutex` alone is NOT sufficient — it serializes but does not restore ordering; the monotonic guard
  + saturating math are what make it crash-proof. Where feasible the plan should capture the
  `(now, bytesCompleted)` sample as close to the atomic byte-count update as possible to keep samples
  in-order, but the sampler is crash-safe regardless of ordering.
- **Warm-up:** return `0` until there are ≥2 (in-order) samples spanning a minimum interval (the sampler's
  OWN constant, e.g. `warmupInterval`, ~250 ms — do NOT reuse the governor's `minGovernorSampleSeconds`, to
  avoid implying coupling). Avoids a first-sample spike. A **stall** decays the rate toward 0 as samples age.
- `Self.progress(...)` is replaced at its call sites by the sampler (it still produces a `JobProgress` with
  the same `bytesCompleted`/`bytesTotal`; only `bytesPerSecond` is now the windowed value). The wire field
  is unchanged.
- The **BBR governor's `ByteCounter` sampler is NOT touched** (it is independent — its windowed delta in the
  control loop at ~814-826 stays exactly as-is).
- The final progress publication at completion uses the sampler too; for a completed job the menu does not
  render a live speed (see §6).

## 5. Tray: dashboard UI

- **Popover (compact, glanceable):** fix the collapse — the jobs list gets a real height (a `minHeight`, or
  a plain `VStack` for the small count shown). Show the top few downloads (filename + a determinate progress
  bar + rolling speed). A **"Downloads…"** button opens the dedicated window. The header keeps the aggregate
  "N active · rolling aggregate speed."
- **Downloads window** (`Window(id:"downloads")`, resizable, mirroring the Trust/Add-Download window +
  `@StateObject` root pattern): the full dashboard — one rich row per job in id order:
  - **Primary line:** file-type SF Symbol + filename (`.headline`, middle-truncated) + trailing
    hover actions (pause/resume, cancel/remove, reveal-in-Finder for completed).
  - **Progress:** determinate `ProgressView(value: bytesCompleted, total: bytesTotal)` when total is known;
    `ProgressView()` (indeterminate spinner) when `bytesTotal == nil`.
  - **Secondary line (`.caption`, muted):** for `.active` — `downloaded / total · rolling-speed · ETA · N
    connections`; ETA = remaining/rolling-rate (omit/"unknown" when total unknown or rate warming);
    `N connections` = `actualConnectionCount`. For `.completed` — `final size · finished-at · <verify
    status>`. For `.failed` — the error summary + retry state. For `.paused` — "Paused (<reason>)".
  - **Verify status (completed rows):** call the existing menu seam `ProvenanceReading.read()` (no args)
    **once**, and on `.entries(let entries)` build a `[destinationPath: ProvenanceEntry]` map; look up each
    completed row by `job.destination`. Show "recorded" (in ledger) / "verified <date>" (`verifiedAt`) when
    found; `.absent`/`.unreadable`/not-found → no badge (never an error). (Read once + map — NOT a per-row
    ledger read; there is no per-path `read(at:)` on the menu seam.)
- Accessibility labels on all controls; respects the existing nonisolated/Sendable + MainActor conventions.

## 6. Security surface
- **No new IPC / no wire change** — the dashboard reads the existing snapshot stream and the local 0600
  provenance ledger (read-only, via the already-present `trustReader`). No new XPC `Command`,
  `protocolVersion` unchanged.
- **No new untrusted input** — all data is the daemon's own job state + the user's own ledger. Any URL shown
  passes `URLDisplay.sanitized` (as the existing rows already do).
- **Engine change is internal** — the sampler consumes the engine's own byte counts; it adds no input path.
  Thread-safety is the only correctness concern (handled in §4).

## 7. Edge cases
- **No downloads:** "No downloads yet." (popover + window), not a collapsed/blank area.
- **Active job, total unknown (`bytesTotal == nil`):** indeterminate spinner; show downloaded size + speed;
  ETA "unknown". When the size becomes known mid-flight, swap to the determinate bar.
- **Warm-up (<~250ms / <2 samples):** speed shows "—"/"starting…"; ETA hidden.
- **Stall (no bytes flowing):** rolling rate decays toward 0; ETA grows/"unknown"; row stays "Active".
- **Pause → resume:** the sampler is per-`run()` (one run executes exactly one of download/resume), so a
  resumed download gets a fresh sampler that warms up again; paused row shows
  "Paused"; no live speed while paused.
- **Completed/failed retained:** stay listed (daemon retains until user removes); completed shows final size
  + finished-at + verify status; failed shows error/retry; both offer remove/reveal as appropriate.
- **Many downloads:** the window list scrolls (it's resizable, so not height-starved); the popover shows a
  capped top-N + "Downloads…" for the rest.
- **Ledger unreadable:** completed rows simply omit the verify badge (no error surfaced).
- **Concurrent engine workers (ranged):** multiple TaskGroup workers call the sampler, possibly out of
  order. The sampler is `Mutex`-guarded, drops regressing samples (bytesCompleted < last stored), and uses
  saturating subtraction, so it produces a sane single rolling rate with **no data race and no `UInt64`
  underflow trap** — even when a later call carries a smaller cumulative byte count (§4).

## 8. Interface contracts

### 8.1 Engine — rolling-rate sampler (GohCore)
```
// Per-job; created in run(job:) and passed into BOTH download(job:) AND resume(...) (sibling paths).
// Thread-safe: Mutex-guarded; MUST tolerate out-of-order/regressing samples from concurrent ranged workers.
final class RollingRateSampler: @unchecked Sendable {   // Mutex-guarded internal state
    // No stored clock — each call site passes its own `clock.now` to record(now:); the sampler
    // only compares the instants it is given, so windowing is internally consistent at every site.
    init(window: Duration = .seconds(5), warmupInterval: Duration = .milliseconds(250))
    // Record the latest cumulative byte count at `now`; return the windowed rate (bytes/sec).
    // - Ignores a sample whose bytesCompleted < the last stored value (monotonic guard).
    // - Evicts samples older than `window`.
    // - Returns 0 during warm-up (<2 in-order samples spanning warmupInterval).
    // - Window delta uses SATURATING subtraction — never underflows/traps.
    func record(bytesCompleted: UInt64, now: ContinuousClock.Instant) -> UInt64
}
```
`DownloadEngine.progress(...)`'s rate is replaced by `sampler.record(...)`; `JobProgress` keeps
`bytesCompleted`/`bytesTotal`; `bytesPerSecond` becomes the windowed value. No signature/field change to
`JobProgress`/`JobSummary`. (Unit tests drive `record(...)` with a synthetic clock + byte sequence,
including an out-of-order/regressing sample to prove no trap, a stall to prove decay-to-0, and warm-up.)

### 8.2 Tray — display model additions (GohMenuBar)
The presenter gains, per row (from existing `JobSummary` fields — no wire change): `progressFraction`
(Double? = bytesCompleted/bytesTotal, nil when total unknown), `sizeText` (downloaded/total), `etaText`
(String?, from rolling rate + remaining; nil when unknown/warming), `elapsedText` (from createdAt/
lastProgressAt), `connectionText` (actualConnectionCount), and a `verifyStatus` for completed rows (from a ONE-TIME
`ProvenanceReading.read()` → `[destinationPath: ProvenanceEntry]` map, looked up by `job.destination`; see
§5). Live speed/ETA are populated only for `.active`. These are `nonisolated`/Sendable additions to the
existing `GohMenuJobRow`/state (following the `nonisolated public struct … : Sendable, Equatable` convention
of `GohMenuJobRow`), unit-tested via the presenter with stub snapshots + a stub `ProvenanceReading`.

### 8.3 Window + scene (goh-menu)
A `Window(id:"downloads")` scene + a `@StateObject` root (mirroring `AddDownloadWindowRoot`/`TrustWindowRoot`),
opened from the popover's "Downloads…" button via `NSApp.activate(...)` + `openWindow(id:"downloads")`.

## 8.4 Components to build
- `Sources/GohCore/Engine/RollingRateSampler.swift` — the sampler (+ used by `DownloadEngine`).
- `Sources/GohCore/Engine/DownloadEngine.swift` — thread the sampler through the progress call sites.
- `Sources/GohMenuBar/GohMenuModels.swift` / `GohMenuPresenter.swift` — enriched row fields + ETA/elapsed/
  connections/verify mapping (live speed/ETA only for active).
- `Sources/GohMenuBar/GohMenuView.swift` — fix the collapse (popover list height) + "Downloads…" button.
- `Sources/GohMenuBar/DownloadsWindowView.swift` (+ a small root) — the rich dashboard rows.
- `Sources/goh-menu/main.swift` — the `Window(id:"downloads")` scene + root, fed the snapshots + trustReader.
- Tests: `RollingRateSamplerTests` (windowed rate, warm-up, stall-decay, eviction, AND an out-of-order /
  regressing-bytes sample asserting no trap + sane rate — deterministic clock);
  presenter tests (rich fields, ETA/unknown, completed verify-join via stub ledger, live-only-for-active);
  a collapse regression assertion if feasible; existing engine/governor/CLI speed tests greped + updated.

## 9. Rollout & migration
- Additive + one internal engine change (rate computation). No wire/format/protocolVersion change; brew/CLI
  users get a better speed number (and the new dashboard if they run the tray). Rollback = revert PR.
- The engine change ships with the menu change in one slice (the rolling rate feeds both); CI builds + tests
  gate it.

## 10. Unverified research claims relied upon
- 5-second sliding window is the right convention [VERIFIED — curl 5s; aria2 10s; wget ~3s]; sliding over
  EWMA [VERIFIED]. ETA from rolling rate, hidden when size unknown [VERIFIED — curl].
- Determinate `ProgressView(value:total:)` / spinner when unknown [VERIFIED — Apple HIG/ProgressView].
- Popover-for-glance + dedicated-window-for-list is the pro menu-bar pattern [SINGLE — Downie/MenuBar Stats].
