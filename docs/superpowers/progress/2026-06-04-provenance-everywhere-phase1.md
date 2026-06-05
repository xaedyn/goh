# Phase 1 Progress — provenance-everywhere

Status: COMPLETE — Tasks 1–3 implemented and passing.

## WHAT WAS BUILT

- `Sources/GohCore/Provenance/ProvenanceRecord.swift` — `ProvenanceRecord` (versioned root,
  `currentVersion = 1`) and `ProvenanceEntry` (5 fields, `Codable`/`Sendable`/`Equatable`).
- `Tests/GohCoreTests/Fixtures/provenance-v1.plist` — golden binary-plist fixture with 2 entries.
- `Tests/GohCoreTests/ProvenanceRecordTests.swift` — golden round-trip, empty, encode/decode.
- `Sources/GohCore/Provenance/ProvenanceStore.swift` — `final class: Sendable` over `Mutex<Inner>`;
  `load()` with version-check + corrupt→sidecar-copy; `record(entry:)` in-place by path + atomic
  rewrite; `lookup(destinationPath:)` (canonicalizes internally); `allEntries()`.
- `Sources/GohCore/Provenance/ProvenanceStoreLocation.swift` — `defaultURL(create:)` and
  `supportDirectoryURL(create:)` shared resolver.
- `Tests/GohCoreTests/ProvenanceStoreTests.swift` — T2 (corrupt/sidecar), T3 (dedup), round-trip,
  missing-file, permissions, no-temp-file, lookup-canonicalization, version-mismatch, create:false.

## CURRENT STATE OF MODIFIED FILES

**`ProvenanceRecord.swift` exports:**
- `ProvenanceRecord: Codable, Sendable, Equatable` — `currentVersion: Int = 1`, `version: Int`,
  `entries: [ProvenanceEntry]`, `empty: ProvenanceRecord`
- `ProvenanceEntry: Codable, Sendable, Equatable` — `url`, `sha256`, `size`, `downloadedAt`, `destinationPath`

**`ProvenanceStore.swift` exports:**
- `ProvenanceStoreError: Error` (fsyncOpenFailed, fsyncFailed, renameFailed)
- `ProvenanceLoadResult: Sendable` — `record: ProvenanceRecord`, `corruptionSidecar: URL?`
- `ProvenanceStore: Sendable` — `init(fileURL:)`, `load() -> ProvenanceLoadResult`,
  `loadReadOnly() -> Bool` (CLI read path; no dir/sidecar creation — BLOCK-3),
  `record(entry:) throws`, `lookup(destinationPath:) -> ProvenanceEntry?`, `allEntries() -> [ProvenanceEntry]`

**`ProvenanceStoreLocation.swift` exports:**
- `ProvenanceStoreLocation: enum` — `defaultURL(create: Bool) throws -> URL`,
  `supportDirectoryURL(create: Bool) throws -> URL` (public static)

## CONTRACTS ESTABLISHED

- On-disk format: binary plist of `ProvenanceRecord`, `currentVersion = 1`.
  Path: `~/Library/Application Support/dev.goh.daemon/provenance.plist`.
  Field `sha256` stored WITH `"sha256:"` prefix. Field `destinationPath` stored in canonical form
  (`URL(fileURLWithPath:).standardizedFileURL.path`).
- `lookup(destinationPath:)` canonicalizes its argument internally — callers pass raw paths.
- `recoverToEmpty()` uses `copyItem` (not `moveItem`) — corrupt original left in place.
- No TTL eviction (intentional divergence from `HostProfileStore` — see source comment).

## OPEN ITEMS

- Phase 2: Thread the digest from `ChunkAssembler.hashToCompletion()` through `complete(...)`,
  widen `completedDownloadHandler`, factor `supportDirectoryURL()` out of `gohd/main.swift`
  into `ProvenanceStoreLocation`, and wire best-effort recording in the daemon handler.
- Phase 3: `goh which` ledger branch + `goh verify --all` + `GohCommandLine` parse/dispatch/usage.
