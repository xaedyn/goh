---
date: 2026-06-04
feature: provenance-everywhere
type: codebase-context-brief
---

# Codebase Context Brief — Provenance-everywhere (verify-only)

**STACK**

Swift 6.2 (swift-tools-version 6.2), macOS 26.0 floor. Transport: `URLSession`.
IPC: XPC (`XPCSession`/`XPCListener`, `XPCPeerRequirement`). Hashing: `CryptoKit`
SHA-256 (in-download: `ChunkAssembler`; at-rest re-hash: `FileDigest`).
Persistence: binary property lists via `PropertyListEncoder/Decoder`. Spotlight
xattr tagging: `setxattr` / `kMDItemWhereFroms` / `kMDItemDownloadedDate`.
Trust-core on-disk codec: `MinimalTOMLReader`/`MinimalTOMLWriter`. Tests: Swift
Testing.

**EXISTING PATTERNS**

- **On-disk frozen formats.** `gohfile.toml` parsed by `ManifestCodec.parse(_:)`
  (TOML, no version field). `gohfile.lock` encoded/decoded by
  `LockfileCodec.encode/decode` (TOML, `lockfileVersion = 1`); both use
  `MinimalTOMLReader/Writer`, written atomically via `rename(2)` + dir `fsync`
  in `GohSyncCommand`.
- **Daemon-owned persistent stores.** In `~/Library/Application Support/dev.goh.daemon/`:
  `catalog.plist` (`CatalogStore` → `JobCatalog`, `currentVersion = 1`),
  `checkpoints/<id>.checkpoint.plist` (`CheckpointStore` → `DownloadCheckpoint`,
  v1), `host-scheduling.plist` (`HostProfileStore` → `HostScheduling`, v1). All
  use binary plist → temp → `fsync(temp)` → `rename` → `fsync(dir)`.
- **Completion path.** `DownloadEngine.complete(jobID:in:transferDuration:isResume:governorOutcome:)`
  calls `store.complete(id:)` → completed `JobSummary`, then invokes
  `completedDownloadHandler?(completed, transferDuration, isResume, governorOutcome)`
  — `(@Sendable (JobSummary, Duration, Bool, GovernorOutcome) -> Void)?`. In
  `gohd/main.swift` this handler records a host-profile bandit observation and
  calls `SpotlightMetadataTagger.tagCompletedDownload(...)`.
- **Spotlight provenance.** `SpotlightMetadataTagger.tagCompletedDownload(destination:sourceURL:downloadedAt:)`
  writes `kMDItemWhereFroms` + `kMDItemDownloadedDate` via `setxattr`.
  `GohWhichCommand` reads them via `getxattr`.
- **SHA-256 streaming.** `ChunkAssembler.hashToCompletion() async -> ChunkAssemblerResult`
  returns `.digest(String)` (lowercase hex, no prefix) in-order as bytes land.
  In `fetchSingle`/`fetchRanged`/resume the result is awaited but the digest is
  **discarded** (`_ = await assembled`). Never forwarded to `complete()` or the
  handler.

**RELEVANT FILES**

- `Sources/GohCore/Model/JobSummary.swift` — `JobSummary: Codable, Sendable`
  (`id, url, destination, state, progress, createdAt, completedAt?, ...`). **No
  `sha256` field** — the memo's "reserved seam" does not exist.
- `Sources/GohCore/Model/JobCatalog.swift` — `currentVersion = 1`, `[JobSummary]`.
- `Sources/GohCore/Model/CatalogStore.swift` — atomic plist idiom.
- `Sources/GohCore/Engine/DownloadEngine.swift` — completion handler; digest
  dropped in all three paths.
- `Sources/GohCore/Engine/ChunkAssembler.swift` — `hashToCompletion()` →
  `.digest(String)`.
- `Sources/GohCore/Platform/SpotlightMetadataTagger.swift` — xattr tagging.
- `Sources/GohCore/CLI/GohWhichCommand.swift` — `gohfile.lock` first, then xattr
  fallback; xattr path emits `sha256: (not recorded)`.
- `Sources/GohCore/CLI/GohVerifyCommand.swift` — operates only on `gohfile.lock`;
  uses `FileDigest.sha256WithSize`.
- `Sources/GohCore/CLI/GohSyncCommand.swift` — only path writing provenance into
  `gohfile.lock`.
- `Sources/GohCore/TrustCore/LockfileCodec.swift` — `LockEntry {url, path,
  sha256, size, downloadedAt}`, `lockfileVersion = 1`.
- `Sources/GohCore/TrustCore/FileDigest.swift` — `sha256WithSize(path:) ->
  (String, Int)`, returns `"sha256:<hex>"`.
- `Sources/GohCore/IPC/Envelope.swift` + `CommandService.swift` —
  `protocolVersion: UInt32 = 3`.
- `Sources/gohd/main.swift` — wires `completedDownloadHandler`; natural injection
  point for the provenance write.

**CONSTRAINTS**

Frozen: `protocolVersion = 3`, `JobCatalog.version = 1`,
`DownloadCheckpoint.version = 1`, `HostScheduling.version = 1`, `gohfile.lock
lockfileVersion = 1`, `GohEnvelope` keys, `JobSummary` wire shape. None may
change without a protocol bump.

**OPEN QUESTIONS**

1. The "reserved sha256 seam" does not exist; digest is computed and discarded.
2. No global provenance record exists; `goh which` emits `sha256: (not
   recorded)` for ad-hoc downloads.
3. Digest is not threaded through `complete()`; either extract `.digest` and
   pass it, or record at the assembler site via a side channel.
4. Natural home for a global record: daemon-owned
   `~/Library/Application Support/dev.goh.daemon/` (mirrors existing stores;
   daemon-writable, CLI-readable). CLI-local won't work — `goh add` goes through
   the daemon, the CLI has no direct digest access.
5. Verify-everything is a new command surface, not an extension of the frozen
   `goh verify` exit-code contract.
6. `gohfile.lock` semantics unaffected — the global record is additive and
   orthogonal.
