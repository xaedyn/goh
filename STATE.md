# STATE.md — goh current state

Where the project is right now. Read after `CLAUDE.md` at the start of every
session; update at the start of every PR and at the end of every session.

## Current state

### 2026-05-29 — platform floor corrected; wordmark redesign parked

- **Branch:** `docs/macos-floor-26.0`, off `main`. Corrects the supported-OS
  claim from macOS 26.5+ to **26.0+** — the real floor, a hard requirement of
  the daemon's macOS 26.0 XPC peer-validation API (`XPCPeerRequirement`,
  `XPCRequirement.isFromSameTeam`, the requirement-carrying `XPCListener` /
  `XPCSession` initializers). Proven by building at a 15.0 floor and watching the
  compiler reject exactly those symbols. Docs-only plus a `Package.swift` comment;
  the `.macOS("26.0")` value is unchanged. Also fixed the `CLAUDE.md` IPC note
  that had mislabeled `XPCPeerRequirement` as macOS 14+. See `DESIGN.md`
  §Platform support.
- **Logo redesign parked:** a wordmark reconstruction effort (cormorant-italic /
  custom-cormorant / free-font drafts) is committed as WIP on branch
  `fix/smooth-wordmark-vector` (commit `5cf22a5`). Current logo kept as-is;
  direction to be revisited later. Leave that branch alone until then.
- **Prior context (code-review sweep):** branch
  `docs/state-after-code-review-sweep`, based on `main` at `06564af`.
- **Current state:** A full code-review sweep ran across `main` after the menu
  bar smoke pass landed. An LLM-driven Phase-1 codebase audit produced 17
  prioritized findings (S1–S7 significant, M1–M10 minor); the sweep merged
  fixes for the five load-bearing ones plus three minors, caught two
  reviewer-mistake findings via direct code spot-checks (S6 and M9 — both
  rejected), and deferred the remaining seven with documented rationales (a
  vision memo at `docs/vision/VISION-2026-05-26.md`, gitignored, captures the
  product-strategy synthesis). One flaky CI timing assertion surfaced by the
  sweep itself was also fixed, and the menu bar Terminal handoff was extended
  beyond Apple Terminal to auto-detect Ghostty / iTerm / WezTerm / Alacritty /
  kitty (running terminal preferred over merely-installed). Test count rose
  274 → 314.
