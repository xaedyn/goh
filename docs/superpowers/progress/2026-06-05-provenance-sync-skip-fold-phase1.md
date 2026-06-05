# Phase 1 Progress — provenance-sync-skip-fold

Status: COMPLETED — merged into PR #85 (feat/provenance-sync-skip-fold)

## Goal

Value/format layer: add `ProvenanceEntry.verifiedAt` as an additive-optional field, keep the
`provenance-v1.plist` golden round-trip green (nil → omitted; `currentVersion` stays 1), and add
`ProvenanceStore.recordVerified(entries:)` with the §3.2 merge rule — all inside one
`Mutex.withLock` + one atomic write. No wire changes, no daemon wiring yet.

## Tasks

- Task 1: Add `verifiedAt: Date?` to `ProvenanceEntry`; update `ProvenanceEntry.init`; confirm
  existing golden round-trip test still passes (nil → omitted means byte-stable for old fixtures).
- Task 2: Add `ProvenanceStore.recordVerified(entries:)` with the merge rule and unit tests
  (same-hash → preserve downloadedAt + set verifiedAt; different-hash → new entry with
  downloadedAt = verifiedAt).

## CONTRACTS ESTABLISHED

*(filled on completion)*

## OPEN ITEMS

- Phase 2: Wire contract (new Command case, protocolVersion bump, fixtures, dispatcher injection).
- Phase 3: CLI batch-send in GohSyncCommand; goh which ledger-first + renderer rewrite.
