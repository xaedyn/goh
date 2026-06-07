---
date: 2026-06-07
feature: tray-trust-layer
phase: 2
status: not-started
---

# Phase 2 — GohMenuBar value layer (GohTrustModels + GohTrustPresenter)

Tasks 4–5. Pure/unit-tested GohMenuBar types with no disk, no AppKit, no
concurrency. All tests use injected stubs via the ProvenanceReading protocol.
Independently testable after Phase 1 completes.

## Tasks
- Task 4: `Sources/GohMenuBar/GohTrustModels.swift` (CREATE) — `GohTrustSummary` / `GohTrustOverview` (.empty/.unavailable/.summary) / `GohTrustEntryRow` + `ProvenanceReading` protocol; 4 tests in `GohTrustModelsTests`.
- Task 5: `Sources/GohMenuBar/GohTrustPresenter.swift` (CREATE) — pure `ProvenanceReadOutcome → (GohTrustOverview, [GohTrustEntryRow])`; absent/empty→.empty, unreadable→.unavailable, entries→.summary; URLs sanitized via URLDisplay.sanitized; 7 tests in `GohTrustPresenterTests`.

## Status
- [ ] Task 4 complete
- [ ] Task 5 complete
