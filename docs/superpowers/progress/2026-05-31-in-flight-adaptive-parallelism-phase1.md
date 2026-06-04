# P1 Artifact — Injected Clock + Rate Instrumentation + Pure Governor

Phase 1 of the in-flight adaptive parallelism slice (spec
`docs/superpowers/specs/2026-05-31-in-flight-adaptive-parallelism-design.md`, plan
`docs/plans/2026-05-31-in-flight-adaptive-parallelism-plan.md`). Built via
subagent-driven-development on branch `design/in-flight-parallelism`, TDD per task, two-stage review.
**Status: COMPLETE.** No behaviour change ships in P1 — the governor is a pure value type, unit-tested
only; nothing is wired to the engine yet.

## dummynet verification spike (spec §12.1 gate) — **CONFIRMED**

`dnctl` (`/usr/sbin/dnctl`) + `pfctl` (`/sbin/pfctl`) present and functional on **macOS 26.5 /
arm64**. Live pipe-creation test passed:

```bash
sudo sh -c 'dnctl pipe 1 config bw 50Mbit/s delay 150 plr 0.005 && dnctl list && dnctl pipe 1 delete'
# 00001:  50.000 Mbit/s  150 ms  50 sl.plr 0.005000 0 queues (1 buckets) droptail
# DUMMYNET_OK
```

**Verdict:** dummynet works on macOS 26 Apple Silicon. **P4's hermetic deterministic benchmark gate
(SM1/SM3 signal-model iteration) uses `dnctl`+`pfctl` directly.** The Linux-VM `tc netem` fallback is
**not needed** and is recorded only as a contingency if dummynet regresses on a future OS. This was the
spec's top `[UNVERIFIED]` risk; it is now closed.

## What was built

- **Task 1 — injected `ContinuousClock`** (`bf0aca6`). `fetchRanged` gained a defaulted
  `clock: ContinuousClock = ContinuousClock()` parameter; the inline `let clock = ContinuousClock()`
  was removed and `started = clock.now` now reads the injected clock. All existing callers unchanged via
  the default. Enables deterministic governor timing in later phases.
- **Task 2 — per-chunk rate accumulator** (`b451823`). `consumeRange` declares
  `var rateSamples: [(bytes: UInt64, elapsed: Duration)]` in body scope and appends `(written,
  clock.now - started)` at the tail of `flush()`. **P1 placeholder** — not yet consumed (`_ = rateSamples`
  keeps it warning-clean). Establishes the sampling chokepoint.
- **Task 3 — pure `ParallelismGovernor`** (`6875bd9`, tests strengthened in `6c75420`). New file
  `Sources/GohCore/Governor/ParallelismGovernor.swift`: a `Sendable` value type, three-phase controller
  (geometric probe → knee detection → cruise + re-probe), injected RNG, **gain-only RTT fallback**.
  Dead state (`lastAggregateAtProbeUp`) and unused imports removed during review.
- **Task 4 — `GovernorOutcome`** (`3f57db2`). New file
  `Sources/GohCore/Governor/GovernorOutcome.swift`: daemon-internal `Sendable & Equatable` struct
  `{ effectiveN: UInt8?, stabilized: Bool }` + `.governorOff` sentinel. **Never on the wire.**

**Test count: 483, all green, warning-clean under `-warnings-as-errors`, strict-concurrency-clean.**
Review caught and fixed a real defect: the first-cut SM3 tests passed via a degenerate
`allWorkersInSteadyState`-returns-false early-return (fewer workers fed than `liveWorkers`); they were
strengthened to genuinely drive the probe-up, RTT-bufferbloat, and gain-only-knee branches.

## Current state of modified / created files

- `Sources/GohCore/Engine/DownloadEngine.swift` — `fetchRanged(... , clock: ContinuousClock =
  ContinuousClock())`; `consumeRange` carries the `rateSamples` accumulator at the `flush()` boundary
  (placeholder, unconsumed in P1). `assembler.advance(range:writtenBytes:)` **unchanged** (P2 migrates
  it to the interval-set API).
- `Sources/GohCore/Governor/ParallelismGovernor.swift` (new) — public API below.
- `Sources/GohCore/Governor/GovernorOutcome.swift` (new) — public API below.
- `Tests/GohCoreTests/DownloadEngineTests.swift` — `injectedClockAccepted`, `flushEmitsRateSamples`.
- `Tests/GohCoreTests/ParallelismGovernorTests.swift` (new) — 7 SM3 tests + `governorOutcomeEffectiveN`.

