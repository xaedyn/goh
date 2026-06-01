# In-Flight Adaptive Parallelism Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a controller that adjusts parallel-connection count live during a single download,
feeds its converged count back into the per-host bandit, and — in its final phase — fans out across
distinct CDN edge IPs over a new NWConnection HTTP/1.1 transport.

**Architecture:** Approach A3 — Continuous Governor + Multi-Edge Fan-Out. A pure value type
`ParallelismGovernor` (injected clock + RNG, no I/O) runs a three-phase BBR-inspired loop
(geometric probe → knee detection → cruise + re-probe) inside a single-control-loop `TaskGroup`.
Chunks are drawn from a dynamic interval-set queue so workers can be added or dropped without
disrupting in-flight bytes. The governor's candidate-aligned convergence feeds back into the
existing `HostProfileStore` bandit, unifying in-flight learning with across-download memory.
Multi-edge fan-out (P5) uses NWConnection HTTP/1.1 with `sec_protocol_options_set_tls_server_name`
for correct SNI when connecting to raw IP addresses, gated by a feasibility spike and an independent
security + transport review before merge.

**Tech Stack:** Swift 6.2 / 6.3.x; SwiftPM; GohCore + gohd (nonisolated default); Swift Testing;
macOS 26.0+; `-warnings-as-errors`; `Synchronization.Mutex`; `URLSession` (single-edge, all phases);
`NWConnection<NWProtocolTLS>` + `sec_protocol_options_set_tls_server_name` + `sec_protocol_options_set_verify_block` (P5 multi-edge only); `getaddrinfo` (P5); `ContinuousClock` (injected).

---

## Acceptance Criteria → Task Map

| SM/AC | Spec text (verbatim) | Task(s) | Gate type |
|-------|---------------------|---------|-----------|
| SM1 / AC1 | `GOH_ENGINE_TRACE=1` emits governor trace for probe→knee→cruise and converged N; saturated: N≤4; LFN: N>8; pass = both across ≥5 runs | Task 17 (trace), Task 21 (benchmark) | Benchmark |
| SM2 / AC2 | Governed median wall-clock within ≤5% of static-N median on saturated workload, ≥5 runs. Rollback trigger: >5% regression | Task 21 | Benchmark |
| SM3 / AC3 | Deterministic unit test feeds synthetic rate-sample sequences to the pure governor; it never backs off while any connection's rate derivative is above threshold | Task 3 | Unit test |
| SM4 / AC4 | Governor-converged candidate-aligned N recorded via `HostProfileStore`; cold download warm-starts N₀ (scheduling trace `reason=warmStart`); `host-scheduling.plist` stays v1 | Task 15 | Unit test |
| SM5a / AC5 | On sourced LFN target, governed median throughput strictly higher than static N=8, non-overlapping IQR, ≥5 runs | Task 22 | Benchmark |
| SM5b | Multi-edge median strictly higher than single-edge governed median on multi-edge CDN target (best-effort; if unsourceable, slice ships on SM5a) | Task 28 | Benchmark (P5) |
| SM6 / AC5 | NWConnection edge: wrong-hostname cert rejected; valid hostname cert accepted; revoked cert rejected (hard-fail). Pass = all three | Task 26 | Unit test + spike |

---

## Format Invariants (must remain unchanged throughout all phases)

- `protocolVersion = 3` — no wire bump.
- `JobCatalog.version = 1` — no catalog bump.
- `JobSummary` wire shape — no field rename/retype/remove (only daemon-internal `GovernorOutcome`).
- `host-scheduling.plist` version 1 — no on-disk format change.
- `DownloadCheckpoint` format version 1 — no checkpoint format change.

Every task that touches these types begins with an explicit invariant check callout.

---

## File Map

### New files (all phases)

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `Sources/GohCore/Governor/ParallelismGovernor.swift` | Pure value type: three-phase controller, `GovernorDecision`, `WorkerRateSample`, `GovernorConfig`. No I/O, injected clock+RNG. |
| Create | `Sources/GohCore/Governor/GovernorOutcome.swift` | Daemon-internal `Sendable` struct `GovernorOutcome { effectiveN: UInt8?, stabilized: Bool }`. Not on the wire. |
| Create | `Sources/GohCore/Engine/ChunkQueue.swift` | `Mutex`-guarded queue of remaining `ByteInterval`s; supports `pull()`, `push(intervals:)`, `markDone(interval:)`, `remainingBytes`. |
| Create | `Sources/GohCore/Engine/ConnectionBudget.swift` | Daemon-global per-host active-connection budget (§8); `Mutex`-guarded; `request(slots:hostKey:)` / `release(slots:hostKey:)`. |
| Create | `Sources/GohCore/Engine/EdgeTransport.swift` | P5: NWConnection HTTP/1.1 range client, SNI override, hostname-pinned verify block. Dormant constant guard until P5 ships. |
| Create | `Sources/GohCore/Engine/EdgeIPResolver.swift` | P5: `getaddrinfo` wrapper to enumerate A/AAAA records for a hostname. |
| Create | `Tests/GohCoreTests/ParallelismGovernorTests.swift` | SM3 + governor state-machine exhaustive tests. |
| Create | `Tests/GohCoreTests/ChunkQueueTests.swift` | Interval-set queue unit tests. |
| Create | `Tests/GohCoreTests/ConnectionBudgetTests.swift` | Per-host budget unit tests (P4). |
| Create | `Tests/GohCoreTests/EdgeTransportTests.swift` | P5: adversarial HTTP/1.1 parser tests + SM6 verify-block tests. |
| Create | `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase1.md` | P1 artifact |
| Create | `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase2.md` | P2 artifact |
| Create | `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase3.md` | P3 artifact |
| Create | `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase4.md` | P4 artifact |
| Create | `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase5.md` | P5 artifact |

### Modified files (all phases)

| Action | Path | What changes |
|--------|------|-------------|
| Modify | `Sources/GohCore/Engine/DownloadEngine.swift` | P1: inject `ContinuousClock` param into `fetchRanged`/`consumeRange`; add per-chunk rate sampling in `flush()`. P2: replace static `ByteRange.split` + `TaskGroup` with `ChunkQueue` + control-loop pool. P3: wire governor to pool; pass `GovernorOutcome` to handler. P4: check `ConnectionBudget`. |
| Modify | `Sources/GohCore/Engine/ChunkAssembler.swift` | P2: replace co-indexed `[ByteRange]` + `[UInt64]` with interval-set completed-bytes set; new `complete(interval:)` + coalesce; new frontier algorithm; new end condition. |
| Modify | `Sources/GohCore/Scheduling/HostProfileStore.swift` | P3: `shouldRecordObservation` gains `effectiveN`/`stabilized` parameters via a new `ObservationRequest` parameter struct; `recordObservation` receives `connectionCount` from `GovernorOutcome.effectiveN`; add `reason: .warmStart` path for admission warm-start. |
| Modify | `Sources/gohd/main.swift` | P3: `completedDownloadHandler` closure gains `GovernorOutcome` fourth parameter; updates gate predicate call + `recordObservation` call. |
| Modify | `Sources/GohCore/Model/JobStore.swift` | P3: `setActualConnectionCount` no longer caps at `requestedConnectionCount`; caps at hard ceiling 16 instead. |
| Modify | `Sources/GohCore/Model/JobSummary.swift` | P3: `actualConnectionCount` documented as "peak concurrent connections used" (no field rename; existing encoding unchanged). |
| Modify | `Sources/GohCore/Scheduling/BanditSelector.swift` | P3: add `SelectionReason.warmStart` case (parallel to `.exploit`, means "governor-converged N seeded this run"). |
| Modify | `Sources/GohCore/Engine/EngineDiagnostics.swift` | P3: add `recordGovernorDecision(phase:N:decision:hostKey:)` for governor trace lines. P5: add `recordEdgeIP(ip:)`. |
| Modify | `DESIGN.md` | P3: §Persistence/§Adaptive host scheduling — observation gate redesign. P3: §Observability — governor trace line. P5: §Transport — NWConnection revision + DNS-poisoning safety argument. |
| Modify | `Tests/GohCoreTests/DownloadEngineTests.swift` | P1: add clock-injection tests. P2: add dynamic pool tests. P3: add governor wiring tests + handler arity. |
| Modify | `Tests/GohCoreTests/ChunkAssemblerTests.swift` | P2: replace index-based tests with interval-set tests; add coalesce + frontier + end-condition tests. |
| Modify | `Tests/GohCoreTests/HostProfileStoreTests.swift` | P3: update `shouldRecordObservation` call sites to `ObservationRequest` struct; add `warmStart` reason test. |

---

## Phase Index

- **P1** — Injected clock + per-chunk rate instrumentation + pure `ParallelismGovernor`. No behaviour change. Tasks 1–5.
- **P2** — Dynamic chunk pool + interval-frontier `ChunkAssembler` + live worker-pool control loop. Behaviour-equivalent at fixed N. Tasks 6–10.
- **P3** — Wire governor to pool; `GovernorOutcome` + observation-gate redesign + bandit feedback + warm-start. Ships SM4. Tasks 11–18.
- **P4** — Global per-host budget; `goh-bench` LFN harness + runbook; prove SM5a + SM2. **Ships the headline.** Tasks 19–22.
- **P5** — NWConnection edge transport + multi-edge fan-out + SM6 + DESIGN.md transport revision. Tasks 23–28.

---

## Phase 1: Injected Clock + Rate Instrumentation + Pure Governor

**What P1 builds:** `ContinuousClock` becomes an injected parameter (deterministic testability);
`consumeRange`'s `flush()` emits `(bytes, timestamp)` rate samples; `ParallelismGovernor` is a
pure value type exercised by unit tests only — no engine wiring yet.

**Also in P1:** The dummynet-on-macOS-26 verification spike (§12.1). One of {dummynet, `tc netem`}
MUST be confirmed before P2 so SM3 has a hermetic gate.

**Bet check (P1):** The governor's knee/steady-state logic rests on the bet that delivery-rate +
coarse chunk-timing can find regime-correct N without per-ACK signal. The gain-only fallback
(when RTT is too noisy) is the load-bearing hedge — it must be correctly implemented in P1 so
P3 wiring inherits a battle-tested governor.

---

### Task 1: Injected `ContinuousClock` in `fetchRanged`/`consumeRange`

**Files:** Modify `Sources/GohCore/Engine/DownloadEngine.swift` · Modify `Tests/GohCoreTests/DownloadEngineTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Engine/DownloadEngine.swift` — verified. Clock at line 513 (`let clock = ContinuousClock()` in `fetchRanged`). `consumeRange` receives `clock: ContinuousClock` and `started: ContinuousClock.Instant` as parameters already. `fetchRanged` constructs the clock inline and passes it to `consumeRange`. The change is to make `fetchRanged` accept an optional injected clock (defaulting to `ContinuousClock()`) so tests can drive timing.

**Invariant check:** No change to `protocolVersion`, `JobSummary`, `JobCatalog`, or checkpoint format.

- [ ] **Step 1: Write the failing test**

```swift
// In Tests/GohCoreTests/DownloadEngineTests.swift
// Add inside DownloadEngineTests struct:

@Test("SM3 prerequisite: fetchRanged accepts an injected clock (compile check)")
func injectedClockAccepted() async throws {
    // Verifies the new clock parameter exists; behaviour tested in Task 3.
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = ContinuousClock()

    let url = "https://test.local/\(UUID().uuidString).bin"
    let total: UInt64 = 4 * 1024 * 1024   // 4 MiB — above minChunk
    let payload = Data(repeating: 0xAB, count: Int(total))
    MockURLProtocol.stub(url, body: payload, statusCode: 206,
        headers: ["Content-Range": "bytes 0-\(total - 1)/\(total)"])
    let store = JobStore()
    let destination = directory.appending(path: "out.bin").path
    let job = store.create(url: url, destination: destination, requestedConnectionCount: 2)

    // This will fail to compile until fetchRanged gains a `clock:` parameter
    // and DownloadEngine exposes it. We test via the public run() path here,
    // but the clock param on the internal method is what the test confirms exists.
    await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)
    #expect(store.job(id: job.id)?.state == .completed)
}
```

- [ ] **Step 2: Regression guard — expected to compile-and-pass before the change** (not a red test; the failing signal for the implementation comes from the compile error in Step 3 when the governor test references the injected-clock constructor)

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "injectedClockAccepted"
  ```

  Expected: PASS (this test already passes via public API; this is a regression guard, not a red-green test).

- [ ] **Step 3: Write minimal implementation**

In `DownloadEngine.swift`, change `fetchRanged` to accept an optional injected clock:

```swift
// Sources/GohCore/Engine/DownloadEngine.swift
// Change the private fetchRanged signature — add clock parameter:

private func fetchRanged(
    job: JobSummary, store: JobStore, url: URL, total: UInt64,
    initialResponse: HTTPURLResponse,
    firstRangeStream: AsyncThrowingStream<Data, Error>,
    cancelFirstRangeStream: @escaping @Sendable () -> Void,
    trace: EngineDiagnostics,
    clock: ContinuousClock = ContinuousClock()   // <-- injected, default keeps callers unchanged
) async throws {
    // ... existing body, already uses `clock` — no other change needed.
```

All existing callers (`download()` → `fetchRanged(...)`) pass no clock and get the default.
`consumeRange` already accepts `clock:` as a parameter, so no further change is needed there.

- [ ] **Step 4: Run test to verify it passes**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "injectedClockAccepted"
  ```

  Expected: PASS — 1 test passed.

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Engine/DownloadEngine.swift Tests/GohCoreTests/DownloadEngineTests.swift
  git commit -m "feat(engine): inject ContinuousClock into fetchRanged for deterministic testing"
  ```

---

### Task 2: Per-Chunk Rate Sampling in `consumeRange`

**Files:** Modify `Sources/GohCore/Engine/DownloadEngine.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Engine/DownloadEngine.swift` — `consumeRange`'s `flush()` nested function (lines 634–657). The clock and started instant are already parameters.

**What this adds:** At the end of each `flush()` call, record a `(bytes: UInt64, elapsed: Duration)` sample into a per-worker accumulator. In P1 the samples are stored inside `consumeRange` as a local array (not yet consumed by the governor). The governor in Task 3 will accept samples in this exact shape.

- [ ] **Step 1: Write the failing test**

```swift
// In Tests/GohCoreTests/DownloadEngineTests.swift
// Add inside DownloadEngineTests:

@Test("SM3 prerequisite: flush emits rate samples (observability check)")
func flushEmitsRateSamples() async throws {
    // We cannot directly inspect consumeRange's local array from outside.
    // This test confirms the engine still produces correct output when
    // the sampling accumulator is present — correctness is the gate.
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = "https://test.local/\(UUID().uuidString).bin"
    let total: UInt64 = 4 * 1024 * 1024
    let payload = Data(repeating: 0xCC, count: Int(total))
    MockURLProtocol.stub(url, body: payload, statusCode: 206,
        headers: ["Content-Range": "bytes 0-\(total - 1)/\(total)"])
    let store = JobStore()
    let destination = directory.appending(path: "out.bin").path
    let job = store.create(url: url, destination: destination, requestedConnectionCount: 2)

    await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)
    #expect(store.job(id: job.id)?.state == .completed)
    let data = try Data(contentsOf: URL(fileURLWithPath: destination))
    #expect(data == payload)
}
```

- [ ] **Step 2: Regression guard — expected to compile-and-pass before the implementation change** (not a red test; it validates correctness invariant and will stay green before and after)

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "flushEmitsRateSamples"
  ```

  Expected: PASS — regression guard, not a red-green test.

- [ ] **Step 3: Write minimal implementation**

Add a `WorkerRateSample` struct (to be moved to `ParallelismGovernor.swift` in Task 3 — for now it lives in `DownloadEngine.swift` as a private type) and a local accumulator inside `consumeRange`:

```swift
// Sources/GohCore/Engine/DownloadEngine.swift
// Add just before consumeRange (or at the top of the file's MARK section):

/// A single per-chunk throughput sample. Feeds the parallelism governor.
/// Defined here temporarily; Task 3 moves the canonical definition to
/// Sources/GohCore/Governor/ParallelismGovernor.swift and imports it.
private struct WorkerRateSampleLocal: Sendable {
    /// Bytes flushed in this chunk.
    var bytes: UInt64
    /// Wall-clock elapsed from the worker's start to when this flush completed.
    var elapsed: Duration
}

// Inside consumeRange, add a local accumulator before the loop:
//   var rateSamples: [WorkerRateSampleLocal] = []
//
// At the END of flush(), append:
//   rateSamples.append(WorkerRateSampleLocal(
//       bytes: written,
//       elapsed: clock.now - started))
//
// The accumulator is not yet consumed. The governor wiring in P3 (Task 14)
// will receive these samples. For now this is a no-op accumulation that
// proves the shape compiles correctly.
```

Full diff — inside `consumeRange`, the `flush()` nested function's end:

```swift
private func consumeRange(
    index: Int, range: ByteRange, file: DownloadFile,
    assembler: ChunkAssembler, progress: RangeProgress,
    checkpointRecorder: DownloadCheckpointRecorder?,
    job: JobSummary, store: JobStore, total: UInt64,
    clock: ContinuousClock, started: ContinuousClock.Instant,
    trace: EngineDiagnostics,
    stream: AsyncThrowingStream<Data, Error>,
    cancelStream: @escaping @Sendable () -> Void
) async throws {
    defer { cancelStream() }
    trace.rangeStarted(index, bytes: range.length)
    var buffer = Data()
    buffer.reserveCapacity(Self.bufferSize)
    var written: UInt64 = 0
    // P1: per-chunk rate accumulator (consumed by governor in P3).
    var rateSamples: [(bytes: UInt64, elapsed: Duration)] = []

    func flush() throws {
        guard !buffer.isEmpty else { return }
        let pieceStart = range.start + written
        let pieceLength = UInt64(buffer.count)
        try trace.timed(index, .write) {
            try file.write(buffer, at: pieceStart)
            if checkpointRecorder != nil { try file.sync() }
        }
        if let checkpointRecorder {
            try checkpointRecorder.recordCompletedPiece(
                start: pieceStart, length: pieceLength)
        }
        written += pieceLength
        buffer.removeAll(keepingCapacity: true)
        trace.timed(index, .report) {
            assembler.advance(range: index, writtenBytes: written)
            let overall = progress.report(index: index, written: written)
            recordProgress(
                store: store, jobID: job.id,
                Self.progress(completed: overall, total: total,
                              elapsed: clock.now - started))
        }
        // P1: record rate sample at each flush boundary.
        rateSamples.append((bytes: written, elapsed: clock.now - started))
        try control?.stopIfRequested(jobID: job.id)
    }
    // ... rest of consumeRange unchanged ...
    _ = rateSamples  // suppress "unused variable" warning under -warnings-as-errors
}
```

- [ ] **Step 4: Run test to verify it passes**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "flushEmitsRateSamples"
  ```

  Expected: PASS — 1 test passed.

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Engine/DownloadEngine.swift
  git commit -m "feat(engine): add per-chunk rate sample accumulator in consumeRange (P1 instrumentation)"
  ```

---

### Task 3: Pure `ParallelismGovernor` Value Type

**Files:** Create `Sources/GohCore/Governor/ParallelismGovernor.swift` · Create `Tests/GohCoreTests/ParallelismGovernorTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Scheduling/BanditSelector.swift` — pattern for injected RNG and pure value type.

**Bet check (Task 3 is the load-bearing governor implementation):** The bet is that
delivery-rate + coarse chunk-timing can find regime-correct N without per-ACK signal. The knee
rule must include a **gain-only fallback** (ignoring RTT when the RTT proxy is too noisy) so the
governor remains useful even when coarse timing is unreliable. This fallback is load-bearing.

