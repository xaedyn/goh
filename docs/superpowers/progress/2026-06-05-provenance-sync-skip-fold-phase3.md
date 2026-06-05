# Phase 3 Progress — provenance-sync-skip-fold

Status: COMPLETED — merged into PR #85 (feat/provenance-sync-skip-fold)

## Goal

CLI emit + reader: add `EntryOutcome.verifiedEntry` carrier in `GohSyncCommand`, populate it at
the upToDate/firstUse/accepted-tofuChange skip-return sites, collect and best-effort batch-send
after the per-entry loop; integration tests for AC1/AC2/AC4. Rewrite `GohWhichCommand` for
ledger-first precedence and three-way `verifiedAt` rendering; rewrite
`GohWhichLedgerTests.lockPrecedence` to assert ledger-first; add M5 output-assertion test.

## Depends on

Phase 2 complete (Command.recordVerifiedProvenance, CommandOutcome.ack, AckReply, protocolVersion=4
all exist; daemon dispatches recordVerifiedProvenance).

## Tasks

- Task 6: Add `verifiedEntry: VerifiedProvenanceEntry?` to `EntryOutcome`; populate at
  `upToDate`/`firstUse`/accepted-`tofuChange` skip-returns in `process()`; collect + best-effort
  batch-send in `run()`. Integration tests (AC1/AC2/AC4): extend `FakeSyncDaemon` to handle
  `.recordVerifiedProvenance`; wire a real `ProvenanceStore`; assert entry count == skipped count
  (AC1/AC2); assert all-present sync with daemon-down exits 0 (AC4).
- Task 7: Rewrite `GohWhichCommand.run` for ledger-first (ledger before lock); rewrite
  `lookupInLedger` body for three-way `verifiedAt` output; rewrite
  `GohWhichLedgerTests.lockPrecedence` to assert ledger-first; add M5 three-way output test.

## CONTRACTS ESTABLISHED

*(filled on completion)*

## OPEN ITEMS

*(filled on completion)*