- **Code-review sweep result (PRs #58–#66):**
  - **#58** — gitignored `docs/vision/` for private strategy memos.
  - **#59** — S1: extracted `XPCReplyDecoder` to collapse seven copies of the
    `withUnsafeUnderlyingDictionary { try? GohEnvelope<X>(...) ... }` decode
    dance into one tested helper. Net –109 / +216.
  - **#60** — M1+M2: centralized `formatBytes` / `progressText` into
    `JobDisplayFormatter` in `GohCore`; standardized percent clamping to
    `[0, 100]` across all four surfaces (CLI table, `goh top`, foreground,
    menu bar). Pre-existing inconsistency: menu bar clamped overruns to 100%
    while the other three rendered values like 200%.
  - **#61** — S3: replaced `_ = try? store.recordProgress(...)` and `_ = try?
    store.fail(...)` masking in `DownloadEngine` with an
    `unexpectedStoreError` reporter. `.jobNotFound` (the expected race when
    `rm` runs concurrently) is still dropped silently; every other store
    failure now lands in `goh.log` with job ID, operation name, and error.
  - **#62** — M5: `goh top` now uses the alternate screen buffer
    (`ESC[?1049h` / `ESC[?1049l`) and redraws in place (`ESC[H` + frame +
    `ESC[J`) instead of clearing + homing every notification. Kills the
    per-update flicker; preserves shell scrollback on exit.
  - **#63** — S2: closed the XPC peer-validation accept-path CI gap by
    testing `peerRequirement(for:)` directly (the factory function the
    production listener consults) plus a fresh `senderSatisfies` assertion
    against the production value. The OS-enforced session-accept path still
    requires a signed-build smoke run; that residual gap is now documented
    in code.
  - **#64** — M4 + M6: `expectedContentLength > 0` → `>= 0` so
    `Content-Length: 0` is a known empty body, not "unknown total." Added
    the missing `@unchecked Sendable` invariant comment on
    `GohXPCNotificationInbox` so it matches the rest of the codebase. M9
    skipped — `XPCReconnect.attempt` is only called from synchronous CLI
    contexts, not the `goh-menu` `Task.detached` path the reviewer cited.
  - **#65** — flaky-test fix: the 500 ms wall-clock bound in
    `removeRangeParallelActiveDownloadCancelsSiblingRanges` (
    `DownloadEngineTests.swift:559`) tripped at 548 ms on PR #59's CI attempt
    1 — three back-to-back local runs measured 88 / 89 / 91 ms, so 548 ms is
    ~6× local scheduling overhead. Raised to `< 2 s` (~22× local headroom,
    still meaningful as a "did not wait for siblings to finish naturally"
    sanity check). The behavioral assertions (partial file + checkpoint
    gone before reply) are the load-bearing checks.
  - **#66** — M10: `goh-menu` Terminal handoff now auto-detects across
    Ghostty (the user's terminal), iTerm2, WezTerm, Alacritty, kitty, and
    Apple Terminal. Two-phase pick: highest-priority **running** terminal
    first (strongest signal for "this is what the user actually uses"),
    then highest-priority **installed** terminal as fallback. Apple Terminal
    is the universal fallback. Each launcher emits a `Process`-ready
    invocation: `osascript` AppleScript for Apple Terminal and iTerm,
    `open -na <App>.app --args -e /bin/sh -c <command>` (xterm-convention)
    for the CLI-based terminals. 22 launcher tests cover priority, the
    running-vs-installed precedence, and AppleScript escaping. Verified
    live: Ghostty's bare `-e <command>` form makes it try to exec a binary
    literally named after the whole command string and fail; the
    `-e /bin/sh -c <command>` wrapping works.
- **Reviewer-mistake findings rejected via spot-check:**
  - **S6** — claim: `ProgressBrokerHub.deliver` holds the lock during
    synchronous `session.send`. Verified false: `deliver(state.withLock {
    ... })` evaluates the closure (acquires + releases the lock) before
    calling `deliver`, so sends already run outside the lock.
  - **M9** — claim: `XPCReconnect.attempt`'s `Thread.sleep` blocks a
    cooperative thread because `goh-menu` calls it from `Task.detached`.
    Grep showed `XPCReconnect.attempt` is only called from synchronous CLI
    contexts (`GohForegroundDownload`, `GohTop`). `Thread.sleep` is correct
    there.
- **Deferred findings (rationales captured in conversation):** S4 (improbable
  fsync-during-verifyHash edge), S5 (unused `NetworkPauseCoordinator` hook —
  dead extension point, harmless), S7 (`PendingDownloadStop` semaphore is
  stylistic), M3 (`JobSummary` encoder `encode` vs `encodeIfPresent` split
  is correct), M7 (`MockURLProtocol.stubs` static-but-guarded-by-UUID-URLs),
  M8 (`SafariCookieJar` intermediate arrays — perf non-issue for ~20
  cookies).
- **Menu bar state:** PR #54 merged the first private menu bar companion slice.
  `goh-menu` is now a SwiftPM-built, dogfood-installed MenuBarExtra backed by
  the same daemon XPC command and progress-subscription surfaces as the CLI. It
  shows daemon health, queue snapshots, active counts, aggregate speed,
  doctor-style recovery copy, clipboard quick-add,
  job controls, Finder reveal, and Terminal handoffs for `goh top` and
  `goh doctor`. PR #56 fixed the root-URL default-destination bug surfaced
  by the first logged-in smoke pass (`https://example.com/` produced
  `~/Downloads/`; now falls back to `~/Downloads/download`). PR #66 then
  taught the Terminal handoff to respect the user's actual terminal.
- **Post-sweep cleanups (PRs #68, #69):** PR #68 rewrote the README's "Why"
  section to lead with what `goh` *is* (architecture + capability list)
  instead of competitor name-drops, removed "10x" buzzwords from
  `ROADMAP.md` / `STATE.md` / the menu bar spec, and clarified that v0.1
  does not actively opt into HTTP/3. PR #69 redacted a home-directory
  path that had appeared in the post-sweep state refresh, reconciled
  DESIGN.md §6 (Observability) with the shipped implementation (`stderr`
  writes today, `os.Logger` migration framed as a v0.2 candidate), and
  tightened `.gitignore` for two local-only files (the Codex-style
  operating manual `AGENTS.md` and `Benchmarks/diagnose-*.log` engine
  traces). A separate `git config user.email` correction was applied
  outside the PR after a prior commit was authored under a personal
  email instead of the GitHub noreply.
- **GitHub account + repo settings hardened (browser-driven):** Enabled
  command-line push protection that rejects future commits authored from
  a personal email. Enabled repository-level Private vulnerability
  reporting, Dependency graph, Dependabot alerts / malware / security
  updates / grouped security updates, and Secret Protection (scanning +
  push protection). Created branch ruleset "Protect main" with basic
  protection: require PRs to merge, block force pushes, block deletions,
  0 required approvals (self-merge OK). 2FA verified enabled (read-only
  check; not modified).
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
  `befa10c`; PR #54 — menu bar companion MB1 — `main` at `56f9ad9`;
  PR #55 — state refresh after menu bar merge — `main` at `4e83522`; PR #56 —
  root-URL default destination fix — `main` at `7121e35`; PR #57 — state
  refresh after menu bar smoke — `main` at `b7bf03d`; PR #58 — gitignore
  `docs/vision/` — `main` at `f239591`; PR #59 — XPCReplyDecoder DRY —
  `main` at `d4a1857`; PR #60 — centralize byte/progress formatting —
  `main` at `5c16ec1`; PR #61 — surface daemon store errors — `main` at
  `4e24106`; PR #62 — `goh top` alternate-screen buffer — `main` at
  `e91b1cb`; PR #63 — XPC peer-requirement coverage — `main` at `a4a4236`;
  PR #64 — robustness sweep (content-length 0, inbox invariant) — `main`
  at `244e9a4`; PR #65 — relax flaky range-cancel timing bound — `main`
  at `dd7c021`; PR #66 — multi-terminal handoff w/ Ghostty — `main` at
  `06564af`; PR #68 — positioning language cleanup — `main` at `fa97d8d`;
  PR #69 — PII redaction + DESIGN §6 reconciliation — `main` at `b09616a`.
  Bookkeeping-only `STATE.md` refresh PRs may be newer than this entry; they do
  not advance the roadmap state.
- **Current slice:** Slice 9, Homebrew formula, signing, notarization, and the
  release pipeline. The first branch shipped the formula/README truth refresh in
  PR #29. PR #30 added CI validation for the in-repo Homebrew formula. The
  PR #31 added an unsigned release-artifact workflow and a reusable local
  packaging script. PR #32 added reusable artifact verification before upload.
  PR #33 documented signing/notarization prerequisites and the credential
  boundary for the remaining release work. PR #34 added an unsigned PKG
  release-candidate artifact and verifier so the direct-download path is
  exercised in CI before credential-backed signing/notarization lands. PR #35
  codified the private release posture: build every release gate, but do not
  publish an official install channel until the explicit public launch decision.
  PR #36 added the manual private signed/notarized/stapled PKG gate and a CI
  verifier for that workflow shape, while keeping official publication out of
  scope. PR #39 recorded the menu bar companion product direction in
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
  saving it under `.build/dogfood/logs`. PR #54 then brought the first native
  menu bar companion slice into private dogfood so non-terminal workflows can be
  exercised before any official install channel opens. PRs #58–#66 ran the
  post-merge code-review sweep and added Ghostty / iTerm / WezTerm /
  Alacritty / kitty support to the menu bar Terminal handoff (see the
  Current state section above for the per-PR breakdown). Test count 274 →
  314; CI green throughout. The remaining slice-9 work is the credential-
  backed signed/notarized PKG release-candidate (PR #36's workflow is
  ready to run with Developer ID secrets) and the Homebrew tap.
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
  health doctor. PR #50 added the private dogfood acceptance gate. PRs #58–#66
  ran a post-merge code-review sweep and shipped multi-terminal handoff support
  in the menu bar.

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

Current branch: `docs/state-after-session-2026-05-26`.

This branch refreshes state after a long session that closed out a
code-review sweep (PRs #58–#66), a positioning + PII cleanup
(PRs #67–#69), and a browser-driven GitHub account + repo settings
hardening pass. `main` is at `b09616a`. 314 tests pass; CI is green;
the menu bar handoff has been live-verified against Ghostty.

**Identity exploration completed in a follow-up session (2026-05-28).**
Brand direction was committed after multi-round image-generation
exploration, several typographic iteration rounds, and
register-comparison sheets. The committed spec, working HTML reference,
prompt templates, design directive, and decision rationale all live
in `docs/vision/` (gitignored). Production handoff work queued in the
spec: production typeface verification, vector mark drawing, icon
asset set export, and a font license decision before the identity is
applied to public surfaces (`goh-menu`, README, brew tap, launch post).

**Highest-leverage pickup, before anything else in this repo:** run the
local audit prompt against other projects under this account. The
`git config user.email` regression caught here (a personal email landed
in a public commit before the post-#69 mitigations were in place) is
likely to recur in other repos. Each occurrence is a separate exposed
email if those repos ever ship publicly. ~10–20 minutes per repo,
asymmetric upside. The audit prompt covers identity leaks, credentials,
PII paths, projected-but-not-shipped feature claims, competitor name
drops, marketing puffery, telemetry, and code-level injection paths.

**Next pickup *here* (in `goh`): cut public v0.1.** Bet 1 from the
gitignored strategy memo at `docs/vision/VISION-2026-05-26.md`:

1. **Sign and notarize the PKG** by running PR #36's
   `private-release-candidate` workflow with Developer ID credentials.
   The workflow shape is already verified by
   `Scripts/verify-private-release-workflow.sh` — what's missing is the
   secrets (`GOH_APP_SIGN_IDENTITY`, `GOH_INSTALLER_SIGN_IDENTITY`,
   notarization credentials).
2. **Open the brew tap** (`xaedyn/homebrew-goh`) and publish the formula
   that PR #29/#30 prepared.
3. **Polish the launch post draft** at
   `docs/vision/LAUNCH-POST-DRAFT.md` (gitignored). Needs a menu bar
   screenshot and a final tone pass. The narrative the vision memo
   lands on: "the macOS download daemon for the AI era — Personal
   Asset Manager, not a faster curl." Reference the buried capabilities
   — `goh diagnose` via `GOH_ENGINE_TRACE=1`, `goh doctor` health gate,
   Spotlight `kMDItemWhereFroms` provenance, sleep assertions, cellular
   auto-pause, the Safari cookie import via fd-passing.
4. **Add `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`** —
   ~30 minutes of writing right before the brew tap opens. `SECURITY.md`
   is the most important (responsible disclosure address for a tool
   that handles cookies and sensitive URLs).
5. **Submit to Hacker News + r/macapps + r/commandline + r/datahoarder.**

**Alternative pickup if v0.1 launch prep is blocked on credentials:**
Bet 2 from the memo — `gohfile.toml` + `goh sync` + `goh verify`.
This is the path to the "Personal Asset Manager" shape and is ~2–4
weeks of work; the persistence and integrity primitives the v0.1
engine already exposes are the foundation. Doesn't depend on signing.

**Note on the local-only files** `AGENTS.md` and
`Benchmarks/diagnose-saturated.log`: both are now properly gitignored
(PR #69). They will no longer appear as untracked in `git status`, but
they remain on disk and should still be left alone.