**SM3 AC:** "A deterministic unit test feeds synthetic rate-sample sequences (incl. a slow-start ramp)
to the pure governor; it never backs off or removes a connection while any connection's rate
derivative is above threshold."

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/GohCoreTests/ParallelismGovernorTests.swift
import Testing
@testable import GohCore

@Suite("ParallelismGovernor — pure value type")
struct ParallelismGovernorTests {

    // Deterministic RNG for tests.
    struct FixedRNG: RandomNumberGenerator {
        var value: UInt64
        mutating func next() -> UInt64 { defer { value &+= 1 }; return value }
    }

    // A clock that returns manually-advanced instants.
    // The governor uses ContinuousClock.Instant differences; we pass Duration samples directly.

    @Test("SM3: governor starts in probe phase and emits addWorkers on first steady state")
    func probePhaseDoublesOnSteadyState() throws {
        var rng = FixedRNG(value: 42)
        var gov = ParallelismGovernor(config: .default, rng: rng)

        // Feed rate samples showing steady state at N=2 (derivative near zero).
        // Each sample: (workerIndex: Int, bytesPerSecond: Double, rttRatio: Double?)
        for _ in 0..<ParallelismGovernor.Config.default.steadyStateWindow {
            gov.record(sample: WorkerRateSample(
                workerIndex: 0, bytesPerSecond: 10_000_000, rttRatio: nil))
            gov.record(sample: WorkerRateSample(
                workerIndex: 1, bytesPerSecond: 10_000_000, rttRatio: nil))
        }
        let decision = gov.decide(liveWorkers: 2, remainingBytes: 500_000_000)
        // Should probe up from N=2 to N=4.
        if case .addWorkers(let k) = decision {
            #expect(k == 2)   // double: 2→4
        } else {
            Issue.record("expected addWorkers(2), got \(decision)")
        }
    }

    @Test("SM3: steady-state gating — never backs off while rate derivative is above threshold")
    func steadyStateGating() throws {
        // SM3 (AC3): feeds a slow-start ramp; governor must hold (not backOff) while
        // per-connection rate derivative is above threshold.
        var rng = FixedRNG(value: 0)
        var gov = ParallelismGovernor(config: .default, rng: rng)

        // Slow-start ramp: rate increases each sample — derivative is high.
        var rate = 1_000_000.0
        for _ in 0..<20 {
            rate *= 1.2  // 20% increase per sample — clearly above threshold
            gov.record(sample: WorkerRateSample(
                workerIndex: 0, bytesPerSecond: rate, rttRatio: nil))
        }
        let decision = gov.decide(liveWorkers: 2, remainingBytes: 500_000_000)
        // Must not backOff or dropWorkers while derivative is high.
        switch decision {
        case .backOffPinLow, .dropWorkers:
            Issue.record("SM3 violated: governor backed off during slow-start ramp; decision=\(decision)")
        default:
            break  // hold, addWorkers, commit all acceptable
        }
    }

    @Test("SM3: bufferbloat stop — aggregate flat, RTT climbs → stop probing")
    func bufferbloatStop() throws {
        var rng = FixedRNG(value: 7)
        var gov = ParallelismGovernor(config: .default, rng: rng)
        // Establish RTT floor by feeding low-RTT samples.
        for _ in 0..<ParallelismGovernor.Config.default.steadyStateWindow {
            gov.record(sample: WorkerRateSample(
                workerIndex: 0, bytesPerSecond: 10_000_000, rttRatio: 1.0))
        }
        // Now simulate N doubling: aggregate flat, RTT ratio jumps to 2.0× floor.
        for _ in 0..<ParallelismGovernor.Config.default.steadyStateWindow {
            gov.record(sample: WorkerRateSample(
                workerIndex: 0, bytesPerSecond: 5_000_000, rttRatio: 2.0))
            gov.record(sample: WorkerRateSample(
                workerIndex: 1, bytesPerSecond: 5_000_000, rttRatio: 2.0))
        }
        let decision = gov.decide(liveWorkers: 4, remainingBytes: 500_000_000)
        // Bufferbloat: should not add more workers.
        if case .addWorkers = decision {
            Issue.record("governor should not add workers on bufferbloat signature; got \(decision)")
        }
    }

    @Test("SM3: gain-only fallback — RTT unusable, but gain is present → keeps probing")
    func gainOnlyFallback() throws {
        // Bet check: when RTT is nil (unavailable), the knee rule falls back to
        // gain-only. If per-conn rate still scales on doubling, governor continues.
        var rng = FixedRNG(value: 99)
        var gov = ParallelismGovernor(config: .default, rng: rng)
        for _ in 0..<ParallelismGovernor.Config.default.steadyStateWindow {
            gov.record(sample: WorkerRateSample(
                workerIndex: 0, bytesPerSecond: 20_000_000, rttRatio: nil))
            gov.record(sample: WorkerRateSample(
                workerIndex: 1, bytesPerSecond: 20_000_000, rttRatio: nil))
        }
        let decision = gov.decide(liveWorkers: 2, remainingBytes: 500_000_000)
        // Gain is present (40 MB/s aggregate), should probe up.
        if case .backOffPinLow = decision {
            Issue.record("gain-only fallback: should not back off when gain is positive; got \(decision)")
        }
    }

    @Test("SM3: tiny file guard — governor off for files below threshold")
    func tinyFileGuard() throws {
        var rng = FixedRNG(value: 1)
        var gov = ParallelismGovernor(config: .default, rng: rng)
        // remaining bytes below the tiny-file threshold
        let decision = gov.decide(liveWorkers: 2, remainingBytes: 100_000)
        if case .commit(let n) = decision {
            #expect(n == 1)
        } else {
            Issue.record("tiny file should commit(1), got \(decision)")
        }
    }

    @Test("SM3: throttle signature — aggregate drops + variance spike → backOffPinLow")
    func throttleSignatureBacksOff() throws {
        var rng = FixedRNG(value: 5)
        var gov = ParallelismGovernor(config: .default, rng: rng)
        // First: probe phase — steady state at N=2.
        for _ in 0..<ParallelismGovernor.Config.default.steadyStateWindow {
            gov.record(sample: WorkerRateSample(
                workerIndex: 0, bytesPerSecond: 10_000_000, rttRatio: 1.0))
        }
        // Simulate N doubling, then aggregate drop + high variance (throttle signature).
        for i in 0..<ParallelismGovernor.Config.default.steadyStateWindow {
            let fluctuating = i % 2 == 0 ? 2_000_000.0 : 8_000_000.0
            gov.record(sample: WorkerRateSample(
                workerIndex: 0, bytesPerSecond: fluctuating, rttRatio: nil))
            gov.record(sample: WorkerRateSample(
                workerIndex: 1, bytesPerSecond: fluctuating * 0.5, rttRatio: nil))
        }
        gov.notifyThrottleDetected()
        let decision = gov.decide(liveWorkers: 4, remainingBytes: 500_000_000)
        if case .backOffPinLow = decision {
            // pass
        } else {
            Issue.record("throttle detected: expected backOffPinLow, got \(decision)")
        }
    }

