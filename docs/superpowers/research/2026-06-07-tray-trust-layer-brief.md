---
date: 2026-06-07
feature: tray-trust-layer
type: research-brief
---

# Research Brief — Trust Layer in the Tray

Mostly internal facts (from the CCB + verified code reads) plus one known repo concurrency gotcha. Tiers:
[VERIFIED] = confirmed in this codebase; [SINGLE] = one internal source; [UNVERIFIED] = reasoning.

## 1. Direct ledger read (no new IPC)
The CLI's `which`/`verify --all` read `provenance.plist` directly via `ProvenanceStore.loadReadOnly()` —
no daemon, no XPC, works daemon-down [VERIFIED — ProvenanceStore.swift, GohWhichCommand.swift]. The
menu app is **unsandboxed** [VERIFIED — no `NSAppSandboxEnabled` in app-Info.plist], so it can read the
same 0600 user-owned file. **Conclusion: the tray reads the ledger directly — no new XPC command, no
`protocolVersion` bump, no daemon dependency.**

## 2. Structured-report seam (the design choice)
`GohVerifyAllCommand.run(...)` returns rendered text + exit code, not the `[VerifyEntryResult]`
[VERIFIED]. The cleanest path to a structured result the tray (and tests) can consume is to **extract a
pure `VerifyAllRunner` into GohCore** that takes a store path (+ a progress/cancel hook) and returns a
`VerifyAllReport`, then have the existing CLI `run()` call it (refactor-in-place, additive, no behavior
change) [design decision]. Alternative — tray calls `run(json:true)` and decodes — needs no GohCore change
but is indirect, gives no progress, and re-implements decoding. **Extraction is preferred** because AC3
(progress + cancel) requires per-file iteration the opaque `run()` doesn't expose, and AC5 (parity) is
trivially satisfied when both the CLI and the tray call the *same* runner.

## 3. Off-main re-hash — progress + cancel (the central risk)
`FileDigest.sha256WithSize` is synchronous blocking I/O; the verify loop is serial with no yield/cancel
[VERIFIED]. **Known repo gotcha [[swift-sync-async-bridge-cooperative-pool-deadlock]]:** running sync
blocking work on a cooperative-pool worker starved CI (#81 hung ~6h). Therefore the runner must execute
on a **real OS thread via `DispatchQueue.global().async`**, NOT `Task.detached` (which stays on the
cooperative pool) and NOT a default `Task` on the cooperative pool [VERIFIED — gotcha]. The runner iterates entries, invoking a
`@Sendable (VerifyProgress) -> Void` callback per file and checking a cancellation flag between files;
on cancel it returns a partial report (or a cancelled state). Results publish back to the `@MainActor`
view model via `MainActor.run`/`@Published` assignment [UNVERIFIED — standard pattern]. Per-file
granularity is sufficient (a single huge file can't be cancelled mid-hash in v1; acceptable).

## 4. Presentation (ROADMAP-safe)
Per "not a full GUI clone": a **summary** in the popover (e.g. "47 tracked · last verify: 45 OK / 1
FAILED / 1 MISSING / —") + **on-demand detail** in a separate window (reuse the Add-Download `Window`
scene + `@StateObject` root pattern already shipped) rather than a large inline per-file list [design].
The "Verify now" button lives in the detail window where progress + cancel have room.

## 5. Honesty: last-recorded vs live
The overview's at-rest status derives from `verifiedAt` (when the daemon last confirmed during a sync),
NOT a live re-hash — it MUST be labelled "last recorded" and visually distinct from a fresh "Verify now"
result, so a stale OK is never shown as a live OK [design; ties to AC1].

## 6. URL safety + empty state
Any `ProvenanceEntry.url` shown passes `URLDisplay.sanitized` [VERIFIED — required]. Absent/empty ledger →
"No downloads recorded yet" (verify-all already treats absent/empty as exit 0/empty report) [VERIFIED].

## Design implications
- Extract `VerifyAllRunner` (GohCore, returns `VerifyAllReport`, takes progress+cancel) — CLI reuses it.
- Tray reads the ledger directly (read-only); a new GohMenuBar trust model + pure presenter + a detail
  window with summary, per-file list, and a background "Verify now" (detached thread, progress, cancel).
- No XPC/wire/frozen-format change; AC5 parity is automatic via the shared runner.
