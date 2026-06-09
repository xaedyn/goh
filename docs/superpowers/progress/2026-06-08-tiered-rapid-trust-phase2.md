# Phase 2 — Capture Path: progress artifact

Date: 2026-06-09
Branch: `design/tiered-rapid-trust`

## Status: COMPLETE

All three tasks executed in order. Full build clean with
`-Xswiftc -warnings-as-errors`; full test suite green (828 tests, 111 suites).

## Commits

- T2.1 `fbd5796` — feat(engine): add DownloadFile.fileStat() for fstat baseline capture
- T2.2 `7231ad0` — feat(engine): widen completedDownloadHandler with trailing FileStat? for stat baseline
- T2.3 `2153ef8` — feat(daemon): route FileStat baseline from engine finalization into ProvenanceEntry

## What shipped

### T2.1 — `DownloadFile.fileStat() throws -> FileStat`
Added after `sync()`, before `finish()`. `Darwin.fstat(descriptor, &st)` on the
open fd, maps `struct stat` to `FileStat` with `(st.st_mode & S_IFMT) == S_IFREG`.
Throws `DownloadFileError.syncFailed(errno:)` on failure; callers use `try?`.
Test `fileStatReturnsAccurateSize` added to `@Suite("Download file")`.

### T2.2 — widened completion seam + three capture sites
- Stored property type, init param, and `complete()` method all gained a trailing
  `FileStat?` (defaulted `nil`).
- Three capture sites, each captures `try? file.fileStat()` BEFORE `file.finish()`:
  - fetchSingle: `fetchSingleFileStat`, digest var `fetchSingleDigest`
  - fetchRanged: `fetchRangedFileStat`, digest var `fetchRangedDigest`
  - resume: `resumeFileStat` (declared `var ... = nil` before the `do` block,
    assigned after `verifyHash` / before `finish()`), digest var `resumeDigest`
- Each `complete(...)` call passes the captured stat as trailing `fileStat:`.
- Drift handled: the five existing `completedDownloadHandler` test closures in
  `DownloadEngineTests.swift` were forced from 5 to 6 closure params (added a
  trailing ignored `_`). Mechanical, required by the arity widen.

### T2.3 — daemon routes FileStat? into ProvenanceEntry
- Closure signature gained trailing `completedFileStat`.
- `ProvenanceEntry(...)` now populates all five baseline fields via
  `completedFileStat.map { ... }` (all five nil or all five non-nil):
  `recordedStatSize`, `recordedMtimeSeconds`, `recordedMtimeNanoseconds`,
  `recordedInode`, `recordedDevice`.

## Governor block: byte-for-byte unchanged

`git diff <T2.1^>..HEAD -- DownloadEngine.swift` does NOT contain any of
`lastSampledTotal`, `lastSampledAt`, `governor.record`, `governor.decide`,
`minGovernorSampleSeconds`, or `bps`. The fetchRanged governor sampling block
(lines ~831–858) is unmodified.

## Frozen contracts

XPC `protocolVersion` (4) unchanged. No wire-format / golden-fixture change.
`JobProgress` untouched. No path-based stat added; no stat in the daemon — the
baseline is captured from the same open fd that produced the hashed bytes
(TOCTOU-closing design).

## THE BET CHECK

Full engine suite + golden provenance tests green; governor block unchanged.
`swift test` → 828 tests in 111 suites passed.
