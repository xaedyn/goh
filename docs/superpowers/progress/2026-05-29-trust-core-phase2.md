---
date: 2026-05-30
feature: trust-core
phase: 2
status: executed (verified by passing tests)
---

# Phase 2 Progress — Manifest + Lockfile codecs + FileDigest

## What was built

- `Sources/GohCore/TrustCore/ManifestCodec.swift`
  - `ManifestCodec.ManifestFile` (manifestHash, base?, assets)
  - `ManifestCodec.AssetEntry` (url, path, sha256?, verify)
  - `ManifestCodec.parse(_:)` — validates schema §7; rejects unknown keys,
    bad sha256 shape, reserved auth present/non-null, both path+dest, version != 1
  - Computes `manifestHash = "sha256:<hex>"` from raw toml bytes before parsing
- `Sources/GohCore/TrustCore/LockfileCodec.swift`
  - `LockfileCodec.Lockfile` (lockfileVersion, manifestHash, entries)
  - `LockfileCodec.LockEntry` (url, path, sha256, size, downloadedAt)
  - `LockfileCodec.decode(_:)` — rejects unknown version, missing manifestHash, reserved chunks
  - `LockfileCodec.encode(_:)` — `lockfileVersion` first, deterministic field order
- `Sources/GohCore/TrustCore/FileDigest.swift`
  - `FileDigest.sha256(path:)` → `"sha256:<64-hex>"`
  - `FileDigest.sha256WithSize(path:)` → `(String, Int)`
  - Streams in 1 MiB chunks via `FileHandle`; throws `GohError(.destinationUnwritable)` on failure
- Tests: `ManifestCodecTests.swift`, `LockfileCodecTests.swift`, `FileDigestTests.swift`

## Current state of modified files

- No pre-existing files modified in Phase 2.

## Contracts established

- §7 schema frozen: `ManifestCodec.AssetEntry` fields, validation rules, error messages.
- §8 schema frozen: `LockfileCodec.LockEntry` fields; `lockfileVersion` first in output.
- `FileDigest.sha256WithSize` is the re-hash entry point for sync and verify.
- `"sha256:<64-lowercase-hex>"` format is the canonical hash string throughout.

## Open items

- Phase 3 (daemon hardening) can proceed in parallel with Phase 4 (`goh which`).
