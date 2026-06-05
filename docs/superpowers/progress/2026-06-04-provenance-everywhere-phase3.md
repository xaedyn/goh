# Phase 3 Progress — provenance-everywhere

Status: COMPLETE — Tasks 6–10 implemented and passing.

## WHAT WAS BUILT

- `Sources/GohCore/CLI/GohWhichCommand.swift` — `run(filePath:lockPath:provenanceStorePath:)`
  gains a defaulted `provenanceStorePath: String? = nil`. New `lookupInLedger` private method routes
  through the shared `ProvenanceStore.loadReadOnly()` + `lookup(destinationPath:)` (BLOCK-3 — no inline
  string compare). The existing `GohWhichCommandTests` tests are unmodified and still pass.
- `Tests/GohCoreTests/GohWhichLedgerTests.swift` — T6 (ledger read), T6b (canonical-path match),
  nil-skip, missing-ledger, lock-precedence.
- `Sources/GohCore/CLI/GohVerifyAllCommand.swift` — `run(provenanceStorePath:) -> GohCommandLineResult`.
  Exit codes 0/2/6/9; precedence 9>2; CLI never copies sidecar or resets store.
- `Tests/GohCoreTests/GohVerifyAllCommandTests.swift` — T7 (OK/FAILED/MISSING), exit 2, exit 0,
  T8 (absent → 0, corrupt → 6 no sidecar), T7b (frozen signature check).
- `Sources/GohCore/CLI/GohCommandLine.swift` — `ParsedCommand.verifyAll` (carries no path; resolution
  deferred to dispatch); injectable `provenanceStorePathResolver` test seam (BLOCK-1, mirrors the
  `foreground`/`top`/`doctor`/`diagnose` injection idiom); `verify --all` parse arm; `which` and
  `verifyAll` dispatch resolve the store path via the resolver; usage updated.
- `Tests/GohCoreTests/GohVerifyAllParseTests.swift` — T7b parse routing, frozen verify, parse errors, usage.
- `DESIGN.md` — provenance-everywhere section added.

## CURRENT STATE

All acceptance criteria satisfied:
- AC1: Engine threads digest; daemon records with "sha256:" prefix at write site.
- AC2: `goh which` reads from ledger (T6/T6b). Offline — no URLSession on path.
- AC3: `goh verify --all` re-hashes via FileDigest, OK/FAILED/MISSING, exit 0/2/9 (T7/T8).
- AC4: All pre-existing golden fixtures unchanged; `provenance-v1.plist` golden round-trip passes;
  `-warnings-as-errors` clean; test count strictly higher.
- AC5: In-place update (T3); corrupt→sidecar (T2); best-effort non-fatal (T4); CLI no-sidecar (T8).

## OPEN ITEMS

None. Feature complete. Proceed to PR creation and CodeRabbit review.
