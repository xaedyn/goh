---
date: 2026-06-07
feature: tray-download-dashboard
phase: 2
status: complete
tasks: [T3, T4]
depends-on: phase1
---

# Phase 2 — GohMenuBar value layer

## Goal
Enrich `GohMenuJobRow` with the rich dashboard fields (T3) and teach `GohMenuPresenter` to populate them from `JobSummary` — including ETA/elapsed/connections/verify status — all pure/unit-tested with stubs (no disk, no AppKit, no real XPC).

## Gate
`swift build -Xswiftc -warnings-as-errors` + `swift test` — full suite green. All existing `GohMenuPresenterTests` pass unchanged. New tests cover: `progressFraction` nil when total unknown; `etaText` nil when total unknown; `etaText` nil for non-active jobs; completed row `verifyStatus` "recorded" / "verified <date>" / nil from stub ledger.

## Tasks

### T3 — MODIFY `Sources/GohMenuBar/GohMenuModels.swift`

- [ ] Add to `GohMenuJobRow` (after existing `controls: Set<GohMenuControl>`):
  - [ ] `public var progressFraction: Double?` — bytesCompleted/bytesTotal as [0,1]; nil when total nil
  - [ ] `public var sizeText: String` — human-readable "downloaded / total" or "downloaded/?"
  - [ ] `public var etaText: String?` — "ETA Xs" / "ETA Nm Xs"; nil when total nil, rate 0/warming, or not active
  - [ ] `public var elapsedText: String?` — elapsed since createdAt; nil when 0
  - [ ] `public var connectionText: String?` — "N connections"; nil when actualConnectionCount == 0
  - [ ] `public var verifyStatus: String?` — "recorded" / "verified <date>"; nil for non-completed or absent ledger
- [ ] Update `GohMenuJobRow` memberwise initializer to include new fields with nil defaults for backward compatibility (or add a new overload — prefer the nil-default approach so existing test factory helpers continue to compile)
- [ ] Confirm `GohMenuJobRow` still `nonisolated public struct ... : Sendable, Equatable, Identifiable`
- [ ] Run `swift build -Xswiftc -warnings-as-errors` — clean
- [ ] Run `swift test` — existing tests still pass (new fields nil by default)

### T4 — MODIFY `Sources/GohMenuBar/GohMenuPresenter.swift` + `Tests/GohMenuBarTests/GohMenuPresenterTests.swift`

- [ ] Add to `Tests/GohMenuBarTests/GohMenuPresenterTests.swift` — 5 failing `@Test` stubs:
  - [ ] `progressFraction is nil when bytesTotal is nil`
  - [ ] `etaText is nil when bytesTotal is nil`
  - [ ] `etaText is nil for non-active (paused) jobs`
  - [ ] `completed row gets verifyStatus 'recorded' from ledger entry without verifiedAt`
  - [ ] `completed row gets verifyStatus 'verified <date>' from ledger entry with verifiedAt`
  - [ ] `completed row with no ledger entry has nil verifyStatus`
- [ ] Extend the `snapshot(...)` private helper to accept `total: UInt64?` (currently `UInt64`; add overload or make optional) and `destination: String` param (for verify-status tests)
- [ ] Modify `GohMenuPresenter.state(health:snapshots:clipboardURL:)` to add `ledgerOutcome: ProvenanceReadOutcome? = nil` param
  - [ ] Build `[String: ProvenanceEntry]` map from `ledgerOutcome` when `.entries(...)`, else empty (O(n) once, not per-row)
  - [ ] Pass map to `row(for:ledgerMap:)` for each job
- [ ] Update `row(for:)` → `row(for:ledgerMap:)`:
  - [ ] Compute `progressFraction`: nil when `bytesTotal` nil; `min(1.0, completed/total)` otherwise
  - [ ] Compute `sizeText`: reuse `JobDisplayFormatter.progressText(job.progress)` (already imported)
  - [ ] Compute `etaText`: only for `.active`, only when `bytesTotal != nil` and `bytesPerSecond > 0`; formula `(total - completed) / bytesPerSecond` → `etaString(_:)` helper; nil otherwise
  - [ ] Compute `elapsedText`: `(completedAt ?? lastProgressAt ?? Date()) - createdAt`; nil when ≤ 0
  - [ ] Compute `connectionText`: `"N connection(s)"` when `actualConnectionCount > 0`; nil when 0
  - [ ] Compute `verifyStatus`: only when `state == .completed` AND ledgerMap has entry for `job.destination`; "recorded" when `verifiedAt == nil`, "verified <dateStyle.short>" when non-nil
  - [ ] All nil for non-active/non-completed states as specified
- [ ] Add private `etaString(seconds: UInt64) -> String` and `elapsedString(seconds: Double) -> String` helpers
- [ ] Update `GohMenuViewModel`:
  - [ ] Add `private var ledgerOutcome: ProvenanceReadOutcome? = nil` stored property
  - [ ] In `loadTrustOverview()`: after reading `outcome`, also `self.ledgerOutcome = outcome` (re-use the same read — not a second call)
  - [ ] In `render(health:)`: pass `ledgerOutcome: ledgerOutcome` to `presenter.state(...)`
- [ ] Run `swift test --filter GohMenuPresenterTests` — all 6 new tests pass, all existing tests pass
- [ ] Run `swift test` — full suite green

## Phase 2 completion criteria
- [ ] `swift build -Xswiftc -warnings-as-errors` clean
- [ ] `swift test` — all tests pass (6 new presenter tests added)
- [ ] `GohMenuJobRow` has 6 new optional fields, all nil in existing tests
- [ ] `GohMenuPresenter.state(...)` new `ledgerOutcome` param defaults to nil — existing call sites unchanged
- [ ] `GohMenuViewModel.loadTrustOverview()` stores `ledgerOutcome` from the SAME read call (not a second disk access)
