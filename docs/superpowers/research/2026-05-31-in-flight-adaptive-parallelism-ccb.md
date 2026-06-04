---
date: 2026-05-31
feature: in-flight-adaptive-parallelism
type: codebase-context-brief
---

# Codebase Context Brief — In-Flight Adaptive Parallelism

STACK
Swift 6.2 (tools-version floor; builds with Swift 6.3.x toolchain). Swift 6 strict-concurrency, nonisolated default on GohCore and gohd. macOS 26.0 hard floor. URLSession for HTTP transport. `apple/swift-http-types` (sole third-party dep). CryptoKit SHA-256, streamed. Swift Testing. `Synchronization.Mutex` for all shared state. No Network.framework (transport brief moved off it).

EXISTING PATTERNS
Concurrency/isolation: all engine concurrency runs via `withThrowingTaskGroup`; shared mutable state is guarded by `Synchronization.Mutex` (no actors in GohCore/gohd).
Error handling: every thrown error is a `GohError`; non-GohError types are mapped through `DownloadEngine.mapError(_:)` before surfacing; store errors go through the `unexpectedStoreError` reporter rather than propagating.
Persistence: atomic temp→fsync→rename→dir-fsync for all stores; binary plist encoding (`CatalogStore`, `HostProfileStore`, `CheckpointStore`).
Test pattern: Swift Testing; dependency injection through `DownloadEngine.init` parameters (session, stores, handlers all injectable); `EngineDiagnostics` enabled via `GOH_ENGINE_TRACE=1`.

RELEVANT FILES

`Sources/GohCore/Engine/DownloadEngine.swift` — the download engine. Key: `fetchRanged(job:store:url:total:initialResponse:firstRangeStream:cancelFirstRangeStream:trace:)` is the range-parallel entry point. `ByteRange.split(total:requested:minChunk:)` is called once up-front at line 502 — the split is fixed before the `TaskGroup` launches. The `withThrowingTaskGroup` at line 517 spans all range workers; `consumeRange` and `downloadRange` are the per-range task bodies. `completedDownloadHandler` has arity `(@Sendable (JobSummary, Duration, Bool) -> Void)?` — args are the completed `JobSummary`, `transferDuration: Duration`, and `isResume: Bool`. `init` accepts `hostProfileStore: HostProfileStore?`.

`Sources/GohCore/Engine/StreamingDataTask.swift` — the URLSession delegate bridge. `URLSession.streamingResponse(for:onMetrics:)` returns `(HTTPURLResponse, AsyncThrowingStream<Data, Error>, @Sendable () -> Void)`. `StreamingDataTaskDelegate` implements `URLSessionDataDelegate` and already captures an `onMetrics: (@Sendable (URLSessionTaskTransactionMetrics) -> Void)?` callback; `urlSession(_:task:didFinishCollecting:)` fires `metrics.transactionMetrics.last`. The metrics object (DNS, connect, TLS, TTFB, negotiated protocol, peer IP, connection reuse) is accessible per-range but **arrives post-body**, after the task completes. `networkProtocolName` and `remoteAddress` both present.

`Sources/GohCore/Engine/ChunkAssembler.swift` — hashes the download in order. `ByteRange` (start/length), `ByteRange.split(total:requested:minChunk:)`. `ChunkAssembler.init(file:ranges:)` takes the fixed `[ByteRange]` array at construction. `advance(range:writtenBytes:)` / `finish()` are the writer-side hooks; not designed to accept a mid-flight change to the ranges array.

`Sources/GohCore/Engine/EngineDiagnostics.swift` — per-download trace. `recordProtocol(_:networkProtocolName:)` captures the negotiated protocol per range index. Extendable to emit delivery-rate / RTT samples.

`Sources/GohCore/Scheduling/HostScheduling.swift` — frozen plist types. `HostScheduling` (version=1), `HostProfile` (host key + arms + updatedAt), `ConnObservation` (connectionCount, throughputEWMA, sampleCount, updatedAt). `ConnObservation.foldingIn(throughput:alpha:)` is the EWMA update.

