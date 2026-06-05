---
date: 2026-06-05
feature: provenance-sync-skip-fold
type: codebase-context-brief
---

# Codebase Context Brief — Record provenance for skipped/already-present `goh sync` files

## STACK

- Swift 6.3.x, Swift 6 language mode, macOS 26.0+ floor.
- Binary plist persistence (`PropertyListEncoder/.binary`) for `provenance.plist`.
- JSON-over-XPC wire format for all CLI↔daemon commands; `protocolVersion = 3`.
- `Mutex<Inner>` (`Synchronization`) for **in-process** state protection only.
- Swift Testing; CI `macos-26`, `-warnings-as-errors`.

## EXISTING PATTERNS

- **XPC peer model:** mutual validation via `XPCPeerRequirement` / `XPCRequirement.isFromSameTeam` (macOS 26.0). Tests use an anonymous listener.
- **Persistence:** `ProvenanceStore` mirrors `HostProfileStore` — write UUID `.tmp` sibling → `chmod 0600` → `fsync(tmp)` → `rename(2)` → `fsync(dir)`. Single-writer is **socially enforced** (daemon is sole `record(entry:)` caller; CLI uses `loadReadOnly()`), plus 0600 perms. **No cross-process lock** on the file; the `Mutex` is in-process only.
- **Error handling:** the daemon wraps `provenanceStore.record(entry:)` in `do/catch` + `warn()` — recording can never fail a download (non-fatal pattern, `ProvenanceStoreTests.swift` AC5/T4).
- **Test pattern:** golden fixtures pin formats — `Fixtures/provenance-v1.plist` (on-disk record) and `Fixtures/envelope-v3-*.json` (wire). Each protocol bump adds new fixtures; old ones are retained immutable.

## RELEVANT FILES

| File | Purpose | Key signatures |
|---|---|---|
| `Sources/GohCore/Provenance/ProvenanceRecord.swift` | On-disk format, `currentVersion = 1`. | `ProvenanceEntry: Codable` = `{url:String, sha256:String (w/ "sha256:" prefix), size:Int, downloadedAt:Date, destinationPath:String}` |
| `Sources/GohCore/Provenance/ProvenanceStore.swift` | Writer (daemon) + reader (CLI). | `init(fileURL:URL)` (no `create:`); `record(entry:) throws`; `lookup(destinationPath:)`; `allEntries()`; `load()`; `loadReadOnly() -> Bool` |
| `Sources/GohCore/Provenance/ProvenanceStoreLocation.swift` | Path resolver shared by daemon + CLI. | `defaultURL(create:Bool) throws -> URL` → `~/Library/Application Support/dev.goh.daemon/provenance.plist` |
| `Sources/GohCore/Model/Command.swift` | XPC command enum (wire vocabulary). | `enum Command: Codable, Sendable, Equatable` — `.add .ls .pause .resume .rm .authImportSafari .subscribe` |
| `Sources/GohCore/Model/CommandService.swift` | Daemon XPC adapter. | `static let protocolVersion: UInt32 = 3`; rejects version mismatch before decode |
| `Sources/GohCore/Model/CommandDispatcher.swift` | Pure router. **Holds NO ProvenanceStore.** | `reply(to command:Command) -> CommandOutcome`; switch ~line 58 |
| `Sources/gohd/main.swift` | Daemon entry. | builds `provenanceStore` (~L102); `completedDownloadHandler` closure (~L139) records provenance (~L172–184); `CommandDispatcher` built (~L198) **without** the store |
| `Sources/GohCore/CLI/GohSyncCommand.swift` | Sync logic. | skip helpers `upToDate`/`firstUse`/`tofuChange` return `EntryOutcome` without touching provenance; talks to daemon only via `sendAdd`/`Sender`; `dest` is local to `process()`, NOT a param of the helpers |
| `Sources/GohCore/CLI/GohWhichCommand.swift` | `goh which`. | reads provenance directly: `loadReadOnly()` + `lookup(...)`, no daemon |
| `Sources/GohCore/CLI/GohVerifyAllCommand.swift` | `goh verify --all`. | reads the plist file directly (distinguishes corrupt exit 6 from empty exit 0), no daemon |
| `Tests/GohCoreTests/CommandTests.swift` | Exhaustive wire round-trip of every `Command` case (`commandRoundTrip`, ~L96). | a new case must be added here |
| `Tests/GohCoreTests/Fixtures/envelope-v3-*.json` | Golden wire fixtures at v3. | a bump needs new `v4-*` fixtures; v3 retained |

## CONSTRAINTS (must not change)

1. **Single-writer invariant on `provenance.plist`** — the `Mutex` is in-process only; a second OS process calling `record` is unprotected. Letting the CLI write directly *as-is* would risk last-writer-wins clobber/corruption.
2. **`ProvenanceRecord.currentVersion = 1` is frozen** — adding a field (e.g. to mark "verified vs downloaded") is a four-round change.
3. **`protocolVersion = 3` enforced exactly** — `CommandService` rejects mismatches before decode. Adding a `Command` case is an on-wire change; `commandRoundTrip` treats the case set as exhaustive.
4. **Envelope golden fixtures must not regress** — a bump adds `v4-*`, keeps `v3-*`.
5. **`GohSyncCommand.run` has no provenance-store path and no store handle** — its only daemon channel is the `send` closure.
6. **`CommandDispatcher` has no `ProvenanceStore`** — wiring one in is a real (small) refactor of its init + the gohd construction site.

## OPEN QUESTIONS (design attention)

1. **Is a `protocolVersion` bump strictly required to add a command case?** Decoding uses the case-name discriminant; an old daemon receiving an unknown case fails to decode → CLI sees a *transport* error, not a clean `protocolVersionMismatch`. So an additive case is wire-incompatible regardless; the **safe procedure is bump 3→4 + new v4 fixtures** so old daemons emit a clean "restart the daemon" error. Actual harm of skipping the bump = confusing error, not corruption. (Decide in design.)
2. **`downloadedAt` semantics for a file goh did NOT transfer now.** `url`=`asset.url` ✓; `sha256`=fresh on-disk hash (skip paths produce *raw hex* — must prepend `"sha256:"` like the daemon does); `size`=on-disk size ✓; `downloadedAt`= ? Options: `Date()` ("verified-present at"), `stat.st_mtime` (closer to truth), or a new `verifiedAt` field (four-round + version bump). Field name says "downloaded"; semantics for a skip is "last confirmed present at this hash."
3. **Where to fire the record** — `dest` lives in `process()`, not the skip helpers; insert in `process()` after each skip `return`, or thread `dest` into the helpers.
4. **How the CLI reaches the writer** — (a) **new XPC command** → daemon writes, preserves single-writer, needs dispatcher to hold the store + bump + fixtures, **requires daemon up**; or (b) **CLI writes directly** → only sound if `ProvenanceStore` is made cross-process safe (advisory `flock` + read-modify-write), no wire change, daemon-down capable. (b) changes a deliberate invariant; (a) changes the wire.
5. **Daemon-down behavior change** — today an all-up-to-date `sync` may exit 0 without needing the daemon. If skip-recording uses a mandatory XPC call, a daemon-down sync would newly exit 1. Recording on skips must be **best-effort / non-fatal** to preserve current exit semantics (mirrors the download completion handler).
