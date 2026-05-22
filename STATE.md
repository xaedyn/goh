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

- **Engine regression — root cause #1 found, root cause #2 in flight.** The
  competitive re-run produced outcome 2: saturated `goh` 13.148s vs `curl`
  6.661s (~2× slower); amenable `goh` 267.415s vs `aria2c` 37.365s (~7×
  slower). Three runs each in tight agreement.

  **Root cause #1 (fixed this round).** The `HEAD` capability probe checked
  `URLResponse.expectedContentLength > 0`, but `URLSession` returns `-1`
  (`NSURLResponseUnknownLength`) for `HEAD` responses on a real network even
  when the server sent `Content-Length` (empirically verified on macOS 26).
  The probe always fell back to `.single`, so the engine has been
  single-connection only on every real download since Slice 3a — the
  range-parallel orchestration ran in tests (under `MockURLProtocol`, which
  populates `expectedContentLength` from headers and doesn't reproduce the
  real-`URLSession` quirk) but never on the wire. That accounts for the
  saturated 2× (goh single vs curl single, plus byte-by-byte `AsyncBytes`
  overhead) and the amenable 7× (goh single vs aria2c 8-conn). Fixed by
  parsing `Content-Length` from the response header directly.

  **Root cause #2 (next round).** Post-fix local verification on a 9 MiB
  ranged URL shows the trace emits as designed (peak active = 8, 8 ranges
  start concurrently). It also reproducibly exposes a second bug: range 0
  receives 7847 bytes past its requested length (1151390 vs 1143543, exactly
  +7847 across three runs) and the download fails with `connectionFailed`.
  Likely an HTTP/2 multiplexing or `URLSession.bytes(for:)` boundary issue;
  speculation deferred until the diagnostic re-run produces evidence.

  The cap hypothesis stays falsified (`httpMaximumConnectionsPerHost = 16`).
  #14 remains in draft. Next: user re-runs `Benchmarks/diagnose.sh` against
  the saturated workload, posts the trace, we form a hypothesis from the
  evidence for root cause #2 — same loop, one change at a time.

## Next-session handoff

Slice 3b: the engine has been single-connection only on every real download
since Slice 3a. Root cause #1 found and fixed this round — the `HEAD` probe
relied on `URLResponse.expectedContentLength`, which `URLSession` does not
populate for `HEAD` on a real network (returns `-1`). Fix parses
`Content-Length` from the response header directly. 100 tests still pass.

Post-fix local verification shows the trace now emits cleanly and 8 ranges
genuinely run concurrently — and it also exposes root cause #2: range 0 over-
delivers by exactly 7847 bytes and the download then fails with
`connectionFailed`, reproducibly across three runs against a 9 MiB ranged URL.
The range-parallel orchestration code shipped in 3a/3b is therefore freshly
untested on the wire; the next round investigates #2 from the diagnosed
re-run's trace.

Next: user re-runs `Benchmarks/diagnose.sh` against the saturated workload —
it will likely fail in the same shape against the NDK URL, and the trace is
the evidence for #2. Form a hypothesis from the evidence, fix one thing,
re-run. As many rounds as it takes. #14 stays in draft until the engine
produces competitive numbers. Next slice after 3b: 3c — error / retry /
cancellation.
