# STATE.md — goh current state

Where the project is right now. Read after `CLAUDE.md` at the start of every
session; update at the start of every PR and at the end of every session.

## Current state

- **Branch:** `feat/download-single-connection`
- **Last merged:** PR #10 — Slice 2, job-model persistence — `main` at `fdd8ddf`.
- **Current slice:** 3a — single-connection HTTP download.

## Slice 3a — progress so far

- Transport-mechanism revision recorded in `DESIGN.md` §Transport.
- Engine-facing job-store transitions wired — `start` / `recordProgress` /
  `complete` / `fail`, driving `queued → active → completed/failed`. `pause`
  narrowed to the 3a no-op-on-active behaviour.
- 75 tests passing.

## Slice 3a — remaining

- File-I/O writer: `pwrite`, `F_PREALLOCATE`, streaming SHA-256, the 1 MB
  checkpoint.
- `URLSession` download engine, tested over a `URLProtocol` mock for CI-safe
  tests.
- Daemon wiring so `add` actually starts moving bytes.
- PR when 3a coheres as a whole.

**Milestone when 3a merges:** the first slice where `goh` moves bytes to disk.

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

Continue Slice 3a heads-down. Next step: the file-I/O writer. Then the
`URLSession` engine over a `URLProtocol` mock. Then the daemon wiring. PR when
3a coheres as a whole.
