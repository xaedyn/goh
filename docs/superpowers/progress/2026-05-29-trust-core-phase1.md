---
date: 2026-05-30
feature: trust-core
phase: 1
status: template (fill after execution)
---

# Phase 1 Progress — Hand-rolled TOML reader+writer

## What was built

- `Sources/GohCore/TrustCore/MinimalTOMLReader.swift`
  - `MinimalTOMLDocument`, `TOMLValue`, `MinimalTOMLReader.ParseError`
  - `MinimalTOMLReader.parse(_:allowedTopLevelKeys:allowedAssetKeys:)`
  - Accepted subset: basic string, integer, boolean scalars; `[[arrayOfTables]]` headers; `#` comments
  - All out-of-subset constructs rejected with named error (inline table, dotted key, array value, float, native datetime, standard `[table]`)
- `Sources/GohCore/TrustCore/MinimalTOMLWriter.swift`
  - `MinimalTOMLWriter.write(_:)` → deterministic TOML string (keys sorted, `[[section]]` after top-level fields)
- `Tests/GohCoreTests/MinimalTOMLReaderTests.swift`
  - Full fixture parse, empty manifest, lockfile, unknown-key rejection, all out-of-subset construct rejection, round-trip
- `Tests/GohCoreTests/Fixtures/` — all Phase 1 fixtures added:
  - `toml-manifest-full.toml`, `toml-manifest-empty.toml`, `toml-lockfile-full.toml`
  - `toml-manifest-bad-unknown-key.toml`, `toml-manifest-bad-inline-table.toml`
  - `toml-manifest-bad-dotted-key.toml`, `toml-manifest-bad-array-value.toml`
  - `toml-manifest-bad-float.toml`, `toml-manifest-bad-native-datetime.toml`
  - `toml-manifest-bad-auth-reserved.toml`, `toml-manifest-bad-sha256-shape.toml`
  - `toml-lockfile-bad-unknown-version.toml`, `toml-lockfile-bad-chunks-reserved.toml`
  - `toml-lockfile-bad-missing-manifestHash.toml`

## Current state of modified files

- All Phase 1 files created; no pre-existing files modified.
- `Package.swift`: unchanged (Fixtures already `.copy` resource).

## Contracts established

- `MinimalTOMLReader.parse` signature frozen; ManifestCodec and LockfileCodec import it.
- Accepted TOML subset documented in code comments; golden fixtures lock the error strings.
- Auth/chunks: reader admits them (valid TOML scalars); domain rejection is ManifestCodec/LockfileCodec's job.

## Open items

- None. Phase 2 can proceed.
