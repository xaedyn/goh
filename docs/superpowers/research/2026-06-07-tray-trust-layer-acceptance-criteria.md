---
date: 2026-06-07
feature: tray-trust-layer
type: acceptance-criteria
---

# Acceptance Criteria — Trust Layer in the Tray

Scope (confirmed): provenance **overview** (read-only, from a direct ledger read) **+ on-demand
background verify** (re-hash with progress + cancel). Read-only; no wire/format change.

**AC1 (overview).** The tray shows a provenance overview built from a direct read of the ledger
(`ProvenanceStore.loadReadOnly()`/`allEntries()`): how many files are tracked and their at-rest status
(downloaded-only vs last-verified), explicitly labelled as the **last recorded** state (not a live
re-hash). An absent or empty ledger shows "No downloads recorded yet" — never an error.
Signal: the overview reflects `allEntries()`; empty/absent → friendly empty state, no crash.

**AC2 (per-file provenance).** The user can see, per recorded file, the source URL (passed through
`URLDisplay.sanitized`), the recorded `sha256`, the downloaded date, and the last-verified date — the
`goh which` field set.
Signal: detail view shows these fields; the URL is sanitized (no control chars, credentials redacted).

**AC3 (background verify).** A "Verify now" action re-hashes all recorded files **off the main actor**
(the popover stays responsive — no freeze), reports **progress** (files done / total), supports
**cancel**, and on completion shows a summary of OK / FAILED / MISSING.
Signal: UI remains interactive during the run; progress advances; cancel halts it and leaves a clear
state; completion shows counts. The re-hash does not run on a cooperative-pool worker (no pool starvation).

**AC4 (read-only, no contract change).** The tray never writes the ledger (no `record`/`recordVerified`);
`ProvenanceRecord` (v1) and `VerifyAllReport` (reportVersion 1) formats are unchanged; `protocolVersion`
is unchanged; no new XPC command is added (trust data is read directly from disk).
Signal: no writer calls from the tray; `git diff -- Sources/GohCore` shows no frozen-format change; the
verify-all golden fixture still round-trips; build + full test suite green.

**AC5 (parity with `goh verify --all`).** For the same ledger, the tray's verify classifies each file
(OK / FAILED / MISSING) identically to `goh verify --all`.
Signal: a unit test compares the shared verify runner's `VerifyAllReport` against the CLI's result for a
fixture ledger (same per-file status + summary counts).
