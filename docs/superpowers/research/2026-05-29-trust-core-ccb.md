# Codebase Context Brief — Trust Core
<!-- 2026-05-29 -->

Feature scope: `gohfile.toml` manifest + lockfile, `goh sync`, `goh verify`, `goh which`.

---

## STACK

- Swift 6.2 (tools-version floor), Swift 6.3.x toolchain, Swift 6 language mode
- `swift-http-types` 1.x (apple/swift-http-types) — only third-party dependency
- CryptoKit — SHA-256 streaming, no third-party hashing library
- Foundation PropertyListSerialization / PropertyListEncoder — binary plist for all on-disk persistence (catalog, checkpoints)
- XPC (modern `XPCSession` / `XPCListener`, macOS 26.0+) — daemon IPC
- CoreServices / `setxattr` — Spotlight extended-attribute writes
- No TOML parser exists anywhere in the codebase or Package.swift

---

## EXISTING PATTERNS

**Error handling.** `GohError: Codable, Sendable, Equatable, Error` is the project-wide error type. It carries an `ErrorCode` enum (raw-value `String`, `CaseIterable`), an optional prose `message`, and an optional `httpStatusCode`. `ErrorCode` already has a `checksumMismatch` case. Thrown errors propagate to the CLI via `GohCommandLineError.daemon(GohError)`, which formats them for stderr. There is no `AppError` class; `GohError` is the equivalent.

**Persistence / atomic-write pattern.** All on-disk writes go through the same pattern: encode to binary plist → write to a UUID-suffixed `.tmp` sibling in the same directory → `fsync` the temp file → `rename(2)` over the target → `fsync` the directory. Used by both `CatalogStore` and `CheckpointStore`. Recovery from a corrupt file always copies it to a timestamped `.corrupt-<unix>` sidecar, then starts from an empty / nil state.

**CLI dispatch pattern.** `GohCommandLine.run()` calls the private `parse(_:)` function, which pattern-matches `[String]` to a private `ParsedCommand` enum. XPC-dispatching verbs call `sendCommand(_:expecting:)`, which wraps the command in a `GohEnvelope<Command>` (protocolVersion, requestID, messageType, payload) and sends it synchronously via the injected `Sender` closure. Local-only verbs (`doctor`, `top`, `foreground`) call injected closures that never touch XPC. The `Command` enum (in `Model/Command.swift`) lists every daemon command.

**Daemon vs CLI-local split.** Commands that read or mutate the job queue go daemon-side: `add`, `ls`, `pause`, `resume`, `rm`, `authImportSafari`, `subscribe`. Commands that only inspect the local machine or file system run CLI-local: `doctor` (probes executable paths, launchctl, disk) is fully CLI-local and never touches XPC if the daemon is unreachable. New verbs follow one of these two patterns; a hybrid verb (calls daemon then does local work) is also possible — `goh which` would likely be pure CLI-local.

---

## RELEVANT FILES

**`Sources/GohCore/Engine/ChunkAssembler.swift`**
Produces `ChunkAssemblerResult` — either `.digest(String)` (lowercase hex SHA-256) or `.failed(GohError)`. The digest is the only place SHA-256 is materialised. It is returned from `hashToCompletion() async -> ChunkAssemblerResult` and consumed inline by the engine's `fetchSingle`, `fetchRanged`, and `verifyHash` helpers. The digest string is never stored: it is checked for failure only and then discarded. No field in `JobSummary` or anywhere else records the completed-download hash.

**`Sources/GohCore/Engine/DownloadEngine.swift`**
Runs downloads and drives `JobStore` state transitions. After `assembler.hashToCompletion()` returns `.digest`, the engine only checks for `.failed` — the hex digest string is thrown away. `complete(jobID:in:)` at line 544 calls `store.complete(id:)` then fires `completedDownloadHandler`. The handler (wired in `gohd/main.swift`) calls `SpotlightMetadataTagger.tagCompletedDownload` — there is no hook to capture the digest here today.

