# STATE.md — goh current state

Where the project is right now. Read after `CLAUDE.md` at the start of every
session; update at the start of every PR and at the end of every session.

## Current state

- **Branch:** `feat/download-single-connection`
- **Last merged:** PR #11 — session-continuity files — `main` at `7a00315`.
- **Current slice:** 3a — single-connection HTTP download — **complete, in review**.

## Slice 3a — shipped

- Transport-mechanism revision recorded in `DESIGN.md` §Transport.
- Engine job-store transitions — `start` (an atomic claim) / `recordProgress` /
  `complete` / `fail`, driving `queued → active → completed/failed`. `pause`
  narrowed to the 3a no-op-on-active behaviour.
- `DownloadFile` — the disk side: `pwrite` at offset, streaming SHA-256, the
  1 MiB fsync checkpoint, best-effort `F_PREALLOCATE`.
- `DownloadEngine` — single-connection HTTP fetch over `URLSession`, streaming
  the body to disk and driving the job; transport/HTTP errors mapped to
  `GohError`. Tested over a `URLProtocol` mock — CI needs no network.
- Daemon wiring — the dispatcher signals queued jobs; `gohd` runs the engine on
  `add`, on `resume`, and for jobs still queued at startup.
- 84 tests passing.

**Milestone:** the first slice where `goh` moves bytes to disk.

## Next planned slice

3b — range-parallel orchestration: N concurrent `URLSession` tasks with `Range`
headers, the `Accept-Ranges` probe, `requestedConnectionCount` vs
`actualConnectionCount` visibility, single-connection fallback.

## Roadmap from here (post-3a)

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

None currently.

## Next-session handoff

Slice 3a is complete and in review. On merge, start Slice 3b — range-parallel
orchestration: N concurrent `URLSession` range requests, the `Accept-Ranges`
probe that decides whether parallelism is possible, `requestedConnectionCount`
vs `actualConnectionCount` visibility, single-connection fallback.
