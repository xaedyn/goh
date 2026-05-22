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

- **Engine regression — root causes #1 and #2 both fixed, ranged path
  verified end-to-end.** The competitive re-run produced outcome 2 with
  magnitude: saturated `goh` 13.148s vs `curl` 6.661s (~2× slower);
  amenable `goh` 267.415s vs `aria2c` 37.365s (~7× slower). The diagnosed
  re-run from the saturated NDK URL surfaced two distinct `URLSession`
  quirks, both fixed (see DESIGN.md §Transport, *URLSession quirks*):

  **#1 — HEAD's `expectedContentLength = -1`.** `URLSession` does not
  populate `expectedContentLength` from `Content-Length` for `HEAD`
  responses on the wire, even when the server sent the header. The probe's
  `expectedContentLength > 0` check therefore always failed and the engine
  always fell back to single-connection. **The range-parallel orchestration
  shipped in 3a/3b had never actually run on the wire** — `MockURLProtocol`
  builds its response from `headerFields:` and populates
  `expectedContentLength`, hiding the quirk in CI. Fixed by parsing
  `Content-Length` from the response header directly.

  **#2 — auto-decompression breaks ranged downloads.** `URLSession`'s
  default `Accept-Encoding: gzip, deflate, br` triggers transparent
  content-decoding. A `Range` over an encoded body returns a partial slice
  of the *encoded* stream, which the decoder can't start mid-stream for
  ranges past 0 (`URLError.cannotDecodeRawData`, -1015) and which
  over-decodes range 0 (proportional overshoot — +7847 bytes on a 9 MiB
  test, +715382 bytes on the 633 MiB saturated NDK, same ~0.7% ratio).
  Verified by isolating in a 4-variant Swift test program against the
  saturated host: the original HTTP/2-multiplexing hypothesis was falsified
  (`Connection: close` and one session per range both kept the same bug
  under h2). Fixed by sending `Accept-Encoding: identity` so the server
  serves uncompressed bytes and URLSession has nothing to auto-decode.

  Post-fix local verification on the 9 MiB ranged URL: 8 ranges complete
  with exact byte counts; peak-active=8; wall-clock 0.373s (vs 0.443s
  single-conn pre-fix). `writeMs` and `reportMs` per range are single-digit
  milliseconds across 18 flushes — the chunk-assembler/mutex coordination
  path is not the bottleneck, ruling out one of the original four
  diagnostic hypotheses. 100 tests still pass; CI green.

  **Next:** user re-runs `Benchmarks/competitive.sh` against the rotated
  defaults. Range-parallel actually runs on the wire now for the first
  time. The slice's definition of done is unchanged — amenable ≥10% over
  `aria2c`, saturated parity. #14 stays in draft until those numbers land.

## Next-session handoff

Slice 3b: range-parallel actually runs on the wire now, for the first time
since 3a. Two `URLSession` quirks were responsible for the regression —
`HEAD`'s `expectedContentLength = -1` made the probe silently fall back to
single-connection, and the default `Accept-Encoding: gzip, deflate, br`
triggered auto-decompression that's structurally incompatible with `Range`
requests. Both fixed and documented in DESIGN.md §Transport (*URLSession
quirks the engine works around*). Local end-to-end verification on a 9 MiB
ranged URL: 8 ranges complete with exact byte counts, peak-active=8, no
errors. 100 tests still pass.

Two of the four original engine-bug hypotheses were ruled out by the trace
data: the connection-cap was already 16, and `writeMs`+`reportMs` per range
are single-digit milliseconds across 18 flushes — chunk-assembler / mutex
coordination is not the bottleneck.

Next: user re-runs `Benchmarks/competitive.sh` against the rotated defaults.
The slice's definition of done is unchanged — amenable ≥10% over `aria2c`,
saturated parity. #14 stays in draft until those numbers land. Next slice
after 3b: 3c — error / retry / cancellation.
