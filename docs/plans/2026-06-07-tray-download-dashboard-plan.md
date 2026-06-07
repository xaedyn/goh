---
date: 2026-06-07
feature: tray-download-dashboard
REQUIRED_SKILL: superpowers:subagent-driven-development
Goal: Fix the no-row collapse bug and the climbing-speed metric; add a professional download dashboard — a compact glanceable popover and a full Downloads window with rich per-download rows, completed/failed retained with verify status.
Architecture: Approach A — "Engine-true speed, dashboard window" (THE BET: a windowed rate in the engine's hot path is safe — the governor is independent — and is worth the consistency). RollingRateSampler in GohCore threaded to all six progress() call sites in DownloadEngine; enriched GohMenuJobRow + GohMenuPresenter in GohMenuBar; DownloadsWindowView + Window(id:"downloads") in goh-menu.
Tech Stack: Swift 6.2/6.3.x toolchain, SwiftPM, macOS 26.0+, SwiftUI+AppKit (MenuBarExtra(.window) + Window scenes), GohCore (nonisolated default), GohMenuBar (.defaultIsolation MainActor), Swift Testing. CI: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build/swift test on macos-26, -warnings-as-errors.
---

# Implementation Plan — Professional Download Dashboard (tray)

## Acceptance criteria map

| AC | Description | Owning task(s) |
|----|-------------|----------------|
| AC1 | ≥1 download in any state → one visible row with non-zero height; "N active" header matches visible rows | T5, T6 |
| AC2 | Speed = 5-second rolling window, not cumulative average; stabilizes near true rate, drops on stall | T1, T2 |
| AC3 | Each row: progress bar, downloaded/total + %, rolling speed, ETA (when total known), elapsed, connection count | T3, T4, T6 |
| AC4 | Completed + failed rows stay (daemon already retains them); completed shows size + finished-at + verify status | T4, T6 |
| AC5 | protocolVersion and JobProgress/JobSummary wire shapes unchanged; BBR governor sampling untouched; suite green | T1, T2, T5 |

## Bet check (THE BET)

> "A windowed rate in the engine's hot path is safe (governor independent) and worth the consistency."
>
> The governor's ByteCounter is a separate `Mutex<UInt64>` inside `consumeRange`'s `trace.timed(.report){}` block (lines 786–826). The sampler is created per-`run()`, passed through to `download()` and `resume()` as siblings, and called at every `Self.progress(...)` site. It is Mutex-guarded and monotonic-guarded — concurrent TaskGroup workers calling it with out-of-order cumulative counts produce no underflow trap and no data race. Approach B (menu-side) was the research recommendation but Approach A was the user's chosen bet; the plan references and validates THE BET throughout.

## Critical regression gate (P1, highest-risk tasks)

**T2 (threading the sampler) MUST leave all 6 progress() sites, the governor's ByteCounter block (lines 786–826), and `JobProgress` field shapes byte-identical on the wire.** Gate: ALL of the following must pass UNCHANGED after T2:
- All existing `DownloadEngineTests` (including SM3 tests `flushEmitsRateSamples` and `injectedClockAccepted`)
- `GohMenuPresenterTests` (all existing assertions; `aggregateSpeedText == "2.9 KB/s"` remains valid because bytesPerSecond is still a UInt64 on the snapshot and the test seeds it directly)
- `GohCommandLineTests.lsFormatsJobTable` (asserts `"2 KB/s"` from a seeded bytesPerSecond: 2048 — this is a stub/seed, not a live-rate assertion, so it remains unchanged)
- `GohTUITests.topDashboardRows` (similarly seeded, unchanged)
- Full suite green (`swift test`)

## Speed-assertion audit (verified in Phase 0 reads)

The following tests seed `bytesPerSecond` directly in a `JobProgress` stub — they do NOT compute the value from a live engine run, so they are NOT pinning the rate algorithm and require no change:
- `GohCommandLineTests.lsFormatsJobTable` — seeds `bytesPerSecond: 2048`, asserts `"2 KB/s"` on display
- `GohTUITests.topDashboardRows` — seeds `bytesPerSecond: 2_048`, asserts `"2 KB/s"` in table
- `GohTUITests.topDashboardKeepsLongColumnsSeparated` — seeds `bytesPerSecond: 123_456_789`, display-only
- `GohMenuPresenterTests.summarizesActiveDownloadsAndAggregateSpeed` — seeds `speed: 1000` + `speed: 2000`, asserts aggregate display `"2.9 KB/s"`

None assert a live-computed engine rate. No test changes are required for these.

## Phase structure

> 7 tasks → 3 phases segmented at deployment-independence boundaries.
> Phase artifacts: `docs/superpowers/progress/2026-06-07-tray-download-dashboard-phase{1,2,3}.md`

- **Phase 1 (Tasks 1–2):** GohCore — `RollingRateSampler` (CREATE) + thread it through `DownloadEngine`'s six `Self.progress()` sites (MODIFY). Independently shippable; fixes the speed metric everywhere (CLI + tray). Regression gate lives here.
- **Phase 2 (Tasks 3–4):** GohMenuBar value layer — enrich `GohMenuJobRow` + `GohMenuState` (MODIFY models) + presenter populates new fields, ETA/elapsed/connections/verify-map (MODIFY presenter). Pure/unit-tested with stubs.
- **Phase 3 (Tasks 5–7):** UI + wiring — fix popover collapse + "Downloads…" button (MODIFY GohMenuView); `DownloadsWindowView` rich dashboard (CREATE); `Window(id:"downloads")` scene + root in main.swift (MODIFY). Build-validated + manual smoke note.

---

## Phase 1 — GohCore: rolling-rate sampler (Tasks 1–2)

### Task 1 — CREATE `Sources/GohCore/Engine/RollingRateSampler.swift`

**Files**
- CREATE `Sources/GohCore/Engine/RollingRateSampler.swift`
- CREATE `Tests/GohCoreTests/RollingRateSamplerTests.swift`

**AC ownership:** AC2 (windowed rate, warm-up, stall-decay), AC5 (no governor touch)

**THE BET reference:** The sampler is the crash-proof load-bearing piece that makes engine-side rate safe: Mutex exclusion + monotonic guard (drops regressing samples from concurrent workers) + saturating subtraction (no UInt64 underflow). Without all three, Approach A would be unsafe.

**Pre-task reads (completed in Phase 0)**
- `Sources/GohCore/Engine/DownloadEngine.swift` lines 1–26 — `ByteCounter` Mutex-in-final-class pattern to mirror exactly.
- `Sources/GohCore/Engine/DownloadEngine.swift` line 77 — `minGovernorSampleSeconds = 0.25` exists; sampler's `warmupInterval` uses its own constant, does NOT reuse this name (no implied coupling).

**Step 1 — Failing tests**

File: `Tests/GohCoreTests/RollingRateSamplerTests.swift` (CREATE)

Write Swift Testing stubs that compile but fail (`#expect(Bool(false), "not yet implemented")`):

- [ ] `@Test("windowed rate reflects only recent bytes, not cumulative average")` — AC2 owner. Feed a synthetic sequence where early bytes are large (high cumulative) but recent bytes are sparse (low window rate); assert the returned rate is close to the recent window delta, not the cumulative average. Use `ContinuousClock.Instant` + `.advanced(by:)` for deterministic instants.
- [ ] `@Test("returns zero during warm-up (fewer than 2 in-order samples or span < warmupInterval)")` — AC2 owner. Call `record(...)` once; assert return is 0. Then call again within warmupInterval; assert still 0.
- [ ] `@Test("rate decays to zero when samples age out of window (stall)")` — AC2 owner. Feed N samples over T seconds, then stop. Advance time past the window; call `record(...)` with the same bytesCompleted (no new bytes). Assert rate returns 0.
- [ ] `@Test("evicts samples older than the window duration")` — AC2. Feed samples at t=0..5s, then feed a new sample at t=6s. Assert the 0s sample is evicted and the rate reflects only the kept window.
- [ ] `@Test("out-of-order or regressing bytesCompleted sample is ignored, not a trap")` — AC2 + AC5 crash-safety. Feed a valid sample at t=1s with bytesCompleted=1000, then feed a regressing sample at t=2s with bytesCompleted=500. Assert: no crash/trap, returned rate is sane (either 0 during warmup or reflects the first sample only), subsequent in-order sample at t=3s with bytesCompleted=1500 produces a positive rate.

**Step 2 — Implementation**

File: `Sources/GohCore/Engine/RollingRateSampler.swift` (CREATE)

```swift
import Foundation
import Synchronization

/// Per-job rolling-rate sampler. Thread-safe: Mutex-guarded.
/// Crash-safe for concurrent ranged workers: monotonic guard drops
/// regressing bytesCompleted samples; saturating subtraction prevents
/// UInt64 underflow. No stored clock — each call site passes its own
/// clock.now so windowing is internally consistent.
final class RollingRateSampler: @unchecked Sendable {

    private struct Sample {
        let instant: ContinuousClock.Instant
        let bytesCompleted: UInt64
    }

    private struct State {
        var samples: [Sample] = []
        var lastStoredBytes: UInt64 = 0
    }

    private let state: Mutex<State>
    private let window: Duration
    private let warmupInterval: Duration

    init(
        window: Duration = .seconds(5),
        warmupInterval: Duration = .milliseconds(250)
    ) {
        self.state = Mutex(State())
        self.window = window
        self.warmupInterval = warmupInterval
    }

    /// Record the latest cumulative byte count at `now`; return the
    /// windowed rate (bytes/sec). Returns 0 during warm-up.
    func record(bytesCompleted: UInt64, now: ContinuousClock.Instant) -> UInt64 {
        state.withLock { s in
            // Append ONLY monotonic samples (drop regressing/out-of-order → crash-safe).
            if bytesCompleted > s.lastStoredBytes || s.samples.isEmpty {
                s.lastStoredBytes = bytesCompleted
                s.samples.append(Sample(instant: now, bytesCompleted: bytesCompleted))
            }
            // ALWAYS evict samples older than the window — on EVERY call, including a
            // stall where no new sample was appended. This is what makes the rate decay
            // toward 0 as the window empties (the round-1 review caught the bug where
            // eviction lived only in the append branch, so a stall froze the rate).
            let cutoff = now - window
            s.samples.removeAll { $0.instant < cutoff }
            return rate(from: s, upTo: now)
        }
    }

    private func rate(from s: State, upTo now: ContinuousClock.Instant) -> UInt64 {
        guard s.samples.count >= 2 else { return 0 }
        let oldest = s.samples.first!
        let newest = s.samples.last!
        // Span from the oldest kept sample UP TO `now` (not to the newest sample), so a
        // stall — `now` advancing with no new bytes — decays the rate smoothly toward 0
        // (denominator grows while numerator is fixed) before the window fully empties.
        let span = oldest.instant.duration(to: now)
        guard span >= warmupInterval else { return 0 }
        // Saturating subtraction — never underflows (monotonic samples guarantee >=, but
        // keep the guard as defense-in-depth).
        let deltaBytes = newest.bytesCompleted >= oldest.bytesCompleted
            ? newest.bytesCompleted - oldest.bytesCompleted : 0
        let seconds = Double(span.components.seconds)
            + Double(span.components.attoseconds) / 1e18
        guard seconds > 0 else { return 0 }
        return UInt64(Double(deltaBytes) / seconds)
    }
}
```

Key invariants to verify in implementation:
- `@unchecked Sendable` (Mutex-guarded internal state, same as ByteCounter)
- `warmupInterval` constant is local — does NOT reference `DownloadEngine.minGovernorSampleSeconds`
- `state.withLock` is the only mutation path
- Monotonic guard: `bytesCompleted > s.lastStoredBytes` drops regressing samples AND allows the first sample (empty array branch)
- Saturating subtraction: `newest.bytesCompleted >= oldest.bytesCompleted ? newest - oldest : 0`

**Step 3 — Gate**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RollingRateSamplerTests
```

All 5 `RollingRateSamplerTests` pass. Full suite: `swift test` — zero regressions.

---

### Task 2 — MODIFY `Sources/GohCore/Engine/DownloadEngine.swift` — thread sampler to all 6 sites

**Files**
- MODIFY `Sources/GohCore/Engine/DownloadEngine.swift`

**AC ownership:** AC2 (rolling rate at engine), AC5 (governor untouched, wire shape unchanged)

**THE BET reference:** The six progress() call sites span three paths (resume, single, ranged). THE BET holds because: (a) the governor's ByteCounter block (lines 786–826) is untouched, (b) `RollingRateSampler` is `@unchecked Sendable` so it captures safely into concurrent TaskGroup worker closures, (c) the monotonic guard + saturating subtraction make out-of-order calls from concurrent workers safe.

**Pre-task reads (completed in Phase 0)**
- Lines 168–224: `run(job:)` — the branch point to `resume(...)` and `download(...)`. Sampler is created HERE, passed to both.
- Lines 355–399: `resume(...)` signature — receives the sampler as a new param. Progress sites at lines 393–394 (final progress before `complete(...)`) and inside `downloadResumeRange` at lines 438–443.
- Lines 483–560: `fetchSingle(...)` — progress sites at lines 525–528 (in-flight) and 553–555 (final). Clock is a `ContinuousClock()` local.
- Lines 562–893: `fetchRanged(...)` — clock is injected param (line 571). Progress sites: line 884–885 (final, post-assembly), and inside `consumeRange` at lines 979–982 (in the `trace.timed(.report){}` block — the ranged concurrent worker site).
- Lines 1040–1047: `static func progress(completed:total:elapsed:)` — compute rate from elapsed; this is REPLACED at call sites by the sampler. The static func can be kept or removed; the minimal diff is: keep the static func but ignore its rate, OR replace its rate computation. Minimal-diff: keep the static func, add a sampler overload `progress(completed:total:sampler:now:)` — but this doubles the API. Cleaner minimal diff: keep the static func for any remaining callers; at each of the 6 sites, call `Self.progress(completed: ..., total: ..., elapsed: ...)` then overwrite `bytesPerSecond` with `sampler.record(...)`. This requires zero signature change to the static func.

**Step 1 — No failing test needed** (existing DownloadEngineTests are the gate; the sampler unit tests from T1 cover AC2 correctness)

**Step 2 — Implementation changes**

Change 1: In `run(job:)`, create one `RollingRateSampler` and pass it to both branches:

```swift
// Inside run(job:), after guard let job = ...:
let sampler = RollingRateSampler()
if let checkpointStore, let checkpoint = ... {
    try await resume(
        job: job, checkpoint: checkpoint, checkpointStore: checkpointStore,
        store: store, trace: EngineDiagnostics(), sampler: sampler)
} else {
    try await download(
        job: job, store: store, trace: EngineDiagnostics(),
        explicitConnectionCount: explicitConnectionCount, sampler: sampler)
}
```

Change 2: Update `resume(...)` signature to accept `sampler: RollingRateSampler`, thread to `downloadResumeRange(...)`, and use sampler at the final progress site (line 393–394):

```swift
// Line 393–394 (final progress before complete):
var p = Self.progress(completed: total, total: total, elapsed: clock.now - started)
p.bytesPerSecond = sampler.record(bytesCompleted: total, now: clock.now)
_ = try store.recordProgress(id: job.id, p)
```

And pass `sampler` to `downloadResumeRange`; inside `downloadResumeRange`, at the flush site (lines 438–443):

```swift
// Replace the Self.progress(...) call in flush():
var p = Self.progress(
    completed: completedBeforeRange + written, total: total, elapsed: clock.now - started)
p.bytesPerSecond = sampler.record(
    bytesCompleted: completedBeforeRange + written, now: clock.now)
recordProgress(store: store, jobID: job.id, p)
```

Change 3: Update `download(...)` signature to accept `sampler: RollingRateSampler`, thread to `fetchSingle(...)` and `fetchRanged(...)`.

Change 4: In `fetchSingle(...)`, at the two progress sites (lines 525–528 and 553–555):

```swift
// In-flight site (lines 525-528):
var p = Self.progress(completed: completed, total: total, elapsed: clock.now - started)
p.bytesPerSecond = sampler.record(bytesCompleted: completed, now: clock.now)
_ = try store.recordProgress(id: job.id, p)

// Final site (lines 553-555):
var p = Self.progress(completed: completed, total: total, elapsed: clock.now - started)
p.bytesPerSecond = sampler.record(bytesCompleted: completed, now: clock.now)
_ = try store.recordProgress(id: job.id, p)
```

Change 5: In `fetchRanged(...)`, thread `sampler` to `consumeRange(...)` (and `downloadRange(...)` which calls `consumeRange`). Update the final progress site (line 884–885):

```swift
// Final site (line 884-885):
var p = Self.progress(completed: total, total: total, elapsed: clock.now - started)
p.bytesPerSecond = sampler.record(bytesCompleted: total, now: clock.now)
_ = try store.recordProgress(id: job.id, p)
```

Change 6: In `consumeRange(...)` at the ranged concurrent worker site (lines 979–982, inside `trace.timed(.report){}`), pass sampler through `consumeRange`'s signature and `downloadRange`'s signature:

```swift
// Inside trace.timed(.report){}:
let overall = bytesWritten.add(pieceLength)
var p = Self.progress(completed: overall, total: total, elapsed: clock.now - started)
p.bytesPerSecond = sampler.record(bytesCompleted: overall, now: clock.now)
recordProgress(store: store, jobID: job.id, p)
```

**Do NOT touch** the governor block (lines 786–826): `lastSampledTotal`, `lastSampledAt`, `bytesWritten.value`, `bps`, `governor.record(...)`, `governor.decide(...)`.

**Step 3 — Gate**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

All existing tests pass (zero regressions). The `aggregateSpeedText == "2.9 KB/s"` assertion in `GohMenuPresenterTests` passes because the test seeds `bytesPerSecond` directly — it does not call the engine.

---

## Phase 2 — GohMenuBar value layer (Tasks 3–4)

### Task 3 — MODIFY `Sources/GohMenuBar/GohMenuModels.swift` — enrich GohMenuJobRow

**Files**
- MODIFY `Sources/GohMenuBar/GohMenuModels.swift`

**AC ownership:** AC3 (rich field availability), AC4 (completed verifyStatus)

**Pre-task reads (completed in Phase 0)**
- `Sources/GohMenuBar/GohMenuModels.swift` — `GohMenuJobRow` (nonisolated public struct ... : Sendable, Equatable, Identifiable); `GohMenuState`.

**Step 1 — No standalone failing test** (fields are exercised by T4's presenter tests)

**Step 2 — Implementation**

Add to `GohMenuJobRow` (inside the existing struct body, following existing field declarations):

```swift
// Rich dashboard fields — all nonisolated Sendable Equatable (same convention).
/// bytesCompleted/bytesTotal as a fraction [0,1]; nil when bytesTotal is nil.
public var progressFraction: Double?
/// Human-readable "downloaded / total" or "downloaded/?" when total unknown.
public var sizeText: String
/// "ETA Xs" string; nil when total unknown, rate warming, or job not active.
public var etaText: String?
/// Human-readable elapsed time since createdAt (rounded to seconds).
public var elapsedText: String?
/// "N connections" string; nil when actualConnectionCount is 0.
public var connectionText: String?
/// Verify/provenance status for completed rows; nil for other states or when
/// the ledger entry is absent/unreadable.
public var verifyStatus: String?
```

Update the `GohMenuJobRow` initializer to accept the new fields with nil defaults (for backward-compat in existing test factory functions).

**Step 3 — Gate**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Suite green. Existing `GohMenuPresenterTests` still pass (new fields are nil-defaulted until T4 populates them).

---

### Task 4 — MODIFY `Sources/GohMenuBar/GohMenuPresenter.swift` — populate rich fields

**Files**
- MODIFY `Sources/GohMenuBar/GohMenuPresenter.swift`
- MODIFY `Tests/GohMenuBarTests/GohMenuPresenterTests.swift` (add new @Test stubs then implementations)

**AC ownership:** AC3 (ETA/elapsed/connections), AC4 (completed verifyStatus via ledger join)

**Pre-task reads (completed in Phase 0)**
- `Sources/GohMenuBar/GohMenuPresenter.swift` — `row(for:)` method, `state(health:snapshots:clipboardURL:)` signature.
- `Sources/GohMenuBar/GohTrustModels.swift` — `ProvenanceReading.read() -> ProvenanceReadOutcome`; `ProvenanceReadOutcome` cases (`.absent`, `.entries([ProvenanceEntry])`, `.unreadable(...)`); `ProvenanceEntry.destinationPath`, `ProvenanceEntry.verifiedAt`.
- `Sources/GohCore/CLI/JobDisplayFormatter.swift` — `formatBytes(:)` and `progressText(:)` to reuse.

**Step 1 — Failing tests**

Add to `Tests/GohMenuBarTests/GohMenuPresenterTests.swift`:

```swift
// AC3: progressFraction is nil when bytesTotal is nil
@Test("progressFraction is nil when bytesTotal is nil")
func progressFractionNilWhenTotalUnknown() {
    let state = GohMenuPresenter().state(
        health: .connected,
        snapshots: [snapshot(id: 1, state: .active, completed: 500, total: nil, speed: 100)],
        clipboardURL: nil)
    #expect(state.rows[0].progressFraction == nil)
}

// AC3: ETA is nil when bytesTotal is nil (unknown total)
@Test("etaText is nil when bytesTotal is nil")
func etaTextNilWhenTotalUnknown() {
    let state = GohMenuPresenter().state(
        health: .connected,
        snapshots: [snapshot(id: 1, state: .active, completed: 500, total: nil, speed: 1000)],
        clipboardURL: nil)
    #expect(state.rows[0].etaText == nil)
}

// AC3: live speed / ETA only populated for .active jobs
@Test("etaText is nil for non-active (paused) jobs")
func etaTextNilForPausedJob() {
    let state = GohMenuPresenter().state(
        health: .connected,
        snapshots: [snapshot(id: 1, state: .paused, completed: 500, total: 1024, speed: 1000)],
        clipboardURL: nil)
    #expect(state.rows[0].etaText == nil)
}

// AC4: completed row gets verifyStatus "recorded" when ledger has entry without verifiedAt
@Test("completed row gets verifyStatus 'recorded' from ledger entry without verifiedAt")
func completedRowVerifyStatusRecorded() {
    let entry = ProvenanceEntry(
        url: "https://x.com/f.bin", sha256: "sha256:abc", size: 1024,
        downloadedAt: Date(timeIntervalSince1970: 0), destinationPath: "/tmp/1.iso", verifiedAt: nil)
    let outcome = ProvenanceReadOutcome.entries([entry])
    let state = GohMenuPresenter().state(
        health: .connected,
        snapshots: [snapshot(id: 1, state: .completed, completed: 1024, total: 1024, speed: 0,
                             destination: "/tmp/1.iso")],
        clipboardURL: nil,
        ledgerOutcome: outcome)
    #expect(state.rows[0].verifyStatus == "recorded")
}

// AC4: completed row gets verifyStatus "verified <date>" when ledger has entry with verifiedAt
@Test("completed row gets verifyStatus 'verified <date>' from ledger entry with verifiedAt")
func completedRowVerifyStatusVerified() {
    let verifiedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = ProvenanceEntry(
        url: "https://x.com/f.bin", sha256: "sha256:abc", size: 1024,
        downloadedAt: verifiedDate, destinationPath: "/tmp/2.iso", verifiedAt: verifiedDate)
    let outcome = ProvenanceReadOutcome.entries([entry])
    let state = GohMenuPresenter().state(
        health: .connected,
        snapshots: [snapshot(id: 1, state: .completed, completed: 1024, total: 1024, speed: 0,
                             destination: "/tmp/2.iso")],
        clipboardURL: nil,
        ledgerOutcome: outcome)
    #expect(state.rows[0].verifyStatus?.hasPrefix("verified") == true)
}

// AC4: completed row with no ledger entry → verifyStatus is nil (no error surfaced)
@Test("completed row with no ledger entry has nil verifyStatus")
func completedRowVerifyStatusNilWhenAbsent() {
    let state = GohMenuPresenter().state(
        health: .connected,
        snapshots: [snapshot(id: 1, state: .completed, completed: 1024, total: 1024, speed: 0)],
        clipboardURL: nil,
        ledgerOutcome: .absent)
    #expect(state.rows[0].verifyStatus == nil)
}
```

Note on the `snapshot` helper (in `GohMenuPresenterTests.swift`, currently `snapshot(id:state:completed:total:speed:)` with non-optional `total: UInt64`): **widen the existing helper in place — do not add a second overload** (an overload taking an optional `total` alongside the existing non-optional `total` is call-ambiguous when a test passes a literal). Two edits: change the param to `total: UInt64?` (passes straight through to `JobProgress.bytesTotal`, which is already `UInt64?`), and add a trailing `destination: String? = nil` that defaults to the current `"/tmp/\(id).iso"` (i.e. `destination: destination ?? "/tmp/\(id).iso"` in the `JobSummary` init). All existing call sites keep compiling unchanged. Also add a `ProvenanceEntry` import if needed (it's in GohCore).

**Step 2 — Implementation**

The presenter gains an optional `ledgerOutcome` param (injected for tests; nil by default — live code passes the outcome from a one-time `ProvenanceReading.read()` in the viewmodel, injected via `state(health:snapshots:clipboardURL:ledgerOutcome:)`).

```swift
// GohMenuPresenter.swift

nonisolated public struct GohMenuPresenter: Sendable {
    public init() {}

    public func state(
        health: GohMenuHealth,
        snapshots: [ProgressSnapshot],
        clipboardURL: URL?,
        ledgerOutcome: ProvenanceReadOutcome? = nil
    ) -> GohMenuState {
        // Build destination→ProvenanceEntry map from ledger (once, O(n)).
        let ledgerMap: [String: ProvenanceEntry]
        if let outcome = ledgerOutcome, case .entries(let entries) = outcome {
            ledgerMap = Dictionary(entries.map { ($0.destinationPath, $0) },
                                   uniquingKeysWith: { _, last in last })
        } else {
            ledgerMap = [:]
        }

        let jobs = snapshots.map(\.job).sorted { $0.id < $1.id }
        let activeJobs = jobs.filter { $0.state == .active }
        let aggregateSpeed = activeJobs.reduce(UInt64(0)) {
            $0 + $1.progress.bytesPerSecond
        }
        let healthCopy = copy(for: health)

        return GohMenuState(
            health: health,
            healthTitle: healthCopy.title,
            healthDetail: healthCopy.detail,
            activeCount: activeJobs.count,
            aggregateSpeedText: JobDisplayFormatter.formatBytes(aggregateSpeed) + "/s",
            primaryAction: primaryAction(
                clipboardURL: clipboardURL, recoveryAction: healthCopy.recovery),
            recoveryAction: healthCopy.recovery,
            rows: jobs.map { row(for: $0, ledgerMap: ledgerMap) })
    }

    private func row(for job: JobSummary, ledgerMap: [String: ProvenanceEntry]) -> GohMenuJobRow {
        let destinationURL = URL(filePath: job.destination)
        let title = destinationURL.lastPathComponent.isEmpty
            ? job.destination : destinationURL.lastPathComponent

        // progressFraction: nil when total unknown
        let progressFraction: Double? = job.progress.bytesTotal.map { total in
            total > 0 ? min(1.0, Double(job.progress.bytesCompleted) / Double(total)) : 1.0
        }

        // sizeText: reuse JobDisplayFormatter
        let sizeText = JobDisplayFormatter.progressText(job.progress)

        // ETA + speed: live only for .active
        let etaText: String?
        if job.state == .active,
           let total = job.progress.bytesTotal,
           job.progress.bytesPerSecond > 0
        {
            let remaining = total >= job.progress.bytesCompleted
                ? total - job.progress.bytesCompleted : 0
            let eta = remaining / job.progress.bytesPerSecond
            etaText = etaString(seconds: eta)
        } else {
            etaText = nil
        }

        // Elapsed: from createdAt to lastProgressAt (or completedAt for completed)
        let referenceDate: Date = job.completedAt ?? job.lastProgressAt ?? Date()
        let elapsedSeconds = max(0, referenceDate.timeIntervalSince(job.createdAt))
        let elapsedText: String? = elapsedSeconds > 0 ? elapsedString(seconds: elapsedSeconds) : nil

        // Connection count
        let connectionText: String? = job.actualConnectionCount > 0
            ? "\(job.actualConnectionCount) connection\(job.actualConnectionCount == 1 ? "" : "s")"
            : nil

        // Verify status: completed only, from ledger map
        let verifyStatus: String?
        if job.state == .completed, let entry = ledgerMap[job.destination] {
            if let verifiedAt = entry.verifiedAt {
                let formatted = DateFormatter.localizedString(
                    from: verifiedAt, dateStyle: .short, timeStyle: .none)
                verifyStatus = "verified \(formatted)"
            } else {
                verifyStatus = "recorded"
            }
        } else {
            verifyStatus = nil
        }

        return GohMenuJobRow(
            id: job.id,
            title: title,
            subtitle: job.destination,
            stateText: stateDisplay(for: job.state),
            progressText: sizeText,
            speedText: job.state == .active
                ? JobDisplayFormatter.formatBytes(job.progress.bytesPerSecond) + "/s"
                : "0 B/s",
            destination: job.destination,
            url: job.url,
            controls: controls(for: job),
            progressFraction: progressFraction,
            sizeText: sizeText,
            etaText: etaText,
            elapsedText: elapsedText,
            connectionText: connectionText,
            verifyStatus: verifyStatus)
    }

    private func etaString(seconds: UInt64) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    private func elapsedString(seconds: Double) -> String {
        let s = UInt64(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
    // ... existing copy(for:), stateDisplay(for:), controls(for:), primaryAction(...) unchanged
}
```

**Wire `ledgerOutcome` into the live viewmodel (REQUIRED — `loadTrustOverview()` does NOT already store it; it currently reads the outcome and discards it into `trustOverview`).** Three concrete edits to `GohMenuViewModel.swift` (read `loadTrustOverview()` ~lines 90-94 and `render(health:)` ~lines 186-191 first):
1. Add a stored property: `private var ledgerOutcome: ProvenanceReadOutcome? = nil`.
2. In `loadTrustOverview()`, **keep the existing off-main read** (`await Task.detached(priority: .utility) { reader.read() }.value` — do NOT replace it with a synchronous `reader.read()`, which would block the MainActor on disk I/O). Capture the raw outcome, store it, then re-render so completed rows pick up the verify status without waiting for the next snapshot. The current body is:
   ```swift
   public func loadTrustOverview() async {
       guard let reader = trustReader else { return }
       let outcome = await Task.detached(priority: .utility) { reader.read() }.value
       trustOverview = GohTrustPresenter().present(outcome).0
   }
   ```
   becomes:
   ```swift
   public func loadTrustOverview() async {
       guard let reader = trustReader else { return }
       let outcome = await Task.detached(priority: .utility) { reader.read() }.value
       self.ledgerOutcome = outcome                              // NEW: store the raw outcome
       trustOverview = GohTrustPresenter().present(outcome).0    // existing derivation
       render(health: state.health)                             // NEW: re-derive rows with the ledger now available
   }
   ```
   The `await` resumes on the MainActor (the type is MainActor-default), so `self.ledgerOutcome = …` and `render(…)` both run on-main — no off-main UI mutation. `render(health: state.health)` is the project's existing re-render idiom (see `refreshClipboard()`, which calls `render(health: state.health)` for the same "re-derive without a new snapshot" reason); there is no `lastHealth` property.
3. In `render(health:)`, pass it through: `presenter.state(health: health, snapshots: snapshots, clipboardURL: clipboardURL, ledgerOutcome: ledgerOutcome)`.
**Without these edits the live app always passes `ledgerOutcome == nil` and the verify badge silently never renders** (only the injected unit tests would pass). Timing note: `loadTrustOverview()` runs once off-main, so until it returns, completed rows render without a verify badge — acceptable; the explicit re-render in step 2 makes the badge appear as soon as the read completes.

**Step 3 — Gate**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohMenuPresenterTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

All new tests pass. Existing presenter tests pass unchanged.

---

## Phase 3 — UI + wiring (Tasks 5–7)

### Task 5 — MODIFY `Sources/GohMenuBar/GohMenuView.swift` — fix collapse + "Downloads…" button

**Files**
- MODIFY `Sources/GohMenuBar/GohMenuView.swift`

**AC ownership:** AC1 (rows visible — no collapse), AC5 (no regression)

**Pre-task reads (completed in Phase 0)**
- Lines 163–183 of `GohMenuView.swift` — the `jobs` computed var: when `rows.isEmpty` shows a Text; when non-empty wraps in `ScrollView { LazyVStack }` with `.frame(maxHeight: 260)` and NO `minHeight`. This is the collapse bug: `maxHeight` with no `minHeight` lets SwiftUI give the content zero height when in a MenuBarExtra popover.

**Step 1 — No failing test** (popover height is a runtime rendering property; no unit test for SwiftUI layout is feasible here)

**Step 2 — Implementation**

Fix 1 (collapse bug): Add `minHeight` to the ScrollView frame — or replace the `ScrollView`/`LazyVStack` with a `VStack` capped to top-N for the popover (simpler, avoids the minHeight ambiguity in popovers):

```swift
// In GohMenuView.jobs:
} else {
    // Show top-5 in the popover; "Downloads…" opens the full window.
    let topRows = Array(model.state.rows.prefix(5))
    VStack(alignment: .leading, spacing: 8) {
        ForEach(topRows) { row in
            GohMenuJobRowView(row: row, model: model)
        }
        if model.state.rows.count > 5 {
            Text("+ \(model.state.rows.count - 5) more — see Downloads")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    .frame(minHeight: 32)  // at least one row height, never collapses to zero
}
```

Fix 2 ("Downloads…" button): Add before `Divider()` at the bottom of the jobs section:

```swift
Button {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: "downloads")
} label: {
    Label("Downloads…", systemImage: "arrow.down.circle")
        .frame(maxWidth: .infinity)
}
.buttonStyle(.bordered)
.controlSize(.small)
.accessibilityLabel("Open Downloads window")
.help("Open the Downloads window to see all downloads")
```

**Step 3 — Gate**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Suite green. Smoke note: launch the tray app with one active download; confirm the row appears (non-zero height) and "Downloads…" button is visible in the popover.

---

### Task 6 — CREATE `Sources/GohMenuBar/DownloadsWindowView.swift`

**Files**
- CREATE `Sources/GohMenuBar/DownloadsWindowView.swift`

**AC ownership:** AC1 (rows visible in window), AC3 (rich row: bar, sizes, speed, ETA, connections), AC4 (completed/failed rows with final state + verify status)

**Pre-task reads (completed in Phase 0)**
- `Sources/GohMenuBar/GohMenuModels.swift` — `GohMenuJobRow` with the new fields from T3.
- `Sources/GohMenuBar/GohMenuViewModel.swift` — `@Published state: GohMenuState` and `@Published trustOverview`.
- `Sources/GohMenuBar/GohMenuView.swift` — `GohMenuJobRowView` for the existing row style to draw contrast from.

**Step 1 — No unit test** (SwiftUI view; verified by `swift build -warnings-as-errors` + manual smoke)

**Step 2 — Implementation**

```swift
// Sources/GohMenuBar/DownloadsWindowView.swift
import AppKit
import SwiftUI

/// The full Downloads dashboard window. Receives the live state from
/// GohMenuViewModel (same @Published state as the popover). One rich row per job.
public struct DownloadsWindowView: View {
    @ObservedObject private var model: GohMenuViewModel
    @Environment(\.openWindow) private var openWindow

    public init(model: GohMenuViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.state.rows.isEmpty {
                Text("No downloads yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.state.rows) { row in
                            DownloadRowView(row: row, model: model)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 200)
    }
}

private struct DownloadRowView: View {
    var row: GohMenuJobRow
    @ObservedObject var model: GohMenuViewModel
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Primary line: file-type icon + middle-truncated filename + hover controls
            HStack(spacing: 8) {
                Image(systemName: fileTypeIcon(for: row.title))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text(row.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isHovered {
                    hoverControls
                }
            }

            // Progress bar
            if let fraction = row.progressFraction {
                ProgressView(value: fraction)
                    .accessibilityLabel("Download progress \(Int(fraction * 100))%")
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Download progress unknown")
            }

            // Secondary line
            Text(secondaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var secondaryText: String {
        var parts: [String] = []
        parts.append(row.sizeText)
        if let eta = row.etaText { parts.append("ETA \(eta)") }
        if let elapsed = row.elapsedText { parts.append(elapsed) }
        if let conn = row.connectionText { parts.append(conn) }
        if let verify = row.verifyStatus { parts.append(verify) }
        if row.stateText == "Paused" { parts.insert("Paused", at: 0) }
        return parts.joined(separator: " · ")
    }

    private var hoverControls: some View {
        HStack(spacing: 2) {
            ForEach(row.orderedControls, id: \.self) { control in
                Button {
                    perform(control)
                } label: {
                    Image(systemName: control.systemImageName)
                        .frame(width: 22, height: 22)
                        .foregroundStyle(control == .remove ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(control.accessibilityLabel)
                .help(control.helpText)
            }
        }
    }

    private func fileTypeIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar": return "doc.zipper"
        case "iso", "dmg", "img": return "opticaldiscdrive"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "mp3", "m4a", "flac", "aac": return "music.note"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }

    private func perform(_ control: GohMenuControl) {
        switch control {
        case .pause:
            Task { await model.pause(jobID: row.id) }
        case .resume:
            Task { await model.resume(jobID: row.id) }
        case .remove:
            Task { await model.remove(jobID: row.id, keepPartialFile: true) }
        case .revealInFinder:
            model.reveal(destination: row.destination)
        case .copyURL:
            model.copy(row.url)
        case .copyDestination:
            model.copy(row.destination)
        }
    }
}

// Re-export the orderedControls extension (or use the existing one from GohMenuView).
private extension GohMenuJobRow {
    var orderedControls: [GohMenuControl] {
        [.pause, .resume, .revealInFinder, .copyURL, .copyDestination, .remove]
            .filter { controls.contains($0) }
    }
}
```

Note: if `orderedControls` is already a `private extension` in `GohMenuView.swift`, move it to a `fileprivate` extension on `GohMenuJobRow` or a `internal extension` in the module so `DownloadsWindowView.swift` can access it. Prefer moving it to a non-private extension in `GohMenuModels.swift`.

**Step 3 — Gate**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
```

Build clean. Manual smoke: open the Downloads window; confirm rows render with progress bars and secondary text.

---

### Task 7 — MODIFY `Sources/goh-menu/main.swift` — Window(id:"downloads") scene + root

**Files**
- MODIFY `Sources/goh-menu/main.swift`

**AC ownership:** AC1 (window openable from popover), AC3/AC4 (window fed live state)

**Pre-task reads (completed in Phase 0)**
- `Sources/goh-menu/main.swift` — `AddDownloadWindowRoot`/`TrustWindowRoot` @StateObject pattern; `Window(id:)` scene declarations; `GohMenuAppDelegate.model` passed to view roots.

**Step 1 — No unit test** (main.swift scene wiring; verified by `swift build` + manual smoke)

**Step 2 — Implementation**

Add a `DownloadsWindowRoot` mirroring `AddDownloadWindowRoot`:

```swift
struct DownloadsWindowRoot: View {
    @ObservedObject private var model: GohMenuViewModel

    init(model: GohMenuViewModel) {
        self.model = model
    }

    var body: some View {
        DownloadsWindowView(model: model)
    }
}
```

Note: unlike `AddDownloadWindowRoot`, this root does not need `@StateObject` because `GohMenuViewModel` is already `@ObservableObject` and owned by `GohMenuAppDelegate` — it's a shared reference, not a new allocation. Use `@ObservedObject` instead.

Add the `Window` scene in `GohMenuApp.body`:

```swift
Window("Downloads", id: "downloads") {
    DownloadsWindowRoot(model: appDelegate.model)
}
.windowResizability(.contentMinSize)
.defaultSize(width: 600, height: 400)
.defaultPosition(.center)
```

**Step 3 — Gate**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Suite green. Manual smoke:
1. Launch tray app with ≥1 active download.
2. Open popover — confirm row(s) visible (non-zero height). AC1 verified.
3. Click "Downloads…" — confirm Downloads window opens.
4. Confirm: progress bar visible (determinate when total known, spinner when nil). AC3 verified.
5. Confirm: secondary line shows `sizeText · ETA · elapsed · N connections`. AC3 verified.
6. Confirm: completed row shows size + finished-at + verify status if ledger has entry. AC4 verified.
7. Run `goh ls` — confirm speed column shows rolling rate (not climbing cumulative). AC2 verified.

---

## Invariants for all tasks

- `-warnings-as-errors` clean on every intermediate `swift build`.
- NO `#available` guards anywhere.
- NO `no-explicit-any` violations — use concrete types everywhere.
- All new GohCore types: `nonisolated` + `@unchecked Sendable` (Mutex-guarded) or `nonisolated Sendable` (value type).
- All new GohMenuBar model types: `nonisolated public struct ... : Sendable, Equatable`.
- NO XPC/wire/protocolVersion/golden-fixture change.
- Governor's ByteCounter block (DownloadEngine lines 786–826) is untouched.
- `JobProgress` struct fields are unchanged; only the runtime value of `bytesPerSecond` changes.
- Commit on each task completion. Never commit to main.
- Branch: `feat/tray-download-dashboard`

## Dependency order

```
T1 (RollingRateSampler) → T2 (thread engine)
                        → T3 (enrich models) → T4 (presenter)
                                             → T5 (popover fix)
                                                             → T6 (DownloadsWindowView)
                                                             → T7 (main.swift wiring)
```

T1 must complete before T2. T3 must complete before T4. T5, T6, T7 can start in parallel after T3 completes (T6 reads the enriched model types; T7 reads T6's view type). T2 can run in parallel with T3.

Safe parallel dispatch after T1:
- **Track A:** T2 (engine threading)
- **Track B:** T3 → T4 → T5 → T6 → T7 (sequential within track)
