---
date: 2026-06-07
feature: tray-trust-layer
phase: 1
status: not-started
---

# Phase 1 — GohCore extraction (ProvenanceLedgerReader + VerifyAllRunner + GohVerifyAllCommand refactor)

Tasks 1–3. Produces all GohCore primitives the tray depends on, with a
byte-identical regression gate on GohVerifyAllCommand. Independently shippable.

**Regression gate (Task 3):** GohVerifyAllCommandTests, GohVerifyAllCommandJSONTests,
verify-all-report-v1.json golden fixture, AND GohAttestCommandTests must ALL pass
UNCHANGED after the refactor. If any pre-existing test regresses, stop and report.

## Tasks
- Task 1: `Sources/GohCore/Provenance/ProvenanceLedgerReader.swift` (CREATE) — `LedgerUnreadableReason` + `ProvenanceReadOutcome` + `ProvenanceLedgerReader.read(at:)`; classification order mirrors current GohVerifyAllCommand exactly; 6 tests in `ProvenanceLedgerReaderTests`.
- Task 2: `Sources/GohCore/CLI/VerifyAllRunner.swift` (CREATE) — `VerifyProgress` + `VerifyAllRunnerError` + `VerifyAllRunner.verifyAll(...)`; progress fires after each file; cancel between files → partial report; per-file errors isolated; throws only on ledger unreadable; 5 tests in `VerifyAllRunnerTests`.
- Task 3: `Sources/GohCore/CLI/GohVerifyAllCommand.swift` (MODIFY) — `run()` delegates to `ProvenanceLedgerReader` + `VerifyAllRunner`; human output, --json bytes, exit codes, entry order, payloadBytes byte-identical; all pre-existing tests pass unchanged.

## Status
- [ ] Task 1 complete
- [ ] Task 2 complete
- [ ] Task 3 complete (regression gate: all pre-existing verify-all + attest tests green)
