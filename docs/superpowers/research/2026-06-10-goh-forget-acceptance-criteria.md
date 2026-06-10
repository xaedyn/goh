---
date: 2026-06-10
feature: goh-forget
type: acceptance-criteria
---

# Acceptance Criteria — goh forget

AC1: When the user runs `goh forget <path>` for a path that has a provenance-ledger
entry, that entry is removed from `provenance.plist`, and a subsequent `goh verify --all`
and `goh verify --quick` no longer list that path (no `MISSING`, no "no baseline" line).
The command exits 0 and prints a one-line confirmation naming the forgotten path.

AC2: When the user runs `goh forget --missing`, the set of removal candidates is exactly
the ledger entries whose `destinationPath` does not exist on disk (entries whose files are
present are never candidates). The candidate paths are listed, and entries are removed only
after an explicit confirmation gate is satisfied (a flag or prompt — mechanism chosen at
approach selection); without the gate, nothing is deleted. Observable: a gated invocation
deletes only the absent-file entries and leaves present-file entries intact.

AC3: When the user runs `goh forget <path>` for a path that has no ledger entry, the
command makes no change, prints a clear "not tracked" message, and exits non-zero — never a
silent success that implies something was removed.

AC4: When `forget` removes one or more entries, the ledger is rewritten atomically
(temp file → fsync → rename → fsync dir). If the process is killed mid-write, the on-disk
`provenance.plist` is either the complete pre-forget ledger or the complete post-forget
ledger — never a truncated or partially-written file. Observable: a test that interrupts/
asserts the written bytes decode as a valid `ProvenanceRecord` in both outcomes.

AC5: In the menu-bar Trust window, a row whose status is MISSING offers a "Forget"
affordance; invoking it removes that entry via the daemon and the row disappears when the
window's overview refreshes. Rows whose files are present do not surface a destructive
Forget action without the same confirmation treatment as the CLI.
