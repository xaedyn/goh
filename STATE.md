# STATE.md — goh current state

Where the project is right now. Read after `CLAUDE.md` at the start of every
session; update at the start of every PR and at the end of every session.

## Current state

- **Branch:** `feat/download-range-parallel`
- **Last merged:** PR #12 — Slice 3a, single-connection HTTP download — `main`
  at `a051819`.
- **Current slice:** 3b — range-parallel orchestration — **PR #14 open in
  draft**, blocked (see Pending questions).
- **Last merged before #14:** PR #13 — the `actualConnectionCount` §1 amendment.

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

Built, tested (95 tests), pushed:

- `DownloadFile` reworked to pure positioned I/O (`pwrite`/`pread`, `Sendable`).
- `ChunkAssembler` — in-order hashing of out-of-order bytes via the
  contiguous-frontier read-back; single-connection runs through it as `N = 1`.
- `ByteRange.split` — file splitting capped by a minimum chunk size.
- The `HEAD` capability probe, `fetchRanged` with N writers in a `TaskGroup`,
  per-range failure cancelling siblings, the single-connection fallback,
  `actualConnectionCount` recorded and kept on completion.
- The `Benchmarks/` suite — `goh-bench` driver, `competitive.sh`, the hashing
  benchmark wired into CI.

The PR is **draft**, holding on two things: GitHub Actions billing (CI cannot
run) and the competitive benchmark run.

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

- **GitHub Actions billing.** CI on PR #14 did not run — "recent account
  payments have failed or your spending limit needs to be increased" (GitHub
  Settings → Billing & plans). CI cannot pass until this is resolved; once it
  is, re-run with `gh run rerun` or a push.
- **Competitive benchmark.** Run `Benchmarks/competitive.sh` on a real network
  and post the numbers to PR #14; then it can be marked ready and merged.

## Next-session handoff

Slice 3b (range-parallel orchestration + the benchmark suite) is complete,
tested — 95 tests — and pushed; PR #14 is open in **draft**. It holds on the
two Pending questions above: GitHub Actions billing (CI blocked) and the
competitive benchmark run. Local hash-overhead preview: ~−2% (within noise —
the read-back is free). Once CI is green and the competitive numbers land,
mark #14 ready and merge. Next slice after 3b: 3c — error / retry /
cancellation.
