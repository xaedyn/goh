---
date: 2026-05-30
feature: trust-core
phase: 4
status: executed (verified by passing tests)
---

# Phase 4 Progress — `goh which`

## What was built

- `Sources/GohCore/CLI/GohWhichCommand.swift`
  - `GohWhichCommand.run(filePath:lockPath:)` → `GohCommandLineResult`
  - Priority: (1) lock lookup by absolute path match, (2) xattr getxattr provenance
    reader (inverse of SpotlightMetadataTagger), (3) exit 4 "no provenance record"
  - `readXattrPropertyList(path:attr:)` — getxattr + PropertyListSerialization
- `Sources/GohCore/CLI/GohCommandLine.swift` — added:
  - `.which(path: String)` to private `ParsedCommand`
  - `if arguments.count == 2, arguments[0] == "which"` branch in `parse(_:)`
  - `case .which(let path):` dispatch in `run()`
  - `goh which <path>` in `usage()`
- `Tests/GohCoreTests/GohWhichCommandTests.swift`
  - Lock record found → exit 0, url + sha256 + downloadedAt printed (AC4)
  - Lock missing + no xattr → exit 4 (AC4)
  - xattr fallback → exit 0 (AC4)

## Contracts established

- `goh which` is CLI-local; no XPC calls.
- Lock lookup resolves entry `path` relative to lock's directory.
- Exit 4 = no provenance record (both sources exhausted).
- xattr output omits sha256 (prints `sha256: (not recorded)`).

## Open items

- None. Phase 5 can proceed.
