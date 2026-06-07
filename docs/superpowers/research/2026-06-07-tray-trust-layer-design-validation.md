---
date: 2026-06-07
feature: tray-trust-layer
type: design-validation
---

# Design Validation — Trust Layer in the Tray (Approach A)

## Acceptance Criteria (from Step 2.5)
- AC1 overview (direct read, "last recorded" labelled, empty-state).
- AC2 per-file provenance (sanitized URL, sha256, dates).
- AC3 background verify (off-main, progress, cancel, OK/FAILED/MISSING).
- AC4 read-only, no `ProvenanceRecord`/`VerifyAllReport`/`protocolVersion` change, no new XPC.
- AC5 parity with `goh verify --all` via the shared runner.

## Dependency Enumeration
Interfaces touched: **`GohVerifyAllCommand`** (GohCore CLI) is refactored to call a new pure
`VerifyAllRunner` — internal change; its public `run(...)` signature, rendered human output, JSON
(`reportVersion 1`), and exit codes (0/2/9/6/64) stay **identical**. External consumers of `verify --all`
= CI/cron via the CLI; they must see **byte-identical** output. New consumer = the tray (calls the same
runner with a progress+cancel hook). The provenance read API (`loadReadOnly`/`allEntries`/`lookup`) is
used as-is, read-only. No XPC `Command`/wire change. No `Sources/GohCore` frozen-format change.

## Questions Asked & Answers

### Zero Silent Failures
- **Existing users on ship?** Additive: a popover summary section + a Trust window. No migration; existing
  popover/jobs behavior unchanged.
- **Existing data?** Read-only. The runner extraction must keep `verify --all` output byte-identical —
  guarded by the existing `GohVerifyAllCommandTests` + the `verify-all-report-v1.json` golden fixture,
  which must pass UNCHANGED. This is the load-bearing constraint of the refactor.
- **Existing integrations?** CI/cron `verify --all` (incl. `--json`) output unchanged — same report, same
  rendering, same exit codes.
- **Partial failure?** A cancelled/errored verify writes nothing (read-only) → no corruption; the window
  shows a partial/cancelled state. A corrupt/unreadable ledger → a friendly tray error state (mirrors
  verify-all exit 6), not a crash.

### Failure at Scale
- **10x?** Summary read (`allEntries()` plist decode) is fast for hundreds of entries; runs off-main. The
  re-hash is the cost — backgrounded with progress + cancel; `FileDigest` streams 1 MiB chunks (no
  full-file load), so memory stays flat on huge files.
- **Concurrent?** Only one verify at a time: "Verify now" is disabled while a run is in progress; cancel
  stops it. A daemon ledger write during a verify is harmless — the tray verifies the in-memory snapshot
  it loaded at start; the daemon's atomic plist write doesn't mutate that snapshot.
- **External dep unavailable?** Daemon down → ledger still readable (direct read). Ledger absent/empty →
  "No downloads recorded yet".

### Simplest Attack
- **Cheapest abuse?** None new — read-only, local, single-user, the user's own 0600 ledger and own files.
- **New endpoint auth?** No new XPC/endpoint — direct disk read. No new IPC surface.
- **Poisoned ledger entry?** URLs shown pass `URLDisplay.sanitized`. A weird `destinationPath` only causes
  a per-file read the user could already do → classified MISSING/FAILED; no write, no escalation. The
  runner must isolate per-file errors (one bad path ≠ abort the run).

## Gaps Found
1. Refactor must keep `verify --all` output byte-identical (CI/cron + golden fixture).
2. Per-file error isolation — unreadable/missing/directory path → MISSING/FAILED, run continues.
3. Single concurrent verify — disable "Verify now" while running; provide cancel.
4. Cancellation granularity is per-file (can't cancel mid-single-file hash) — documented; partial result.
5. Corrupt/unreadable ledger → friendly tray error state, not a crash.
6. "Last recorded" (at-rest, from `verifiedAt`) must be visually distinct from a live "Verify now" result.
7. Re-hash must run on a dedicated thread, NOT the cooperative pool ([[swift-sync-async-bridge-cooperative-pool-deadlock]]).
8. Even the cheap summary read runs off the MainActor and publishes back (no popover hitch).

## Fixes Applied (folded into the spec)
1. The shared `VerifyAllRunner` returns the same `VerifyAllReport`; `run()` renders it unchanged; existing
   verify-all tests + golden fixture are a required regression gate (AC5 + AC4).
2. Runner catches per-file digest errors → MISSING/FAILED, continues (preserves current CLI behavior).
3. Spec: "Verify now" disabled while running; cancel button; one run at a time.
4. Spec: per-file cancellation granularity; cancel yields a partial/cancelled result, no write.
5. Spec: a corrupt/unreadable ledger maps to a tray error state mirroring exit 6.
6. Spec: distinct labels/sections for at-rest "last recorded" vs live verify results.
7. Spec: runner executes on a dedicated thread (`Task.detached`/explicit thread), progress + cancel via a
   `@Sendable` hook + cancellation check between files; results published via `@MainActor`.
8. Spec: the popover summary loads `allEntries()` off-main and publishes to the `@MainActor` model.

No gap required a user decision; all resolved at design time.