**`Sources/GohCore/Model/JobSummary.swift`**
The persisted and wire-transmitted job record. Fields: `id`, `url`, `destination`, `state`, `progress`, `createdAt`, `lastProgressAt`, `requestedConnectionCount`, `actualConnectionCount`, plus state-specific optionals. No `sha256` or `digest` field. Adding one here is the natural place to persist a completed-download hash.

**`Sources/GohCore/Model/JobCatalog.swift`**
Container persisted to disk. `version: Int = 1` (`currentVersion = 1`). Holds `nextID` and `[JobSummary]`. A schema bump (version 2) is required if `JobSummary` gains a new required field. The load path in `CatalogStore.load()` rejects any `version != currentVersion`, so the migration path is: bump `currentVersion`, write a migration branch in `load()`.

**`Sources/GohCore/Model/CatalogStore.swift`**
Binary-plist atomic writer/reader for `JobCatalog`. Disk path: `~/Library/Application Support/dev.goh.daemon/catalog.plist`. Atomic-replace pattern described above. `JobCatalog.version` is checked on load.

**`Sources/GohCore/Model/CheckpointStore.swift`** / **`Sources/GohCore/Model/DownloadCheckpoint.swift`**
Resume metadata. Binary-plist files at `~/Library/Application Support/dev.goh.daemon/checkpoints/<jobID>.checkpoint.plist`. `DownloadCheckpoint.currentVersion = 1`. Stores `url`, `destination`, `totalBytes`, `strongETag`, `lastModified`, `completedPieces`. No digest field here either.

**`Sources/GohCore/CLI/GohCommandLine.swift`**
CLI entry point. `parse(_:)` → `ParsedCommand` enum → either `sendCommand` (XPC) or injected closure (local). Extending `ParsedCommand` and adding a `case` to `parse(_:)` is the add-a-verb pattern. Usage string at the bottom must also be updated.

**`Sources/GohCore/Model/Command.swift`**
`Command` enum — the XPC payload type. `AddRequest`, `RmRequest`, `AuthImportSafariRequest` are the companion structs. New daemon-side verbs require a new `case` here, a handler in `CommandDispatcher.reply(to:)`, and a new `CommandOutcome` case if the reply shape differs.

**`Sources/GohCore/Model/CommandDispatcher.swift`**
Routes `Command` cases to `JobStore` mutations, returns `CommandOutcome`. New daemon commands are added here. Currently handles: `add`, `ls`, `pause`, `resume`, `rm`, `authImportSafari`, `subscribe`.

**`Sources/GohCore/Model/CommandService.swift`**
XPC adapter. `protocolVersion: UInt32 = 3`. Any new daemon command that is added to `Command` is dispatched via `dispatcher.reply(to:)` without changes here, unless the command needs an XPC fd sibling (as `authImportSafari` does) or server-initiated notifications (as `subscribe` does).

**`Sources/GohCore/Model/GohError.swift`**
`ErrorCode` enum with `checksumMismatch` already present — directly usable for `goh verify` failure reporting.

**`Sources/GohCore/Platform/SpotlightMetadataTagger.swift`**
Writes `kMDItemWhereFroms` and `kMDItemDownloadedDate` via `setxattr` after a download completes. Called from `gohd/main.swift`'s `completedDownloadHandler`. This is the seed of `goh which` — reading back `kMDItemWhereFroms` from a file is the reverse path. `SpotlightMetadataTagger` only writes; a companion reader would be new, likely in the CLI, using `getxattr`.

**`Sources/GohCore/Auth/ImportedCookieStore.swift`** / **`Sources/GohCore/Auth/SafariCookieFileLocator.swift`**
Safari cookie import. Cookies are held in memory as `SafariCookieJar`; not written to disk in any format goh owns. Authentication works for any download where `useImportedCookies` is true on the `AddRequest`. Relevant to `goh sync` if manifested URLs require authentication.

