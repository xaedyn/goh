---
date: 2026-06-03
feature: goh-diagnose
type: codebase-context-brief
---

# Codebase Context Brief: `goh diagnose <url>`

## STACK

- Swift tools-version 6.2 (`.defaultIsolation` floor; builds with Swift 6.3.x), Swift 6 strict concurrency.
- Targets: `goh` (CLI, MainActor-default), `gohd` (daemon, nonisolated), `GohCore` (shared lib, nonisolated), `GohTUI` (MainActor).
- Tests: Swift Testing (not XCTest), CI on `macos-26`.
- One third-party dep: `apple/swift-http-types`. Platform floor macOS 26.0.

## EXISTING PATTERNS

- **CLI-local verb:** `public enum SomeCommand` with `static func run(...) -> GohCommandLineResult`
  (`struct { exitCode: Int32; standardOutput: String; standardError: String }`). Wired in
  `GohCommandLine.parse(_:)` as a `ParsedCommand` case, dispatched in `run()` switch, usage text in
  `usage()`. Sync verbs (`which`, `verify`) called inline; async verbs (`doctor`) injected as a closure
  via `GohCommandLine.init` and wired in `Sources/goh/main.swift`. **`diagnose` is async → closure pattern.**
- **Exit codes:** no single frozen enum; each command documents its own codes in a header comment
  (`GohVerifyCommand.swift:9-17`). 0 = success, 1 = generic. `diagnose` defines its own set.
- **Error handling:** `GohError` with `ErrorCode` enum (`Sources/GohCore/Model/GohError.swift`).

## RELEVANT FILES

- `Sources/GohCore/Engine/DownloadEngine.swift` — engine. Key sites:
  - **Abort-on-non-206 (the wrinkle):** `downloadRange` `guard http.statusCode == 206 else { throw Self.httpFailure(...) }`
    (~line 885) — parallel-worker path; throw propagates out of the `TaskGroup`, control loop (~766) calls
    `group.cancelAll()`, tears down all siblings. Speculative-probe abort at `download` (~270-272). Error =
    `GohError(.httpStatus, httpStatusCode:)` from `httpFailure` (~1042); 401/403 → `.unauthorized`.
  - **429:** treated like any non-206 → throws immediately. `retryEligible` returns true for 408/425/429
    (~1061) but the engine does NOT retry; the daemon decides. No back-off path today.
  - **Reusable per-connection request helper:** `request(for:job:)` (~992) builds the `URLRequest`, injects
    `Cookie` via `cookieHeaderProvider`. Range header set by caller. **Reusable by diagnose unmodified.**
  - **Streaming:** `streamingResponse(for:onMetrics:)` + `consumeRange` drain bytes. `streamingResponse`
    hooks `onTermination` to cancel the `URLSessionDataTask` (clean cancel).
  - **Throughput:** `ByteCounter` (`Mutex<UInt64>`); control loop reads `.value` per reap, computes B/s over
    ≥0.25 s windows, feeds `governor.record(aggregateBytesPerSecond:)`.
- `Sources/GohCore/Engine/StreamingDataTask.swift` — `StreamingDataTaskDelegate` (`URLSessionDataDelegate`).
  `urlSession(_:task:didFinishCollecting:)` (~144) fires **post-hoc** (after task ends, including cancel),
  picks `metrics.transactionMetrics.last`, calls `onMetrics` → `trace.recordProtocol(index, networkProtocolName:)`.
  **Protocol name (`networkProtocolName: String?`) is only available after the task finishes/cancels**, not
  synchronously with the response. `URLSessionTaskTransactionMetrics.isReusedConnection` is the closest
  available signal for connection reuse.
- `Sources/GohCore/Engine/EngineDiagnostics.swift` — **stderr-emit only**, gated on `GOH_ENGINE_TRACE=1`.
  Retains no structured data (only `peakActive: Int` for tests). Nothing consumes it programmatically.
  Diagnose needs NEW structured fields (per-connection protocol, TTFB, throughput sample, accept/reject counts).
- `Sources/GohCore/CLI/GohVerifyCommand.swift`, `GohWhichCommand.swift` — canonical CLI-local verb patterns.
- `Sources/GohCore/CLI/GohDoctor.swift` — async-closure verb pattern (probes-struct injection).
- `Sources/GohCore/CLI/GohCommandLine.swift` — dispatch hub: `ParsedCommand` enum (~189), `usage()` (~458),
  `GohCommandLineResult` (~4).
- `Sources/goh/main.swift` — wires async verb closures into `GohCommandLine.init`.

## CONSTRAINTS

- `protocolVersion = 3` (frozen, `CommandService.swift:14`), `JobCatalog.version = 1`, `JobSummary` wire
  shape, `LockfileCodec`/`ManifestCodec` on-disk formats — **all untouched**. Diagnose is **purely additive**:
  new `ParsedCommand` case + new `GohDiagnoseCommand` + new closure in `GohCommandLine.init` + `usage()` line.
  Zero wire/schema change, no daemon, no XPC.
- `DownloadEngine.run()` requires a `JobStore` + `JobSummary` — diagnose CANNOT reuse it directly; it must use
  the lower-level primitives (`request(for:)`, `streamingResponse`) as a standalone probe with no store/sink.

## OPEN QUESTIONS (design attention)

1. **Probe-without-abort:** must NOT reuse `downloadRange` (its 206-guard is fatal). Need a variant that
   captures the status and continues/cancels. `request(for:)` + `streamingResponse` are reusable; only the
   status-check policy differs.
2. **Protocol metrics are post-hoc** — arrive in `didFinishCollecting` after the task ends/cancels. Apple docs
   say metrics ARE delivered on cancel; verify empirically for a ~10s mid-stream cancel.
3. **Accept/reject counting:** URLSession exposes no count of TCP/QUIC connections actually opened (h2/h3
   multiplex over one). The meaningful signal is at the probe level: fire N concurrent range requests, count
   how many return 206 vs 429/4xx. `isReusedConnection` distinguishes reuse.
4. **Time-box ~10s + clean cancel:** structured concurrency (`withTaskCancellationHandler`,
   `Task.sleep` race). No temp file/sink needed — discard bytes in the stream loop.
