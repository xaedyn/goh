# Phase 2 Progress — goh diagnose

Status: COMPLETE — Tasks 4, 5, 6 implemented and passing.

## Tasks completed

- **Task 4:** `GohDiagnoseProbe` Phase 1 — single-connection throughput (T₁).
  `ByteCounter` wraps `Mutex<UInt64>`, `@unchecked Sendable`. Coordinator child
  takes two counter snapshots at `ContinuousClock.Instant` boundaries; elapsed is
  the real measured duration between snapshots, not the `sampleWindowSeconds`
  constant. `singleConnMBps` set from the delta. Deadline child (within the same
  `withTaskGroup`) cancels drain children when the time-box expires. `--full` mode
  omits the deadline child; drain runs to EOF and `wholeFileMBps` is set from
  `Σ eofTotalBytes / elapsed(firstByte → now)`.

- **Task 5:** `GohDiagnoseProbe` Phase 2 — multi-connection throughput (Tₙ).
  `targetConnections` connections open concurrently after Phase 1 establishes T₁.
  Rejected connections (non-206) are counted in `rejections` and `accepted` vs
  `attempted`. Tₙ measurement uses the same two-snapshot/real-elapsed approach as
  T₁, with conn-0 included in both snapshots (it drains continuously through Phase
  2). Deadline child cancels all drain children including conn-0.

- **Task 6:** AC1/AC2/AC3/AC4 acceptance-criteria tests.
  - AC1: reachable + range-supporting server → `.diagnosed`, `singleConnMBps` set.
  - AC2: transport failure → `.unreachable`, `reachable == false`.
  - AC3: server rejects all parallel connections → `accepted == 1`.
  - AC4: time-box fires before window exhausts → deadline child cancels group,
    `multiConnMBps` still computed from available data.
  All integration tests use `targetConnections ≥ 2` to exercise Phase 2 and the
  deadline child's concurrent cancellation path.

## Suite results (at Task 6 completion)

All diagnose-related tests passing; full suite green.