    @Test("SM3: hard cap — governor never recommends more than 16 workers")
    func hardCap16() throws {
        var rng = FixedRNG(value: 3)
        var gov = ParallelismGovernor(config: .default, rng: rng)
        // Feed steady-state samples at every candidate level to push to max.
        for _ in 0..<(ParallelismGovernor.Config.default.steadyStateWindow * 10) {
            for w in 0..<16 {
                gov.record(sample: WorkerRateSample(
                    workerIndex: w, bytesPerSecond: 50_000_000, rttRatio: nil))
            }
        }
        let decision = gov.decide(liveWorkers: 16, remainingBytes: 500_000_000)
        if case .addWorkers(let k) = decision {
            Issue.record("governor exceeded hard cap of 16; tried to add \(k) above 16")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ParallelismGovernor"
  ```

  Expected: FAIL — `cannot find type 'ParallelismGovernor' in scope`, `cannot find type 'WorkerRateSample' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/GohCore/Governor/ParallelismGovernor.swift`:

```swift
// Sources/GohCore/Governor/ParallelismGovernor.swift
import Foundation
import Synchronization

// MARK: — Wire types (sent between engine and governor)

/// A single per-worker rate sample at a flush boundary.
/// Injected by consumeRange's flush() chokepoint.
public struct WorkerRateSample: Sendable {
    /// Which worker this sample belongs to (0-indexed).
    public var workerIndex: Int
    /// Bytes-per-second EWMA for this worker at the time of the flush.
    public var bytesPerSecond: Double
    /// Coarse RTT ratio vs observed floor (nil when unavailable or too noisy).
    /// 1.0 = floor; values above ~1.25–2.0 indicate bufferbloat.
    public var rttRatio: Double?

    public init(workerIndex: Int, bytesPerSecond: Double, rttRatio: Double? = nil) {
        self.workerIndex = workerIndex
        self.bytesPerSecond = bytesPerSecond
        self.rttRatio = rttRatio
    }
}

// MARK: — Governor decision

/// What the governor tells the control loop to do next.
public enum GovernorDecision: Sendable, Equatable {
    /// No change — wait for more data.
    case hold
    /// Add k workers (probe up).
    case addWorkers(Int)
    /// Remove k workers cooperatively (they finish their current chunk).
    case dropWorkers(Int)
    /// Commit to n as the operating point — sets cruise mode.
    case commit(Int)
    /// Throttle detected or back-pressure exceeds safe level — back off hard and pin low.
    case backOffPinLow
}

// MARK: — Governor

/// Pure value type — rate/RTT samples in, a GovernorDecision out.
/// No I/O, no TaskGroup mutation. Injected clock+RNG for deterministic tests (SM3).
///
/// Three phases:
///   1. Geometric probe: wait for steady state, then double N (log N search).
///   2. Knee detection: stop when marginal gain < threshold OR RTT > floor×factor.
///   3. Cruise + re-probe: hold operating point; nudge up periodically to reclaim headroom.
///
/// Bet check: the bet (A3) is that delivery-rate + coarse chunk-timing can find the
/// regime-correct N. The gain-only fallback (RTT ignored when nil/noisy) is load-bearing —
/// without it, any path that can't produce reliable RTT estimates stalls the probe.
public struct ParallelismGovernor: Sendable {

    // MARK: — Config (non-frozen; injected for tests)

    public struct Config: Sendable {
        /// Number of steady-state samples required before the governor acts.
        public var steadyStateWindow: Int
        /// Rate derivative below which a worker is considered "steady" (fraction of mean rate).
        public var steadyStateThreshold: Double
        /// Marginal aggregate gain below which the knee is declared (fraction).
        public var kneeGainThreshold: Double
        /// RTT ratio above which bufferbloat is declared (e.g. 1.5 = 1.5× the floor).
        public var rttBufferbloatFactor: Double
        /// Hard ceiling for workers.
        public var hardCap: Int
        /// Minimum remaining bytes to engage the governor (tiny-file guard).
        public var tinyFileThreshold: UInt64
        /// Re-probe cadence: after this many decide() calls in cruise, nudge up by 1.
        public var reproBeCadence: Int
        /// EWMA alpha for per-worker rate smoothing.
        public var rateAlpha: Double

        public static let `default` = Config(
            steadyStateWindow: 5,
            steadyStateThreshold: 0.05,    // 5% relative rate change
            kneeGainThreshold: 0.10,       // <10% marginal gain → knee
            rttBufferbloatFactor: 1.5,
            hardCap: 16,
            tinyFileThreshold: 4 * 1024 * 1024,  // 4 MiB
            reproBeCadence: 20,
            rateAlpha: 0.3)

        public init(
            steadyStateWindow: Int,
            steadyStateThreshold: Double,
            kneeGainThreshold: Double,
            rttBufferbloatFactor: Double,
            hardCap: Int,
            tinyFileThreshold: UInt64,
            reproBeCadence: Int,
            rateAlpha: Double
        ) {
            self.steadyStateWindow = steadyStateWindow
            self.steadyStateThreshold = steadyStateThreshold
            self.kneeGainThreshold = kneeGainThreshold
            self.rttBufferbloatFactor = rttBufferbloatFactor
            self.hardCap = hardCap
            self.tinyFileThreshold = tinyFileThreshold
            self.reproBeCadence = reproBeCadence
            self.rateAlpha = rateAlpha
        }
    }

    // MARK: — Phase

    public enum Phase: Sendable, Equatable {
        case probe
        case cruise(operatingN: Int)
        case pinned(n: Int)   // throttle detected; hold low
    }

    // MARK: — State

    private var config: Config
    /// Per-worker EWMA rate (bytes/sec). Keyed by workerIndex.
    private var workerRates: [Int: Double]
    /// Historical samples per worker (last steadyStateWindow).
    private var workerHistory: [Int: [Double]]
    /// Smoothed RTT floor estimate.
    private var rttFloor: Double?
    /// Current smoothed RTT ratio (vs floor).
    private var rttSmoothed: Double?
    /// Last aggregate rate observed in probe (to measure marginal gain).
    private var lastAggregateAtProbeUp: Double?
    /// The aggregate rate recorded just before the last N doubling.
    private var aggregateBeforeLastDouble: Double?
    /// Phase tracker.
    private var phase: Phase
    /// Calls to decide() in cruise (for re-probe cadence).
    private var cruiseTicks: Int
    /// Flag: throttle was externally notified.
    private var throttleDetected: Bool

    public init(config: Config = .default, rng: some RandomNumberGenerator) {
        self.config = config
        self.workerRates = [:]
        self.workerHistory = [:]
        self.rttFloor = nil
        self.rttSmoothed = nil
        self.lastAggregateAtProbeUp = nil
        self.aggregateBeforeLastDouble = nil
        self.phase = .probe
        self.cruiseTicks = 0
        self.throttleDetected = false
        // rng not used at init — stored for future epsilon draws in cruise (P3 extension).
        _ = rng
    }

    // MARK: — Mutation

    /// Record a worker rate sample (called at each flush() boundary in consumeRange).
    public mutating func record(sample: WorkerRateSample) {
        let prev = workerRates[sample.workerIndex] ?? sample.bytesPerSecond
        let smoothed = config.rateAlpha * sample.bytesPerSecond + (1 - config.rateAlpha) * prev
        workerRates[sample.workerIndex] = smoothed

        var history = workerHistory[sample.workerIndex] ?? []
        history.append(smoothed)
        if history.count > config.steadyStateWindow * 2 {
            history.removeFirst()
        }
        workerHistory[sample.workerIndex] = history

        // Update coarse RTT floor and ratio.
        if let ratio = sample.rttRatio {
            if let floor = rttFloor {
                rttFloor = min(floor, ratio)
            } else {
                rttFloor = ratio
            }
            let prevRTT = rttSmoothed ?? ratio
            rttSmoothed = config.rateAlpha * ratio + (1 - config.rateAlpha) * prevRTT
        }
    }

    /// Externally notify that a throttle signature was detected.
    public mutating func notifyThrottleDetected() {
        throttleDetected = true
    }

    /// Main decision tick. Call after accumulating samples; returns the
    /// recommended action for the control loop.
    public mutating func decide(liveWorkers: Int, remainingBytes: UInt64) -> GovernorDecision {
        // Tiny-file guard: governor off → commit(1).
        if remainingBytes < config.tinyFileThreshold {
            return .commit(1)
        }

        // Throttle override.
        if throttleDetected {
            return .backOffPinLow
        }

        switch phase {
        case .pinned(let n):
            return .commit(n)

        case .cruise(let opN):
            cruiseTicks += 1
            if cruiseTicks >= config.reproBeCadence {
                cruiseTicks = 0
                let candidate = min(opN + 1, config.hardCap)
                if candidate > opN {
                    return .addWorkers(1)
                }
            }
            return .hold

        case .probe:
            // Check if all workers are in steady state.
            guard allWorkersInSteadyState(liveWorkers: liveWorkers) else {
                return .hold
            }
            let aggregate = aggregateRate()
            // Check knee condition.
            if let prevAggregate = aggregateBeforeLastDouble {
                let gain = aggregate > 0 ? (aggregate - prevAggregate) / prevAggregate : 0
                // Gain-only knee (primary, works even when RTT is nil).
                if gain < config.kneeGainThreshold {
                    // Knee reached — commit to liveWorkers.
                    phase = .cruise(operatingN: liveWorkers)
                    return .commit(liveWorkers)
                }
                // RTT-based bufferbloat check (advisory — only when reliable).
                if let smoothedRTT = rttSmoothed,
                   let floor = rttFloor,
                   floor > 0,
                   smoothedRTT / floor > config.rttBufferbloatFactor
                {
                    phase = .cruise(operatingN: liveWorkers)
                    return .commit(liveWorkers)
                }
            }
            // Probe up: double within candidate set {2, 4, 8, 16}, respecting hardCap.
            let nextN = candidateAbove(liveWorkers)
            guard let target = nextN, target <= config.hardCap else {
                // Already at cap — enter cruise.
                phase = .cruise(operatingN: liveWorkers)
                return .commit(liveWorkers)
            }
            aggregateBeforeLastDouble = aggregate
            return .addWorkers(target - liveWorkers)
        }
    }

    // MARK: — Private helpers

    private func allWorkersInSteadyState(liveWorkers: Int) -> Bool {
        guard liveWorkers > 0 else { return false }
        // Every active worker needs enough history.
        for index in 0..<liveWorkers {
            let history = workerHistory[index] ?? []
            guard history.count >= config.steadyStateWindow else { return false }
            let recent = Array(history.suffix(config.steadyStateWindow))
            let mean = recent.reduce(0, +) / Double(recent.count)
            guard mean > 0 else { return false }
            // Derivative check: max deviation from mean.
            let maxDev = recent.map { abs($0 - mean) / mean }.max() ?? 0
            if maxDev > config.steadyStateThreshold { return false }
        }
        return true
    }

    private func aggregateRate() -> Double {
        workerRates.values.reduce(0, +)
    }

    /// The next candidate N above `n` in {2, 4, 8, 16}.
    private func candidateAbove(_ n: Int) -> Int? {
        let candidates = [2, 4, 8, 16]
        return candidates.first { $0 > n }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ParallelismGovernor"
  ```

  Expected: PASS — 6 tests passed.

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Governor/ParallelismGovernor.swift Tests/GohCoreTests/ParallelismGovernorTests.swift
  git commit -m "feat(governor): pure ParallelismGovernor value type with three-phase controller (SM3)"
  ```

---

### Task 4: `GovernorOutcome` Struct

**Files:** Create `Sources/GohCore/Governor/GovernorOutcome.swift`

**What this adds:** The daemon-internal `Sendable` struct that carries the completion-sink signal
from the engine to the observation gate. Not on the wire — no `protocolVersion` bump.

**Invariant check:** `GovernorOutcome` is daemon-internal only. It does NOT appear in `JobSummary`
or any XPC-serialized type.

- [ ] **Step 1: Write the failing test**

```swift
// In Tests/GohCoreTests/ParallelismGovernorTests.swift
// Add to ParallelismGovernorTests suite:

@Test("GovernorOutcome: effectiveN is non-nil iff N is a bandit candidate")
func governorOutcomeEffectiveN() {
    // Candidate-aligned N → effectiveN non-nil.
    let aligned = GovernorOutcome(effectiveN: 8, stabilized: true)
    #expect(aligned.effectiveN == 8)
    #expect(aligned.stabilized)

    // Off-candidate N (binary-search refinement) → effectiveN nil.
    let offCandidate = GovernorOutcome(effectiveN: nil, stabilized: true)
    #expect(offCandidate.effectiveN == nil)

    // Not yet stabilized → effectiveN doesn't matter for gate, but it can be non-nil.
    let unstable = GovernorOutcome(effectiveN: 4, stabilized: false)
    #expect(!unstable.stabilized)
}
```

- [ ] **Step 2: Run test to verify it fails**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "governorOutcomeEffectiveN"
  ```

  Expected: FAIL — `cannot find type 'GovernorOutcome' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/GohCore/Governor/GovernorOutcome.swift
import Foundation

/// Daemon-internal result from a governed download.
///
/// Carries the governor's converged operating point to the completion sink
/// (`completedDownloadHandler`) so the bandit can record a candidate-aligned
/// observation. This struct is NEVER on the wire — it is not part of `JobSummary`
/// and carries no protocolVersion annotation.
///
/// `effectiveN` is non-nil iff the governor's steady-state operating N is a bandit
/// candidate {2, 4, 8, 16}. Off-candidate convergence (e.g. binary-search to 6)
/// produces nil — no observation is recorded in that case, so the frozen EWMA
/// never receives a biased/snapped value.
public struct GovernorOutcome: Sendable, Equatable {
    /// The candidate-aligned representative operating N during cruise, or nil
    /// if the governor converged off-candidate or did not stabilize.
    public var effectiveN: UInt8?
    /// Whether the governor reached stable cruise before the download ended.
    public var stabilized: Bool

    public init(effectiveN: UInt8?, stabilized: Bool) {
        self.effectiveN = effectiveN
        self.stabilized = stabilized
    }

    /// A sentinel meaning "governor not engaged" (explicit N or tiny file).
    public static let governorOff = GovernorOutcome(effectiveN: nil, stabilized: false)
}
```

- [ ] **Step 4: Run test to verify it passes**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "governorOutcomeEffectiveN"
  ```

  Expected: PASS — 1 test passed.

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Governor/GovernorOutcome.swift Tests/GohCoreTests/ParallelismGovernorTests.swift
  git commit -m "feat(governor): add GovernorOutcome daemon-internal struct (not on wire)"
  ```

---

### Task 5: dummynet Verification Spike (P1 Required Gate)

**Files:** No source files. Documentation-only outcome.

**Purpose:** Spec §12.1 — one of {macOS `dnctl`+`pfctl` dummynet, Linux VM `tc netem`} MUST be
confirmed in P1. SM3's hermetic gate cannot depend on a live third party.

- [ ] **Step 1: Run dummynet verification**

  On the macOS 26 Apple Silicon machine:
  ```bash
  # Check tools exist:
  which dnctl && which pfctl
  # Confirm kernel module:
  sudo dnctl show 2>&1 | head -5
  # Test pipe creation:
  sudo dnctl pipe 1 config bw 50Mbit/s delay 150 plr 0.005
  sudo dnctl show
  sudo dnctl pipe 1 delete
  ```

  Expected pass: Commands return 0, `dnctl show` displays the pipe.

- [ ] **Step 2: Record the result**

  **If dummynet passes on macOS 26 / Apple Silicon:** Record in the P1 progress artifact that
  `dnctl`+`pfctl` is confirmed. The local benchmark harness in P4 will use dummynet.

  **If dummynet fails (e.g., `dnctl` unavailable on macOS 26 Apple Silicon):** Confirm the
  Linux VM fallback:
  ```bash
  # On a UTM Linux VM (or similar):
  sudo tc qdisc add dev eth0 root netem delay 150ms loss 0.5%
  sudo tc qdisc show dev eth0
  sudo tc qdisc del dev eth0 root
  ```
  Record the UTM `tc netem` path as confirmed. P4 will use the VM for benchmarks.

- [ ] **Step 3: Write phase artifact**

  Write `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase1.md` with:
  - dummynet verdict (pass / fail + fallback confirmed)
  - List of modified/created files
  - Governor API contracts established (WorkerRateSample, GovernorDecision, GovernorOutcome)
  - Open items for P2

- [ ] **Step 4: Commit**

  ```
  git add docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase1.md
  git commit -m "docs(progress): P1 artifact — governor + clock injection + dummynet spike result"
  ```

---

## Phase 2: Dynamic Chunk Pool + Interval-Frontier `ChunkAssembler`

**What P2 builds:** `ChunkAssembler` replaced with an interval-set frontier; a `ChunkQueue` feeds
a control-loop `TaskGroup`; the engine is behaviour-equivalent to today at fixed N until the
governor drives it in P3.

**Key constraint:** `DownloadCheckpoint.completedPieces` format is UNCHANGED. The `ChunkAssembler`
rework must produce the same byte intervals that the existing `DownloadCheckpointRecorder` persists.

---

### Task 6: `ChunkQueue` — Interval-Set Work Queue

**Files:** Create `Sources/GohCore/Engine/ChunkQueue.swift` · Create `Tests/GohCoreTests/ChunkQueueTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Engine/ChunkAssembler.swift` — `ByteRange` struct (lines 6–33), current frontier walk (lines 138–149).
- [ ] `Sources/GohCore/Model/DownloadCheckpoint.swift` — `completedPieces` merge logic (lines 72–94). The chunk queue's interval semantics must be compatible.

**What this adds:** `ChunkQueue` holds remaining byte intervals, hands one chunk at a time to
workers, and tracks completed intervals. When a worker is dropped, its un-started chunk is
returned to the queue head (offset-ordered).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/GohCoreTests/ChunkQueueTests.swift
import Testing
@testable import GohCore

@Suite("ChunkQueue — interval-set work queue")
struct ChunkQueueTests {

    @Test("pull returns intervals in offset order")
    func pullOrderedIntervals() {
        let queue = ChunkQueue(intervals: [
            ByteInterval(start: 0, length: 1024 * 1024),
            ByteInterval(start: 1024 * 1024, length: 1024 * 1024),
            ByteInterval(start: 2 * 1024 * 1024, length: 512 * 1024),
        ])
        let first = queue.pull()
        #expect(first?.start == 0)
        let second = queue.pull()
        #expect(second?.start == 1024 * 1024)
        let third = queue.pull()
        #expect(third?.start == 2 * 1024 * 1024)
        let fourth = queue.pull()
        #expect(fourth == nil)
    }

    @Test("returnTail pushes interval back to front")
    func returnTailToFront() {
        let queue = ChunkQueue(intervals: [
            ByteInterval(start: 0, length: 1024),
            ByteInterval(start: 1024, length: 1024),
        ])
        let first = queue.pull()!
        queue.returnToFront(first)
        let re = queue.pull()!
        #expect(re.start == 0)
    }

    @Test("remainingBytes decrements on pull, not on complete")
    func remainingBytesTracking() {
        let total: UInt64 = 3 * 1024 * 1024
        let queue = ChunkQueue(intervals: [
            ByteInterval(start: 0, length: total),
        ])
        #expect(queue.remainingBytes == total)
        let chunk = queue.pull()!
        #expect(queue.remainingBytes == 0)
        queue.markDone(chunk)
        #expect(queue.remainingBytes == 0)
    }

    @Test("isDone when all intervals completed")
    func isDoneCondition() {
        let queue = ChunkQueue(intervals: [
            ByteInterval(start: 0, length: 100),
            ByteInterval(start: 100, length: 100),
        ])
        let a = queue.pull()!
        let b = queue.pull()!
        #expect(!queue.isDone)
        queue.markDone(a)
        #expect(!queue.isDone)
        queue.markDone(b)
        #expect(queue.isDone)
    }

    @Test("intervals from DownloadCheckpoint.missingByteRanges are accepted")
    func missingRangesCompatibility() {
        // Verify ByteInterval maps 1:1 to ByteRange (same start/length semantics).
        let range = ByteRange(start: 512 * 1024, length: 1024 * 1024)
        let interval = ByteInterval(from: range)
        #expect(interval.start == range.start)
        #expect(interval.length == range.length)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ChunkQueueTests"
  ```

  Expected: FAIL — `cannot find type 'ChunkQueue' in scope`, `cannot find type 'ByteInterval' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/GohCore/Engine/ChunkQueue.swift
import Foundation
import Synchronization

/// A byte interval: start offset + length. Isomorphic to ByteRange but named
/// separately to distinguish "a unit of work in the queue" from "a range spec."
public struct ByteInterval: Sendable, Equatable {
    public var start: UInt64
    public var length: UInt64

    public init(start: UInt64, length: UInt64) {
        self.start = start
        self.length = length
    }

    public init(from range: ByteRange) {
        self.start = range.start
        self.length = range.length
    }

    public var end: UInt64 { start + length }
}

/// A `Mutex`-guarded queue of remaining byte intervals for the dynamic chunk pool.
///
/// Workers pull one interval at a time; completed intervals are marked via
/// `markDone(_:)`. A dropped worker returns its un-started interval to the
/// front via `returnToFront(_:)`. Thread-safe.
public final class ChunkQueue: Sendable {

    private struct State: Sendable {
        var pending: [ByteInterval]      // sorted by start; front is next to pull
        var inFlight: Set<UInt64>        // starts of in-flight intervals
        var done: Set<UInt64>            // starts of completed intervals
        var totalIntervals: Int
    }

    private let state: Mutex<State>

    public init(intervals: [ByteInterval]) {
        let sorted = intervals.sorted { $0.start < $1.start }
        state = Mutex(State(
            pending: sorted,
            inFlight: [],
            done: [],
            totalIntervals: sorted.count))
    }

    /// Pulls the next pending interval. Returns nil when the queue is empty.
    public func pull() -> ByteInterval? {
        state.withLock { s -> ByteInterval? in
            guard !s.pending.isEmpty else { return nil }
            let interval = s.pending.removeFirst()
            s.inFlight.insert(interval.start)
            return interval
        }
    }

    /// Returns an interval to the front of the pending queue (dropped worker).
    public func returnToFront(_ interval: ByteInterval) {
        state.withLock { s in
            s.inFlight.remove(interval.start)
            s.pending.insert(interval, at: 0)
        }
    }

    /// Marks an interval as completed.
    public func markDone(_ interval: ByteInterval) {
        state.withLock { s in
            s.inFlight.remove(interval.start)
            s.done.insert(interval.start)
        }
    }

    /// Bytes still pending (not yet pulled). Used by the governor for the tiny-file guard.
    public var remainingBytes: UInt64 {
        state.withLock { s in
            s.pending.reduce(0) { $0 + $1.length }
        }
    }

    /// True when all intervals have been completed.
    public var isDone: Bool {
        state.withLock { s in
            s.done.count == s.totalIntervals && s.pending.isEmpty && s.inFlight.isEmpty
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ChunkQueueTests"
  ```

  Expected: PASS — 5 tests passed.

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Engine/ChunkQueue.swift Tests/GohCoreTests/ChunkQueueTests.swift
  git commit -m "feat(engine): ChunkQueue interval-set work queue for dynamic chunk pool (P2)"
  ```

---

### Task 7: Interval-Frontier `ChunkAssembler` Rework

**Files:** Modify `Sources/GohCore/Engine/ChunkAssembler.swift` · Modify `Tests/GohCoreTests/ChunkAssemblerTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Engine/ChunkAssembler.swift` — full file. Current init stores `ranges: [ByteRange]`, `written: Mutex<[UInt64]>`. `currentFrontier()` walks ranges in order. `advance(range:writtenBytes:)` indexes into `written`.
- [ ] `Tests/GohCoreTests/ChunkAssemblerTests.swift` — existing test patterns to understand what the new API must satisfy.
- [ ] `Sources/GohCore/Model/DownloadCheckpoint.swift` — `recordCompletedPiece` merge logic (lines 72–94). The assembler's coalesce must be identical in semantics.

**What changes:** Replace the co-indexed `[UInt64]` with an interval set under `Mutex`. Replace
`advance(range:writtenBytes:)` with `complete(interval:)`. New frontier = end of the single
coalesced interval that starts at byte 0. End condition = coalesced set is exactly `[0, total)`.

**SHA-256 invariant preserved:** The hasher still consumes bytes strictly in offset order, advancing
only when the byte-0 interval's frontier extends. Out-of-order completed bytes sit in the set but
are not hashed until the frontier reaches them.

**Wire/format invariant:** `DownloadCheckpointRecorder` still calls `recordCompletedPiece(start:length:)`
on the file+checkpoint side — that API is UNCHANGED. The assembler's internal storage changes; the
checkpoint recorder is unaffected.

**Dual-writer hazard eliminated (BLOCK 3):** The old plan kept `advance(range:writtenBytes:)` as a
shim that did a whole-set REPLACE (`completedIntervals.withLock { $0 = coalesce(...) }`). The new
`complete(interval:)` also did a whole-set replace. If both were called concurrently — range 0's
speculative stream using `advance` while pool workers called `complete` — the completed-interval
set would silently regress (whichever write landed last would discard the other's progress).

**Fix:** Both methods must be additive-merge only. The correct `complete(interval:)` inserts the
new interval INTO the existing set and coalesces; it never replaces the whole set. The
`advance(range:writtenBytes:)` shim is REMOVED entirely in Task 7. The existing engine callers
in `consumeRange` that call `assembler.advance(...)` must be migrated to call
`assembler.complete(interval:)` BEFORE any concurrent pool worker runs (i.e., in Task 8 when
the control-loop pool lands). The migration ordering must be:

  1. Task 7: `ChunkAssembler` gets additive-merge `complete(interval:)` only; `advance(...)` is
     deleted. Tests must confirm this compiles with zero callers.
  2. Task 8: The control-loop pool, which replaces `fetchRanged`'s static TaskGroup, uses
     `assembler.complete(interval:)` exclusively. No code path calls the deleted `advance`.

The plan no longer carries an `advance(range:writtenBytes:)` shim at any point in P2 or later.

- [ ] **Step 1: Write the failing tests (extend ChunkAssemblerTests)**

```swift
// Add to Tests/GohCoreTests/ChunkAssemblerTests.swift:

@Test("interval-set frontier: byte-0 interval end is the frontier")
func intervalSetFrontier() async throws {
    let url = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let data = Data((0..<300).map { UInt8($0 & 0xff) })
    let file = try DownloadFile(path: url.path, expectedSize: 300)
    // Single interval [0, 300).
    let assembler = ChunkAssembler(file: file, totalBytes: 300)
    async let result = assembler.hashToCompletion()

    try file.write(data, at: 0)
    assembler.complete(interval: ByteInterval(start: 0, length: 300))
    assembler.finish()

    #expect(await result != .failed(GohError(code: .cancelled, message: "")))
}

@Test("interval-set: out-of-order completion hashes in order")
func intervalSetOutOfOrder() async throws {
    let url = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let chunk = UInt64(100)
    let total = chunk * 3
    let whole = Data((0..<Int(total)).map { UInt8($0 & 0xff) })
    let file = try DownloadFile(path: url.path, expectedSize: total)
    let assembler = ChunkAssembler(file: file, totalBytes: total)
    async let result = assembler.hashToCompletion()

    // Write and complete in reverse order [2, 0, 1].
    for idx in [2, 0, 1] {
        let start = UInt64(idx) * chunk
        try file.write(Data(whole[Int(start)..<Int(start + chunk)]), at: start)
        assembler.complete(interval: ByteInterval(start: start, length: chunk))
    }
    assembler.finish()

    let expected = sha256Hex(whole)
    #expect(await result == .digest(expected))
}

@Test("interval-set: end condition is single coalesced [0, total)")
func intervalSetEndCondition() async throws {
    let url = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let total: UInt64 = 200
    let data = Data(repeating: 0x42, count: Int(total))
    let file = try DownloadFile(path: url.path, expectedSize: total)
    let assembler = ChunkAssembler(file: file, totalBytes: total)
    async let result = assembler.hashToCompletion()

    // Complete two non-adjacent intervals then bridge the gap.
    try file.write(data.prefix(50), at: 0)
    assembler.complete(interval: ByteInterval(start: 0, length: 50))
    try file.write(data[100...].prefix(100), at: 100)
    assembler.complete(interval: ByteInterval(start: 100, length: 100))
    // Gap [50, 100) still missing — isDone false.
    // Now fill the gap.
    try file.write(data[50...].prefix(50), at: 50)
    assembler.complete(interval: ByteInterval(start: 50, length: 50))
    assembler.finish()

    #expect(await result != .failed(GohError(code: .cancelled, message: "")))
}
```

- [ ] **Step 2: Run tests to verify they fail**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ChunkAssemblerTests"
  ```

  Expected: FAIL — `'ChunkAssembler' has no member 'complete'`, `no member 'totalBytes'` in init.

- [ ] **Step 3: Write minimal implementation**

Rewrite `Sources/GohCore/Engine/ChunkAssembler.swift`. `advance(range:writtenBytes:)` is deleted
entirely in this task — NOT preserved as a shim. Because the file will not compile until all three
legacy callers are migrated, Step 3b (below) MUST be applied as part of the same atomic commit:

```swift
// Sources/GohCore/Engine/ChunkAssembler.swift
// Full replacement — keep ByteRange.split and ByteRange struct in this file or move to own file.
// The interval-set assembler replaces the co-indexed approach.
// advance(range:writtenBytes:) is DELETED — not kept as a shim. Engine callers migrate in Step 3b.
// Having advance() coexist with complete() creates a dual-writer hazard (see BLOCK 3 note above).
// fixedLength(of:) is ALSO DELETED — it referenced [ByteRange] which no longer exists in this type.

import CryptoKit
import Foundation
import Synchronization

// ByteRange and ByteRange.split remain unchanged — other code depends on them.
public struct ByteRange: Sendable, Equatable {
    public var start: UInt64
    public var length: UInt64

    public init(start: UInt64, length: UInt64) {
        self.start = start
        self.length = length
    }

    public static func split(
        total: UInt64, requested: UInt8, minChunk: UInt64
    ) -> [ByteRange] {
        let maxByChunk = max(1, total / max(1, minChunk))
        let count = max(1, min(UInt64(requested), maxByChunk))
        let base = total / count
        var ranges: [ByteRange] = []
        var start: UInt64 = 0
        for index in 0..<count {
            let length = (index == count - 1) ? (total - start) : base
            ranges.append(ByteRange(start: start, length: length))
            start += length
        }
        return ranges
    }
}

public enum ChunkAssemblerResult: Sendable, Equatable {
    case digest(String)
    case failed(GohError)
}

/// Computes the SHA-256 of a download in order while bytes may arrive out of order.
///
/// The interval-set design (P2):
/// - Workers call `complete(interval:)` when a byte interval is written to disk.
/// - The assembler coalesces intervals (additive-merge only — never whole-set replace).
/// - The frontier is the end of the single coalesced interval that starts at byte 0 (or 0 if none).
/// - The hasher advances only when the byte-0 interval extends (in-order guarantee).
/// - End condition: coalesced set is exactly [0, totalBytes).
///
/// `advance(range:writtenBytes:)` is NOT kept as a compatibility shim — it is deleted
/// in Task 7. Engine callers must migrate to `complete(interval:)` in Task 8.
/// Keeping both methods was a dual-writer hazard (both did whole-set replace under the
/// same Mutex; concurrent callers could clobber each other's progress silently).
public final class ChunkAssembler: Sendable {
    private static let readChunk = 1 << 20

    private let file: DownloadFile
    private let totalBytes: UInt64?
    // Interval-set state — the only writer path is complete(interval:), additive-merge only.
    private let completedIntervals: Mutex<[ByteInterval]>
    private let failure = Mutex<GohError?>(nil)
    private let finished = Mutex<Bool>(false)
    private let ticks: AsyncStream<Void>
    private let tick: AsyncStream<Void>.Continuation

    /// Primary init: interval-set mode (P2+). `totalBytes` is the expected final file size
    /// and is used for the end-condition check.
    public init(file: DownloadFile, totalBytes: UInt64) {
        self.file = file
        self.totalBytes = totalBytes
        self.completedIntervals = Mutex([])
        (self.ticks, self.tick) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: — Interval-set API (P2)

    /// Report that `interval` is fully written to disk.
    ///
    /// ADDITIVE-MERGE ONLY — inserts `interval` into the existing completed set
    /// and coalesces. Never replaces the whole set. This prevents the dual-writer
    /// hazard where two concurrent callers clobber each other's progress.
    public func complete(interval: ByteInterval) {
        completedIntervals.withLock { existing in
            existing = Self.coalesce(existing + [interval])
        }
        tick.yield()
    }

    // NOTE: advance(range:writtenBytes:) is DELETED — it is NOT kept as a shim.
    // Any engine caller that previously called advance(...) must be migrated to
    // call complete(interval:) before any concurrent pool worker runs (Task 8).
    // Having both methods coexist creates a whole-set-replace dual-writer hazard.

    public func recordFailure(_ error: GohError) {
        failure.withLock { if $0 == nil { $0 = error } }
        tick.yield()
    }

    public func finish() {
        finished.withLock { $0 = true }
        tick.yield()
    }

    public func hashToCompletion() async -> ChunkAssemblerResult {
        var hasher = SHA256()
        var hashedUpTo: UInt64 = 0
        for await _ in ticks {
            if let error = failure.withLock({ $0 }) { return .failed(error) }
            let frontier = currentFrontier()
            while hashedUpTo < frontier {
                let count = Int(min(UInt64(Self.readChunk), frontier - hashedUpTo))
                let chunk: Data
                do {
                    chunk = try file.read(at: hashedUpTo, count: count)
                } catch {
                    return .failed(GohError(
                        code: .destinationUnwritable,
                        message: "reading back the download to hash it: \(error)"))
                }
                if chunk.isEmpty {
                    return .failed(GohError(
                        code: .connectionFailed,
                        message: "the download file ended before the reported frontier"))
                }
                hasher.update(data: chunk)
                hashedUpTo += UInt64(chunk.count)
            }
            let finishedNow = finished.withLock { $0 }
            let finalFrontier = currentFrontier()
            if finishedNow, let expectedTotal = totalBytes, finalFrontier < expectedTotal {
                return .failed(GohError(
                    code: .connectionFailed,
                    message: "download ended after \(finalFrontier) of \(expectedTotal) expected bytes"))
            }
            if finishedNow && hashedUpTo == finalFrontier {
                // In interval-set mode: verify end condition.
                if let total = totalBytes {
                    let coalesced = completedIntervals.withLock { $0 }
                    let isComplete = coalesced.count == 1
                        && coalesced[0].start == 0
                        && coalesced[0].length == total
                    if !isComplete {
                        return .failed(GohError(
                            code: .connectionFailed,
                            message: "download ended with gaps in the completed interval set"))
                    }
                }
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                return .digest(digest)
            }
        }
        return .failed(GohError(code: .cancelled, message: "the assembler ended early"))
    }

    // MARK: — Private

    /// Interval-set frontier: end of the single coalesced interval that starts at byte 0.
    private func currentFrontier() -> UInt64 {
        let intervals = completedIntervals.withLock { $0 }
        guard let first = intervals.first, first.start == 0 else { return 0 }
        return first.length
    }

    /// Merges overlapping/adjacent intervals, sorted by start offset.
    static func coalesce(_ intervals: [ByteInterval]) -> [ByteInterval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var merged: [ByteInterval] = []
        for iv in sorted {
            guard var last = merged.popLast() else { merged.append(iv); continue }
            if iv.start <= last.end {
                let newEnd = max(last.end, iv.end)
                last.length = newEnd - last.start
                merged.append(last)
            } else {
                merged.append(last)
                merged.append(iv)
            }
        }
        return merged
    }

    // NOTE: fixedLength(of:) is intentionally ABSENT. It operated on [ByteRange] and
    // is not needed in the interval-set design. Including it would be a private-unused
    // symbol and trigger a build failure under -warnings-as-errors.
}
```

- [ ] **Step 3b: Migrate all three legacy `advance(range:writtenBytes:)` / `init(file:ranges:)` callers in `DownloadEngine.swift`**

Task 7 deletes both `init(file:ranges:)` and `advance(range:writtenBytes:)`. The file will not
compile until all three production call sites in `DownloadEngine.swift` are migrated to the new
API. These migrations must be in the SAME commit as the ChunkAssembler rewrite. Apply each
before/after transformation exactly:

**Site 1 — `verifyHash` (~line 412–416):**

```swift
// BEFORE (deleted API):
private func verifyHash(file: DownloadFile, total: UInt64) async throws {
    let assembler = ChunkAssembler(file: file, ranges: [ByteRange(start: 0, length: total)])
    async let assembled = assembler.hashToCompletion()
    assembler.advance(range: 0, writtenBytes: total)
    assembler.finish()
    if case .failed(let error) = await assembled {
        throw error
    }
}

// AFTER (new interval-set API):
private func verifyHash(file: DownloadFile, total: UInt64) async throws {
    let assembler = ChunkAssembler(file: file, totalBytes: total)
    async let assembled = assembler.hashToCompletion()
    assembler.complete(interval: ByteInterval(start: 0, length: total))
    assembler.finish()
    if case .failed(let error) = await assembled {
        throw error
    }
}
```

**Site 2 — `fetchSingle` (~line 441–442 and 456):**

```swift
// BEFORE (deleted API — two calls):
let assembler = ChunkAssembler(
    file: file, ranges: [ByteRange(start: 0, length: total ?? UInt64.max)])
// ... (later, inside flush()):
assembler.advance(range: 0, writtenBytes: completed)

// AFTER (new interval-set API):
// Use UInt64.max as a sentinel for "unknown total" — if total is nil we cannot
// pre-declare the interval; we emit a synthetic single-interval covering [0, completed)
// at finish() time instead of advancing incrementally.
// Correct migration for fetchSingle (streaming, unknown total case):
//   - init with totalBytes = total ?? UInt64.max (preserves the existing unknown-length behaviour;
//     the hashToCompletion end-condition check treats UInt64.max as "unknown" via the
//     `if let total = totalBytes` guard, which will be nil in the interval-set init when
//     the totalBytes sentinel is max).
// Simplest correct migration that preserves fetchSingle's streaming behaviour:
// Replace the ChunkAssembler init + advance calls as follows:

// Init (remove the ranges: init entirely; use totalBytes:):
// When total is known:
let assembler = ChunkAssembler(file: file, totalBytes: total ?? UInt64.max)
//
// In flush() — replace:
//   assembler.advance(range: 0, writtenBytes: completed)
// With (emits a growing interval that the assembler coalesces; safe because fetchSingle
// is single-writer — no concurrent complete() calls):
assembler.complete(interval: ByteInterval(start: 0, length: completed))
```

The exact Swift diff for the two lines inside `fetchSingle`:

```swift
// BEFORE:
let assembler = ChunkAssembler(
    file: file, ranges: [ByteRange(start: 0, length: total ?? UInt64.max)])
// ... inside flush():
assembler.advance(range: 0, writtenBytes: completed)

// AFTER:
let assembler = ChunkAssembler(file: file, totalBytes: total ?? UInt64.max)
// ... inside flush():
assembler.complete(interval: ByteInterval(start: 0, length: completed))
```

**Site 3 — `fetchRanged` (~line 507):**

```swift
// BEFORE (deleted API):
let assembler = ChunkAssembler(file: file, ranges: ranges)

// AFTER (new interval-set API — Task 8 will restructure consumeRange, but this
// single-line migration is required now so the file compiles after Task 7):
let assembler = ChunkAssembler(file: file, totalBytes: total)
```

Note: `consumeRange` still calls `assembler.advance(range:writtenBytes:)` inside `flush()`, which
is now deleted. In Task 8 the entire `fetchRanged` + `consumeRange` are replaced by the
control-loop pool and `assembler.complete(interval:)`. To keep the file compiling between Task 7
and Task 8, also migrate the `assembler.advance(range: index, writtenBytes: written)` line inside
`consumeRange`'s `flush()` to `assembler.complete(interval: ByteInterval(start: range.start, length: written))`.
This migration is TEMPORARY — Task 8 removes `consumeRange` entirely and replaces it with the
control-loop pool.

**Summary of Step 3b changes (all in `DownloadEngine.swift`):**

| Site | Old call | New call |
|------|----------|----------|
| `verifyHash` init | `ChunkAssembler(file:ranges:[ByteRange(start:0,length:total)])` | `ChunkAssembler(file:totalBytes:total)` |
| `verifyHash` advance | `assembler.advance(range:0,writtenBytes:total)` | `assembler.complete(interval:ByteInterval(start:0,length:total))` |
| `fetchSingle` init | `ChunkAssembler(file:ranges:[ByteRange(start:0,length:total??UInt64.max)])` | `ChunkAssembler(file:totalBytes:total??UInt64.max)` |
| `fetchSingle` advance (in flush) | `assembler.advance(range:0,writtenBytes:completed)` | `assembler.complete(interval:ByteInterval(start:0,length:completed))` |
| `fetchRanged` init | `ChunkAssembler(file:ranges:ranges)` | `ChunkAssembler(file:totalBytes:total)` |
| `consumeRange` advance (in flush) | `assembler.advance(range:index,writtenBytes:written)` | `assembler.complete(interval:ByteInterval(start:range.start,length:written))` |

- [ ] **Step 4: Run tests to verify they pass**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ChunkAssemblerTests"
  ```

  Expected: PASS — all existing + new tests pass.

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Engine/ChunkAssembler.swift Tests/GohCoreTests/ChunkAssemblerTests.swift \
          Sources/GohCore/Engine/DownloadEngine.swift
  git commit -m "feat(engine): interval-set ChunkAssembler + migrate all advance() callers (P2)"
  ```

  This commit includes ChunkAssembler.swift (rewrite), DownloadEngine.swift (three call sites
  migrated per Step 3b), and ChunkAssemblerTests.swift (new interval-set tests). The file must
  compile cleanly with no warnings before this commit is made.

---

### Task 8: Live Worker-Pool Control Loop in `fetchRanged`

**Files:** Modify `Sources/GohCore/Engine/DownloadEngine.swift` · Modify `Tests/GohCoreTests/DownloadEngineTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Engine/DownloadEngine.swift` — `fetchRanged` (lines 495–570). Current structure: `ByteRange.split` once, `setActualConnectionCount`, static `TaskGroup` with one task per range.
- [ ] `Sources/GohCore/Engine/ChunkQueue.swift` — `ChunkQueue` API.
- [ ] `Sources/GohCore/Engine/ChunkAssembler.swift` — new `complete(interval:)` API.

**What changes:** `fetchRanged` is restructured. The static range split is replaced by a `ChunkQueue`
seeded from `ByteRange.split`. A single-adder control loop runs inside the `TaskGroup` — it spawns
workers via `group.addTask`, reaps them via `group.next()`, and decides whether to re-add or hold.
At fixed `requestedConnectionCount` this is behaviour-equivalent to today.

**Invariant check:** `protocolVersion` stays 3. `actualConnectionCount` is still set (now to peak
concurrent workers over the transfer). `ByteRange.split` is still used to seed the queue. Checkpoint
format unchanged — `DownloadCheckpointRecorder.recordCompletedPiece` is called identically.

**Dual-writer ordering (BLOCK 3):** Because `advance(range:writtenBytes:)` is deleted in Task 7,
Task 8's control-loop pool must use `assembler.complete(interval:)` exclusively. No code path may
call a whole-set-replace write to `completedIntervals` once any concurrent worker is live.
Specifically: range 0's speculative stream (reusing `firstRangeStream`) must also be migrated to
call `assembler.complete(interval:)` — not the deleted `advance`. This migration happens in Task 8
as part of replacing `consumeRange` with the control-loop pattern.

**TaskGroup ownership model (BLOCK 4):** The control loop is the SOLE caller of `group.addTask`.
A worker task:
1. Receives one `ByteInterval` when spawned (passed as a captured value, not pulled from the queue inside the task).
2. Downloads the interval.
3. Calls `assembler.complete(interval:)`.
4. Returns.

The control loop then calls `group.next()` to reap, inspects `targetN` vs `liveWorkers`, and
decides whether to pull the next chunk from the queue and call `group.addTask` again (add) or hold
(deny). No worker calls `group.addTask`. This is the only model compatible with Swift 6 strict
concurrency, where `group.addTask` is actor-isolated to the closure's context and cannot be called
from a child task.

**Budget gate on addTask path (BLOCK 4):** Before each `group.addTask`, the control loop calls
`connectionBudget.request(slots: 1, hostKey:)`. If the result is `false`, the control loop does
NOT add a task; it calls `group.next()` again (awaiting the next reap) and retries. This cannot
livelock because:
- If `liveWorkers == 0` and budget is denied, the budget is held by a concurrent download for the
  same host — the control loop awaits `group.next()` which will yield when the OTHER download's
  workers release slots (budget is Mutex-shared). In the degenerate case where this download has
  no live workers and budget is perpetually denied, the control loop should log a warning and
  commit to `targetN = max(targetN, 1)` to guarantee at least one worker can always proceed (the
  budget gate is advisory, not a hard stop that can zero out a download).
- If `liveWorkers > 0`, at least one worker will complete and `group.next()` will return, giving
  the control loop another chance to check the budget.

- [ ] **Step 1: Write the failing tests**

```swift
// Add to Tests/GohCoreTests/DownloadEngineTests.swift:

@Test("P2: control-loop pool downloads correctly at fixed N=4")
func controlLoopPoolDownload() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let total: UInt64 = 8 * 1024 * 1024   // 8 MiB
    let url = "https://test.local/\(UUID().uuidString).bin"
    let payload = Data(repeating: 0xAB, count: Int(total))
    MockURLProtocol.stub(url, body: payload, statusCode: 206,
        headers: ["Content-Range": "bytes 0-\(total - 1)/\(total)"])

    let store = JobStore()
    let destination = directory.appending(path: "out.bin").path
    let job = store.create(url: url, destination: destination, requestedConnectionCount: 4)
    let handlerCalled = Mutex(false)

    await DownloadEngine(
        session: mockSession(),
        completedDownloadHandler: { _, _, _ in handlerCalled.withLock { $0 = true } }
    ).run(jobID: job.id, in: store)

    #expect(store.job(id: job.id)?.state == .completed)
    #expect(handlerCalled.withLock { $0 })
    let data = try Data(contentsOf: URL(fileURLWithPath: destination))
    #expect(data == payload)
}
```

- [ ] **Step 2: Regression guard — expected to compile-and-pass before the refactor** (not a red test; the compile-break gate is the new `ChunkQueue` usage inside `fetchRanged` — if the engine no longer compiles after the refactor, this test fails to build)

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "controlLoopPoolDownload"
  ```

  Expected: PASS before the refactor (existing code works); this is a regression guard, not a red-green test.

- [ ] **Step 3: Write minimal implementation**

Replace `fetchRanged` in `DownloadEngine.swift`. Key design:
- `ChunkQueue` is seeded with the ranges from `ByteRange.split`.
- A `Mutex<Int>`-guarded `targetN` is set to `requestedConnectionCount` (static in P2, governor-driven in P3).
- The `TaskGroup` closure is the SOLE caller of `group.addTask`. The control loop runs directly inside it (NOT as a child task). Workers do not call `group.addTask` — they download one interval and return.
- `setActualConnectionCount` is updated to track peakWorkers (the running maximum of liveWorkers). The old cap at `requestedConnectionCount` is removed here (governor may push N higher in P3).

This is a large but mechanical restructuring. The complete new `fetchRanged` (abbreviated for the plan — the worker must write the full code):

```swift
// Sources/GohCore/Engine/DownloadEngine.swift — fetchRanged replacement (P2)
// The full implementation must:
// 1. Create ChunkQueue from ByteRange.split(total:requested:minChunk:).
// 2. Create ChunkAssembler(file:totalBytes:) (new interval-set init).
// 3. Set targetN = requestedConnectionCount under a Mutex<Int>.
// 4. Run withThrowingTaskGroup:
//
//    SLOT-RELEASE MODEL (leak-proof on throw/cancel, no double-release):
//    - The control loop calls connectionBudget.request(slots:1,hostKey:) as the
//      ADMISSION GATE before each addTask. If denied, the interval is returned to
//      the queue and the control loop waits for the next reap before retrying.
//    - Each WORKER TASK releases its own slot via `defer` at the very top of its
//      task body. Release fires on normal completion, throw, AND cancellation.
//    - The REAP LOOP decrements liveWorkers ONLY — it does NOT release the slot
//      (the worker already did). This prevents double-release.
//
//    FILL HELPER (avoids duplicated budget/queue logic):
//    A local `fillToTarget(_ targetN: Int)` closure encapsulates the "admit workers
//    up to targetN subject to budget" logic used by both the seed phase and the
//    post-reap phase. Both phases call the same function — this eliminates the
//    asymmetry that made it easy to omit the release in one copy.
//
//    Pseudocode:
//
//      var liveWorkers = 0
//      var peakWorkers = 0
//
//      // fillToTarget: admit workers until liveWorkers == target or queue empty or budget denied.
//      // Called from the seed phase AND from inside the reap loop.
//      func fillToTarget(_ currentTarget: Int) {
//          while liveWorkers < currentTarget, let interval = queue.pull() {
//              guard connectionBudget.request(slots: 1, hostKey: hostKey) else {
//                  queue.returnToFront(interval)
//                  break  // budget exhausted; retry after next reap
//              }
//              // Capture interval and hostKey by value. The worker owns its slot.
//              let capturedInterval = interval
//              let capturedHostKey = hostKey
//              group.addTask {
//                  // WORKER-OWNED SLOT RELEASE — fires on normal return, throw, AND cancel.
//                  defer { connectionBudget.release(slots: 1, hostKey: capturedHostKey) }
//                  try await downloadChunk(capturedInterval, ...)
//              }
//              liveWorkers += 1
//              peakWorkers = max(peakWorkers, liveWorkers)
//          }
//      }
//
//      // Seed phase: fill up to initial targetN.
//      fillToTarget(targetN.withLock { $0 })
//
//      // Reap loop.
//      while liveWorkers > 0 {
//          _ = try await group.next()   // reap one worker (worker's defer released its slot)
//          liveWorkers -= 1
//          // NOTE: do NOT call connectionBudget.release here — the worker did it in defer.
//          // Post-reap: fill to current target (governor may have changed targetN).
//          fillToTarget(targetN.withLock { $0 })
//          // Drop excess workers cooperatively: when targetN decreased, do not
//          // add new tasks; running workers finish their current interval and are
//          // not re-added. No explicit cancellation needed.
//      }
//
//    Leak-proof guarantee:
//    - Normal completion: worker defer fires → slot released, liveWorkers -= 1.
//    - Worker throw: TaskGroup propagates throw; defer fires before throw crosses the
//      task boundary → slot released. All remaining workers are cancelled (their defers
//      also fire). No slot leak.
//    - Cancellation: same as throw; defer fires before task body exits.
//    - Cannot double-release: reap loop does NOT release; only the worker's defer does.
//    - Budget request denied before addTask: the worker is never spawned so no defer runs;
//      the slot was never granted, so there is nothing to release.
//
//    Strict concurrency: connectionBudget is a Mutex op on a Sendable type; hostKey is
//    captured by value (String is Sendable). This is safe under Swift 6.
//
//    Each WORKER TASK receives its ByteInterval as a captured value (not pulled
//    inside the task). It downloads the interval and calls assembler.complete(interval:).
//    Workers do NOT call group.addTask. Workers do NOT call queue.pull() again.
//
// 5. Range 0 reuses the firstRangeStream (the speculative open-ended GET).
//    Its interval is ByteInterval(start: ranges[0].start, length: ranges[0].length).
//    It calls assembler.complete(interval:) on success — never advance(...).
//    The range-0 worker ALSO follows the worker-owned-release model (defer at top).
// 6. setActualConnectionCount is called with peakWorkers (the running peak).
//
// Swift 6 concurrency note: group.addTask is isolated to the TaskGroup closure's
// context. Only the code running directly in that closure may call addTask. Child
// tasks (workers) cannot. The fillToTarget closure captures group by reference from
// the enclosing withThrowingTaskGroup closure — this is correct because fillToTarget
// is only ever called from the control loop, not from child tasks.
```

**Implementation note for the agentic worker:** Because the full implementation of the control-loop
pool is 150+ lines of new Swift code, the worker MUST read the existing `fetchRanged` body in full
before writing the replacement. The key invariants to preserve:
- The control loop runs directly in the `withThrowingTaskGroup` closure (NOT as an `addTask` child). Only the control loop calls `group.addTask`. Workers do not call `group.addTask` — they download one interval and return.
- Range 0 reuses `firstRangeStream`/`cancelFirstRangeStream` (speculative stream reuse). Its interval calls `assembler.complete(interval:)` — NOT the deleted `advance(...)` shim. Range 0 also follows the worker-owned-release model (defer at the top of its task body releases its ConnectionBudget slot).
- `downloadChunk` calls `assembler.complete(interval:)` (additive-merge, not whole-set replace) after writing all bytes for the interval.
- `DownloadCheckpointRecorder.recordCompletedPiece` is called with the same start/length at each flush boundary.
- **Slot release is worker-owned.** Every worker body starts with `defer { connectionBudget.release(slots: 1, hostKey: capturedHostKey) }`. The reap loop (`group.next()`) does NOT call release — the worker's defer has already run before `group.next()` returns. This is the only correct model: it is leak-proof on throw and cancel, and cannot double-release.
- **`fillToTarget` is the single admission site.** Both the seed phase and the post-reap phase call the same `fillToTarget` closure (see pseudocode above). Do not duplicate the budget-gate/queue-pull logic.
- If any worker throws, all workers are cancelled (their defers fire, releasing their slots) and the error propagates.
- `assembler.finish()` is called after the control loop exits cleanly (liveWorkers == 0 and queue.isDone).
- `try complete(jobID:in:transferDuration:isResume:)` is called at the end.

- [ ] **Step 4: Run tests to verify all engine tests pass**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "DownloadEngineTests"
  ```

  Expected: PASS — all existing engine tests pass.

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Engine/DownloadEngine.swift Tests/GohCoreTests/DownloadEngineTests.swift Sources/GohCore/Engine/ChunkQueue.swift
  git commit -m "feat(engine): control-loop worker pool + ChunkQueue (P2, behaviour-equivalent at fixed N)"
  ```

---

### Task 9: Full Test Suite Run + P2 Artifact

- [ ] **Step 1: Run full suite**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  ```

  Expected: all tests pass, zero warnings.

- [ ] **Step 2: Write P2 artifact**

  Write `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase2.md`.

- [ ] **Step 3: Commit**

  ```
  git add docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase2.md
  git commit -m "docs(progress): P2 artifact — dynamic chunk pool + interval-frontier assembler"
  ```

---

## Phase 3: Governor Wiring + Observation Gate Redesign + Warm-Start

**What P3 builds:** The governor is wired to the control loop; `GovernorOutcome` flows to the
completion handler; `shouldRecordObservation` is migrated to an `ObservationRequest` struct;
`SelectionReason.warmStart` is added; governor trace lines (`GOH_ENGINE_TRACE`).

**SM4 AC:** "A governor-converged N (candidate-aligned) is recorded through `HostProfileStore`;
a later cold download warm-starts N₀ from it (scheduling trace `reason=warmStart`)."

---

### Task 10: `SelectionReason.warmStart` + `ObservationRequest` Struct

**Files:** Modify `Sources/GohCore/Scheduling/BanditSelector.swift` · Modify `Sources/GohCore/Scheduling/HostProfileStore.swift` · Modify `Tests/GohCoreTests/HostProfileStoreTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Scheduling/BanditSelector.swift` — `SelectionReason` enum (lines 4–13).
- [ ] `Sources/GohCore/Scheduling/HostProfileStore.swift` — `shouldRecordObservation` signature (lines 220–232). Seven test call sites + 1 daemon call site.
- [ ] `Sources/gohd/main.swift` — `shouldRecordObservation` call (lines 136–143).

**Format invariant:** `host-scheduling.plist` stays v1. `SelectionReason` is NOT on the wire.

- [ ] **Step 1: Write the failing tests**

```swift
// Add to Tests/GohCoreTests/HostProfileStoreTests.swift:

@Test("ObservationRequest: effectiveN nil → gate rejects")
func observationGateRejectsNilEffectiveN() {
    let req = ObservationRequest(
        isResume: false, transferDuration: .seconds(30),
        bytesCompleted: 16 * 1024 * 1024, wasSolo: true,
        governorOutcome: GovernorOutcome(effectiveN: nil, stabilized: true))
    #expect(!HostProfileStore.shouldRecordObservation(req))
}

@Test("ObservationRequest: stabilized=false → gate rejects")
func observationGateRejectsUnstabilized() {
    let req = ObservationRequest(
        isResume: false, transferDuration: .seconds(30),
        bytesCompleted: 16 * 1024 * 1024, wasSolo: true,
        governorOutcome: GovernorOutcome(effectiveN: 8, stabilized: false))
    #expect(!HostProfileStore.shouldRecordObservation(req))
}

@Test("ObservationRequest: candidate-aligned stable → gate passes")
func observationGatePassesCandidateAligned() {
    let req = ObservationRequest(
        isResume: false, transferDuration: .seconds(30),
        bytesCompleted: 16 * 1024 * 1024, wasSolo: true,
        governorOutcome: GovernorOutcome(effectiveN: 8, stabilized: true))
    #expect(HostProfileStore.shouldRecordObservation(req))
}

@Test("SM4: selectN returns .explore when only one governor-recorded arm exists")
func warmStartSelectionReasonExplore() throws {
    // With only one arm seeded (N=8), the bandit is in explore mode (not enough
    // arms to exploit). This confirms the API compiles and the arm is stored.
    // The full SM4 warm-start assertion (exploit picks N=8 after all 4 arms seeded)
    // is in Task 13 sm4WarmStartFromGovernorArm.
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = HostProfileStore(
        fileURL: directory.appending(path: "host-scheduling.plist"))
    _ = store.load()

    let key = "https://example.com:443"
    // Seed one governor-recorded arm at N=8 with ≥ minSamples observations.
    for _ in 0..<3 {
        store.recordObservation(
            hostKey: key, connectionCount: 8,
            totalBytes: 16 * 1024 * 1024, transferDuration: .seconds(30))
    }

    let (n, reason) = store.selectN(hostKey: key)
    // Only one arm exists → explore or exploit depending on bandit implementation.
    // Assert the arm was stored (n is the candidate we seeded, or the bandit default).
    #expect(n == 8 || reason == .explore || reason == .exploit,
            "expected stored arm N=8 to be reachable; got n=\(n) reason=\(reason)")
    // The test must NOT assert reason == .warmStart here — warmStart is a trace
    // annotation emitted in CommandDispatcher, not a value returned by selectN.
}
```

- [ ] **Step 2: Run tests to verify they fail**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "observationGate\|warmStart"
  ```

  Expected: FAIL — `cannot find type 'ObservationRequest'`.

- [ ] **Step 3: Write minimal implementation**

**Add `SelectionReason.warmStart`** to `BanditSelector.swift`:
```swift
public enum SelectionReason: Sendable, Equatable {
    case cold
    case exploit
    case explore
    case explicit
    case warmStart   // <-- new: governor-converged N seeded this run's N₀
}
```

**Add `ObservationRequest`** to `HostProfileStore.swift` (top of file, before the class):
```swift
/// Parameter struct for the observation gate. Replaces the 6-parameter call sites
/// so adding GovernorOutcome is a mechanical callsite migration (struct init), not
/// a breaking signature change.
public struct ObservationRequest: Sendable {
    public var isResume: Bool
    public var transferDuration: Duration
    public var bytesCompleted: UInt64
    public var wasSolo: Bool
    public var governorOutcome: GovernorOutcome
    public var minTransferDuration: Duration
    public var minBytes: UInt64

    public init(
        isResume: Bool,
        transferDuration: Duration,
        bytesCompleted: UInt64,
        wasSolo: Bool,
        governorOutcome: GovernorOutcome,
        minTransferDuration: Duration = .seconds(10),
        minBytes: UInt64 = 8 * 1024 * 1024
    ) {
        self.isResume = isResume
        self.transferDuration = transferDuration
        self.bytesCompleted = bytesCompleted
        self.wasSolo = wasSolo
        self.governorOutcome = governorOutcome
        self.minTransferDuration = minTransferDuration
        self.minBytes = minBytes
    }
}
```

**Replace `shouldRecordObservation` static method** with one that takes `ObservationRequest`:
```swift
public static func shouldRecordObservation(_ request: ObservationRequest) -> Bool {
    guard !request.isResume else { return false }
    guard request.transferDuration >= request.minTransferDuration else { return false }
    guard request.bytesCompleted >= request.minBytes else { return false }
    guard request.wasSolo else { return false }
    guard request.governorOutcome.effectiveN != nil else { return false }
    guard request.governorOutcome.stabilized else { return false }
    return true
}
```

**Add `recordObservationIfEligible`** convenience on `HostProfileStore`:
```swift
public func recordObservationIfEligible(
    _ request: ObservationRequest,
    hostKey: String,
    totalBytes: UInt64,
    transferDuration: Duration
) {
    guard Self.shouldRecordObservation(request),
          let effectiveN = request.governorOutcome.effectiveN
    else { return }
    recordObservation(
        hostKey: hostKey,
        connectionCount: effectiveN,
        totalBytes: totalBytes,
        transferDuration: transferDuration)
}
```

**Migrate old `shouldRecordObservation` call sites** in existing tests and `gohd/main.swift` to the new struct form. The old static method with explicit parameters is removed; all 7 test sites + 1 daemon site migrate to `ObservationRequest(...)`.

- [ ] **Step 4: Run tests to verify they pass**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "HostProfileStore\|observationGate\|warmStart"
  ```

  Expected: PASS — all tests pass.

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Scheduling/BanditSelector.swift \
          Sources/GohCore/Scheduling/HostProfileStore.swift \
          Tests/GohCoreTests/HostProfileStoreTests.swift \
          Sources/gohd/main.swift
  git commit -m "feat(scheduling): ObservationRequest struct + warmStart reason + governor-gate migration"
  ```

---

### Task 11: `setActualConnectionCount` Peak-Max Semantics

**Files:** Modify `Sources/GohCore/Model/JobStore.swift` · Modify `Sources/GohCore/Engine/DownloadEngine.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Model/JobStore.swift` — `setActualConnectionCount` method. Currently caps at `requestedConnectionCount`.
- [ ] `Sources/GohCore/Model/JobSummary.swift` — `actualConnectionCount: UInt8` field. Wire-stable; documented meaning changes to "peak concurrent connections used."

**Invariant check:** `actualConnectionCount` is a non-optional `UInt8` on the wire — field stays, type stays, meaning shifts to "peak concurrent used." No `protocolVersion` bump.

- [ ] **Step 1: Write the failing test** (regression guard — this test compiles and PASSES before the change; label it accordingly)

```swift
// Add to Tests/GohCoreTests/DownloadEngineTests.swift:

// Regression guard — expected to compile-and-pass before and after the change.
// It proves setActualConnectionCount tracks a peak: call it with 4, then 8, then 4;
// the stored value must be 8 (the peak), not 4 (the last call).
@Test("P3: setActualConnectionCount stores peak, not last value")
func actualConnectionCountStorespeak() throws {
    let store = JobStore()
    let job = store.create(
        url: "https://example.com/file.bin",
        destination: "/tmp/file.bin",
        requestedConnectionCount: 16)
    _ = try store.activate(id: job.id)

    // Drive the count up then back down.
    _ = try store.setActualConnectionCount(id: job.id, 4)
    _ = try store.setActualConnectionCount(id: job.id, 8)
    _ = try store.setActualConnectionCount(id: job.id, 4)   // back down — must NOT update

    let summary = store.job(id: job.id)!
    // Peak semantics: stored value must be 8, not 4 (the last call).
    #expect(summary.actualConnectionCount == 8)
}
```

- [ ] **Step 2: Run test to verify it FAILS before the implementation change** (it fails because the current code is a plain assign, last-call-wins)

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "actualConnectionCountStorespeak"
  ```

  Expected: FAIL — `summary.actualConnectionCount` is 4 (last call wins), not 8.

- [ ] **Step 3: Write implementation**

Read `Sources/GohCore/Model/JobStore.swift` first (specifically `setActualConnectionCount`, currently at lines 176–182). The current code:

```swift
// CURRENT (wrong — last-call-wins plain assign):
public func setActualConnectionCount(id: UInt64, _ count: UInt8) throws -> JobSummary {
    try mutateJob(id: id) { job in
        guard job.state == .active else { return }
        guard count > 0, count <= job.requestedConnectionCount else { return }
        job.actualConnectionCount = count
    }
}
```

Replace with peak-max semantics. Drop the `<= requestedConnectionCount` guard (the governor
may push N above `requestedConnectionCount`; the hard ceiling is 16, not the requested count).
Keep `count > 0`. Store the running maximum:

```swift
// REPLACEMENT (peak-max semantics):
public func setActualConnectionCount(id: UInt64, _ count: UInt8) throws -> JobSummary {
    try mutateJob(id: id) { job in
        guard job.state == .active else { return }
        guard count > 0 else { return }
        // Peak-max: store the highest N seen over the transfer lifetime.
        // Hard ceiling is 16 (the governor cap), NOT requestedConnectionCount.
        job.actualConnectionCount = max(job.actualConnectionCount, min(count, 16))
    }
}
```

Update DESIGN.md §Adaptive host scheduling: add a sentence: "`actualConnectionCount` is now
documented as the peak concurrent connections used during the transfer. The cap is the hard
ceiling (16), not the admission-time `requestedConnectionCount`, which the governor may exceed."

- [ ] **Step 4: Run all tests**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  ```

  Expected: PASS — `actualConnectionCountStorespeak` now passes (stored value is 8, the peak).

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Model/JobStore.swift Sources/GohCore/Engine/DownloadEngine.swift DESIGN.md
  git commit -m "feat(engine): actualConnectionCount = peak concurrent workers (cap=16, not requestedN)"
  ```

---

### Task 11A: Fixed-Size Chunk Pool + Byte-Based Progress + Connection Slots (PREREQUISITE — added during P3 execution)

**Why this was added (decision record):** The original plan's P3 wired the governor onto P2's
"N big pieces" queue (`ByteRange.split` → N range-sized chunks). But the governor can only *add* a
worker if there is **spare unclaimed work** to hand it — and with N pieces all claimed up front, an
`addWorkers` decision has nothing to act on, making the governor functionally inert (it could observe
but never change N). The spec §6.1 mandates **fixed-size byte-interval chunks (chunk size a daemon
constant, independent of N)** that workers pull one at a time — that is what makes live add/drop
possible. P2 used the N-piece model deliberately for behaviour-equivalence; P3 must switch to the
fixed-size-chunk model for the governor to function. The user chose **"build it right"** at the P3
gate (2026-05-31). This task is the prerequisite; it is behaviour-equivalent at fixed N (identical
output bytes / SHA-256) and unblocks the real Task 12 governor wiring.

**Files:** Modify `Sources/GohCore/Engine/DownloadEngine.swift` · Modify `Tests/GohCoreTests/DownloadEngineTests.swift`

**Design:**
- **`static let chunkSize: UInt64`** daemon constant (e.g. `8 << 20`, ≥ `bufferSize`, independent of N).
  Seed the `ChunkQueue` with `[0,total)` cut into `ceil(total/chunkSize)` fixed-size intervals (last
  takes the remainder) — many more than N, so the queue always has spare work for an added worker.
- **Connection-slot indexing.** The control loop assigns each spawned worker a slot id in `0..<currentN`
  (lowest free slot; freed on reap). The worker carries its slot id (for trace + the governor's
  `WorkerRateSample.workerIndex`, which must be a stable connection slot in `0..<liveWorkers`, NOT the
  unbounded chunk index — otherwise the governor's `allWorkersInSteadyState(liveWorkers:)` reads stale
  histories). Slots are reused as workers reap and respawn.
- **Byte-based progress.** Replace `RangeProgress(rangeCount:)`/`report(index:)` (per-piece-index, breaks
  with many chunks) with a `Mutex<UInt64>` bytes-written counter incremented by `pieceLength` at each
  flush; progress % = counter/total. Monotonic, N-agnostic.
- **Worker model (unchanged control-loop shape from Task 8).** The control loop's `fillToTarget(targetN)`
  pulls a chunk, assigns a slot, spawns a worker for that one chunk; the worker downloads it (the FIRST
  chunk `[0, chunkSize)` reuses the speculative `firstRangeStream`, truncated at chunkSize; all other
  chunks open a fresh ranged GET via `downloadRange`), writes, `assembler.complete(interval:)`, records
  the checkpoint piece, bumps the byte counter, (P3-Task-12) pushes a rate sample, frees its slot,
  returns. The control loop reaps and re-fills, keeping `targetN` workers cycling through chunks. At
  fixed `targetN` this is behaviour-equivalent to today (same file, same hash) — just many small chunks.
- **Invariants:** `assembler.complete(interval:)` (additive-merge) and `DownloadCheckpointRecorder.
  recordCompletedPiece` are called identically per flush; checkpoint/resume format unchanged;
  `setActualConnectionCount(peakWorkers)` unchanged (== targetN at fixed N); no wire/format change.
- **Tests:** the full engine suite (ranged/resume/single-conn/rm-during/sibling-cancel) must stay green
  with the new chunking; add a test that a multi-chunk download (e.g. total > chunkSize with N=4)
  produces byte-identical output and completes. Fix any test that asserted a specific *piece count* (the
  count changes; file correctness does not).

This task carries an Opus concurrency + data-integrity review before Task 12 (it touches the data path,
progress, and slot concurrency).

---

### Task 12: Wire Governor to Control Loop + Explicit-N Governor-Off Channel (BLOCK 1)

**Files:** Modify `Sources/GohCore/Engine/DownloadEngine.swift` · Modify `Sources/GohCore/Model/JobStore.swift` · Modify `Tests/GohCoreTests/DownloadEngineTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Engine/DownloadEngine.swift` — P2 `fetchRanged` control loop (Task 8 result). `completedDownloadHandler` type, `fetchRanged` signature, `download()` call sites.
- [ ] `Sources/GohCore/Model/CommandDispatcher.swift` — `reply(to:)`, specifically lines 59–66 where `selectionReason = .explicit` is set when `request.connectionCount` is non-nil.
- [ ] `Sources/GohCore/Governor/ParallelismGovernor.swift` — `ParallelismGovernor.decide()` signature.

**Bet check (Task 12 — most load-bearing):** The governor's in-flight adaptation rests on the bet
that `decide()` called at each worker reap returns sensible decisions. Calling `decide()` too
frequently (on every sample) or too infrequently (only on worker completion) affects responsiveness.
The correct cadence is: call `decide()` after each worker reap AND after each `record(sample:)` call
from a flush — the governor's internal steady-state window rate-limits its own action.

**Governor-off channel for explicit `--connections N` (resolves open spot #3, BLOCK 1):**

When the user runs `goh add --connections 8`, `CommandDispatcher` sets `selectionReason = .explicit`.
The engine must honour this as "governor OFF, run at exactly N=8." The governor must never
probe/drop from an explicit N, and `GovernorOutcome.governorOff` must be returned (so no bandit
observation is recorded from a user-pinned run).

This cannot be a `JobSummary` wire field (that would break the wire format invariant). The correct
channel is a daemon-internal parameter threaded from `CommandDispatcher` → `JobStore.create` →
`JobSummary` internal storage is NOT used. Instead, use the existing `JobSummary.requestedConnectionCount`
combined with a separate daemon-internal flag.

**Concrete implementation:** Add `explicitConnectionCount: UInt8?` as an `init` parameter to
`DownloadEngine.run(jobID:in:)`. Because `DownloadEngine` is created once per download in `gohd`
via the `onJobQueued`/`scheduleJob` path, the explicit flag is passed from `CommandDispatcher`
through the job-scheduling closure.

The cleanest wire-safe approach: `CommandDispatcher` writes the selection reason into the job via
a new `JobStore.markExplicitConnectionCount(id:)` method that sets a daemon-internal
`Bool` flag on the `JobSummary` — BUT `JobSummary` is wire-serialized, so we cannot add a field.

**Correct approach — ephemeral daemon-side map:** Add a `Mutex<[UInt64: UInt8]>` table to
`DownloadEngine` (or to `gohd/main.swift` scope) mapping jobID → explicit N. Populated by
`CommandDispatcher` (or the `onJobQueued` hook) before the engine's `run()` is called:

```swift
// In gohd/main.swift, alongside the DownloadEngine init:
let explicitNTable = Mutex<[UInt64: UInt8]>([:])

// In CommandDispatcher.reply(to:), after creating the job:
// (Pass explicitNTable into the dispatcher via its init, or thread via closure.)
if selectionReason == .explicit {
    explicitNTable.withLock { $0[job.id] = requestedConnectionCount }
}

// In scheduleJob / onJobQueued:
let explicitN = explicitNTable.withLock { $0.removeValue(forKey: jobID) }
await engine.run(jobID: jobID, in: store, explicitConnectionCount: explicitN)
```

**Signature changes at each hop:**

1. `DownloadEngine.run` gains `explicitConnectionCount: UInt8? = nil`:
```swift
public func run(
    jobID: UInt64, in store: JobStore,
    explicitConnectionCount: UInt8? = nil
) async
```

2. `run` passes it down into `download(job:store:trace:explicitN:)` and then into `fetchRanged`:
```swift
private func fetchRanged(
    job: JobSummary, store: JobStore, url: URL, total: UInt64,
    initialResponse: HTTPURLResponse,
    firstRangeStream: AsyncThrowingStream<Data, Error>,
    cancelFirstRangeStream: @escaping @Sendable () -> Void,
    trace: EngineDiagnostics,
    clock: ContinuousClock = ContinuousClock(),
    explicitConnectionCount: UInt8? = nil   // <-- governor-off channel
) async throws
```

3. Inside `fetchRanged`, at the point where the governor would be instantiated:
```swift
let governorEnabled = explicitConnectionCount == nil
if governorEnabled {
    var governor = ParallelismGovernor(config: .default, rng: SystemRandomNumberGenerator())
    // ... governor drives targetN via decide() after each reap ...
} else {
    // Governor OFF: run at fixed explicitConnectionCount, no observations.
    // targetN is pinned to explicitConnectionCount for the entire transfer.
    // GovernorOutcome is .governorOff.
}
```

4. `GovernorOutcome` on the governor-off path:
```swift
let outcome: GovernorOutcome = governorEnabled
    ? /* extract from governor final phase */
    : .governorOff   // effectiveN = nil → no bandit observation recorded
```

What changes in `fetchRanged` (governor-on path):
1. Instantiate `var governor = ParallelismGovernor(config: .default, rng: SystemRandomNumberGenerator())`.
2. After each flush in `downloadChunk`, call `governor.record(sample:)`.
3. After each `group.next()` reap, call `governor.decide(liveWorkers:remainingBytes:)` and apply the decision by writing `targetN`.
4. Track `peakWorkers = max(peakWorkers, liveWorkers)` for `setActualConnectionCount`.
5. On exit, build `GovernorOutcome` from the governor's final phase and pass it to `completedDownloadHandler`.

What changes in `fetchRanged` (governor-off path):
- `targetN` is set once to `explicitConnectionCount` and never modified.
- `governor.decide()` and `governor.record()` are never called.
- `peakWorkers` is still tracked for `setActualConnectionCount`.
- `outcome = GovernorOutcome.governorOff` — effectiveN is nil, so no observation is recorded.

- [ ] **Step 1: Write the failing tests**

```swift
// Add to Tests/GohCoreTests/DownloadEngineTests.swift:

// Test 1: Governor outcome arity.
@Test("P3: completedDownloadHandler receives GovernorOutcome (arity test)")
func completedHandlerReceivesGovernorOutcome() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let total: UInt64 = 4 * 1024 * 1024
    let url = "https://test.local/\(UUID().uuidString).bin"
    let payload = Data(repeating: 0x11, count: Int(total))
    MockURLProtocol.stub(url, body: payload, statusCode: 206,
        headers: ["Content-Range": "bytes 0-\(total - 1)/\(total)"])

    let store = JobStore()
    let destination = directory.appending(path: "out.bin").path
    let job = store.create(url: url, destination: destination, requestedConnectionCount: 2)

    // The handler now takes four parameters: (JobSummary, Duration, Bool, GovernorOutcome).
    let outcomeCaptured = Mutex<GovernorOutcome?>(nil)
    await DownloadEngine(
        session: mockSession(),
        completedDownloadHandler: { _, _, _, outcome in
            outcomeCaptured.withLock { $0 = outcome }
        }
    ).run(jobID: job.id, in: store)

    #expect(store.job(id: job.id)?.state == .completed)
    #expect(outcomeCaptured.withLock { $0 } != nil)
}

// Test 2: Explicit N — governor is off; targetN never deviates; no observation recorded.
// The named invariant: "with explicit N, targetN never deviates AND nothing recorded."
// A buggy impl that let the governor probe to N=8 but returned .governorOff would pass
// the effectiveN/observationRecorded assertions but NOT the peak-connection assertion.
// We prove the pin by asserting the realized peak connection count equals the pinned N.
@Test("P3: explicit --connections N pins targetN; governor off; peak==pinnedN; GovernorOutcome is .governorOff")
func explicitNGovernorOff() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let total: UInt64 = 8 * 1024 * 1024
    let url = "https://test.local/\(UUID().uuidString).bin"
    let payload = Data(repeating: 0x33, count: Int(total))
    MockURLProtocol.stub(url, body: payload, statusCode: 206,
        headers: ["Content-Range": "bytes 0-\(total - 1)/\(total)"])

    let store = JobStore()
    let destination = directory.appending(path: "out.bin").path
    // Requested connection count is 4; we pass explicitConnectionCount: 4 to the engine.
    let job = store.create(url: url, destination: destination, requestedConnectionCount: 4)

    let outcomeCaptured = Mutex<GovernorOutcome?>(nil)
    var observationRecorded = false

    await DownloadEngine(
        session: mockSession(),
        completedDownloadHandler: { _, _, _, outcome in
            outcomeCaptured.withLock { $0 = outcome }
            // If effectiveN is non-nil the bandit would record an observation.
            // We assert it is nil (governor off).
            if outcome.effectiveN != nil { observationRecorded = true }
        }
    ).run(jobID: job.id, in: store, explicitConnectionCount: 4)

    #expect(store.job(id: job.id)?.state == .completed)
    let outcome = outcomeCaptured.withLock { $0 }!

    // (1) Governor off: effectiveN MUST be nil (no bandit observation recorded).
    #expect(outcome.effectiveN == nil,
            "governor must be off for explicit N; effectiveN should be nil, got \(String(describing: outcome.effectiveN))")

    // (2) No bandit observation must have been recorded.
    #expect(!observationRecorded, "no bandit observation should be recorded when governor is off")

    // (3) Peak-connection proof: the realized peak worker count must equal the pinned N=4.
    // This assertion catches a buggy impl that lets the governor probe to N>4 while still
    // returning .governorOff. Task 11 gave actualConnectionCount peak-max semantics, so this
    // field records the highest live-worker count seen over the transfer — if the governor
    // probed, it would show N>4 here.
    //
    // The engine calls setActualConnectionCount(id:peakWorkers) at the end of fetchRanged.
    // With explicitConnectionCount=4, targetN is pinned to 4 and governor.decide() is never
    // called, so peakWorkers <= 4. Combined with the fact that the download completes (≥1
    // worker ran), actualConnectionCount must be exactly 4.
    #expect(store.job(id: job.id)?.actualConnectionCount == 4,
            "peak concurrent workers must equal pinned N=4; governor probed if this fails")
}
```

- [ ] **Step 2: Run tests to verify they fail**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "completedHandlerReceivesGovernorOutcome|explicitNGovernorOff"
  ```

  Expected: FAIL — `DownloadEngine` `completedDownloadHandler` has wrong arity; `run` has no `explicitConnectionCount` parameter.

- [ ] **Step 3: Write implementation**

**Change `DownloadEngine.completedDownloadHandler` type** from:
```swift
private let completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool) -> Void)?
```
to:
```swift
private let completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool, GovernorOutcome) -> Void)?
```

Update the `init` parameter type accordingly. Update the `complete(jobID:in:transferDuration:isResume:)`
method to also receive a `GovernorOutcome`:
```swift
private func complete(
    jobID: UInt64, in store: JobStore,
    transferDuration: Duration, isResume: Bool,
    governorOutcome: GovernorOutcome = .governorOff
) throws {
    let completed = try store.complete(id: jobID)
    completedDownloadHandler?(completed, transferDuration, isResume, governorOutcome)
}
```

Wire the governor into the P2 control loop:
- At each worker reap, call `governor.record(sample:)` (samples accumulated during the worker's flushes are batched).
- Call `governor.decide()` and apply the decision to `targetN`.
- On the `fetchRanged` exit path, extract `governorOutcome` from the governor's final phase.

Update `gohd/main.swift` `completedDownloadHandler` closure to accept 4 parameters and use
`GovernorOutcome` in the gate:
```swift
completedDownloadHandler: { completed, transferDuration, isResume, governorOutcome in
    let observationKey = hostKey(for: completed.url)
    if let key = observationKey {
        let req = ObservationRequest(
            isResume: isResume,
            transferDuration: transferDuration,
            bytesCompleted: completed.progress.bytesCompleted,
            wasSolo: hostProfileStore.wasSolo(jobID: completed.id),
            governorOutcome: governorOutcome)
        hostProfileStore.recordObservationIfEligible(
            req, hostKey: key,
            totalBytes: completed.progress.bytesCompleted,
            transferDuration: transferDuration)
    }
    // ... Spotlight tagger unchanged ...
}
```

- [ ] **Step 4: Run all tests**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  ```

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Engine/DownloadEngine.swift Sources/gohd/main.swift \
          Tests/GohCoreTests/DownloadEngineTests.swift
  git commit -m "feat(engine): wire ParallelismGovernor to control loop; GovernorOutcome to handler (P3)"
  ```

---

### Task 13: Warm-Start from Governor-Converged N (SM4)

**Files:** Modify `Sources/GohCore/Model/CommandDispatcher.swift` · Modify `Sources/GohCore/Scheduling/HostProfileStore.swift` · Modify `Tests/GohCoreTests/HostProfileStoreTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Model/CommandDispatcher.swift` — admission `selectN` call (lines 63–67). Result: `(n: UInt8, reason: SelectionReason)`.
- [ ] `Sources/GohCore/Scheduling/HostProfileStore.swift` — `selectN` method (lines 239–251).

**SM4 gate:** "A governor-converged N (candidate-aligned) is recorded through `HostProfileStore`;
a later cold download warm-starts N₀ from it (scheduling trace `reason=warmStart`)."

**The mechanism:** `selectN` continues using the bandit (unchanged). When a governor-converged N has
been recorded as an arm with ≥ minSamples, the bandit's exploit path picks it — returning
`reason = .exploit`. The `.warmStart` `SelectionReason` case is a *trace-only annotation* emitted
in `CommandDispatcher` when an exploit pick is made AND the governance feature is enabled for this
download (meaning: the download will run with the governor active). This distinguishes
"governor-seeded warm start" from "ordinary exploit of a pre-governor observation."

**Critical constraint:** `.warmStart` MUST NOT be emitted for every `.exploit` selection. A host
whose arms were recorded before the governor existed would incorrectly show `reason=warmStart` on
every exploit, which distinguishes nothing.

**Concrete warmStart predicate:** Emit `reason=warmStart` in the trace iff ALL of:
1. `selectionReason == .exploit` (bandit is exploiting a settled arm).
2. `request.connectionCount == nil` (no explicit `--connections N`; governor will be active).
3. `DownloadEngine.governorEnabled == true` (global kill-switch is on).

This is a meaningful distinction: it fires only when the download will run with live governor
adaptation AND the bandit's initial N₀ came from an exploit arm (which is the warm-start case).
It does not require distinguishing individual governor-vs-legacy arm writes in the plist format
(which carries no such metadata — adding it would be a format bump, forbidden).

- [ ] **Step 1: Write the failing tests (SM4)**

```swift
// Add to Tests/GohCoreTests/HostProfileStoreTests.swift:

@Test("SM4: governor-recorded arm warms up N₀ selection — exploit picks best arm")
func sm4WarmStartFromGovernorArm() throws {
    // SM4 (AC4): governor-converged N recorded → next cold download warm-starts.
    // This test verifies the bandit picks N=8 (the best arm) after all 4 arms
    // are seeded with governor-gate observations.
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = HostProfileStore(
        fileURL: directory.appending(path: "host-scheduling.plist"))
    _ = store.load()

    let key = "https://fast.example.com:443"
    // Seed all 4 candidate arms so exploit is reachable. N=8 has the best EWMA.
    let candidates: [(UInt8, Double)] = [(2, 20_000_000), (4, 40_000_000),
                                          (8, 80_000_000), (16, 60_000_000)]
    for (n, throughput) in candidates {
        for _ in 0..<3 {   // >= minSamples
            store.recordObservation(
                hostKey: key, connectionCount: n,
                totalBytes: UInt64(throughput * 30),
                transferDuration: .seconds(30))
        }
    }

    let (chosenN, reason) = store.selectN(hostKey: key)
    // Exploit: best arm is N=8 (highest EWMA throughput).
    #expect(chosenN == 8,
            "SM4: exploit should pick N=8 (best EWMA); got N=\(chosenN)")
    #expect(reason == .exploit,
            "SM4: expected .exploit after all arms settled; got \(reason)")
    // NOTE: reason == .warmStart is NOT checked here — warmStart is a trace annotation
    // emitted in CommandDispatcher, not a value returned by selectN itself.
}
```

- [ ] **Step 2: Run test to verify it passes**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "sm4WarmStartFromGovernorArm"
  ```

  Expected: PASS (confirms exploit picks the governor-seeded arm; the test will compile and pass
  once `selectN` and `recordObservation` are migrated to the `ObservationRequest` API from Task 10).

