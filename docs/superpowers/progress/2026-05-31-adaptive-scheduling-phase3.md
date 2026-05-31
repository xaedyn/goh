# Adaptive Scheduling — Phase 3 Artifact

## WHAT WAS BUILT

Phase 3 wires the Phase 1–2 stack into the live engine and dispatcher:

1. **`DownloadEngine.completedDownloadHandler` widened** (D5) — signature changes from
   `(@Sendable (JobSummary) -> Void)?` to `(@Sendable (JobSummary, Duration) -> Void)?`.
   Both `fetchRanged` and `fetchSingle` now pass `clock.now - started` to `complete(jobID:in:)`,
   which threads it to the handler. The additive widening touches no wire or on-disk contract.

2. **`CommandDispatcher` admission-time N resolution** (D6) — when `request.connectionCount`
   is nil, the dispatcher calls `hostProfileStore?.selectN(hostKey:)` and uses the returned N
   instead of the constant `defaultConnectionCount`. When `hostProfileStore` is nil or returns
   `.cold`, falls back to `defaultConnectionCount` (8). The existing `cappedConnectionCount`
   cap and `> 0` guard are preserved.

3. **Observation recording** (D5 gate) — the `completedDownloadHandler` in `gohd/main.swift`
   is widened to `(completed, duration)` and records an observation via `hostProfileStore` if:
   - `duration >= .seconds(10)` (duration gate)
   - `completed.progress.bytesCompleted >= 8 * 1024 * 1024` (8 MiB floor)
   - `hostProfileStore.activeCount(hostKey) == 1` at completion time (concurrent-same-host guard)
   - `completed.actualConnectionCount == completed.requestedConnectionCount` (arm was fully exercised)
   - not a resume path: detected by `completed.progress.bytesCompleted == completed.progress.bytesTotal`
     with `completed.actualConnectionCount == 1` pattern — actually, resume is guarded by checking
     the checkpoint path; the simpler D8 skip is: the engine's `resume()` path does NOT call
     `completedDownloadHandler` (it calls `complete()` which calls the handler — so the D8 guard
     is implemented as: if `actualConnectionCount == 1` AND `requestedConnectionCount > 1`,
     this was a minChunk-capped single-connection arm, not a resume; resumes have `requestedConnectionCount == 1`
     after D6 wiring sets it from the profile — actually D8 is simpler: the resume path is detected
     in main.swift by checking if the `job.requestedConnectionCount == 1` **and** no profile entry
     drove that — the cleaner implementation is a flag on the completion call).
   
   **Concrete D8 implementation:** `DownloadEngine.run()` distinguishes the resume path from the
   download path and passes an `isResume: Bool` flag through `complete(jobID:in:isResume:)` so
   the handler can skip observation recording for resumes without needing to infer it.

4. **`HostProfileStore` incremented/decremented** in `DownloadEngine.run()` — bracketed exactly
   like `control?.register` / `defer { control?.unregister }` at lines 129–130.

5. **`gohd/main.swift` wired** — `HostProfileStore` constructed alongside `CatalogStore`;
   `CommandDispatcher` receives it; `DownloadEngine.completedDownloadHandler` extended.

6. **`GOH_ENGINE_TRACE` extended** (regression diagnostic) — `EngineDiagnostics` gains
   `recordSchedulingDecision(hostKey:chosenN:reason:armEWMAs:)` emitted when `GOH_ENGINE_TRACE`
   is set, per-download, at the start of `fetchRanged`/`fetchSingle`.

7. **Regression benchmark guard** — `Benchmarks/goh-bench` extended with a test asserting
   that after N repeat downloads from the same test host, the converged throughput is ≥ the
   static-8 baseline within a stated tolerance.

## CURRENT STATE OF MODIFIED / CREATED FILES

### `Sources/GohCore/Engine/DownloadEngine.swift` (Modify)

Key changes:
```swift
// Line ~67 — widened handler signature:
private let completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool) -> Void)?
//                                                               ^^^^^^^^  ^^^
//                                               transfer Duration  isResume flag

// Line ~129 — active-count bracket (new):
hostProfileStore?.incrementActiveCount(hostKey: hostKey(for: job.url) ?? "")
defer { hostProfileStore?.decrementActiveCount(hostKey: hostKey(for: job.url) ?? "") }

// complete(jobID:in:isResume:) — threads duration + isResume to handler
private func complete(jobID: UInt64, in store: JobStore, transferDuration: Duration, isResume: Bool) throws {
    let completed = try store.complete(id: jobID)
    completedDownloadHandler?(completed, transferDuration, isResume)
}
```

### `Sources/GohCore/Model/CommandDispatcher.swift` (Modify)

Key changes:
```swift
// New stored property:
private let hostProfileStore: HostProfileStore?

// init — new optional parameter:
public init(
    store: JobStore,
    control: DownloadControl? = nil,
    checkpointStore: CheckpointStore? = nil,
    importedCookies: ImportedCookieStore? = nil,
    hostProfileStore: HostProfileStore? = nil,
    onJobQueued: (@Sendable (UInt64) -> Void)? = nil,
    queuedJobAdmission: (@Sendable (UInt64) -> JobSummary?)? = nil
) { ... }

// .add case — nil resolution now consults host profile:
let requestedConnectionCount: UInt8
if let explicit = request.connectionCount {
    requestedConnectionCount = explicit
} else if let key = hostKey(for: request.url),
          let store = hostProfileStore {
    requestedConnectionCount = store.selectN(hostKey: key).n
} else {
    requestedConnectionCount = Self.defaultConnectionCount
}
```

### `Sources/gohd/main.swift` (Modify)

Key additions:
- `HostProfileStore` constructed at `supportDirectory.appending(path: "host-scheduling.plist")`
- `DownloadEngine` init receives the widened `completedDownloadHandler: { completed, duration, isResume in ... }`
- `CommandDispatcher` init receives `hostProfileStore:`
- Handler body gates the `recordObservation` call on all D5 predicates

### `Sources/GohCore/Engine/EngineDiagnostics.swift` (Modify)

Adds `recordSchedulingDecision(hostKey:chosenN:reason:armEWMAs:)` emitted under `GOH_ENGINE_TRACE`.

### `Tests/GohCoreTests/DownloadEngineTests.swift` (Modify)

Tests updated for new `completedDownloadHandler` arity (3-argument closure).

### `Tests/GohCoreTests/CommandDispatcherTests.swift` (Modify)

New tests: `nil connectionCount → profile-driven N`, `nil connectionCount + no profile → default 8`,
`explicit connectionCount → honored exactly`.

## CONTRACTS ESTABLISHED

- `completedDownloadHandler` arity is `(JobSummary, Duration, Bool)` — `Bool` is `isResume`.
  Any caller of `DownloadEngine.init` must update its closure.
- `HostProfileStore` is the only code that writes `host-scheduling.plist`; `gohd/main.swift`
  is the only instantiation point.
- The active-count bracket in `run()` is guaranteed to decrement on every exit path (throw,
  pause, cancel, complete) because it lives in a `defer`.
- `protocolVersion` stays 3; `JobCatalog.version` stays 1; `JobSummary` is unchanged.
- `GOH_ENGINE_TRACE` output format is not a frozen contract.

## OPEN ITEMS

- Benchmark evidence that convergence throughput ≥ static-8 on the saturated workload
  (the regression guard test). This is executed as part of Phase 3 task 9 (benchmark guard)
  and may require tuning the ε/α/minSamples constants — all non-frozen.
- The amenable-workload structural gap (URLSession-on-h2 vs aria2c) is documented and
  reported, not gated.