## Contracts established (for P2/P3 to import against)

```swift
public struct WorkerRateSample: Sendable {
    public var workerIndex: Int
    public var bytesPerSecond: Double
    public var rttRatio: Double?            // nil when RTT proxy unavailable/too noisy
    public init(workerIndex: Int, bytesPerSecond: Double, rttRatio: Double? = nil)
}

public enum GovernorDecision: Sendable, Equatable {
    case hold
    case addWorkers(Int)
    case dropWorkers(Int)                   // RESERVED — never produced by decide() in P1; P3 cruise/throttle wiring emits it
    case commit(Int)
    case backOffPinLow
}

public struct ParallelismGovernor: Sendable {
    public struct Config: Sendable {        // steadyStateWindow, steadyStateThreshold, kneeGainThreshold,
        public static let `default`: Config // rttBufferbloatFactor, hardCap=16, tinyFileThreshold=4 MiB,
        // ...full init...                   // reproBeCadence, rateAlpha=0.3
    }
    public enum Phase: Sendable, Equatable { case probe; case cruise(operatingN: Int); case pinned(n: Int) }
    public init(config: Config = .default, rng: some RandomNumberGenerator)   // rng stored for a P3 epsilon draw
    public mutating func record(sample: WorkerRateSample)
    public mutating func notifyThrottleDetected()
    public mutating func decide(liveWorkers: Int, remainingBytes: UInt64) -> GovernorDecision
}

public struct GovernorOutcome: Sendable, Equatable {   // daemon-internal; NOT on the wire
    public var effectiveN: UInt8?           // non-nil iff steady-state N ∈ {2,4,8,16} candidate set
    public var stabilized: Bool
    public init(effectiveN: UInt8?, stabilized: Bool)
    public static let governorOff: GovernorOutcome     // effectiveN nil, stabilized false
}
```

## Open items for P2 / P3

1. **Rate-sample shape is a placeholder (P2/P3).** Task 2's accumulator records *cumulative* bytes +
   *total* elapsed-since-start, not per-flush deltas. The governor consumes `WorkerRateSample`
   (`bytesPerSecond` per worker). P3 wiring must compute per-flush deltas (Δbytes / Δt since last flush)
   and the per-worker EWMA before feeding the governor — the `(bytes, elapsed)` tuple is thrown away.
   The `_ = rateSamples` suppressor is removed when the governor consumes the samples (P3).
2. **`.dropWorkers` and `Phase.pinned` are forward-API in P1.** `decide()` never returns `.dropWorkers`
   and never sets `phase = .pinned` in P1 (throttle returns `.backOffPinLow` without a phase transition).
   P3 wires the live worker pool: cooperative drops (§6.2) and the throttle→pin-low transition. Documented
   on `GovernorDecision.dropWorkers` so it is not mistaken for dead code.
3. **Governor is unwired.** P3 (Tasks 11–18) instantiates the governor inside the control loop, threads
   `WorkerRateSample`s from `flush()`, applies `GovernorDecision`, and emits `GovernorOutcome` to the
   completion sink. P2 (Tasks 6–10) first replaces the static range split + `TaskGroup` with the
   `ChunkQueue` + interval-set `ChunkAssembler` + control-loop pool (behaviour-equivalent at fixed N).
4. **RNG reserved.** `ParallelismGovernor.init` stores `rng` but doesn't use it in P1 (the cruise
   re-probe is deterministic). P3 may use it for an epsilon-style cruise nudge; revisit whether it's
   actually needed or should be dropped.
5. **Config tuning is empirical (P4).** `Config.default` values (steadyStateWindow 5, kneeGainThreshold
   0.10, rttBufferbloatFactor 1.5, reproBeCadence 20) are first-cut. The plan's biggest open question is
   the `decide()`/`record()` call cadence vs. responsiveness — to be tuned against the now-confirmed
   dummynet harness in P4 before SM1/SM5a are claimed.

## Invariants held

`protocolVersion` 3, `JobCatalog.version` 1, `JobSummary` wire shape, `host-scheduling.plist` v1,
`DownloadCheckpoint` v1 — all **unchanged**. P1 added only pure types + an injected parameter + an
unconsumed accumulator. Nothing daemon-internal crossed the wire.
