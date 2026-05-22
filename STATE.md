# STATE.md — goh current state

Where the project is right now. Read after `CLAUDE.md` at the start of every
session; update at the start of every PR and at the end of every session.

## Current state

- **Branch:** `feat/download-range-parallel`
- **Last merged:** PR #12 — Slice 3a, single-connection HTTP download — `main`
  at `a051819`.
- **Current slice:** 3b — range-parallel orchestration — **scoping** (the
  scoping note is pending review).

## Slice 3a — shipped (the milestone: `goh` moves bytes to disk)

- Engine job-store transitions — `start` (an atomic claim) / `recordProgress` /
  `complete` / `fail`, driving `queued → active → completed/failed`.
- `DownloadFile` — `pwrite` at offset, streaming SHA-256, the 1 MiB fsync
  checkpoint, best-effort `F_PREALLOCATE`.
- `DownloadEngine` — single-connection HTTP fetch over `URLSession`.
- Daemon wiring — `gohd` runs the engine on `add`, on `resume`, and for jobs
  still queued at startup.
- 84 tests; the engine path is tested over a `URLProtocol` mock.

## Slice 3b — range-parallel orchestration (scoping)

N concurrent `URLSession` range requests; the `Accept-Ranges` + `Content-Length`
probe; `requestedConnectionCount` vs `actualConnectionCount`; single-connection
fallback. Two known design points the scoping note addresses: concurrent
offset-writers reworking `DownloadFile`, and in-order hashing of out-of-order
bytes (the chunk assembler). The definition of done includes benchmark targets
against `aria2` and `curl`.

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

- The Slice 3b scoping note is awaiting review — scope, the `DownloadFile`
  concurrent-writer rework, the chunk-assembler hashing approach, and the
  benchmark targets that form part of 3b's definition of done.

## Next-session handoff

Slice 3b is scoped but not yet started — the scoping note is pending review.
Once the scope and the benchmark targets are confirmed, build 3b heads-down:
the `Accept-Ranges` probe, range splitting, concurrent offset-writers, the
chunk assembler, single-connection fallback. Then the benchmark harness and a
documented `goh` vs `aria2` vs `curl` run.
