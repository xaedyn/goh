# STATE.md — goh current state

Where the project is right now. Read after `CLAUDE.md` at the start of every
session; update at the start of every PR and at the end of every session.

## Current state

- **Branch:** `main` after PR #52 (this bookkeeping branch only refreshes state)
- **Last roadmap merge:** PR #22 — Spotlight tagging and sleep assertions —
  `main` at `5b3884d`; PR #23 — one-shot CLI commands — `main` at `db9b82a`;
  PR #24 — CLI add options and JSON list — `main` at `58c2e73`; PR #25 — progress
  subscription contract — `main` at `c31283d`; PR #26 — backend progress
  subscription plumbing — `main` at `976775f`; PR #27 — foreground progress
  CLI — `main` at `076bfaf`; PR #28 — top progress dashboard — `main` at
  `0adf0a7`; PR #29 — release-packaging surface refresh — `main` at
  `2e1c3c7`; PR #30 — Homebrew formula validation in CI — `main` at
  `5ad60b6`; PR #31 — release artifact workflow — `main` at `e79c0bd`;
  PR #32 — release artifact verification — `main` at `b668aa0`; PR #33 —
  release signing prerequisites — `main` at `580b7c2`; PR #34 — unsigned PKG
  release artifact — `main` at `865d6aa`; PR #35 — private release posture —
  `main` at `33b1ea9`; PR #36 — private signed release gate — `main` at
  `b7e22e6`; PR #39 — menu bar companion roadmap/spec — `main` at `c2f4911`;
  PR #40 — local dogfood lane — `main` at `fd93b8d`; PR #47 — active `rm`
  cleanup hardening — `main` at `54317a9`; PR #49 — local health doctor —
  `main` at `ff45e99`; PR #50 — private dogfood acceptance gate — `main` at
  `cbe2c61`; PR #51 — state refresh after acceptance gate merge — `main` at
  `0aa3887`; PR #52 — dogfood performance evidence output — `main` at
  `befa10c`.
  Bookkeeping-only `STATE.md` refresh PRs may be newer than this entry; they do
  not advance the roadmap state.
