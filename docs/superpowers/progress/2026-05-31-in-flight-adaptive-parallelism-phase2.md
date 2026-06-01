# P2 Artifact — Dynamic Chunk Pool + Interval-Frontier ChunkAssembler

Phase 2 of the in-flight adaptive parallelism slice. Built via subagent-driven-development on branch
`design/in-flight-parallelism`, TDD per task, two-stage review (spec + Opus quality/concurrency).
**Status: COMPLETE.** P2 is **behaviour-equivalent at fixed N** — it ships no functional change; it is the
structural rework that lets P3 vary the connection count live. **493 tests pass**, warning-clean under
`-warnings-as-errors`, strict-concurrency-clean.

## What was built

- **Task 6 — `ChunkQueue`** (`efe69cf`). New `Sources/GohCore/Engine/ChunkQueue.swift`: `public struct
  ByteInterval` (start/length, `.end`, `init(from: ByteRange)`) + a `Mutex`-guarded `final class ChunkQueue`
  (`pull()`, `returnToFront(_:)`, `markDone(_:)`, `remainingBytes`, `isDone`). Offset-sorted; thread-safe.
- **Task 7 — interval-set `ChunkAssembler`** (`b99fdd1`, empty-file fix `9a02981`). Replaced the co-indexed
  `[ByteRange]`/`[UInt64]` design with an interval set under `Mutex`. `advance(range:writtenBytes:)` and the
  co-indexed state/`fixedLength` are **DELETED** (not shimmed — keeping both writers was a dual-writer
  clobber hazard). New `complete(interval:)` is **additive-merge only** (`coalesce(existing + [interval])`,
  never whole-set replace). Frontier = end of the coalesced interval anchored at byte 0; end-condition =
  the set is exactly `[0, total)`. **SHA-256 in-order invariant preserved** (hash advances only as the
  byte-0 frontier extends; out-of-order intervals sit unhashed; no re-hash). Migrated all callers:
  `verifyHash`, `fetchSingle`, `fetchRanged`, `consumeRange`'s per-flush `complete(...)`, **and**
  `Benchmarks/goh-bench/main.swift` (a 4th caller the implementer found).
- **Task 8 — control-loop worker pool** (`b41136a`). `fetchRanged` no longer statically spawns one
  `TaskGroup` task per range. It seeds a `ChunkQueue` from `ByteRange.split` and runs a **single control
  loop inside `withThrowingTaskGroup`** that is the SOLE caller of `group.addTask` (nested non-escaping
  `spawn`/`fillToTarget` funcs, called only synchronously from the control loop). Workers download one
  captured interval (range 0 reuses the speculative `firstRangeStream`; others open a fresh ranged GET via
  `downloadRange`) and return. `targetN` is **static** (= `requestedConnectionCount`) in P2.

## Two defects caught by review and fixed (do not re-introduce)

1. **`totalBytes` optionality (caught pre-implementation).** The plan's `init(file:totalBytes: UInt64)` +
   `fetchSingle` migration `totalBytes: total ?? UInt64.max` was a bug: it stored `.some(.max)`, never nil,
   so an unknown-length (no `Content-Length`) download would fail the `[0,total)` end-condition. Corrected
   to **`init(file:totalBytes: UInt64?)`** with `fetchSingle` passing the real optional — preserving the
   prior `expectedFixedLength == nil` skip-the-end-condition behaviour. The migrated `openEndedSingleRange`
   test (`totalBytes: nil`) is the load-bearing proof.
2. **Empty file (`Content-Length: 0`) regression (caught by Opus quality review).** A valid empty download
   (`total == 0`, admitted by `fetchSingle`) never calls `complete(interval:)`, so the empty interval set
   failed the `coalesced.count == 1` end-condition → spurious `.connectionFailed`. The old assembler
   digested empty files correctly. Fixed: `isComplete = (total == 0 && coalesced.isEmpty) || (…[0,total)…)`,
   plus a regression test `intervalSetEmptyFile` (red-before/green-after) asserting the canonical empty
   SHA-256.

## Current state of modified / created files

- `Sources/GohCore/Engine/ChunkQueue.swift` (new) — `ByteInterval`, `ChunkQueue`.
- `Sources/GohCore/Engine/ChunkAssembler.swift` — interval-set rework. `init(file:totalBytes: UInt64?)`;
  `complete(interval:)` (additive-merge); `coalesce` (static); `currentFrontier` (byte-0 interval end);
  `recordFailure`/`finish`/`hashToCompletion` retained; `advance`/`fixedLength`/co-indexed state removed.
  `ByteRange` + `ByteRange.split` + `ChunkAssemblerResult` unchanged.