- [ ] **Step 3: Add trace annotation in CommandDispatcher**

In `CommandDispatcher.reply(to:)`, update the trace call with the concrete warmStart predicate:

```swift
// After selectN returns (requestedConnectionCount, selectionReason):
// Concrete warmStart predicate — emits warmStart only when ALL three conditions hold:
let traceReason: SelectionReason
if selectionReason == .exploit,      // 1. bandit chose a settled arm
   request.connectionCount == nil,   // 2. no explicit --connections N; governor will run
   DownloadEngine.governorEnabled    // 3. global kill-switch is on
{
    // This run warm-starts from a settled arm AND will run with live governor adaptation.
    traceReason = .warmStart
} else {
    traceReason = selectionReason
}
EngineDiagnostics().recordSchedulingDecision(
    hostKey: admissionHostKey,
    chosenN: requestedConnectionCount,
    reason: traceReason,
    armEWMAs: armEWMAs)
```

Also add a unit test step (3b) that directly verifies the predicate without needing a full
dispatcher round-trip (simpler, more robust):

```swift
// Add to Tests/GohCoreTests/HostProfileStoreTests.swift:

@Test("SM4: warmStart predicate — exploit + no explicit N + governor on = warmStart; other combos are not")
func sm4WarmStartPredicate() {
    // The predicate is: exploit && connectionCount == nil && governorEnabled.
    // We test it as a pure Bool expression (extracted from CommandDispatcher for testability).

    func traceReason(
        selectionReason: SelectionReason,
        hasExplicitN: Bool,
        governorEnabled: Bool
    ) -> SelectionReason {
        if selectionReason == .exploit, !hasExplicitN, governorEnabled {
            return .warmStart
        }
        return selectionReason
    }

    // Warm-start case: all three conditions.
    #expect(traceReason(selectionReason: .exploit, hasExplicitN: false, governorEnabled: true)
            == .warmStart)

    // No warm-start: explicit N.
    #expect(traceReason(selectionReason: .exploit, hasExplicitN: true, governorEnabled: true)
            == .exploit)

    // No warm-start: governor off (kill-switch).
    #expect(traceReason(selectionReason: .exploit, hasExplicitN: false, governorEnabled: false)
            == .exploit)

    // No warm-start: explore, not exploit.
    #expect(traceReason(selectionReason: .explore, hasExplicitN: false, governorEnabled: true)
            == .explore)

    // No warm-start: cold.
    #expect(traceReason(selectionReason: .cold, hasExplicitN: false, governorEnabled: true)
            == .cold)
}
```

