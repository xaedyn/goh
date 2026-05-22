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

Built, tested (97 tests), pushed:

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
  synthetic Cloudflare endpoint having 403'd on `Range`). Each workload now
  self-checks its structural assumption at run time — the amenability WARN
  joined by a saturation WARN.

The PR is **draft**, holding on the competitive benchmark run; CI is green.

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

- **Competitive benchmark re-run.** Run `Benchmarks/competitive.sh` on a real
  network against the rotated defaults and post the numbers to PR #14. The prior
  indicative run (~17% over `aria2c` on amenable, but the amenability check
  WARNed — not validated) is already posted to #14 for the record. The re-run
  has three possible outcomes:
  1. Both checks PASS and `goh` beats `aria2c` by ≥10% on amenable — the
     validated 3b measurement; mark #14 ready, CodeRabbit reviews, merge.
  2. Both checks PASS but `goh` misses ≥10% — a real finding; surface what
     bottlenecked (likely a profiling pass), decide tune-in-3b vs accept
     parity for v0.1. No moved goalpost.
  3. Either check WARNs — rotate that workload's URL again (the README's
     ranked fallback list), commit, re-run.
  #14 stays in draft until one of the three lands.

## Next-session handoff

Slice 3b is complete, tested — 97 tests — and pushed; PR #14 is open in
**draft** with CI green. The orchestration code and the hashing measurement are
settled. This round rotated the benchmark default workloads to Range-honoring
URLs, added a default `User-Agent`, and gave the saturated workload a run-time
self-check to match the amenable one — both workloads now validate their
structural assumption at run time. The prior indicative numbers are posted to
PR #14, honestly framed.

The competitive benchmark *re-run* against the rotated defaults is the only
outstanding piece — see the three outcomes under Pending questions. #14 stays
draft until one of them lands; then mark it ready (CodeRabbit reviews on
un-draft, since it skips drafts) and merge. Next slice after 3b: 3c — error /
retry / cancellation.