- **Current slice:** Slice 9, Homebrew formula, signing, notarization, and the
  release pipeline. The first branch shipped the formula/README truth refresh in
  PR #29. PR #30 added CI validation for the in-repo Homebrew formula. The
  PR #31 added an unsigned release-artifact workflow and a reusable local
  packaging script. PR #32 added reusable artifact verification before upload.
  PR #33 documented signing/notarization prerequisites and the credential
  boundary for the remaining release work. PR #34 added an unsigned PKG
  release-candidate artifact and verifier so the 10x direct-download path is
  exercised in CI before credential-backed signing/notarization lands. PR #35
  codified the private release posture: build every release gate, but do not
  publish an official install channel until the explicit public launch decision.
  PR #36 added the manual private signed/notarized/stapled PKG gate and a CI
  verifier for that workflow shape, while keeping official publication out of
  scope. PR #39 recorded the 10x native menu bar companion product direction in
  the roadmap and a design spec. PR #40 added the local dogfood lane so the
  product can be used and tested privately from source before any official
  install channel opens.
  PR #42 fixed dogfood-discovered destination parent-directory creation at
  `6506089`, PR #43 refreshed state at `5247964`, PR #44 fixed dogfood usability
  gaps in `goh top` at `34d8646`, PR #45 added the product catchphrase to
  restrained visible surfaces at `4c6a784`, and PR #47 fixed the dogfood-
  discovered active `rm` path where a resumed or range-parallel download could
  leave a visible partial file behind after the catalog row was removed. PR #47
  also tightened the file-ownership boundary so `rm` of a queued never-started
  job does not delete a pre-existing destination file. PR #49 added `goh
  doctor` as a read-only local health gate for private dogfood: it checks the
  dogfood binaries, LaunchAgent, launchd load state, XPC queue reachability,
  peer-relaxation setup, writable local paths, and daemon log posture, then
  prints exact recovery commands without adding daemon IPC surface. PR #50 added
  the private readiness acceptance gate above smoke: build/install, doctor,
  smoke, foreground download, JSON list, active pause/resume/remove cleanup,
  daemon restart, and opt-in competitive performance comparison. PR #52 made
  that `--performance` path evidence-grade by streaming the benchmark table and
  saving it under `.build/dogfood/logs`.
- **Slice 7 progress:** the first CLI implementation pass adds a testable
  `GohCore` command-line runner for the one-shot control verbs: `goh add`,
  `goh ls`, `goh pause`, `goh resume`, and `goh rm [--keep]`. `Sources/goh`
  is now thin process I/O plus the real XPC sender, and the existing
  `goh auth import safari` flow is routed through the same runner. The CLI
  returns `64` for local usage errors, `1` for daemon/transport failures, and
  prints `brew services start goh` guidance when the daemon is unreachable.
  Foreground `goh <url>` shipped in PR #27 as a live subscriber over the progress
  subscription path rather than a background-add alias.
  The follow-up CLI polish branch exposes already-frozen `add` options
  (`--output`, `--connections`, `--priority`, `--no-cookies`) and adds
  `goh ls --json` over the existing `LsReply` payload. PR #25 froze the
  load-bearing progress subscription contract: `Command.subscribe`,
  `SubscribeReply`, `ProgressEvent`, full in-scope progress snapshots,
  progress-model revisions, explicit `fullSnapshot` update events, 100 ms
  coalescing, foreground reconnect, and `goh top` subscription behavior. The
  PR #26 shipped the v3 wire schema, golden fixtures, protocol-version bump,
  session-aware XPC transport wrappers, broker-backed `subscribe` replies and
  notifications, `JobStore` progress publishing, and daemon composition through
  `ProgressBrokerHub`. PR #27 implemented foreground `goh <url>` as `add` plus
  `subscribe(scope: job, jobID:)` on one session. PR #28 shipped the first
  `goh top` dashboard over `subscribe(scope: all)`.
- **Slice 5 progress:** the first implementation step adds a pure in-memory
  `GohCore` Safari `Cookies.binarycookies` parser with Swift Testing coverage
  for page tables, offset-based strings, flags, Cocoa dates, and malformed
  inputs. The second step adds in-memory RFC 6265-style URL matching and
  `Cookie` header serialization with conservative host-only handling for bare
  Safari domains. The third step adds a download-engine cookie-header provider
  hook so initial, range-parallel, and resume requests can carry daemon-supplied
  cookies. The fourth step wires the frozen `add.useImportedCookies` field to a
  volatile per-job header snapshot and clears it on `rm`. No persistent
  cookie-store format or new IPC command has been added. The fifth step adds the
  Safari cookie-file locator for the modern container path plus legacy fallback.
  The sixth step composes one daemon-local `ImportedCookieStore` into both the
  dispatcher and `DownloadEngine`, so the already-built hooks are live in
  `gohd` without adding a new command. PR #19 shipped these non-wire
  foundations. PR #20 froze the load-bearing command/FDA contract for the
  remaining `goh auth import safari` surface. PR #21 implemented the
  `protocolVersion = 2` command, including XPC fd passing, daemon parse/import,
  and CLI Full Disk Access handling. PR #22 shipped Spotlight completion
  metadata and active-download sleep assertions. Slices 5 and 6 are shipped.
- **Last merged before #16:** PR #15 — core correctness gates — `dcdf709`.
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

## Slice 3b — range-parallel orchestration (shipped)

Built, tested (101 tests), pushed:

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

Merged as PR #14. The final validated run accepted parity-for-v0.1 and moved the
remaining adaptive host scheduling work to v0.2.

## Roadmap from here

- **3c** — shipped in PR #17: checkpoint/resume implementation, error / retry /
  cancellation, live `pause` / `resume`, and `rm --keep` partial adoption.
- **4** — shipped in PR #18: `NWPathMonitor` cellular auto-pause (§12).
- **5** — shipped across PR #19, PR #20, and PR #21: Safari cookie import
  foundation, auth import command contract, and implementation.
- **6** — shipped in PR #22: Spotlight tagging and sleep assertions.
- **7** — shipped across PR #23, PR #24, and PR #27: the `goh` CLI client.
- **8** — shipped in PR #28: the TUI for `goh top`.
- **9** — in progress: Homebrew formula, signing, notarization, the release pipeline.
  PR #29 refreshed the pre-release formula/docs surfaces. PR #30 added formula
  validation to CI. PR #31 added unsigned release artifacts and checksums. PR #32
  added packaged-artifact verification. PR #33 documented signing and
  notarization prerequisites. PR #34 added an unsigned PKG artifact and verifier
  for the future direct-download channel. PR #35 removed premature public install
  guidance and recorded the private launch gate. PR #36 added a manual private
  signed/notarized PKG release-candidate workflow that can be run only with
  credentials and an explicit workflow-dispatch input. PR #49 added the local
  health doctor. PR #50 added the private dogfood acceptance gate.

## Recent 3b validation notes

- **3b validated — parity-for-v0.1 accepted.** See the validated-measurement
  comment on PR #14 for the full numbers and reasoning. Saturated criterion
  met with margin (`goh` 7.020s vs `aria2c` 7.293s vs `curl` 6.802s at the
  default 8 conn — slight win over `aria2c`, 3.2 % behind `curl`'s
  single-stream ceiling). Amenable parity confirmed (`goh` 10.915s vs
  `aria2c` 10.958s at 8 conn; 16-conn data point widens `aria2c`'s lead
  marginally — the gap is the structural HTTP/2-vs-N-TCP one we've been
  circling, not a `goh` code defect).

  The investigation that got here surfaced and resolved three URLSession
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

  **HTTP/3 trial reverted.** A first round of three optimizations
  (speculative ranged GET, per-request `URLRequest.assumesHTTP3Capable`,
  1 MiB flush buffer) regressed the saturated workload by ~45 %
  (`goh` 6.607s → 10.754s median, with run-to-run variance suggesting
  server-side rate-limiting against h3 traffic on this network path).
  `aria2c` and `curl` stayed flat. HTTP/3 reverted; skip-HEAD and 1 MiB
  buffer kept (they don't show the variance signature). The slice landed
  a per-range `protocol=` trace line so the next h3 attempt isn't blind.

  **Final state at merge:** speculative ranged GET (one RTT saved per
  download), 1 MiB flush buffer (~16× fewer pwrites), per-range protocol
  diagnostic, all URLSession quirks (HEAD `expectedContentLength = -1`
  and Range-incompatible auto-decompression) worked around, two committed
  default benchmark workloads with run-time amenability/saturation checks,
  the engine diagnostics that drove this slice's debugging cycles. 101
  tests; CI green.

## Next-session handoff

Current branch: `main` after PR #52. The current bookkeeping branch only
refreshes this state file.

PR #50 is merged at `cbe2c61`. The local dogfood lane now has three private
readiness gates on `main`: build/install/smoke, `goh doctor`, and
`Scripts/dogfood-acceptance.sh`. The acceptance gate builds and installs the
dogfood debug build, runs doctor and smoke, checks `goh ls --json`, exercises
foreground `goh <url>`, pause/resume/remove cleanup on an active larger
download, daemon restart, and an opt-in `Benchmarks/competitive.sh` performance
pass via `--performance`.

PR #52 fixed a usability hole found during manual performance dogfood:
`Scripts/dogfood-acceptance.sh --performance` ran the competitive benchmark but
hid the timing table on success. The fix streams the benchmark output to the
terminal, saves it to
`.build/dogfood/logs/acceptance-performance-*.log`, and prints the saved
`Performance log:` path.

The local dogfood LaunchAgent is currently loaded and running:

- LaunchAgent: `~/Library/LaunchAgents/dev.goh.daemon.plist`
- Binaries: `.build/dogfood/current/bin`
- Logs: `.build/dogfood/logs/goh.log`
- Downloads: `.build/dogfood/downloads`

Merged PR #47 gates:

- `git diff --check`
- `swift build -Xswiftc -warnings-as-errors`
- `swift test` (218 tests)
- `Scripts/dogfood-build.sh`
- `Scripts/dogfood-install.sh`
- `Scripts/dogfood-smoke.sh --timeout 30`
- live dogfood check: add the Ubuntu 26.04 ISO, pause, resume, then `goh rm`
  while active; the job disappears, the destination is removed, and `lsof` shows
  no daemon handle on the removed path.
- PR #47 CI: `Build & test` and `Package release artifacts` passed after the
  CI scheduling-flake fix was amended into the branch. CodeRabbit's actionable
  file-ownership review was fixed with a red/green regression; the thread is
  resolved and outdated.

PR #50 private-readiness verification:

- `bash -n Scripts/dogfood-acceptance.sh`
- `Scripts/verify-dogfood-kit.sh`
- `git diff --check`
- `swift build -Xswiftc -warnings-as-errors`
- `swift test` (223 tests)
- `Scripts/dogfood-acceptance.sh --timeout 45`
  - build/install/doctor/smoke passed
  - smoke, foreground, and active-control test files were cleaned up
  - `goh ls --json`, foreground `goh <url>`, active pause/resume/remove,
    active partial removal, `lsof` handle check, daemon restart, and
    post-restart doctor passed
  - performance comparison was intentionally skipped by default; run
    `GOH_ACCEPTANCE_PERF_RUNS=1 Scripts/dogfood-acceptance.sh --performance`
    when a live competitive network pass is desired

PR #50 GitHub gates:

- PR #50 CI `Build & test`: passed.
- PR #50 CI `Package release artifacts`: passed.
- PR #50 private signed/notarized PKG gate: skipped as expected without
  credentials/manual dispatch.
- CodeRabbit produced only a rate-limit notice and no actionable review threads.

Manual performance evidence from 2026-05-25 after PR #50:

- `GOH_ACCEPTANCE_PERF_RUNS=3 Scripts/dogfood-acceptance.sh --performance`
  passed, but hid the benchmark table.
- Running `RUNS=3 Benchmarks/competitive.sh | tee .build/dogfood/logs/...`
  showed:
  - amenable: `goh` 10.728s, `aria2c` 10.517s, `curl` 29.285s; workload check
    passed.
  - saturated: `goh` 6.561s, `aria2c` 7.192s, `curl` 6.204s; workload check
    passed.
  - conclusion: performance is competitive enough that product polish can move
    ahead before adaptive scheduling, unless a later logged acceptance run
    shows a material regression.

PR #52 branch verification:

- Red check observed: `Scripts/verify-dogfood-kit.sh` failed before the script
  change because `Scripts/dogfood-acceptance.sh` did not contain
  `acceptance-performance-`.
- `Scripts/verify-dogfood-kit.sh`
- `bash -n Scripts/dogfood-acceptance.sh`
- `git diff --check`
- `GOH_ACCEPTANCE_PERF_RUNS=1 AMENABLE_URL=https://example.com/ SATURATED_URL=https://example.com/ Scripts/dogfood-acceptance.sh --timeout 45 --performance`
  streamed the benchmark table, printed `Performance log:`, saved the log under
  `.build/dogfood/logs/acceptance-performance-20260525221708-29523.log`, and
  ended with the expected warning because `example.com` is not an amenable
  workload.
- `swift build -Xswiftc -warnings-as-errors`
- `swift test` (223 tests)

PR #52 GitHub gates:

- PR #52 CI `Build & test`: passed.
- PR #52 CI `Package release artifacts`: passed.
- PR #52 private signed/notarized PKG gate: skipped as expected without
  credentials/manual dispatch.
- CodeRabbit generated no actionable comments and no review threads.

Next pickup: choose the next 10x private-readiness/product slice. Apple
credentials are still unavailable, so public signing/notarization remains
blocked by design; the strongest next option is likely the first native menu
bar companion implementation slice, with adaptive per-host scheduling deferred
until logged benchmark evidence shows a material gap.

Leave unrelated untracked files (`AGENTS.md`,
`Benchmarks/diagnose-saturated.log`) untouched.
