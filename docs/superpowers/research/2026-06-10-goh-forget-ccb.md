---
date: 2026-06-10
feature: goh-forget
type: codebase-context-brief
---

# Codebase Context Brief — goh forget

## STACK
- Swift 6 language mode, swift-tools-version 6.2. Per-target `.defaultIsolation`:
  `MainActor` on `goh`/`GohTUI`/`GohMenuBar`/`goh-menu`; `nonisolated` on `GohCore`/`gohd`.
- IPC: modern low-level Swift XPC (macOS 26). `CommandService.protocolVersion = 4` (frozen).
  Additive command extensions add a `Command` enum case + request/reply types without
  bumping protocolVersion.
- Persistence: `provenance.plist` (binary plist) under
  `~/Library/Application Support/dev.goh.daemon/`, owned exclusively by `gohd`; CLI is
  read-only. `ProvenanceRecord.currentVersion = 1` (frozen; four-round to bump).
- Wire payload codec: `CommandCoding.encoder/decoder` (JSON, ISO-8601, sorted keys) inside
  XPC envelopes. `GohFeatureLevel.current = 1` — monotonic skew axis distinct from protocolVersion.

## EXISTING PATTERNS
- **CLI verb dispatch:** `GohCommandLine.parse(_:)` maps `[String]` → `ParsedCommand`;
  `run()` switches and dispatches. Local-only verbs (`verify --all/--quick`) route straight
  to a runner; daemon verbs call `sendCommand(_:expecting:)` wrapping `Command` in a `GohEnvelope`.
- **XPC command/reply:** `Command` enum (`GohCore/Model/Command.swift`), replies
  (`CommandReply.swift`), in-process union `CommandOutcome.swift`. Add command = enum case +
  request struct + reply (or reuse `AckReply`) + outcome (or reuse `.ack`) + handle in
  `CommandService.encodeReply` and `CommandDispatcher.reply`. **`recordVerifiedProvenance`
  (protocolVersion 4) is the closest precedent.**
- **ProvenanceStore API** (`GohCore/Provenance/ProvenanceStore.swift`): `load()`,
  `loadReadOnly()`, `record(entry:)`, `recordVerified(entries:)`, `lookup(destinationPath:)`,
  `allEntries()`. **No delete/remove path exists.** Atomic write (`writeAtomically`): encode →
  tmp → chmod 0600 → fsync(tmp) → rename(2) → fsync(dir).
- **ProvenanceEntry:** keyed by canonical absolute `destinationPath`. Fields: `url`, `sha256`
  ("sha256:"-prefixed), `size`, `downloadedAt`, `destinationPath`, `verifiedAt?` + 5
  additive-optional stat fields.
- **Daemon dispatch:** `CommandService.handle` → `CommandDispatcher.reply`. Dispatcher holds
  `provenanceStore: ProvenanceStore?`. Store-writing commands mirror `recordVerifiedProvenance`:
  guard store non-nil, call store, return `.ack`.
- **GohMenuClient** (`@MainActor`, `GohMenuBar/GohMenuViewModel.swift`): methods
  `progressSnapshots/add/pause/resume/remove/recordVerifiedProvenance/ls`. Conformers:
  `LiveGohMenuClient` (goh-menu/main.swift) + injected `(any GohMenuClient)?` in
  `TrustWindowViewModel`/`AddDownloadViewModel`; test doubles created inline in tests.
- **TrustWindowViewModel:** runs verify off-pool via `DispatchQueue.global().async`; after a
  run calls `menuClient?.recordVerifiedProvenance(...)`. A "Forget" action = new `@MainActor`
  method → new `GohMenuClient` method → `loadOverview()` refresh.
- **Tests:** Swift Testing; golden fixtures in `Tests/GohCoreTests/Fixtures/` (e.g.
  `envelope-v4-record-verified-provenance-{request,reply}.json`); `GohCommandLineTests`.

## RELEVANT FILES
- `GohCore/Provenance/ProvenanceStore.swift` — add `forget(paths:) throws` (filter → writeAtomically).
- `GohCore/Model/Command.swift` — add `case forgetProvenance(request: ForgetProvenanceRequest)` + request struct.
- `GohCore/Model/CommandReply.swift` / `CommandOutcome.swift` — likely reuse `AckReply` / `.ack`.
- `GohCore/Model/CommandDispatcher.swift` — add `.forgetProvenance` case (mirror recordVerifiedProvenance).
- `GohCore/Model/CommandService.swift` — `.ack` already handled; protocolVersion stays 4.
- `GohCore/CLI/GohCommandLine.swift` — add `ParsedCommand.forget(...)`, parse + dispatch.
- `GohCore/CLI/GohForgetCommand.swift` (new) — CLI runner.
- `GohMenuBar/GohMenuViewModel.swift` — add `forget(paths:)` to `GohMenuClient`.
- `goh-menu/main.swift` — `LiveGohMenuClient.forget(paths:)`.
- `GohMenuBar/TrustWindowViewModel.swift` + `TrustWindowView.swift` — Forget action on MISSING rows.
- `Tests/GohCoreTests/Fixtures/` — new golden envelope pair; `ProvenanceStore`/`GohForgetCommand` tests.

## CONSTRAINTS
- `protocolVersion = 4` frozen — `forgetProvenance` is additive (new enum case). Old daemon
  returns nil/malformed → CLI surfaces an error; no silent corruption.
- `ProvenanceRecord.currentVersion = 1` must not change — forget is a runtime `entries[]`
  mutation, no schema field change, no version bump.
- `VerifyAllReport` JSON + golden frozen — forget does not touch the report.
- launchd plist + `machServiceName` must not change.
- Pruning must NEVER be automatic — `forget(paths:)` only on explicit request.
- `GohFeatureLevel.current` likely bumps to 2 (daemon supports forgetProvenance) so a stale
  daemon can be detected/healed before the command is sent.

## OPEN QUESTIONS
1. No delete path exists — `forget(paths:)` is net-new (filter + reuse `writeAtomically`).
2. Entries keyed by canonical `destinationPath`. Canonicalize where? Precedent
   (`recordVerifiedProvenance`) canonicalizes in the daemon — same applies here.
3. **No TTY-prompt / confirmation pattern anywhere in the CLI.** `daemon restart --force`
   uses a flag, not a prompt. `--missing` (bulk delete) needs a safety-model decision:
   `--force` flag / `--dry-run` default / `--confirm` flag. → an approach fork.
4. `--missing` enumeration: cheaper to filter the ledger by `!FileManager.fileExists` (the
   FastCheck/lstat approach) than a full `verify --all` re-hash. → reuse `FileStatProbing`.
5. Adding `forget` to `GohMenuClient` requires updating every inline test double.
6. `goh forget <path>` needs a live daemon (atomic write). `--missing` may read-then-send.
