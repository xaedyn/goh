---
date: 2026-06-07
feature: tray-trust-layer
phase: 3
status: not-started
---

# Phase 3 — UI + wiring (TrustWindowViewModel + View + popover section + main.swift)

Tasks 6–9. All build-validated (no unit tests for UI/composition-root code).
Each task ends with `swift build -Xswiftc -warnings-as-errors` clean + a
manual smoke note. Final task runs the full `swift test` suite.

## Tasks
- Task 6: `Sources/GohMenuBar/TrustWindowViewModel.swift` (CREATE) — `@MainActor` observable; `TrustRunState` (idle/running/finished/cancelled/failed); off-main ledger load via Task.detached; verify dispatched via `DispatchQueue.global().async` (NOT Task.detached); cancel via `CancellationBox` (Mutex<Bool> reference wrapper); progress published via `Task { @MainActor in ... }`.
- Task 7: `Sources/GohMenuBar/TrustWindowView.swift` (CREATE) — per-file list (displayPath, sanitizedURL, sha256, at-rest chip, live chip); Verify now / progress bar / Cancel / live result summary; "Verify now" disabled when empty/unavailable/running; accessibility labels on all controls.
- Task 8: `Sources/GohMenuBar/GohMenuView.swift` + `GohMenuViewModel.swift` (MODIFY) — popover trust summary section ("No downloads recorded yet" / "Trust data unavailable" / "\(n) tracked · last recorded: …") + "Trust…" button (openWindow(id:"trust") + NSApp.activate); `trustOverview: GohTrustOverview` published on model; off-main load on `start()`.
- Task 9: `Sources/goh-menu/main.swift` (MODIFY) — `LiveProvenanceReader` (nonisolated, calls ProvenanceLedgerReader.read); `TrustWindowRoot` (@StateObject, mirrors AddDownloadWindowRoot); `Window(id:"trust")` scene; `provenancePath` from `ProvenanceStoreLocation.defaultURL(create: false)`; live reader wired into both GohMenuViewModel (for popover) and TrustWindowRoot (for window); full regression suite green.

## Status
- [ ] Task 6 complete
- [ ] Task 7 complete
- [ ] Task 8 complete
- [ ] Task 9 complete (full swift test suite green — zero regressions)
