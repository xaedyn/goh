---
date: 2026-06-07
feature: tray-trust-layer
type: spec
approach: A — Status badge + Trust window
status: draft
revision: 2 (post adversarial spec review round 1 — 3 block issues fixed)
---

# Spec — Trust Layer in the Tray

## 1. Problem

goh's differentiator is the trust layer — "is this still exactly what I downloaded, and where did it
come from?" — but it is only reachable from the CLI (`goh which`, `goh verify --all`). The tray app shows
in-flight download progress but nothing about provenance or integrity. This spec surfaces, read-only, the
provenance **overview** (what's tracked, source, dates, last-recorded status) in the popover and a Trust
**window** with per-file detail and an on-demand **background verify** (re-hash → OK/FAILED/MISSING). It
does NOT re-implement the engine, does NOT write the ledger, and does NOT change any wire/on-disk format.

## 2. Success metrics

Done = all five ACs (`docs/superpowers/research/2026-06-07-tray-trust-layer-acceptance-criteria.md`) hold,
plus:
- `swift build -warnings-as-errors` clean; full existing suite green (currently 758) + new tests.
- The popover shows a trust summary from a direct, off-main ledger read; empty/absent ledger →
  "No downloads recorded yet".
- A Trust window lists per-file provenance (sanitized URL, sha256, downloaded/last-verified dates) and a
  "Verify now" that re-hashes off the main actor with visible progress + working cancel, ending in an
  OK/FAILED/MISSING summary that **matches `goh verify --all`** for the same ledger.
- **`goh verify --all` output is byte-identical to before** (human + `--json` + exit codes + entry order):
  the existing `GohVerifyAllCommandTests`, the `verify-all-report-v1.json` golden fixture, AND the **attest
  tests** pass UNCHANGED. (`goh attest` re-decodes `verify --all --json` and signs `payloadBytes(for:)` —
  a second consumer of the exact bytes; the refactor must not alter that signed input.)
- No diff to frozen formats; `protocolVersion` unchanged; no new XPC command; the tray makes no
  `record`/`recordVerified` calls.

Rollback trigger: any existing test regresses (esp. verify-all output), or the tray writes the ledger, or
the re-hash runs on the cooperative pool / freezes the popover.

## 3. Out of scope
- **Per-file "verify just this one"** in the window (cheap future add via the untouched `goh verify`).
- **Writing/repairing** the ledger or re-downloading drifted files (verify-only, daemon stays sole writer).
- **A new XPC command / daemon push of trust data** — the tray reads the ledger directly.
- **Live auto-verify / background drift watch** (FSEvents) — deferred elsewhere.
- **Changing `ProvenanceRecord` (v1) or `VerifyAllReport` (reportVersion 1)** or the per-file
  `GohVerifyCommand`.
- **Mid-single-file cancellation** — cancel is per-file granularity.

## 4. Behavior & flow
- **Popover summary (Approach A):** on popover open, load `ProvenanceStore.allEntries()` off-main and
  publish a one-line summary: tracked count + at-rest breakdown derived from `verifiedAt` (e.g. "47 files
  tracked · last recorded: 45 verified · 2 download-only"), explicitly labelled **last recorded** (NOT a
  live check). Absent/empty → "No downloads recorded yet". A read failure → "Trust data unavailable"
  (mirrors verify-all's ledger-error path), never a crash. A "Verify…/Trust…" entry opens the Trust window.
- **Trust window** (`Window(id:"trust")` + `@StateObject` root, same pattern as Add-Download):
  - A **per-file list**: for each `ProvenanceEntry` — file name/path, source URL via `URLDisplay.sanitized`,
    `sha256`, downloaded date, last-verified date (the `goh which` field set), and an at-rest status chip
    ("downloaded" / "verified <date>").
  - A **"Verify now"** button → runs the shared `VerifyAllRunner` on a dedicated thread; the window shows
    **progress** (files done / total, current file optional) and a **Cancel** button; "Verify now" is
    disabled while a run is in progress (one run at a time). On completion: a **live** summary +
    per-file live status (OK/FAILED/MISSING), visually distinct from the at-rest labels. On cancel: a
    partial/cancelled state; nothing written.
  - Empty/absent ledger → empty state; "Verify now" is **disabled** (consistent with the disabled-while-
    running rule). Unreadable/corrupt ledger → "Trust data unavailable"; "Verify now" disabled.

## 5. Security surface
- **No new IPC / no wire change.** Trust data is read directly from the user-owned 0600
  `provenance.plist` (the unsandboxed tray, like the CLI). No new XPC `Command`; `protocolVersion`
  unchanged.
- **Read-only.** The tray calls only `loadReadOnly()`/`allEntries()`/`lookup()`. It NEVER calls
  `record`/`recordVerified`. The daemon remains the sole writer.
- **No new untrusted input.** Trust data is the user's own daemon-written ledger. Any `url` shown passes
  `URLDisplay.sanitized` (control-char strip + credential redaction). A re-hash reads only files the user
  already owns; a malformed `destinationPath` yields MISSING/FAILED, never a write or escalation.
- **Concurrency safety.** The re-hash runs on a **real OS thread** (`Thread.detachNewThread`/dedicated
  `DispatchQueue`), NOT `Task.detached` or any default `Task` — those stay on the fixed-width cooperative
  pool and the suspension-point-free hashing loop would starve it ([[swift-sync-async-bridge-cooperative-pool-deadlock]]);
  results publish back via `@MainActor`.

## 6. Edge cases
- **Absent / empty ledger:** "No downloads recorded yet"; verify is a no-op empty report (exit-0 analog).
- **Corrupt / unreadable ledger:** friendly "Trust data unavailable" state (mirrors verify-all exit 6);
  no crash.
- **Per-file read error during verify** (missing file, directory, permission): classified MISSING/FAILED;
  the run **continues** (one bad file never aborts the batch) — preserves current CLI behavior.
- **Huge single file:** streamed (1 MiB chunks), flat memory; cannot be cancelled mid-file (per-file
  granularity) — documented.
- **Cancel mid-run:** stops before the next file; shows partial/cancelled; writes nothing.
- **Concurrent "Verify now":** disabled while running; exactly one run at a time.
- **Daemon writes the ledger during a verify:** the tray verifies the snapshot it loaded at start; the
  daemon's atomic write doesn't mutate that snapshot. (The next popover open / window refresh re-reads.)
- **Popover closes during a verify:** the verify is owned by the Trust window (not the popover), so it
  continues; closing the popover does not cancel it.
- **Stale vs live:** at-rest "last recorded" status and a live "Verify now" result are separate, distinctly
  labelled — a stale OK is never presented as a live OK.

## 7. Interface contracts

### 7.0 Shared ledger reader (GohCore) — unifies the corrupt/empty boundary
To guarantee the tray's overview and the runner classify a corrupt ledger identically (AC5 + §6), BOTH
read through one shared helper that does the same direct decode + version check the current
`GohVerifyAllCommand` does:
```
// The unreadable reason is STRUCTURED (not a free-form String) because the CLI's frozen --json
// emits three distinct, separately-tested VerifyErrorCodes — and version-unknown embeds the int.
nonisolated public enum LedgerUnreadableReason: Sendable, Equatable {
    case io                          // Data(contentsOf:) failed   → maps to .ledgerUnreadable
    case corrupt                     // PropertyListDecoder failed → maps to .ledgerCorrupt
    case versionUnknown(found: Int)  // version != currentVersion  → maps to .ledgerVersionUnknown
}
nonisolated public enum ProvenanceReadOutcome: Sendable, Equatable {
    case absent                            // file does not exist → treat as empty
    case entries([ProvenanceEntry])        // decoded OK (may be empty array)
    case unreadable(LedgerUnreadableReason)
}
nonisolated public enum ProvenanceLedgerReader {
    /// `create:false` read of provenance.plist. Classification order MUST match the current
    /// GohVerifyAllCommand.run exactly: fileExists==false → .absent; Data(contentsOf:) throws →
    /// .unreadable(.io); PropertyListDecoder throws → .unreadable(.corrupt); record.version !=
    /// currentVersion → .unreadable(.versionUnknown(found: record.version)); else .entries(record.entries)
    /// in stored order. Never writes, never throws.
    public static func read(at path: String) -> ProvenanceReadOutcome
}
```
- `VerifyAllRunner` uses `.read` and maps each `.unreadable` reason to the EXACT existing frozen
  `VerifyErrorCode` + human string the CLI emits today (`.io`→`.ledgerUnreadable`/"provenance ledger
  unreadable"; `.corrupt`→`.ledgerCorrupt`/"provenance ledger corrupt"; `.versionUnknown(n)`→
  `.ledgerVersionUnknown`/"provenance ledger version \(n) is unknown") → **exit 6**. `.absent`/`entries([])`
  → empty report (**exit 0**); `entries(n)` → re-hash in stored order. This preserves byte-identical
  `verify --all` (human + `--json` codes + entry order + the golden fixture + the attest `payloadBytes`
  input). The three existing JSON-error tests (`.ledgerUnreadable`/`.ledgerCorrupt`/`.ledgerVersionUnknown`)
  stay green WITHOUT string-parsing.
- The tray's live `ProvenanceReading` (§7.2) also uses `.read` but **collapses all three `.unreadable`
  reasons to `.unavailable`** (it doesn't need the discrimination) — so a corrupt ledger surfaces as
  `.unavailable`, never silently empty.

### 7.1 Shared verify runner (GohCore — the extraction)
A pure, testable runner that both the CLI and the tray call, so verify results are identical (AC5) and the
tray can show progress + cancel (AC3).
```
public struct VerifyProgress: Sendable, Equatable {
    public let completed: Int      // files fully hashed so far
    public let total: Int          // total recorded files
    public let currentPath: String? // file just completed (for display)
}

public enum VerifyAllRunner {
    /// Re-hashes every recorded file and returns the structured report.
    /// CONTRACT (pinned — not impl-defined):
    ///  • `progress` fires AFTER each file is fully hashed; `completed` == number finished,
    ///    `currentPath` == the file just completed. So `completed` reaches `total` only on a full run.
    ///  • `isCancelled` is checked BETWEEN files (before starting the next). Cancellation granularity
    ///    is per-file; a single in-progress file is not interrupted mid-hash.
    ///  • On cancellation it STOPS and RETURNS a partial `VerifyAllReport` containing only the entries
    ///    processed so far (summary folded from those entries). It does NOT throw on cancel.
    ///  • It THROWS only on a ledger-level read error (`ProvenanceReadOutcome.unreadable`) — the CLI maps
    ///    that to exit 6; the tray maps it to `.failed`.
    ///  • Per-file digest errors (missing/unreadable/directory) are CAUGHT and classified MISSING/FAILED;
    ///    the run never aborts on one bad file.
    ///  • Pure: no rendering, no exit codes, no CLI parse. Entry ORDER and summary folding match the
    ///    current command exactly (so the golden fixture is unchanged).
    public static func verifyAll(
        provenanceStorePath: String,   // non-optional — matches the current run() + both callers
        generatedAt: Date,             // injected (CLI uses Date(); the tray passes its own value)
        progress: (@Sendable (VerifyProgress) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> VerifyAllReport
}
```
- The `VerifyAllReport` value fed to `GohAttestCommand.payloadBytes(for:)` is structurally identical to
  today's (same entries, order, summary), so the signed `payload_bytes` input is unchanged by construction.
- **`GohVerifyAllCommand.run(...)` is refactored to call `VerifyAllRunner.verifyAll(...)`** (with nil
  progress/cancel) and render exactly as before. Human output, `--json` bytes, exit codes (0/2/9/6/64),
  entry order, and `payloadBytes(for:)` are **unchanged** — guarded by the existing verify-all tests, the
  `verify-all-report-v1.json` golden fixture, AND the attest tests (attest re-decodes `run(json:true)` and
  signs `payloadBytes` — a second frozen consumer; see §2/§9).
- `VerifyAllReport`/`VerifySummary`/`VerifyEntryResult`/`VerifyStatus` are reused unchanged (frozen
  reportVersion 1).

### 7.2 Tray trust model + presenter (GohMenuBar)
```
nonisolated public struct GohTrustSummary: Sendable, Equatable {
    public let tracked: Int
    public let verified: Int        // verifiedAt != nil
    public let downloadOnly: Int    // verifiedAt == nil
}
nonisolated public enum GohTrustOverview: Sendable, Equatable {
    case empty                      // no/absent ledger
    case unavailable                // corrupt/unreadable
    case summary(GohTrustSummary)
}
nonisolated public struct GohTrustEntryRow: Sendable, Equatable {
    public let displayPath: String
    public let sanitizedURL: String // URLDisplay.sanitized applied
    public let sha256: String
    public let downloadedAt: Date
    public let verifiedAt: Date?
}
```
- A pure presenter maps a `ProvenanceReadOutcome` → `GohTrustOverview` + `[GohTrustEntryRow]` (URLs
  sanitized): `.absent`/`.entries([])` → `.empty`; `.entries(n)` → `.summary` + rows; `.unreadable` →
  `.unavailable`. Unit-tested with fixtures; no framework, no disk.
- A small **read seam** so the model/tests don't touch disk — it returns the SAME trichotomy the runner
  uses, so the corrupt/empty boundary is identical across the tray and `verify --all`:
  `nonisolated public protocol ProvenanceReading: Sendable { func read() -> ProvenanceReadOutcome }`
  with a live impl that calls `ProvenanceLedgerReader.read(at:)` (read-only) and a test stub. (It does NOT
  expose `loadReadOnly()`'s bare `Bool`, which cannot distinguish corrupt from empty.)

### 7.3 Verify run state (GohMenuBar, @MainActor)
A `@MainActor` observable (e.g. `TrustWindowViewModel`) owns: the overview + rows (loaded off-main), and
the verify run state — `idle | running(VerifyProgress) | finished(VerifyAllReport) | cancelled(VerifyAllReport)
| failed(message)`. (`cancelled` carries the partial report per §7.1.)

**Concurrency (load-bearing — do NOT use the cooperative pool):** the synchronous re-hash MUST run on a
**real OS thread off the Swift concurrency cooperative pool** — `Thread.detachNewThread { ... }` (or a
dedicated `DispatchQueue.global().async`). **`Task.detached` is FORBIDDEN here**: it still executes on the
fixed-width cooperative pool, and the hashing loop has no suspension points, so it would occupy a pool
worker for the entire multi-GB run and reproduce the #81 starvation
([[swift-sync-async-bridge-cooperative-pool-deadlock]]). `VerifyProgress` is forwarded to the MainActor
via `MainActor.run`/`@MainActor`-hop from the worker thread (the established `GohMenuViewModel` pattern).
Cancellation is an `Atomic<Bool>` (Swift `Synchronization`). NOTE: `Atomic` is `~Copyable`, so the
`@Sendable isCancelled` closure cannot capture it by value — box it in an enclosing reference type (the
repo's `GohMenuProgressSubscriptionCancellation` already does this) and capture that. Errors map to a
plain-English message (never raw). (The worker-thread → `MainActor.run` publish-back is standard Swift 6;
it is NOT an existing in-repo pattern — the progress stream uses AsyncStream+Task — so treat it as a new,
standard technique, not a copied one.)

### 7.4 View + scene
- A popover trust **summary section** (one line + the "Trust…/Verify…" button) driven by `GohTrustOverview`.
- A `Window(id: "trust")` + `@StateObject` root (mirroring `AddDownloadWindowRoot`) hosting the per-file
  list + "Verify now"/progress/Cancel + the live result summary. Accessibility labels on controls.

## 8. Components to build
- `Sources/GohCore/Provenance/ProvenanceLedgerReader.swift` — shared `ProvenanceReadOutcome` +
  `ProvenanceLedgerReader.read(at:)` (the single decode+version-check used by BOTH the runner and the tray).
- `Sources/GohCore/CLI/VerifyAllRunner.swift` — the extracted pure runner (+ `VerifyProgress`), using the
  shared reader.
- `Sources/GohCore/CLI/GohVerifyAllCommand.swift` — refactor `run()` to call the runner (output unchanged).
- `Sources/GohMenuBar/GohTrustModels.swift` — `GohTrustSummary`/`GohTrustOverview`/`GohTrustEntryRow` +
  `ProvenanceReading` protocol.
- `Sources/GohMenuBar/GohTrustPresenter.swift` — pure `[ProvenanceEntry]` → overview + rows (sanitized).
- `Sources/GohMenuBar/TrustWindowViewModel.swift` — `@MainActor` run-state + off-main load + background verify.
- `Sources/GohMenuBar/TrustWindowView.swift` — the window UI (list + verify/progress/cancel).
- `Sources/GohMenuBar/GohMenuView.swift` — popover summary section + "Trust…" entry.
- `Sources/GohMenuBar/GohMenuViewModel.swift` — off-main trust-summary load + published overview (or a
  dedicated loader injected at the composition root).
- `Sources/goh-menu/main.swift` — live `ProvenanceReading` impl + `Window(id:"trust")` scene +
  `@StateObject` root, wired at the composition root (keep AppKit/disk specifics here).
- Tests (`Tests/GohCoreTests/` + `Tests/GohMenuBarTests/`): runner parity (same `VerifyAllReport` as the
  CLI for a fixture ledger) + per-file error isolation + cancellation (partial result); presenter
  (entries → overview/rows, URL sanitized, empty/unavailable); existing verify-all tests + golden fixture
  unchanged & green.

## 9. Rollout & migration
- Additive; new files + a popover section + a Window scene + an internal refactor of `GohVerifyAllCommand`.
- The ONLY behavior change to existing surfaces is internal (verify-all rewired to the runner) — output
  must stay byte-identical (regression-gated). Backward compatible; brew/CLI users unaffected.
- Rollback = revert the PR; no persisted state, no format change.

## 10. Unverified research claims relied upon
- Same-user 0600 read of the daemon's `provenance.plist` from the unsandboxed tray works (the CLI already
  does it) [SINGLE]. If false, the overview/verify degrade to "Trust data unavailable" — handled.
- Running the sync re-hash on a **real OS thread** (not `Task.detached`) avoids cooperative-pool
  starvation [VERIFIED via the repo's #81 incident + its detached-thread fix]; the `@MainActor`
  publish-back from a worker thread is the established in-repo pattern (`GohMenuViewModel`'s progress hop)
  [VERIFIED].