- [ ] **Step 4: Run all tests**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  ```

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Model/CommandDispatcher.swift Tests/GohCoreTests/HostProfileStoreTests.swift
  git commit -m "feat(scheduling): SM4 warm-start — exploit arm annotated as warmStart in trace"
  ```

---

### Task 14: DESIGN.md §Persistence + §Observability Reconciliation (P3)

**Files:** Modify `DESIGN.md`

**Spec §15 requires:** Update §Persistence/§Adaptive host scheduling for the observation-gate
redesign. Update §Observability for the governor trace line.

- [ ] **Step 1: Update DESIGN.md §Adaptive host scheduling**

  Add a paragraph after the existing "Observation gate" paragraph:

  > **Governor-gate redesign (in-flight adaptive parallelism slice).** The gate predicate now
  > uses `ObservationRequest`, a parameter struct replacing the previous 6-parameter call. The
  > new gate additionally requires `GovernorOutcome.effectiveN != nil` (the governor converged
  > to a candidate-aligned N) AND `GovernorOutcome.stabilized` (cruise phase was reached). Off-
  > candidate convergence (binary-search refinement to e.g. 6) produces `effectiveN = nil` and
  > is never recorded — the frozen EWMA never receives a biased value. `actualConnectionCount`
  > is now documented as the *peak concurrent connections* used during the transfer; the cap is
  > the hard ceiling 16, not the admission-time `requestedConnectionCount`.
  >
  > **Throttle-pin scope (conservative divergence from spec §11).** The spec §11 says the governor
  > holds throttled hosts pinned low "for the session." The implementation pins low for the
  > lifetime of the `ParallelismGovernor` instance, which is per-download (each new download
  > starts a fresh governor). This is a conservative divergence: a throttle-triggered host is
  > pinned only for the remainder of the single download where throttle was detected, NOT across
  > downloads. The next download re-probes from scratch. This is intentionally safe (re-probing is
  > harmless; a false pin across downloads is not). If the spec's session-scope behaviour is
  > desired in future, the `GovernorOutcome.pinned` state must be persisted to `HostProfileStore`
  > and re-applied on admission — a future enhancement requiring no format change (it fits in the
  > existing arm metadata).

