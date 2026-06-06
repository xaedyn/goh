---
date: 2026-06-05
feature: verify-json
type: acceptance-criteria
---

# Acceptance Criteria — `goh verify --all --json`

AC1: When the user runs `goh verify --all --json` against a ledger with mixed entry states,
stdout is a SINGLE valid JSON document (parses with a standard JSON parser, no trailing/leading
non-JSON text) carrying `reportVersion: 1`, a per-entry array where each element has
`{ path, url, sha256 (the expected, "sha256:"-prefixed digest), status ∈ {ok, failed, missing} }`
and, for `failed`, the `actualSha256`; plus a `summary { ok, failed, missing, total }` block whose
counts equal the per-entry tallies (`ok+failed+missing == total == entries.count`).

AC2: `goh verify --all --json` returns the SAME exit code as `goh verify --all` for the same ledger
state, per the existing contract with precedence **9 > 2 > 0**: 0 when every entry is OK; 2 when any
entry is FAILED (hash mismatch) and NONE is MISSING; 9 when any entry is MISSING (regardless of
failures). (Observable: a test runs both forms against an identical temp ledger and asserts equal
exit codes for each of the all-ok, failed-only, and missing-present cases; the `--json` flag never
alters the exit code.)

AC3: The human-readable `goh verify --all` (no `--json`) output is byte-identical to today and its
exit codes are unchanged. (Observable: every existing `GohVerifyAllCommandTests` /
`GohVerifyAllParseTests` assertion on output strings and exit codes passes unmodified.)

AC4: When the provenance ledger is unreadable, corrupt, or an unknown version, `goh verify --all
--json` still emits a SINGLE JSON document — an error envelope `{ reportVersion: 1, error: <stable
machine code/string> }` — on stdout (never mixed plain-text + JSON), and returns the same exit code
that condition returns today (6). The empty-ledger case likewise emits a valid JSON document with
an empty entries array and a zeroed summary, exit 0.

AC5: The JSON schema is pinned by a committed golden fixture `Tests/GohCoreTests/Fixtures/
verify-all-report-v1.json` plus a Swift Testing encode-equals-fixture test (mirroring
`diagnose-report-v1.json`), so any change to the serialized schema fails the test and forces a
deliberate `reportVersion` decision.
