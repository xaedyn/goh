# STATE.md — goh current state

Where the project is right now. Read after `CLAUDE.md` at the start of every
session; update at the start of every PR and at the end of every session.

## Current state

- **Branch:** `feat/download-range-parallel`
- **Last merged:** PR #12 — Slice 3a, single-connection HTTP download — `main`
  at `a051819`.
- **Current slice:** 3b — range-parallel orchestration — **PR #14 open in
  draft**, CI green; holding for the competitive benchmark run.
- **Last merged before #14:** PR #13 — the `actualConnectionCount` §1 amendment.
- **Repository is public** (github.com/xaedyn/goh) — flipped 2026-05-22, which
  also made GitHub Actions free on the `macos-26` runner.

## Slice 3a — shipped (the milestone: `goh` moves bytes to disk)

- Engine job-store transitions — `start` (an atomic claim) / `recordProgress` /
  `complete` / `fail`, driving `queued → active → completed/failed`.
- `DownloadFile` — `pwrite` at offset, streaming SHA-256, the 1 MiB fsync
  checkpoint, best-effort `F_PREALLOCATE`.
- `DownloadEngine` — single-connection HTTP fetch over `URLSession`.
- Daemon wiring — `gohd` runs the engine on `add`, on `resume`, and for jobs
  still queued at startup.
- 84 tests; the engine path is tested over a `URLProtocol` mock.

## Slice 3b — range-parallel orchestration (PR #14, draft)

Built, tested (100 tests), pushed:

- `DownloadFile` reworked to pure positioned I/O (`pwrite`/`pread`, `Sendable`).
- `ChunkAssembler` — in-order hashing of out-of-order bytes via the
  contiguous-frontier read-back; single-connection runs through it as `N = 1`.
- `ByteRange.split` — file splitting capped by a minimum chunk size.
- The `HEAD` capability probe, `fetchRanged` with N writers in a `TaskGroup`,
  per-range failure cancelling siblings, the single-connection fallback,
  `actualConnectionCount` recorded and kept on completion.
- A default `User-Agent` — `goh/0.1 (+repo)` — on every download request, set
  via `GohCore.downloadSessionConfiguration()`.
- The `Benchmarks/` suite — `goh-bench` driver, `competitive.sh`, the hashing
  benchmark wired into CI. Default workloads rotated to Range-honoring URLs
  (amenable → an archive.org item; saturated → a `dl.google.com` asset, the
  synthetic Cloudflare endpoint having 403'd on `Range`). Each workload
  self-checks its structural assumption at run time — the amenability WARN
  joined by a saturation WARN.
- Engine diagnostics — `Benchmarks/diagnose.sh` plus `GOH_ENGINE_TRACE=1` emit
  per-range start / first-byte / completion timestamps, peak concurrent range
  count, and per-range critical-section time split between the `pwrite`+fsync
  phase and the assembler/progress/store mutex phase. Off in normal runs;
  release builds flip it on without recompiling.

The PR is **draft**, holding on engine investigation (see Pending questions).
CI on the code-correctness path is green; the competitive re-run reproduced
engine regressions (~2× slower than `curl` saturated, ~7× slower than `aria2c`
amenable — three runs in tight agreement, structural not noise).

## Roadmap from here

- **3b** — range-parallel orchestration.
- **3c** — error / retry / cancellation: the retry policy (§2.2 Retry boundary),
  `pause` / `resume` interrupting and resuming a live transfer against the
  checkpoint, `rm` teardown with `keepPartialFile`.
- **4** — `NWPathMonitor` cellular auto-pause (§12).
- **5** — Safari cookie import: `binarycookies` parsing, the Full Disk Access
  flow.
- **6** — Spotlight tagging and sleep assertions.
- **7** — the `goh` CLI client.
- **8** — the TUI for `goh top`.
- **9** — Homebrew formula, signing, notarization, the release pipeline.

## Pending questions for the user

- **Engine regression — diagnose, fix, re-run.** The competitive re-run
  produced outcome 2 with magnitude: saturated `goh` 13.148s vs `curl` 6.661s
  (~2× slower) vs `aria2c` 7.648s (72% slower); amenable `goh` 267.415s vs
  `aria2c` 37.365s (~7× slower) vs `curl` 0.309s. Saturation check PASSed
  (workload structurally valid); amenability check WARNed because the file
  was clearly cached for `curl`. Three runs each in tight agreement. The
  benchmark gate working — caught before merge.

  The cap hypothesis is falsified (`GohCore.downloadSessionConfiguration()`
  already sets `httpMaximumConnectionsPerHost = 16`). Diagnostics ship this
  round. Next: run `Benchmarks/diagnose.sh` against the saturated workload,
  post the trace to PR #14, form a hypothesis from the evidence, fix one
  thing, re-run. As many rounds as it takes. #14 stays in draft until the
  engine produces competitive numbers — no moved goalpost.

## Next-session handoff

Slice 3b is paused on a real engine finding. The competitive re-run against
the rotated defaults reproduced ~2× slower than `curl` saturated and ~7×
slower than `aria2c` amenable — three runs each in tight agreement, structural
not noise. The benchmark discipline working — caught it before merge.

This round shipped diagnostic instrumentation: `Benchmarks/diagnose.sh` plus
`GOH_ENGINE_TRACE=1` emit per-range start/first-byte/completion timestamps,
peak concurrent ranges, and per-range critical-section time split between the
`pwrite`+fsync phase and the assembler/progress/store mutex phase. Off by
default; release-build benchmarks flip it on via the env var. 100 tests
(diagnostics adds 3); CI green on the code-correctness path.

Next: run `Benchmarks/diagnose.sh` against the saturated workload, post the
trace to PR #14, form a hypothesis from the evidence, fix one thing, re-run.
As many rounds as it takes. The slice's definition of done explicitly
required parity on saturated and ≥10% beat on amenable; we have neither, and
#14 stays in draft until the engine produces competitive numbers. Next slice
after 3b: 3c — error / retry / cancellation.