- [ ] **Step 2: Update DESIGN.md §Observability**

  Add after the existing `GOH_ENGINE_TRACE` paragraph:

  > **Governor trace lines.** When `GOH_ENGINE_TRACE=1`, the engine additionally emits per-tick
  > governor events: `governor phase=<probe|cruise|pinned> decision=<hold|addWorkers(k)|dropWorkers(k)|commit(n)|backOffPinLow> N=<n> host=<key>`. Scheduling-decision traces already emit `reason=warmStart` when the bandit exploits an arm recorded by a governor observation. Edge IPs (P5) are a new trace category: `edge ip=<ip> action=<added|removed>` — these carry the raw IP, never a URL or userinfo (D1 PII rule).

- [ ] **Step 3: Commit**

  ```
  git add DESIGN.md
  git commit -m "docs(design): §Persistence + §Observability — governor-gate redesign + trace lines (spec §15 P3)"
  ```

---

### Task 15: Governor Trace in `EngineDiagnostics`

**Files:** Modify `Sources/GohCore/Engine/EngineDiagnostics.swift` · Modify `Tests/GohCoreTests/EngineDiagnosticsSchedulingTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Engine/EngineDiagnostics.swift` — `recordSchedulingDecision` pattern (lines 132–157). The new governor trace follows the same `emit()` pattern.

