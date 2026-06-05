# Phase 2 Progress — provenance-everywhere

Status: COMPLETE — Tasks 4–5 implemented and passing.

## WHAT WAS BUILT

- `DownloadEngine.completedDownloadHandler` widened from 4-param to 5-param
  (`JobSummary, Duration, Bool, String?, GovernorOutcome`).
- `DownloadEngine.complete(...)` gains `sha256: String?` parameter.
- `DownloadEngine.verifyHash(file:total:)` changed from `-> Void` to `-> String`
  (returns lowercase-hex digest, resume path captures and passes to `complete`).
- `fetchSingle` and `fetchRanged` restructured to bind `await assembled` once and
  extract the hex digest from `.digest(hex)` — one await per site, exhaustive handling.
- 4 existing `DownloadEngineTests` handler closures updated with `_` wildcard for sha256 param.
- `gohd/main.swift`: local `supportDirectoryURL()` removed; replaced by
  `ProvenanceStoreLocation.supportDirectoryURL(create: true)`. `ProvenanceStore` constructed
  alongside other stores; best-effort `provenanceStore.record(entry:)` block added after
  Spotlight block in `completedDownloadHandler`.

## CURRENT STATE OF MODIFIED FILES

**`DownloadEngine.swift`:**
- `completedDownloadHandler`: `(@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome) -> Void)?`
- `complete(jobID:in:transferDuration:isResume:sha256:governorOutcome:)` — sha256 is 4th param (String?), governorOutcome defaulted
- `verifyHash(file:total:) async throws -> String` — returns lowercase-hex digest

**`gohd/main.swift`:**
- `supportDirectoryURL()` function removed
- `ProvenanceStore` constructed via `ProvenanceStoreLocation.defaultURL(create: true)`
- Handler closure: `{ completed, transferDuration, isResume, sha256, governorOutcome in ... }`
- Recording: `"sha256:" + sha256` prefixing at the write site; canonical path via `URL(fileURLWithPath:).standardizedFileURL.path`

## CONTRACTS ESTABLISHED

- Handler closure type (daemon-internal, NOT on any wire):
  `@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome) -> Void`
- `sha256` in handler = bare lowercase hex (no prefix). Daemon prepends `"sha256:"` before writing.
- Recording is best-effort: `do/catch` + `warn()`, never propagated.
- `nil` sha256 → no provenance entry written (skipped, not a placeholder entry).

## OPEN ITEMS

- Phase 3: `goh which` ledger branch (Task 6); `goh verify --all` new surface (Task 7);
  `GohCommandLine` parse/dispatch (Task 8); usage update (Task 9); `DESIGN.md` update (Task 10).

## DEVIATIONS FROM PLAN

- **`record(entry:)` label.** The plan's Task 5 §2c daemon snippet calls
  `provenanceStore.record(ProvenanceEntry(...))` without the `entry:` argument label.
  The real `ProvenanceStore.record` signature is `record(entry:)` (verified in
  `Sources/GohCore/Provenance/ProvenanceStore.swift`), so the call was written as
  `record(entry: ProvenanceEntry(...))`. Matches the labeled call used throughout
  `ProvenanceStoreTests.swift`.
- **Resume-path scoping.** Plan §3f uses a `...` ellipsis between `verifyHash` and
  `complete`. The original code placed `recordProgress` + `complete` OUTSIDE the
  `do/catch`. To preserve that exact control flow while binding the digest, the
  `resumeDigest` local was hoisted to `let resumeDigest: String` above the `do`
  block; `verifyHash` assigns it inside the `do`, and `complete(sha256: resumeDigest)`
  runs after the block as before. No behavioral change vs. the original error/cancel path.
- **Per-task build independence.** Task 4's commit (engine + tests) does not build the
  `gohd` target standalone, because `swift test`/`swift build` compile the whole package
  and `gohd`'s 4-param closure is incompatible with the widened 5-param handler type until
  Task 5 lands. The final working tree (after both commits) builds warning-clean and all
  584 tests pass. This is an inherent ordering property of the plan, not a defect in the code.
