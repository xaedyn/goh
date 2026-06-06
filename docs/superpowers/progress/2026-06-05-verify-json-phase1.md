---
date: 2026-06-05
feature: verify-json
phase: 1
tasks: 1–2
status: not-started
---

# Phase 1 — Frozen types + golden fixture

## Scope
Pure additive: create the frozen `VerifyAllReport` / `VerifyErrorReport` types, their encode-equals tests,
and commit the golden `verify-all-report-v1.json` fixture. No behavior change. Compiles standalone
(no modification to `GohVerifyAllCommand` or `GohCommandLine` yet).

## Tasks
- [ ] Task 1 — CREATE `Sources/GohCore/CLI/VerifyReportTypes.swift`; CREATE `Tests/GohCoreTests/VerifyReportTypesTests.swift`
- [ ] Task 2 — CREATE `Tests/GohCoreTests/Fixtures/verify-all-report-v1.json` (compact, no trailing newline)

## Exit gate
`swift test --filter VerifyReportTypesTests` → all 5 tests pass (including `encodeEqualsGoldenFixture`).
`swift build -Xswiftc -warnings-as-errors` → clean.

## Phase 2 prerequisite
Types file must exist before Phase 2 modifies `GohVerifyAllCommand.run()`.
