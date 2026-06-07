---
date: 2026-06-07
feature: tray-download-dashboard
phase: 1
status: complete
tasks: [T1, T2]
---

# Phase 1 — GohCore: rolling-rate sampler

## Goal
Create `RollingRateSampler` and thread it through all six `Self.progress()` call sites in `DownloadEngine`. After this phase the speed metric is correct everywhere (CLI + tray). Independently shippable.

## Gate
`swift build -Xswiftc -warnings-as-errors` + `swift test` — full suite green (zero regressions). The governor's ByteCounter block (lines 786–826) is untouched. `bytesPerSecond` wire field shape is unchanged.

## Tasks

### T1 — CREATE `Sources/GohCore/Engine/RollingRateSampler.swift`

- [ ] CREATE `Tests/GohCoreTests/RollingRateSamplerTests.swift` with 5 failing `@Test` stubs:
  - [ ] `windowed rate reflects only recent bytes, not cumulative average`
  - [ ] `returns zero during warm-up (fewer than 2 in-order samples or span < warmupInterval)`
  - [ ] `rate decays to zero when samples age out of window (stall)`
  - [ ] `evicts samples older than the window duration`
  - [ ] `out-of-order or regressing bytesCompleted sample is ignored, not a trap`
- [ ] CREATE `Sources/GohCore/Engine/RollingRateSampler.swift` — `final class RollingRateSampler: @unchecked Sendable` wrapping `Mutex<State>` (mirrors ByteCounter pattern from DownloadEngine.swift lines 11–26)
- [ ] Implement `init(window: Duration = .seconds(5), warmupInterval: Duration = .milliseconds(250))`
- [ ] Implement `record(bytesCompleted: UInt64, now: ContinuousClock.Instant) -> UInt64` with:
  - [ ] Mutex guard (`state.withLock { ... }`)
  - [ ] Monotonic guard: drop sample if `bytesCompleted <= lastStoredBytes` (unless first sample)
  - [ ] Append sample; evict samples with `instant < now - window`
  - [ ] Warm-up: return 0 if fewer than 2 in-order samples OR span < warmupInterval
  - [ ] Saturating subtraction: `newest.bytesCompleted >= oldest.bytesCompleted ? newest - oldest : 0`
  - [ ] Rate = deltaBytes / deltaSeconds
- [ ] Run `swift test --filter RollingRateSamplerTests` — all 5 pass
- [ ] Run `swift test` — full suite green

### T2 — MODIFY `Sources/GohCore/Engine/DownloadEngine.swift`

- [ ] Read all 6 `Self.progress(...)` sites before touching any (lines 393–394, 438–443, 525–528, 553–555, 884–885, 979–982)
- [ ] In `run(job:)` (~line 198): create `let sampler = RollingRateSampler()` and pass to both `resume(...)` and `download(...)` as new param `sampler: RollingRateSampler`
- [ ] Update `resume(...)` signature: add `sampler: RollingRateSampler`
  - [ ] Thread to `downloadResumeRange(...)` as new param
  - [ ] At final progress site (lines 393–394): call `sampler.record(...)` and overwrite `bytesPerSecond`
- [ ] Update `downloadResumeRange(...)` signature: add `sampler: RollingRateSampler`
  - [ ] At flush site (lines 438–443): call `sampler.record(...)` and overwrite `bytesPerSecond`
- [ ] Update `download(...)` signature: add `sampler: RollingRateSampler`
  - [ ] Thread to `fetchSingle(...)` and `fetchRanged(...)`
- [ ] Update `fetchSingle(...)` signature: add `sampler: RollingRateSampler`
  - [ ] At in-flight site (lines 525–528): call `sampler.record(...)` and overwrite `bytesPerSecond`
  - [ ] At final site (lines 553–555): call `sampler.record(...)` and overwrite `bytesPerSecond`
- [ ] Update `fetchRanged(...)` signature: add `sampler: RollingRateSampler`
  - [ ] Thread to `downloadRange(...)` and `consumeRange(...)`
  - [ ] At final site (lines 884–885): call `sampler.record(...)` and overwrite `bytesPerSecond`
- [ ] Update `downloadRange(...)` signature: add `sampler: RollingRateSampler`; thread to `consumeRange(...)`
- [ ] Update `consumeRange(...)` signature: add `sampler: RollingRateSampler`
  - [ ] At ranged-worker flush site (lines 979–982, inside `trace.timed(.report){}`): call `sampler.record(bytesCompleted: overall, now: clock.now)` and overwrite `bytesPerSecond`
- [ ] Verify governor block (lines 786–826) is NOT touched: `lastSampledTotal`, `lastSampledAt`, `bytesWritten.value`, `governor.record(...)`, `governor.decide(...)` all unchanged
- [ ] Run `swift build -Xswiftc -warnings-as-errors` — clean
- [ ] Run `swift test` — full suite green, including:
  - [ ] All existing `DownloadEngineTests` (including `flushEmitsRateSamples` and `injectedClockAccepted`)
  - [ ] `GohMenuPresenterTests.summarizesActiveDownloadsAndAggregateSpeed` (`aggregateSpeedText == "2.9 KB/s"` passes — test seeds bytesPerSecond directly, not a live-engine assertion)
  - [ ] `GohCommandLineTests.lsFormatsJobTable` (`"2 KB/s"` passes — seeded stub, not live)
  - [ ] `GohTUITests.topDashboardRows` (`"2 KB/s"` passes — seeded stub, not live)

## Phase 1 completion criteria
- [ ] `swift build -Xswiftc -warnings-as-errors` clean
- [ ] `swift test` — all ~780+ tests pass, 5 new RollingRateSamplerTests added
- [ ] Governor block unchanged (grep confirms no diff in lines 786–826)
- [ ] `JobProgress` struct fields unchanged (no new fields, no CodingKey changes)

## Completion record (2026-06-07)

- **T1** commit `b7c5a19` — `RollingRateSampler` + 5 tests (5/5 pass). Mutex-guarded, monotonic guard,
  saturating subtraction, always-evict, span oldest→`now`. Reviewed: APPROVED, no block issues.
- **T2** commit `80b95e4` — sampler threaded to all 6 display sites (resume final=`total`,
  resume flush=`completedBeforeRange+written`, single in-flight=`completed`, single final=`completed`,
  ranged final=`total`, consumeRange worker=`overall`). Sampler created exactly once in `run(job:)`,
  captured by reference into concurrent workers. Reviewed: APPROVED — governor block (lines ~805–848)
  proven byte-for-byte unchanged; `JobProgress` wire shape unchanged.
- **Gate:** `swift build -Xswiftc -warnings-as-errors` clean; `swift test` 785/785 pass. Zero regressions.
- **Contract for Phase 2:** GohMenuBar consumes the now-rolling `bytesPerSecond` via existing snapshots;
  no Phase 1 symbol is referenced from GohMenuBar.