**`Sources/gohd/main.swift`**
Daemon bootstrap. Resolves support-directory path, wires `CatalogStore` → `CatalogWriter` → `JobStore` → `DownloadEngine`. The `completedDownloadHandler` closure is where the SHA-256 digest could be captured and written to `JobSummary` before `store.complete()` is called. This is the only place all three — digest, `JobSummary`, and persistence — are reachable simultaneously.

---

## CONSTRAINTS

1. **XPC `protocolVersion = 3` is a frozen contract.** Any new daemon command requires a protocol bump to version 4 and a corresponding update to `CommandService.protocolVersion` and `GohEnvelope` fixtures in the test suite. Do not add new cases to `Command` without bumping.
2. **No TOML parser exists.** `Package.swift` has one dependency (`swift-http-types`). Adopting a TOML parser requires explicit justification under the "Apple frameworks first" policy. Apple provides no TOML parser in the SDK. Options: write a minimal hand-rolled parser, or adopt a Swift community package (e.g. `LebJe/TOMLKit` or `jpsim/Yams` for YAML instead). This is the largest unresolved dependency decision.
3. **No Node, Python, or non-Swift runtime.** Manifest tooling must be pure Swift.
4. **Catalog schema `version = 1` is not a frozen external contract** (the file is daemon-private), but migration must be handled in `CatalogStore.load()` when `currentVersion` bumps.
5. **`CI runs on macos-26` runner, stable Xcode only.** Any new Apple API must exist in the stable SDK shipping with that Xcode, not a beta.
6. **Swift 6 language mode + `Sendable`.** All new types that cross actor boundaries must be `Sendable`. No `@unchecked Sendable` without documented justification.

---

## OPEN QUESTIONS

1. **Is the completed-download SHA-256 persisted today?** No. `ChunkAssembler.hashToCompletion()` returns `.digest(String)` but the engine discards the hex string after checking for failure. There is no `sha256` field in `JobSummary`, `JobCatalog`, or any on-disk format. `goh verify` must either re-hash the file on demand (slow, ~1 GB/s on Apple Silicon — acceptable for a CLI command) or persist the digest at completion time (requires a `JobSummary` schema change and catalog version bump to 2).

2. **TOML parser: build vs buy?** No TOML library is in the project. A `gohfile.toml` manifest requires parsing TOML. Options are: (a) hand-roll a minimal subset parser (no dependency, but brittle); (b) adopt a community Swift TOML package (dependency review required under the Apple-frameworks-first policy). This needs an explicit decision in the spec before implementation starts.

3. **Is `goh sync` daemon-side or CLI-local?** If `goh sync` reads `gohfile.toml` and enqueues downloads via `goh add`, it could be implemented as a CLI-local loop that issues one `add` XPC call per manifest entry — no new daemon command needed. If it needs atomic batch semantics (all-or-nothing enqueue), it needs a new `Command.syncManifest` case and a protocol bump. The simpler CLI-local path is preferred unless batch atomicity is a product requirement.

4. **Where does the lockfile live, and who owns it?** If `goh sync` writes a `gohfile.lock` next to `gohfile.toml`, that write happens in the CLI process, not the daemon — consistent with the CLI-local pattern. If the daemon needs to know about the lockfile (e.g. to enforce re-download on digest mismatch), it needs a new IPC surface.

5. **`goh which` read path.** `SpotlightMetadataTagger` writes `kMDItemWhereFroms` via `setxattr`. Reading it back requires `getxattr` on the file path — no existing code does this. `goh which <file>` would be a pure CLI-local command (no XPC needed) that calls `getxattr` and decodes the binary plist. Confirm this is sufficient vs. querying the daemon's job catalog for provenance.

6. **`goh verify` scope.** Does it verify against the `gohfile.toml` expected digest, against the digest recorded in the job catalog at completion, or does it re-hash on demand? Each answer implies different architecture: manifest-only requires no catalog changes; catalog-recorded requires schema bump; on-demand re-hash requires no storage changes but is slower.