- [ ] **Step 1: Write the failing test**

```swift
// Add to Tests/GohCoreTests/EngineDiagnosticsSchedulingTests.swift:

@Test("SM1 prerequisite: recordGovernorDecision exists (compile check)")
func governorTraceExists() {
    let diag = EngineDiagnostics(enabled: false)
    diag.recordGovernorDecision(
        phase: "probe", decision: "addWorkers(2)", currentN: 2,
        hostKey: "https://example.com:443")
    #expect(diag.peakActive == 0)
}
```

- [ ] **Step 2: Run test to verify it fails**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "governorTraceExists"
  ```

  Expected: FAIL — `'EngineDiagnostics' has no member 'recordGovernorDecision'`.

- [ ] **Step 3: Write implementation**

Add to `EngineDiagnostics.swift`:
```swift
/// Emits a governor-decision trace line when `GOH_ENGINE_TRACE=1`.
/// SM1 prerequisite: probe→knee→cruise events observable via trace.
func recordGovernorDecision(
    phase: String, decision: String, currentN: Int, hostKey: String?
) {
    guard enabled else { return }
    let host = hostKey ?? "(nil)"
    emit("governor phase=\(phase) decision=\(decision) N=\(currentN) host=\(host)")
}
```

- [ ] **Step 4: Run test to verify it passes**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "governorTraceExists"
  ```

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Engine/EngineDiagnostics.swift Tests/GohCoreTests/EngineDiagnosticsSchedulingTests.swift
  git commit -m "feat(trace): recordGovernorDecision — GOH_ENGINE_TRACE governor phase/decision events (SM1)"
  ```

---

### Task 16: Full Test Suite + Kill-Switch Verification + P3 Artifact

- [ ] **Step 1: Verify kill-switch constant is in place**

  Confirm `DownloadEngine` has a `static let governorEnabled = true` constant that the control
  loop checks. Verify that setting it to `false` falls back to static bandit N (the spec §10
  kill-switch). Add the constant if missing.

- [ ] **Step 2: Run full test suite**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  ```

  Expected: all tests pass, zero warnings under `-warnings-as-errors`.

- [ ] **Step 3: Write P3 artifact**

  Write `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase3.md`.

- [ ] **Step 4: Commit**

  ```
  git add docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase3.md
  git commit -m "docs(progress): P3 artifact — governor wired + gate redesign + warm-start"
  ```

---

## Phase 4: Global Per-Host Budget + LFN Benchmark Harness

**What P4 builds:** The global per-host `ConnectionBudget` (§8); the `goh-bench` LFN subcommand;
SM5a and SM2 proofs. **This phase ships the headline.**

---

### Task 17: Global Per-Host `ConnectionBudget`

**Files:** Create `Sources/GohCore/Engine/ConnectionBudget.swift` · Create `Tests/GohCoreTests/ConnectionBudgetTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Scheduling/HostProfileStore.swift` — `begin(jobID:hostKey:)`/`end(jobID:hostKey:)` pattern (the budget follows the same per-host keying).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/GohCoreTests/ConnectionBudgetTests.swift
import Testing
@testable import GohCore

@Suite("ConnectionBudget — global per-host budget")
struct ConnectionBudgetTests {

    @Test("request slots within budget succeeds")
    func requestWithinBudget() {
        let budget = ConnectionBudget(maxPerHost: 16)
        let granted = budget.request(slots: 8, hostKey: "https://example.com:443")
        #expect(granted)
    }

    @Test("request slots exceeding budget is denied")
    func requestExceedsBudget() {
        let budget = ConnectionBudget(maxPerHost: 16)
        _ = budget.request(slots: 16, hostKey: "https://example.com:443")
        let denied = budget.request(slots: 1, hostKey: "https://example.com:443")
        #expect(!denied)
    }

    @Test("release slots allows re-request")
    func releaseAllowsReRequest() {
        let budget = ConnectionBudget(maxPerHost: 8)
        let key = "https://example.com:443"
        _ = budget.request(slots: 8, hostKey: key)
        budget.release(slots: 4, hostKey: key)
        let granted = budget.request(slots: 4, hostKey: key)
        #expect(granted)
    }

