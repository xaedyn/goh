# Phase 2 Progress Artifact — In-Flight Adaptive Parallelism

**Status:** NOT STARTED  
**Prerequisite:** Phase 1 artifact complete and all P1 tests passing.  
**To be completed by:** the implementing agent at the end of Phase 2.

---

## Template (fill in after P2 tasks are complete)

### WHAT WAS BUILT

- Task 6: `ChunkQueue` interval-set work queue
- Task 7: Interval-frontier `ChunkAssembler` rework (complete/coalesce API)
- Task 8: Live worker-pool control loop inside `fetchRanged`
- Task 9: Full test suite run + artifact

### CURRENT STATE OF MODIFIED FILES

| File | Status |
|------|--------|
| `Sources/GohCore/Engine/ChunkQueue.swift` | Created |
| `Sources/GohCore/Engine/ChunkAssembler.swift` | Reworked to interval-set; `advance()` shim present |
| `Sources/GohCore/Engine/DownloadEngine.swift` | `fetchRanged` uses `ChunkQueue` + control loop |

### INVARIANT VERIFICATION

- [ ] `protocolVersion` is still 3
- [ ] `JobCatalog.version` is still 1
- [ ] `JobSummary` wire shape unchanged
- [ ] `host-scheduling.plist` format unchanged
- [ ] `DownloadCheckpoint` format unchanged (same `completedPieces` intervals)

### CONTRACTS ESTABLISHED

- `ChunkQueue(intervals:)` + `pull()` + `returnToFront(_:)` + `markDone(_:)` + `remainingBytes` + `isDone`
- `ChunkAssembler.complete(interval:)` — replaces `advance(range:writtenBytes:)` in new pool
- `ByteInterval(start:length:)` + `ByteInterval(from:ByteRange)` — isomorphic to ByteRange

### BEHAVIOUR EQUIVALENCE VERIFICATION

At fixed N (no governor yet), the P2 engine produces byte-for-byte identical output to P1:
_(fill in: comparison test result)_

### OPEN ITEMS FOR P3

_(fill in at end of P2)_

### FULL TEST SUITE STATUS

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
# Result: _(fill in)_
```