- `Sources/GohCore/Engine/DownloadEngine.swift` — `fetchRanged` dispatch restructured to the control-loop
  pool; `consumeRange`/`downloadRange` bodies UNCHANGED (already call `complete(interval:)`).
  `setActualConnectionCount` now called once after the seed fill with `UInt8(peakWorkers)` (== ranges.count
  at fixed N); the `JobStore` method body is unchanged (its peak-max upgrade is P3/Task 11).
- `Benchmarks/goh-bench/main.swift` — migrated `advance` → `complete(interval:)`.
- Tests: `ChunkQueueTests.swift` (new, 5), `ChunkAssemblerTests.swift` (4 migrated + 4 new incl. empty-file),
  `DownloadEngineTests.swift` (+`controlLoopPoolDownload`).

## Invariant verification

- [x] `protocolVersion` still 3 — no wire change.
- [x] `JobCatalog.version` still 1.
- [x] `JobSummary` wire shape unchanged (`actualConnectionCount` still set; peak-max semantics deferred to P3).
- [x] `host-scheduling.plist` format unchanged.
- [x] `DownloadCheckpoint` format unchanged — `DownloadCheckpointRecorder.recordCompletedPiece(start:length:)`
  is called identically (per-flush piece); the assembler's internal storage changed, the checkpoint did not.

## Behaviour-equivalence verification

Confirmed by the full engine suite (31 tests: ranged, resume, single-connection 200 fallback, unknown-length,
rm-during-download, sibling-cancellation) staying green, plus a dedicated **Opus concurrency review** of
Task 8 that traced the loop and confirmed: single-adder invariant Swift-6-safe by construction; each range
dispatched exactly once; range-0 `firstRangeStream` consumed exactly once; cancel-on-throw + assembler
`recordFailure` preserved; no data race (control-loop `var`s never captured by a worker); no hang path.
Only observable difference: a sub-millisecond shift in when `actualConnectionCount` is recorded — identical
value, not a regression.

## Contracts established (for P3)

- `ChunkQueue` + `ByteInterval` (above).
- `ChunkAssembler.complete(interval:)` — the additive-merge completion sink workers call.
- The control-loop pool: `fillToTarget(_ target:)` is the **live re-admission point** — P3 passes a
  governor-updated target here after each reap; `peakWorkers` already accumulates the high-water mark.

## Open items for P3

1. **Wire the governor (Tasks 11–18).** Replace the static `let targetN = Int(job.requestedConnectionCount)`
   with a `Mutex<Int>` the governor writes; feed `WorkerRateSample`s from `consumeRange`'s `flush()`
   (currently the `(bytes, elapsed)` accumulator is unconsumed — P3 computes **per-flush deltas + per-worker
   EWMA**, not cumulative, before feeding the governor); apply `GovernorDecision` by updating the target and
   re-calling `fillToTarget`; emit `GovernorOutcome` to the completion sink.
2. **Cooperative drop / re-queue.** `queue.returnToFront`/`markDone`/`isDone` are unused at fixed N. P3's
   drop path (governor lowers target → a finishing worker isn't re-spawned; an un-started interval returns
   to the queue) uses them. P4's per-host budget adds the budget gate + worker-`defer`-release into the
   structure built here.
3. **`setActualConnectionCount` peak-max (Task 11).** Under dynamic N the JobStore method must become
   `max(existing, min(count,16))` (peak across the transfer) — currently it caps at requested/assigns; P2's
   single post-seed call is fine only because N is static.
4. **`peakWorkers` reader semantics.** At fixed N it equals `ranges.count`; under dynamic N it becomes a true
   high-water mark, which is the intended `actualConnectionCount` = "peak concurrent connections used."
5. **The defensive `guard let index` in `spawn`** is dead at fixed N (distinct starts) but is cheap insurance
   for P3 when intervals are re-split.

## Invariants held

`protocolVersion` 3, `JobCatalog.version` 1, `JobSummary` wire shape, `host-scheduling.plist` v1,
`DownloadCheckpoint` v1 — all unchanged. P2 reworked engine internals only; nothing crossed the wire.
