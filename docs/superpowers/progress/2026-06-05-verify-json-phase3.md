---
date: 2026-06-05
feature: verify-json
phase: 3
tasks: 4–5
status: not-started
---

# Phase 3 — Parse/dispatch wiring + full health check

## Scope
Add `case verifyAll(json: Bool)` to `ParsedCommand`, update the `verify --all` parse branch to accept
`["--json"]` as the only valid remainder, update the dispatch site to pass `json:` through to
`GohVerifyAllCommand.run()`, update usage text, and run the full test suite.

## Tasks
- [ ] Task 4 — MODIFY `GohCommandLine.swift` (4 targeted changes: enum case, parse branch, dispatch, usage); CREATE `Tests/GohCoreTests/GohVerifyAllParseJSONTests.swift`
- [ ] Task 5 — Full `swift test` + `swift build -Xswiftc -warnings-as-errors` health check; manual spot-check of JSON output

## Parse boundary being pinned

| Input | Expected |
|-------|----------|
| `verify --all --json` | `verifyAll(json:true)` → exit 0 (empty store) |
| `verify --all` | `verifyAll(json:false)` → exit 0 (empty store) |
| `verify --json --all` | exit 64 (falls to frozen verify arm, `--json` unknown) |
| `verify --json` | exit 64 (frozen verify arm) |
| `verify --all --json --json` | exit 64 (remainder not exactly `["--json"]`) |
| `verify --all --strict-untracked` | exit 64 (unchanged) |
| `verify --all <path>` | exit 64 (unchanged) |

## Exit gate
`swift test --filter GohVerifyAllParseJSONTests` → all 7 parse-boundary tests pass.
`swift test --filter GohVerifyAllParseTests` → all existing tests pass UNMODIFIED.
`swift test` (full suite) → zero failures.
`swift build -Xswiftc -warnings-as-errors` → clean.
