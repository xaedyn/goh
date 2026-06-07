---
date: 2026-06-07
feature: tray-trust-layer
type: pipeline-retrospective
---

# Pipeline Retrospective — Trust Layer in the Tray

## Adversarial Review Categories That Fired

### Spec Review (round 1: 4 block; round 2: 2 block — fixed; escalated, user accepted)
- Concurrency: `Task.detached` does NOT escape the cooperative pool → would reintroduce the #81
  6-hour starvation; mandated a real OS thread (`DispatchQueue.global().async`/`Thread.detachNewThread`),
  forbade `Task.detached` for the blocking re-hash.
- Read-path divergence: a unified reader was needed so the tray and the runner classify a corrupt
  ledger identically; added `ProvenanceLedgerReader.read → ProvenanceReadOutcome`.
- Cancel/progress contract was deferred to impl — pinned (progress after each file; cancel → partial
  report, no throw; throw only on unreadable).
- Round 2: the unified `unreadable(reason: String)` would have collapsed three FROZEN `verify --all
  --json` error codes — fixed by carrying a structured `LedgerUnreadableReason`; reverted an unjustified
  optional `provenanceStorePath`.

### Plan Review (round 1: 1 block; round 2: APPROVED)
- Round 1: the runner's TEST `@Sendable` closures captured mutable `var`s → would not compile under
  `-warnings-as-errors`; fixed with a `RunnerTestBox` reference box (mirrors the production
  `CancellationBox`). Tightened the unreadable-ledger test to assert the specific error + reason; scrubbed
  stale `Atomic<Bool>` prose to `Mutex<Bool>` (a future reader "fixing" it back would reintroduce the
  `~Copyable` capture trap).
- Round 2: APPROVED — the byte-identical `verify --all` refactor verified line-by-line against the real
  command (three frozen codes + strings incl. version int, entry order, exit codes, summary fold,
  `payloadBytes` input all preserved).

## Approach Selected
**Chosen:** A — Status badge + Trust window.
**THE BET:** a glanceable at-rest summary in the popover is worth the extra section (the tray's reason to
exist is glanceable status).
**Rejected:** B — Trust window only (no at-a-glance status; strictly a subset of A).

## Design Validation Changes
8 gaps fixed at design time, the load-bearing ones: keep `verify --all` byte-identical (extract a shared
`VerifyAllRunner` both CLI and tray call → parity automatic); real-thread re-hash (not the cooperative
pool); unified corrupt/empty classification; per-file error isolation; read-only (daemon stays sole
writer); no new IPC (direct ledger read).

## Open Risks Not Resolved
- Same-user 0600 read of `provenance.plist` from the unsandboxed tray (the CLI already does it) [SINGLE];
  degrades to "Trust data unavailable" if it ever fails.
- Live window behavior (NSOpenPanel-free here, but the background verify progress/cancel UX) is only fully
  confirmable in a running app, not CI — the value layer (runner, reader, presenter) is fully unit-tested.
- Advisories carried into implementation: assert `currentPath` in the progress test; a double-weak-hop
  comment in `startVerify`; merge the two identical `hashEntry` catch arms post-parity-lock.