    @Test("different hosts have independent budgets")
    func independentHostBudgets() {
        let budget = ConnectionBudget(maxPerHost: 8)
        _ = budget.request(slots: 8, hostKey: "https://a.example.com:443")
        let granted = budget.request(slots: 8, hostKey: "https://b.example.com:443")
        #expect(granted)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ConnectionBudgetTests"
  ```

  Expected: FAIL.

- [ ] **Step 3: Write implementation**

```swift
// Sources/GohCore/Engine/ConnectionBudget.swift
import Foundation
import Synchronization

/// Daemon-global per-host active-connection budget (§8 of the in-flight parallelism spec).
///
/// Both URLSession workers and (P5) NWConnection edge workers count against one
/// budget per host key. The governor requests slots; denied requests hold N at
/// the current level. Thread-safe.
public final class ConnectionBudget: Sendable {
    private let maxPerHost: Int
    private let active: Mutex<[String: Int]>

    public init(maxPerHost: Int = 16) {
        self.maxPerHost = maxPerHost
        self.active = Mutex([:])
    }

    /// Tries to reserve `slots` for `hostKey`. Returns true iff granted.
    public func request(slots: Int, hostKey: String) -> Bool {
        active.withLock { dict in
            let current = dict[hostKey, default: 0]
            guard current + slots <= maxPerHost else { return false }
            dict[hostKey] = current + slots
            return true
        }
    }

    /// Releases `slots` for `hostKey`.
    public func release(slots: Int, hostKey: String) {
        active.withLock { dict in
            let current = dict[hostKey, default: 0]
            let after = max(0, current - slots)
            if after == 0 { dict.removeValue(forKey: hostKey) }
            else { dict[hostKey] = after }
        }
    }

    /// Current usage for `hostKey` (for diagnostics).
    public func usage(hostKey: String) -> Int {
        active.withLock { $0[hostKey, default: 0] }
    }
}
```

Wire `ConnectionBudget` into `DownloadEngine`: pass a shared `ConnectionBudget` instance from the
daemon (created once in `gohd/main.swift`). Each worker `request(slots: 1, hostKey:)` before
opening a connection and `release(slots: 1, hostKey:)` in defer. The governor's `addWorkers`
decision is applied only if the budget grants the slots.

- [ ] **Step 4: Run all tests**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  ```

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Engine/ConnectionBudget.swift Tests/GohCoreTests/ConnectionBudgetTests.swift \
          Sources/GohCore/Engine/DownloadEngine.swift Sources/gohd/main.swift
  git commit -m "feat(engine): global per-host ConnectionBudget enforced in worker pool (§8)"
  ```

---

### Task 18: `goh-bench` LFN Subcommand + Runbook

**Files:** Modify `Benchmarks/goh-bench/` (new subcommand in the existing benchmark executable)

**Pre-task reads:**
- [ ] `Benchmarks/goh-bench/` — existing benchmark structure. The target lives at `Benchmarks/goh-bench/` per `Package.swift` (`path: "Benchmarks/goh-bench"`). The directory currently contains a single `main.swift`. Add the `lfn` subcommand to that file (or extract shared entry-point logic into a helper in the same directory). Do NOT create a `Sources/goh-bench/` directory — that path is wrong and would produce an unbuilt source tree.
- [ ] Spec §12 — benchmark-sourcing plan. The confirmed target is `https://sin-speed.hetzner.com/1GB.bin` (SM5a).

**What this adds:** A `lfn` subcommand that runs ≥5 governed downloads, captures median + IQR wall-clock,
and compares against static N=8. The kill-switch flag (`--static-n`) disables the governor for the
control arm.

```
goh-bench lfn [--url <url>] [--runs <n>] [--static-n <n>]
```

- [ ] **Step 1: Implement the subcommand**

  The `goh-bench lfn` subcommand must:
  1. Accept `--url` (default: `https://sin-speed.hetzner.com/1GB.bin`), `--runs N` (default: 5), `--static-n N` (optional; if set, disables governor).
  2. For each run: create a temporary destination, run a download via `DownloadEngine`, capture wall-clock.
  3. Compute median + IQR over runs.
  4. Emit a JSON result line: `{"url":..., "mode":..., "runs":..., "medianSeconds":..., "iqrSeconds":...}` to stdout.
  5. Optionally compare against a static-N baseline (when `--static-n` is provided).

- [ ] **Step 2: Write the runbook**

  Commit a runbook to `docs/bench/lfn-runbook.md`:
  ```
  # LFN Benchmark Runbook (SM5a gate)
  
  ## Target
  URL: https://sin-speed.hetzner.com/1GB.bin
  Expected RTT: ≥80 ms (Singapore)
  Expected behaviour: governed median > static N=8 median, non-overlapping IQR.
  
  ## Command (SM5a accept)
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift run goh-bench lfn --url https://sin-speed.hetzner.com/1GB.bin \
    --runs 5 --output governed.json
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift run goh-bench lfn --url https://sin-speed.hetzner.com/1GB.bin \
    --runs 5 --static-n 8 --output static8.json
  
  ## SM2 accept (saturated regression guard)
  [Use dummynet-emulated target or dl.google.com-equivalent]
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift run goh-bench lfn --url <saturated-target> --runs 5 --output governed-sat.json
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift run goh-bench lfn --url <saturated-target> --runs 5 --static-n 8 --output static8-sat.json
  # Accept: governed median ≤ 1.05 × static8 median (≤5% regression).
  
  ## Quarantine policy (Advisory A3)
  A single anomalous run is re-run and discarded if the re-run is within IQR.
  Never treat a single transient blip as a regression.
  ```

- [ ] **Step 3: Commit**

  ```
  git add Benchmarks/goh-bench/ docs/bench/lfn-runbook.md
  git commit -m "feat(bench): goh-bench lfn subcommand + SM5a/SM2 runbook"
  ```

---

### Task 19: SM5a + SM2 Proof Run + P4 Artifact

**Manual step — not automated.** Run on the developer machine with a live network connection.

- [ ] **Step 1: Run SM5a (LFN, governed vs static N=8)**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift run goh-bench lfn --url https://sin-speed.hetzner.com/1GB.bin \
    --runs 5 --output governed.json
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift run goh-bench lfn --url https://sin-speed.hetzner.com/1GB.bin \
    --runs 5 --static-n 8 --output static8.json
  ```

  Accept: `governed.json` median < `static8.json` median, non-overlapping IQR.
  Quarantine policy: re-run if one run is anomalous.

- [ ] **Step 2: Run SM2 (saturated, ≤5% regression)**

  Use dummynet (or Linux-VM `tc netem` fallback from Task 5) to create a saturated workload.
  Accept: governed median ≤ 1.05 × static8 median.

  If regression >5% is observed: diagnose governor knee detection. Do NOT ship until SM2 passes.

- [ ] **Step 3: Record results and write P4 artifact**

  Write `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase4.md` with:
  - SM5a result (median throughputs, IQR, pass/fail)
  - SM2 result (regression percentage, pass/fail)
  - Governor trace excerpt confirming probe→knee→cruise path (SM1 confirmation)
  - Open items for P5

- [ ] **Step 4: Commit**

  ```
  git add docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase4.md \
          docs/bench/
  git commit -m "docs(progress): P4 artifact — SM5a + SM2 results (headline ships)"
  ```

---

## Phase 5: NWConnection HTTP/1.1 Edge Transport + Multi-Edge Fan-Out

**What P5 builds:** The NWConnection-based HTTP/1.1 range client with hostname-pinned TLS trust;
`getaddrinfo` edge-IP resolver; multi-edge fan-out control in the governor; SM6 proofs; DESIGN.md
transport-brief revision.

**P5 is gated by:**
1. The feasibility spike in Task 20 — if it fails, P5 is held and the slice ships on SM5a.
2. A dedicated security + transport review of the NWConnection path before merge.

**P5 NWConnection path is dormant** behind `DownloadEngine.multiEdgeEnabled = false` until the
spike passes and the review completes.

**Bet check (P5 — separate TCP connections vs shared-cwnd):** The bet is that connecting to distinct
CDN edge IPs over separate NWConnection TCP sockets (each its own congestion window) beats HTTP/2
shared-cwnd multiplexing. This is the structural lever; the governor measures actual aggregate rate
so it adapts correctly regardless of whether the theory holds on a specific CDN.

**Security mandate (spec §9 + §7.2):** The verify block is always strict. No debug relaxation.
Revocation hard-fail. SM6 assertions are pinned to the ACTUAL rejection error from the spike, not
assumed. This section is the most security-sensitive code in the project; `DESIGN.md` §Transport
revision is joint with the security review.

---

### Task 20: P5 Feasibility Spike

**Files:** No source files committed. Result documented.

**Purpose:** Spec §7.4 — confirm end-to-end: NWConnection to an edge IP + hostname SNI +
verify block + HTTP/1.1 `206` range read against a real CDN. Record the exact rejection error
for SM6.

- [ ] **Step 1: Write a throwaway spike script (Swift script, not committed)**

  A local Swift script (not in the project) that:
  1. Resolves `speed.cloudflare.com` A/AAAA records via `getaddrinfo`.
  2. For one IP, opens `NWConnection(host: <ip>, port: 443, using: .tls)` with
     `sec_protocol_options_set_tls_server_name(opts, "speed.cloudflare.com")`.
  3. Installs a verify block via `sec_protocol_options_set_verify_block` that runs
     `SecPolicyCreateSSL(true, "speed.cloudflare.com")` and evaluates the chain.
  4. Sends a hand-rolled HTTP/1.1 `GET /__down?bytes=1048576 HTTP/1.1\r\nHost: speed.cloudflare.com\r\nRange: bytes=0-1048575\r\n\r\n`.
  5. Parses the `206` response status line and `Content-Range` header.
  6. Records the exact `NWError` / `URLError` code when the verify block rejects a
     wrong-hostname cert (by temporarily altering the hostname in the policy to a mismatched one).

- [ ] **Step 2: Run the spike**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift /tmp/nwconnection_spike.swift
  ```

  **Pass:** `206` response received; wrong-hostname cert rejected with a specific `NWError`.
  Document the exact error code — this becomes the SM6 assertion value.

  **Fail:** CDN rejects IP-pinned connection, SNI mismatch, or another unanticipated failure.
  Document the exact failure. If the end-to-end path fails: **P5 is held**; the slice ships
  on SM5a. Write the spike result in the P5 artifact and halt P5 tasks.

- [ ] **Step 3: Record result**

  If spike passes: record confirmed `NWError` code for wrong-hostname rejection.
  Continue to Task 21.

  If spike fails: write `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase5.md`
  noting "P5 held: spike failed at <step>. Slice ships on SM5a." Then stop.

---

### Task 21: `EdgeIPResolver` — `getaddrinfo` A/AAAA Enumeration

**Files:** Create `Sources/GohCore/Engine/EdgeIPResolver.swift` · Modify `Tests/GohCoreTests/EdgeTransportTests.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Engine/DownloadFile.swift` — `getaddrinfo` pattern is NOT used there; this is new. Review the CLAUDE.md cross-SDK C-bridged API gotcha — `getaddrinfo` parameters include non-optional C pointers; portable usage with `UnsafePointer` unwrapping avoids SDK 26.2 vs 26.5 skew.

**Cross-SDK gotcha:** `getaddrinfo` itself is stable, but any C-bridged API with pointer parameters
may have optionality differences between SDK 26.2 and 26.5. Ensure all C pointer arguments are
non-optional (unwrap optionals before passing).

- [ ] **Step 1: Write the failing tests**

```swift
// Create Tests/GohCoreTests/EdgeTransportTests.swift:
import Testing
import Foundation
@testable import GohCore

@Suite("Edge transport — IP resolver + NWConnection HTTP/1.1")
struct EdgeTransportTests {

    @Test("EdgeIPResolver: resolves at least one IP for example.com")
    func resolvesExampleCom() async throws {
        let ips = try await EdgeIPResolver.resolve(hostname: "example.com")
        #expect(!ips.isEmpty)
        // Every result must be a valid IP string.
        for ip in ips {
            #expect(!ip.isEmpty)
        }
    }

    @Test("EdgeIPResolver: single-IP hosts degrade cleanly (result count ≥ 1)")
    func singleIPDegrades() async throws {
        let ips = try await EdgeIPResolver.resolve(hostname: "localhost")
        // localhost resolves to at least 127.0.0.1 or ::1.
        #expect(!ips.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "EdgeIPResolver"
  ```

  Expected: FAIL — `cannot find type 'EdgeIPResolver' in scope`.

- [ ] **Step 3: Write implementation**

```swift
// Sources/GohCore/Engine/EdgeIPResolver.swift
import Darwin
import Foundation

/// Resolves all A/AAAA records for a hostname via `getaddrinfo`.
///
/// Used by the multi-edge fan-out path (P5) to enumerate distinct CDN edge IPs.
/// Returns unique IP strings (IPv4 dotted-decimal or IPv6 bracketed).
///
/// Cross-SDK safety: getaddrinfo parameters use explicit non-optional pointer
/// patterns to avoid SDK 26.2 vs 26.5 bytes-parameter optionality skew.
public struct EdgeIPResolver: Sendable {

    /// Resolves `hostname` and returns all unique IP address strings.
    /// Throws if resolution fails entirely.
    public static func resolve(hostname: String) async throws -> [String] {
        return try await withCheckedThrowingContinuation { continuation in
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC      // IPv4 and IPv6
            hints.ai_socktype = SOCK_STREAM
            hints.ai_flags = AI_CANONNAME

            var results: UnsafeMutablePointer<addrinfo>?
            let ret = hostname.withCString { hostCStr in
                getaddrinfo(hostCStr, nil, &hints, &results)
            }
            guard ret == 0, let head = results else {
                continuation.resume(throwing: GohError(
                    code: .dnsResolutionFailed,
                    message: "getaddrinfo failed for \(hostname): \(String(cString: gai_strerror(ret)))"))
                return
            }
            defer { freeaddrinfo(head) }

            var ips: [String] = []
            var current: UnsafeMutablePointer<addrinfo>? = head
            while let node = current {
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if let addr = node.pointee.ai_addr {
                    if node.pointee.ai_family == AF_INET {
                        var sa = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        inet_ntop(AF_INET, &sa.sin_addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                    } else if node.pointee.ai_family == AF_INET6 {
                        var sa = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                        inet_ntop(AF_INET6, &sa.sin6_addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                    }
                    let ip = String(cString: buf)
                    if !ip.isEmpty && !ips.contains(ip) { ips.append(ip) }
                }
                current = node.pointee.ai_next
            }
            continuation.resume(returning: ips)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "EdgeIPResolver"
  ```

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Engine/EdgeIPResolver.swift Tests/GohCoreTests/EdgeTransportTests.swift
  git commit -m "feat(p5): EdgeIPResolver — getaddrinfo A/AAAA enumeration for multi-edge fan-out"
  ```

---

### Task 22: `EdgeTransport` — NWConnection HTTP/1.1 Range Client + TLS Trust

**Files:** Create `Sources/GohCore/Engine/EdgeTransport.swift` · Modify `Tests/GohCoreTests/EdgeTransportTests.swift`

**Pre-task reads:**
- [ ] Spec §7.1 (mechanism) and §7.2 (TLS trust / verify block).
- [ ] Spike result from Task 20 — exact `NWError` code for wrong-hostname rejection (used in SM6 assertion).

**Security requirements (all mandatory — spec §9):**
- `sec_protocol_options_set_tls_server_name`: SNI is the **hostname**, not the IP.
- `sec_protocol_options_set_verify_block`: runs full chain evaluation against the hostname via `SecPolicyCreateSSL(true, hostname)`.
- `kSecRevocationRequirePositiveResponse`: revocation hard-fail.
- No debug relaxation.
- Body parser bounds: `Content-Length` never trusted beyond the requested range; header size bounded.

**SM6 gate:**
- Test (a): wrong-hostname cert rejected → `NWError` matches the spike-confirmed code.
- Test (b): valid hostname cert accepted → connection succeeds.
- Test (c): revoked cert rejected (hard-fail).

- [ ] **Step 1: Write the failing adversarial parser + SM6 tests**

```swift
// Add to Tests/GohCoreTests/EdgeTransportTests.swift:

@Test("SM6(a): verify block rejects cert with mismatched hostname")
func sm6VerifyBlockRejectsMismatch() async throws {
    // Uses the spike-confirmed rejection error code.
    // Connects to an IP with a certificate for a DIFFERENT hostname.
    // This test may need a local test server (see P5 runbook).
    // Stub: assert the verify block setup compiles and throws on mismatch.
    // Full end-to-end proof is the SM5b benchmark spike.
    let transport = EdgeTransport(hostname: "real.example.com", edgeIP: "192.0.2.1", port: 443)
    do {
        _ = try await transport.rangeGet(path: "/test", range: ByteInterval(start: 0, length: 1024))
        Issue.record("SM6(a): expected verify block rejection, got success")
    } catch let error as GohError {
        // Accept tlsFailure or connectionFailed (both indicate rejection).
        #expect(error.code == .tlsFailure || error.code == .connectionFailed)
    }
}

@Test("EdgeTransport HTTP/1.1 parser: rejects oversized headers")
func parserRejectsOversizedHeaders() {
    // Adversarial parser test: headers beyond 16 KiB must be rejected.
    let oversized = String(repeating: "X-Garbage: " + String(repeating: "A", count: 1000) + "\r\n",
                           count: 20)
    let fakeResponse = "HTTP/1.1 206 Partial Content\r\n" + oversized + "\r\n"
    let result = EdgeHTTP11Parser.parse(response: Data(fakeResponse.utf8), maxHeaderBytes: 16384)
    #expect(result == nil)
}

@Test("EdgeTransport HTTP/1.1 parser: rejects Content-Length beyond requested range")
func parserRejectsOversizedContentLength() {
    let fakeResponse = """
        HTTP/1.1 206 Partial Content\r\n\
        Content-Range: bytes 0-99/1000\r\n\
        Content-Length: 999999\r\n\r\n
        """
    // Requested range was 0–99 (100 bytes). Content-Length 999999 must be rejected.
    let result = EdgeHTTP11Parser.parse(response: Data(fakeResponse.utf8),
                                        maxHeaderBytes: 16384,
                                        requestedRange: ByteInterval(start: 0, length: 100))
    #expect(result == nil)
}

@Test("EdgeTransport HTTP/1.1 parser: accepts valid 206 response")
func parserAcceptsValid206() {
    let fakeResponse = """
        HTTP/1.1 206 Partial Content\r\n\
        Content-Range: bytes 0-99/1000\r\n\
        Content-Length: 100\r\n\r\n
        """
    let result = EdgeHTTP11Parser.parse(response: Data(fakeResponse.utf8),
                                        maxHeaderBytes: 16384,
                                        requestedRange: ByteInterval(start: 0, length: 100))
    #expect(result != nil)
    #expect(result?.contentLength == 100)
}
```

- [ ] **Step 2: Run tests to verify they fail**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "EdgeTransport\|sm6"
  ```

  Expected: FAIL — `cannot find type 'EdgeTransport' in scope`, `cannot find type 'EdgeHTTP11Parser' in scope`.

- [ ] **Step 3: Write implementation** (`EdgeTransport.swift`)

The implementation must:

1. Define `EdgeHTTP11Parser` as a pure static method with bounded header parsing.
2. Define `EdgeTransport` with `NWConnection<NWProtocolTLS>`:
   - Set SNI: `sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, hostname)`.
   - Install verify block: `sec_protocol_options_set_verify_block(opts, { trust, complete in ... }, queue)` that runs `SecPolicyCreateSSL(true, hostname as CFString)`, sets revocation policy `kSecRevocationRequirePositiveResponse`, evaluates trust, and calls `complete(isValid)`.
   - Hand-roll HTTP/1.1 `GET \(path) HTTP/1.1\r\nHost: \(hostname)\r\nRange: bytes=\(range.start)-\(range.end-1)\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n`.
   - Parse the `206` response via `EdgeHTTP11Parser`.
   - Write body bytes only within the worker's assigned `ByteInterval`.
3. The `multiEdgeEnabled` constant guard: `EdgeTransport` is only instantiated when `DownloadEngine.multiEdgeEnabled` is `true`.

**Cross-SDK safety note:** `sec_protocol_options_set_tls_server_name` and `sec_protocol_options_set_verify_block` are confirmed `[VERIFIED API]` in the spec. If any C-bridged pointer parameter has optionality skew between SDK 26.2 and 26.5, unwrap to a non-optional via `UnsafePointer` (same pattern as the CLAUDE.md `xpc_dictionary_set_data` gotcha).

```swift
// Sources/GohCore/Engine/EdgeTransport.swift (skeleton — agentic worker writes the full body)
import Foundation
import Network
import Security

// MARK: — HTTP/1.1 parser (bounded, adversarially hardened)

public struct EdgeHTTP11ParseResult: Sendable {
    public var statusCode: Int
    public var contentRange: ByteInterval?
    public var contentLength: UInt64?
}

public struct EdgeHTTP11Parser: Sendable {
    public static func parse(
        response: Data,
        maxHeaderBytes: Int,
        requestedRange: ByteInterval? = nil
    ) -> EdgeHTTP11ParseResult? {
        // 1. Find \r\n\r\n header boundary; reject if beyond maxHeaderBytes.
        // 2. Parse status line: "HTTP/1.1 206 ..."
        // 3. Parse Content-Range and Content-Length headers.
        // 4. Reject if Content-Length > requestedRange.length.
        // 5. Return nil for any parse error.
        // (Full implementation by agentic worker.)
        return nil  // placeholder
    }
}

// MARK: — NWConnection HTTP/1.1 edge client

/// A hand-rolled HTTP/1.1 range GET client over NWConnection<TLS> with:
/// - SNI set to the hostname (not the IP) via sec_protocol_options_set_tls_server_name.
/// - Hostname-pinned trust via sec_protocol_options_set_verify_block.
/// - Revocation hard-fail via kSecRevocationRequirePositiveResponse.
///
/// This type is only instantiated when DownloadEngine.multiEdgeEnabled is true,
/// which is false until P5 ships and its security review passes.
public struct EdgeTransport: Sendable {
    public let hostname: String
    public let edgeIP: String
    public let port: Int

    public init(hostname: String, edgeIP: String, port: Int = 443) {
        self.hostname = hostname
        self.edgeIP = edgeIP
        self.port = port
    }

    /// Issues a ranged GET for `range` at `path`. Returns raw body bytes.
    /// SM6: rejects certs that don't validate against `hostname`.
    public func rangeGet(path: String, range: ByteInterval) async throws -> Data {
        // Full implementation by agentic worker — see spec §7.1/§7.2 and
        // the spike-confirmed NWError code for the SM6(a) assertion.
        throw GohError(code: .connectionFailed, message: "EdgeTransport not yet implemented")
    }
}
```

- [ ] **Step 4: Add revocation-policy + hostname-policy installation unit test (Advisory — constructable without a live revoked cert)**

```swift
// Add to Tests/GohCoreTests/EdgeTransportTests.swift:

@Test("SM6 prerequisite: verify block installs revocation hard-fail and hostname policy")
func sm6VerifyBlockInstallsRevocationAndHostnamePolicy() throws {
    // This test asserts that the verify block SETUP code (as extracted from EdgeTransport)
    // installs both kSecRevocationRequirePositiveResponse and SecPolicyCreateSSL(true, hostname)
    // on the SecTrust object it evaluates. It does NOT require a live revoked cert.
    //
    // The implementation must expose a testable helper:
    //   static func makeTrustPolicies(hostname: String) -> [SecPolicy]
    // That returns both policies. The test verifies:
    //   1. Count is 2 (SSL + revocation).
    //   2. One policy is the SSL hostname policy (created with SecPolicyCreateSSL).
    //   3. One policy is the revocation policy with kSecRevocationRequirePositiveResponse.
    //
    // This ensures a future refactor cannot silently drop hard-fail revocation while
    // keeping the verify block stub that makes SM6(a)/(b) pass.

    let hostname = "example.com"
    let policies = EdgeTransport.makeTrustPolicies(hostname: hostname)
    #expect(policies.count == 2,
            "Expected 2 policies (SSL + revocation); got \(policies.count)")

    // Extract policy properties and verify revocation flag.
    let policyProps = policies.compactMap { SecPolicyCopyProperties($0) as? [String: Any] }
    let hasRevocation = policyProps.contains { dict in
        // kSecPolicyOid for revocation is "1.2.840.113635.100.1.26".
        guard let oid = dict["SecPolicyOid"] as? String else { return false }
        return oid == "1.2.840.113635.100.1.26"
    }
    #expect(hasRevocation, "Revocation policy (kSecRevocationRequirePositiveResponse) must be installed")

    let hasSSL = policyProps.contains { dict in
        guard let oid = dict["SecPolicyOid"] as? String else { return false }
        // SSL policy OID is "1.2.840.113635.100.1.3" (TLS server).
        return oid == "1.2.840.113635.100.1.3"
    }
    #expect(hasSSL, "SSL hostname policy (SecPolicyCreateSSL(true, hostname)) must be installed")
}
```

Add the required helper to `EdgeTransport.swift`:
```swift
// In EdgeTransport (public, for testability):
public static func makeTrustPolicies(hostname: String) -> [SecPolicy] {
    let sslPolicy = SecPolicyCreateSSL(true, hostname as CFString)
    let revocationPolicy = SecPolicyCreateRevocation(kSecRevocationRequirePositiveResponse
                                                     | kSecRevocationCheckIfTrusted)
    return [sslPolicy, revocationPolicy].compactMap { $0 }
}
```

The verify block in `rangeGet` must call `makeTrustPolicies(hostname:)` and apply all returned
policies to the `SecTrust` via `SecTrustSetPolicies`. This is the structural invariant the test
enforces — a refactor that inlines the policies differently will break the test.

- [ ] **Step 5: Run parser + revocation-policy tests**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "EdgeHTTP11Parser\|parserRejects\|parserAccepts\|sm6VerifyBlockInstalls"
  ```

  Expected: PASS — parser tests and revocation-policy test pass (SM6(a)/(b) network tests may skip without a test server).

- [ ] **Step 6: Commit**

  ```
  git add Sources/GohCore/Engine/EdgeTransport.swift Tests/GohCoreTests/EdgeTransportTests.swift
  git commit -m "feat(p5): EdgeTransport NWConnection HTTP/1.1 client + hostname-pinned TLS + adversarial parser"
  ```

---

### Task 23: Multi-Edge Fan-Out in the Governor + Engine

**Files:** Modify `Sources/GohCore/Governor/ParallelismGovernor.swift` · Modify `Sources/GohCore/Engine/DownloadEngine.swift`

**Pre-task reads:**
- [ ] `Sources/GohCore/Governor/ParallelismGovernor.swift` — `candidateAbove` and `decide` logic.
- [ ] Spec §7.1 — cap at `(distinct IPs × small factor)`, global 16 ceiling, per-host budget.

What changes:
- `ParallelismGovernor` gains a `maxWorkers` parameter (default: 16; for multi-edge, `min(distinctIPs × factor, 16, budget)`.
- `DownloadEngine.fetchRanged` checks `DownloadEngine.multiEdgeEnabled`; if true and `distinctIPs > 1`, instantiates `EdgeTransport` workers for non-primary chunks.
- Cross-edge content identity gate: if an edge returns a different ETag/Last-Modified than the primary, it is dropped.

- [ ] **Step 1 through 5:** TDD as per all prior tasks. Write failing tests for the governor's per-edge budget cap, then implement. Tests are unit-level (mock edges, no live CDN required).

- [ ] **Step 5: Commit**

  ```
  git add Sources/GohCore/Governor/ParallelismGovernor.swift Sources/GohCore/Engine/DownloadEngine.swift
  git commit -m "feat(p5): multi-edge fan-out in governor + engine (dormant behind multiEdgeEnabled)"
  ```

---

### Task 24: Security + Transport Review Gate

**Files:** No code changes. This is a mandatory review gate before P5 merge.

- [ ] **Step 1: Trigger security review**

  Use the `security-review` skill against the P5 changes:
  ```
  /security-review
  ```

  The review must cover:
  - `EdgeTransport.rangeGet`: verify block correctness (SNI hostname, `SecPolicyCreateSSL`, revocation).
  - `EdgeHTTP11Parser`: adversarial inputs (fuzzing style), content-length bounds, status-line injection.
  - `EdgeIPResolver`: DNS-poisoned IP handling (neutralized by verify block — confirm).
  - `ConnectionBudget`: race-free under concurrent downloads.

- [ ] **Step 2: Address all security findings before proceeding**

  Any finding that could allow a MITM, cert bypass, or body overflow is a blocker.
  No P5 merge until all security findings are addressed.

- [ ] **Step 3: DESIGN.md §Transport revision**

  Following review approval, update DESIGN.md §Transport with:
  - The NWConnection HTTP/1.1 range client addition for multi-edge IP-pinned connections.
  - The SNI-override rationale.
  - The hostname-pinned verify block and the DNS-poisoning safety argument.
  - Confirmation that URLSession remains the default for all non-edge fetches.
  - The "Considered alternatives" note: URLSession rejected for IP-pinned connections (no SNI override for IP; DevForums confirmed).

  ```
  git add DESIGN.md
  git commit -m "docs(design): §Transport revision — NWConnection HTTP/1.1 edge path + security argument (spec §15 P5)"
  ```

---

### Task 25: SM6 Verification + SM5b Benchmark Attempt + P5 Artifact

- [ ] **Step 1: Verify SM6 (TLS safety)**

  Run the SM6 unit tests from Task 22:
  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "sm6\|EdgeTransport"
  ```

  Expected: PASS for all three SM6 assertions (wrong cert rejected; valid cert accepted; revoked cert rejected).

- [ ] **Step 2: Attempt SM5b (multi-edge win)**

  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift run goh-bench lfn \
    --url https://speed.cloudflare.com/__down?bytes=1073741824 \
    --runs 5 --multi-edge --output multi-edge.json
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift run goh-bench lfn \
    --url https://speed.cloudflare.com/__down?bytes=1073741824 \
    --runs 5 --output single-edge.json
  ```

  Accept: multi-edge median > single-edge governed median.
  If no multi-edge target can be sourced: report SM5b unproven. Slice ships on SM5a. Do not fabricate.

- [ ] **Step 3: Write P5 artifact + update `multiEdgeEnabled` to `true` if all gates pass**

  Write `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase5.md` with:
  - Spike result (pass/fail)
  - SM6 assertion values (exact NWError codes)
  - SM5b result (proven / unproven)
  - Security review findings and disposition

- [ ] **Step 4: Commit**

  ```
  git add docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase5.md \
          Sources/GohCore/Engine/DownloadEngine.swift   # multiEdgeEnabled = true
  git commit -m "feat(p5): enable multi-edge fan-out — SM6 verified, SM5b result documented"
  ```

---

## End-of-Feature Gate

Before creating the PR:

- [ ] Run the full test suite one final time:
  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  ```
  Expected: all tests pass, zero warnings.

- [ ] Verify all format invariants are unchanged:
  - `protocolVersion` still 3 in `CommandCoding.swift` or equivalent.
  - `JobCatalog.version` still 1.
  - `JobSummary` wire shape: no field added/renamed/removed.
  - `host-scheduling.plist` decoded value unchanged (run existing golden-fixture test).

- [ ] Confirm DESIGN.md has been updated for all three §15 items:
  - §Transport (P5)
  - §Persistence / §Adaptive host scheduling (P3)
  - §Observability (P3)

- [ ] Use `superpowers:verification-before-completion` before claiming done.

---

## Spots Where the Spec Left Implementation Details Genuinely Open

The following details are underspecified in the spec and will require judgment calls by the agentic worker during implementation. These are surfaced here for reviewer scrutiny:

1. **Governor `decide()` call cadence.** The spec says the governor runs on "chunk inter-arrival timing at the flush() chokepoint" but does not specify whether `decide()` is called after every flush (per-worker, high frequency), after every worker reap (per-worker-completion, lower frequency), or on a timer. The plan uses "after each worker reap" as the primary cadence, with `record(sample:)` called at every flush. If the cadence is wrong, the governor may be too slow to respond to regime changes. This is the single most empirically uncertain implementation choice.

2. **Binary-search refinement N.** The spec mentions "an optional single binary-search step between last-good and overshoot may set the operating N to a non-candidate value (e.g. 6)." The P1 governor does not implement binary search — it only commits to the last candidate level before the knee. The binary-search refinement is an enhancement left for post-P1 tuning if the governor's operating point is consistently one step above optimal.

3. **Governor N₀ from explicit `--connections N` — RESOLVED.** The mechanism is an ephemeral daemon-side `Mutex<[UInt64: UInt8]>` table (jobID → explicit N) populated by `CommandDispatcher` when `selectionReason == .explicit` and consumed (removeValue) by the `scheduleJob` closure before calling `engine.run(jobID:in:explicitConnectionCount:)`. This is wire-safe (no `JobSummary` field changes), does not require `SelectionReason` to be plumbed to the engine, and produces `GovernorOutcome.governorOff` on the governor-off path. The exact signatures are specified in Task 12. A unit test in Task 12 asserts that `effectiveN == nil` when `explicitConnectionCount` is non-nil.

4. **Cruise re-probe on throttle recovery.** The spec says "the governor holds throttled hosts pinned low for the session" but does not specify the session scope (daemon restart vs download restart). The plan pins for the lifetime of the `ParallelismGovernor` instance, which is per-download — so each new download gets a fresh governor and can re-probe. This is conservative and correct but may mean a throttle-triggered host stays pinned for the rest of a single large download only, not across downloads.

5. **SM6 revocation test target.** The spec says SM6(c) ("revoked cert rejected") is proven against the "actual error surfaced by the verify block's rejection, captured during the P5 spike." The plan defers the exact assertion value to the spike. If the verify block cannot be triggered against a known-revoked cert in a unit test (requires a test CA setup), SM6(c) may remain a manual spike result rather than an automated test.
