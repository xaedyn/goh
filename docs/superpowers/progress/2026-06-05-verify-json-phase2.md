---
date: 2026-06-05
feature: verify-json
phase: 2
tasks: 3
status: not-started
---

# Phase 2 — Compute-once-render-twice refactor

## Scope
Refactor `GohVerifyAllCommand.run()` to build one `[VerifyEntryResult]` array, derive `summary` and
exit code from it, then render either human text (byte-identical to today) or JSON. No parse/dispatch
changes yet — `ParsedCommand.verifyAll` still carries no `json` associated value and callers still
use the 1-arg signature (which compiles because `json:` defaults to `false`).

## Bet
Deriving both renderings from one result model keeps the JSON and human verdicts + exit codes
consistent at zero ongoing cost; the existing byte-exact regression tests prove the human output
stayed identical after the refactor.

## Tasks
- [ ] Task 3 — MODIFY `GohVerifyAllCommand.swift`; CREATE `Tests/GohCoreTests/GohVerifyAllCommandJSONTests.swift`

## Exit gate
`swift test --filter GohVerifyAllCommandJSONTests` → all new tests pass.
`swift test --filter GohVerifyAllCommandTests` → all EXISTING tests pass UNMODIFIED (M3 regression gate).
`swift build -Xswiftc -warnings-as-errors` → clean.

## Phase 3 prerequisite
The refactored `run(provenanceStorePath:json:generatedAt:)` signature must exist before Phase 3
wires the `json: Bool` value from the parse layer.
