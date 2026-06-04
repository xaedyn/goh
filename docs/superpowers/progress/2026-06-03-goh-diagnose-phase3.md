# Phase 3 Progress — goh diagnose

Status: COMPLETE — Tasks 7, 8, 9 implemented and passing.

## Tasks completed

- **Task 7:** `GohDiagnoseCommand` — synchronous face for the `diagnose` verb.
  Arg parsing (`<url>`, `--full`, `--json`, `--connections N / -c N`). Malformed
  URL gate at arg-parse, before the probe runs. Async→sync bridge via
  `DispatchSemaphore` + `Task` (`nonisolated(unsafe) var probeResult`; semaphore
  establishes happens-before edge for Swift 6 Sendable compliance). Exit-code
  mapping from `ProbeTermination` enum (never from `verdictText`): exit 0
  (diagnosed), 2 (unreachable), 3 (HTTP error), 4 (auth required), 64 (usage).
  Human output (label-aligned text) and `--json` output (encoded `DiagnosisReport`).

- **Task 8:** `GohCommandLine` + `main.swift` wiring — `diagnose` sub-command
  routed through `GohCommandLine.run(arguments:)`, session factory injected for
  tests. `main.swift` unchanged (remains synchronous). `GohCommandLine` dispatches
  to `GohDiagnoseCommand.run` for the `diagnose` verb. Integration smoke-test
  confirms the routing reaches the probe.

- **Task 9:** Full suite pass, `-warnings-as-errors` clean, cleanups:
  - `MockURLProtocol` marked `@unchecked Sendable` (all state Mutex-guarded;
    eliminates the `[weak self]` `@Sendable` closure warning at line 246).
  - Human output label `"reachable:"` → `"Reachable:"` (sentence-case consistency
    with all sibling labels); test assertion updated accordingly.
  - DESIGN.md: `streamingResponse` cancellation-race fix documented under
    Transport; `goh diagnose` probe-without-abort and bottleneck-verdict-hedging
    documented under CLI.
  - Phase 1/2/3 progress artifacts updated from stubs to real summaries.

## Suite results

```
Test run with 528 tests in 75 suites passed after ~15.6 seconds.
```

Production build: `Build complete!` — no warnings under `-warnings-as-errors`.
Test build: no warnings (MockURLProtocol `@Sendable` capture warning resolved).
