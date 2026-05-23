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

- **Engine regression — three root causes fixed; saturated PARITY; amenable
  remains route-bound on archive.org.** The original competitive re-run
  showed saturated 2× slower than `curl` and amenable 7× slower than
  `aria2c`. The investigation surfaced and resolved three URLSession
  behaviours, of which the first two are quirks documented in DESIGN.md
  §Transport (*URLSession quirks*):

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
  ranges past 0 (-1015) and over-decodes range 0 (proportional overshoot).
  Verified by isolating in a 4-variant Swift test program against the
  saturated host: the original HTTP/2-multiplexing hypothesis was falsified.
  Fixed by sending `Accept-Encoding: identity`.

  **#3 (engine hygiene) — byte-by-byte AsyncBytes replaced with chunked
  Data delivery.** `URLSession.bytes(for:)` was iterating one async
  suspension per byte (~70M per range on the amenable file). Replaced with
  a `URLSession.dataTask` + `URLSessionDataDelegate` bridge that yields
  `Data` chunks via an `AsyncThrowingStream`. Tested as the amenable-gap
  hypothesis; **falsified** — the asymmetric throughput pattern reproduces
  locally with the new chunked code at the same magnitude. The change
  ships anyway as engine hygiene (~70M async iterations per range becomes
  ~700-760).

  **Competitive re-run (post #1 + #2):**
  - **Saturated PARITY achieved.** `goh` 7.056s vs `aria2c` 7.300s vs `curl`
    6.223s. Saturation check PASS (`aria2c 0.85× curl`, converged). `goh`
    slightly faster than `aria2c`; both pay ~13-17% overhead vs single-conn
    `curl` — the intrinsic cost of parallelism. The slice's hardest target
    is met.
  - **Amenable check WARN'd as expected** (curl 0.3s cached at edge), and
    inside the WARN `goh` is ~5× slower than `aria2c` on the same ranged
    URL (164s vs 33s). The diagnostic trace shows asymmetric throughput
    (1-2 ranges fast, 6-7 throttled to ~430 KB/s) that reproduces locally
    against archive.org. Not a goh code issue — the leading hypothesis is
    archive.org's per-stream rate-limiting under sustained HTTP/2 multiplexed
    load, against which `aria2c`'s HTTP/1.1 + separate-TCP-connection model
    fares better. `URLSession` doesn't expose a clean way to force HTTP/1.1.

  Three of the four original diagnostic hypotheses are now ruled out:
  cap-throttling (cap is 16, observed peak=8); mutex contention
  (`writeMs`+`reportMs` per range stay single-digit milliseconds); and
  AsyncBytes byte-iteration (chunked Data fix didn't change the gap).

  **Next:** the user re-runs `Benchmarks/competitive.sh` against three
  fresh engine optimizations landed this round, aimed at closing the
  saturated 295 ms gap to `curl` and exceeding `aria2c` ≥10% on amenable:

  1. **Speculative ranged GET.** First request is `Range: bytes=0-`, not
     `HEAD`. The 206 response carries `Content-Range` (total) AND starts
     range 0's bytes — one RTT saved per download.
  2. **HTTP/3 per request** via `URLRequest.assumesHTTP3Capable = true`.
     URLSession negotiates `h3` via ALPN (falling back to `h2` then
     `http/1.1` silently). Brings 0-RTT TLS resumption, independent
     per-stream flow control (the HTTP/2-on-archive.org head-of-line
     issue is structurally addressed), connection migration.
  3. **1 MiB flush buffer** (was 64 KiB) — ~16× fewer `pwrite`s; matches
     the cumulative-fsync checkpoint.

  101 tests still pass; local end-to-end download verified. Same three
  outcomes by the framework: (1) check PASS + `goh` ≥10% over `aria2c` →
  validated 3b, mark #14 ready; (2) check PASS but `goh` misses ≥10% →
  cross-host evidence the gap is real, accept saturated parity per the
  README's escape clause and file the residual amenable behaviour as a
  v0.2 investigation; (3) check WARNs → rotate to fallback #2 (large
  GitHub release asset). #14 stays in draft until one outcome lands.

## Next-session handoff

Slice 3b: saturated PARITY achieved (`goh` 7.056s vs `aria2c` 7.300s vs
`curl` 6.223s; saturation check PASS), the slice's hardest target met. Two
URLSession quirks documented in DESIGN.md §Transport were responsible
(HEAD's `expectedContentLength = -1`, and default `Accept-Encoding`
auto-decompression structurally incompatible with `Range`); a third change
(chunked Data via `URLSession.dataTask` + delegate, replacing byte-by-byte
`URLSession.bytes(for:)`) shipped as engine hygiene after being tested and
falsified as the amenable-gap cause.

Three of the four original engine-bug hypotheses are now ruled out
empirically: the connection cap was already 16 (peak-active=8 observed),
`writeMs`+`reportMs` are negligible (mutex/disk path not the bottleneck),
and AsyncBytes byte-iteration didn't change the amenable gap when replaced.
The residual amenable gap (~5× slower than `aria2c` on archive.org) appears
to be URLSession's HTTP/2-multiplexed behaviour against archive.org's
per-stream rate-limiter — reproducible locally, not a goh code issue.

Next: three engine optimizations shipped this round — speculative ranged
GET (saves one RTT per download by skipping the HEAD probe), HTTP/3 per
request (`URLRequest.assumesHTTP3Capable`; URLSession negotiates h3 via
ALPN), 1 MiB flush buffer (16× fewer pwrites). 101 tests; local end-to-end
verified. User re-runs `Benchmarks/competitive.sh` against the rotated
amenable + the new engine; see the three outcomes under Pending questions.
#14 stays in draft until one lands. Next slice after 3b: 3c — error /
retry / cancellation.
