# Phase 2 Progress — provenance-sync-skip-fold

Status: COMPLETED — merged into PR #85 (feat/provenance-sync-skip-fold)

## Goal

Daemon XPC surface: add `Command.recordVerifiedProvenance` + its payload types, bump
`protocolVersion` 3 → 4, add `envelope-v4-*` golden fixtures (retain `envelope-v3-*`), update
`commandRoundTrip`, add `CommandOutcome.ack` + `AckReply`, add `CommandService.encodeReply` `.ack`
arm, inject `ProvenanceStore?` into `CommandDispatcher`, add the dispatch arm, wire in
`gohd/main.swift`. End state: daemon accepts and records a batch.

## Depends on

Phase 1 complete (ProvenanceEntry.verifiedAt, ProvenanceStore.recordVerified exist).

## Tasks

- Task 3: Add `RecordVerifiedProvenanceRequest`, `VerifiedProvenanceEntry` (Codable, Sendable,
  Equatable) to `Command.swift`; add `case recordVerifiedProvenance` to `Command`; add `AckReply`
  to `CommandReply.swift`; add `.ack` to `CommandOutcome`.
- Task 4: Bump `protocolVersion` to 4 in `CommandService.swift`; add `.ack` arm to `encodeReply`;
  add `envelope-v4-record-verified-provenance-request.json` and
  `envelope-v4-record-verified-provenance-reply.json` fixtures; add their decode tests to
  `EnvelopeCodecTests`; add `.recordVerifiedProvenance` case to `commandRoundTrip` literal.
- Task 5: Add `provenanceStore: ProvenanceStore?` param to `CommandDispatcher.init`; add
  `.recordVerifiedProvenance` arm to `reply(to:)`; wire `provenanceStore: provenanceStore` in
  `gohd/main.swift`.

## CONTRACTS ESTABLISHED

*(filled on completion)*

## OPEN ITEMS

- Phase 3: CLI batch-send in GohSyncCommand; goh which ledger-first + renderer rewrite.