`Sources/GohCore/Scheduling/HostProfileStore.swift` — mutable scheduling state. Methods: `begin(jobID:hostKey:)`, `end(jobID:hostKey:)`, `wasSolo(jobID:)`, `recordObservation(hostKey:connectionCount:totalBytes:transferDuration:alpha:)`, `selectN(hostKey:selector:) -> (n: UInt8, reason: SelectionReason)`, `shouldRecordObservation(isResume:transferDuration:bytesCompleted:wasSolo:actualConnectionCount:requestedConnectionCount:minTransferDuration:minBytes:) -> Bool` (static gate).

`Sources/GohCore/Scheduling/BanditSelector.swift` — `candidateSet = [2,4,8,16]`, `defaultN = 8`, `select(profile:rng:) -> (n: UInt8, reason: SelectionReason)`.

`Sources/GohCore/Scheduling/HostKey.swift` — `hostKey(for urlString: String) -> String?` (D1 normalizer).

`Sources/GohCore/Model/CommandDispatcher.swift` — admission-time N resolution. Lines 58–90: explicit `request.connectionCount` → `.explicit`; else `hostProfileStore?.selectN(hostKey:)`. `maximumConnectionCount = 16`. N stored in `JobSummary.requestedConnectionCount` before the engine sees the job.

`Sources/GohCore/GohCore.swift` — `downloadSessionConfiguration()` sets `httpMaximumConnectionsPerHost = 16` and `Accept-Encoding: identity`. No per-request IP binding or connection identity.

`Sources/gohd/main.swift` — `completedDownloadHandler` closure (lines 129–157) evaluates `shouldRecordObservation` and calls `recordObservation`. The insertion point for feeding a governor's converged N back into the bandit.

CONSTRAINTS
`protocolVersion` stays 3. `JobCatalog.version` stays 1. `JobSummary` wire shape frozen within protocolVersion=3 (optional-field additions OK; removal/retyping not). `host-scheduling.plist` frozen at `HostScheduling.currentVersion = 1` — only raw measurements persisted; knobs (candidateSet, ε, α, TTL) are non-persisted daemon constants. Checkpoint/resume contract (`DownloadCheckpoint.currentVersion = 1`) must not change — validator, pieceSize, completedPieces are the resume invariant; mid-flight range re-planning must not corrupt or orphan checkpoints. 16-connection ceiling is hard. No new third-party deps. macOS 26.0 floor — no `#available` ladders.

OPEN QUESTIONS

1. **Range split is fixed up-front.** `ByteRange.split` is called once before the `TaskGroup` launches; `ChunkAssembler` takes the immutable ranges array at init. Adding connections mid-flight requires either (a) splitting remaining unclaimed bytes into new ranges and constructing additional workers against the existing assembler, or (b) redesigning the assembler to accept a mutable range list. The design must resolve which approach preserves checkpoint correctness.

2. **Metrics arrive post-body, not per-chunk.** `URLSessionTaskTransactionMetrics` (incl. `remoteAddress`, `networkProtocolName`, connect/TLS/TTFB timestamps) is delivered once, after each task completes. It cannot supply RTT samples *during* the transfer. The delivery-rate signal must come from chunk inter-arrival timing within `consumeRange`, not from URLSession metrics. The governor's coarse-RTT estimate is chunk-gap time, not a true network RTT.

3. **No existing per-chunk timestamp.** `consumeRange` does not timestamp individual chunk arrivals. A delivery-rate governor needs a clock read per chunk (or per flush) — new instrumentation inside `consumeRange`.

4. **No IP-pinning surface in URLSession.** Nothing pins a connection to a specific resolved IP; URLSession handles DNS internally and may reuse connections to the same host. Multi-edge fan-out requires per-IP `URLRequest` targets (connect to `https://1.2.3.4/path` with `Host:` override) or dropping to `NWConnection` — neither present today.

5. **`transferDuration` is whole-download elapsed, not transfer phase alone.** `started = clock.now` before the TaskGroup; `clock.now - started` is full elapsed including connection setup. To separate setup time from steady-state throughput the governor needs an additional timestamp.

6. **`shouldRecordObservation` requires `actualConnectionCount == requestedConnectionCount`.** If the governor changes N mid-download, the final `actualConnectionCount` may not equal the admission-time `requestedConnectionCount`, suppressing the observation. The observation-recording contract must be revisited to feed a governor-converged N back into the bandit.
