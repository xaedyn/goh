---
date: 2026-06-10
feature: goh-forget
type: design-validation
---

# Design Validation — goh forget

Chosen approach: **Approach 1 (Preview-and-Confirm)**, full CLI + tray scope, plan-segmented
into a CLI phase and a tray phase.

## Acceptance Criteria (from Step 2.5)

- **AC1:** `goh forget <path>` removes a tracked path's ledger entry; subsequent `verify --all`
  and `verify --quick` no longer list it; exit 0 + one-line confirmation.
- **AC2:** `goh forget --missing` candidate set = exactly entries whose `destinationPath` is
  absent on disk (present-file entries never candidates); deletion only after the `--confirm`
  gate; without it, nothing is deleted.
- **AC3:** `goh forget <path>` for an untracked path → no change, clear "not tracked" message,
  non-zero exit (never silent success).
- **AC4:** A removing `forget` rewrites the ledger atomically (temp → fsync → rename → fsync dir);
  a mid-write kill leaves a complete old or new `provenance.plist`, never a truncated file.
- **AC5:** Tray Trust window offers a "Forget" affordance on MISSING rows; invoking it removes
  the entry via the daemon and the row disappears on refresh; present-file rows do not get a
  one-click destructive Forget without the same preview/confirm treatment.

## Dependency Enumeration

Modified interfaces and every consumer (from research brief):

- **`GohMenuClient` protocol** (`Sources/GohMenuBar/GohMenuViewModel.swift:5`) — **5 conformers**
  must implement the new `forget(paths:)`: `LiveGohMenuClient` (goh-menu/main.swift:11, prod);
  `FakeMenuClient` (AddDownloadViewModelTests.swift:18); `FakeMenuClient`
  (GohMenuViewModelTests.swift:350); `LongLivedMenuClient` (GohMenuViewModelTests.swift:453);
  `SpyMenuClient` (TrustWindowViewModelBackfillTests.swift:9). All compile-time breaks.
- **`Command` enum** (`Sources/GohCore/Model/Command.swift`) — exhaustive switch in
  `CommandDispatcher.reply(to:)` (CommandDispatcher.swift:73) MUST gain a case (compile-time);
  `CommandService.handle()` uses `default` (additive-safe).
- **`ProvenanceStore`** — net-new `forget(paths:)`; no existing consumer of a delete path
  (none exists). Mirrors `recordVerified` + `writeAtomically`.

No interface is changed in a backward-incompatible way: `protocolVersion` stays 4 (new enum
case is additive on the wire), `ProvenanceRecord.currentVersion` stays 1. All breakages are
compile-time, none silent.

## Questions Asked & Answers

### Zero Silent Failures
- **Existing users on ship?** No action needed; `forget` is a new opt-in verb. Existing ledger
  entries and all other commands are unchanged.
- **Existing data/schema?** No schema change. `forget` mutates `record.entries[]` at runtime;
  the on-disk `ProvenanceRecord` v1 format is unchanged and remains round-trip compatible.
- **Existing callers?** Adding the `Command` case breaks one exhaustive switch and the
  `GohMenuClient` method breaks 5 conformers — all **compile-time**, caught by CI's
  `-warnings-as-errors` build. No silent break.
- **First step succeeds, second fails?** The daemon removes entries then `writeAtomically`s.
  Temp→rename→fsync means the ledger is the complete old or complete new file (AC4) — never
  partial. If the write throws, the dispatcher returns a **`.failure(GohError)` reply** (NOT
  `.ack`/success — `forgetProvenance` deliberately diverges from `recordVerifiedProvenance`'s
  best-effort `.ack`-on-throw, because it is a foreground destructive command the user is
  synchronously waiting on), so the CLI exits non-zero; entries are reported as NOT removed.
- **Stale daemon (predates `forgetProvenance`)?** Decoding an unknown `Command` case throws
  `DecodingError`; the daemon returns malformed/nil. The CLI **must not** report
  "forgot 0 entries" success. → see Fixes.

### Failure at Scale
- **10x volume?** `--missing` does N `lstat`s (cheap) + one full-plist atomic rewrite — the
  same O(N) write cost the existing `record`/`recordVerified` already pay. Fine for thousands.
- **Concurrent operations?** `ProvenanceStore` serializes all mutations via `inner.withLock`.
  A `forget` concurrent with a download completing (which records provenance) is serialized:
  either the entry is removed-then-re-added or re-added-then-removed — consistent, never
  corrupt. The whole-ledger atomic write means no interleaved partial state.
- **External dependency unavailable?** The `--missing` preview (no `--confirm`) is a read-only
  lstat pass and works with the daemon stopped. The mutating paths (`forget <path>`,
  `--missing --confirm`) need the daemon; if it's down the CLI gets a connection error and
  exits non-zero with nothing removed — graceful.

### Simplest Attack
- **Cheapest abuse?** The command rides the existing XPC peer-validated (`isFromSameTeam`)
  dispatch — no new endpoint, no new auth surface. Only a same-team-signed client (the user's
  own binaries) can send it; erasing one's own ledger is in-scope user intent, not an attack.
- **Misconfigured authz on a new endpoint?** There is no new endpoint — `forgetProvenance` is a
  case on the existing validated `Command` channel.
- **Can forget touch the filesystem?** It must NOT. `forget` removes ledger entries only and
  must never delete or modify the file at the path. → see Fixes (asserted in spec + test).

## Gaps Found

1. **Stale-daemon silent success.** A daemon predating `forgetProvenance` fails to decode the
   command; the CLI could misreport success.
2. **File-deletion safety not yet contractual.** Nothing in the design yet *states* that
   `forget` never deletes the actual file — only the ledger entry. This must be an explicit,
   tested invariant.
3. **TOCTOU on `--missing`.** A file can reappear (drive remounted) between the CLI's preview
   enumeration and the daemon's deletion.

## Fixes Applied

1. **Stale-daemon → actionable error, never silent success.** Bump `GohFeatureLevel.current`
   to 2 (daemon advertises `forgetProvenance` support). Before a mutating forget sends the
   destructive command, the CLI runs a **NEW gate specific to `forget`**: a *fresh `.ls` +
   featureLevel compare*, decided exit-code-affecting CLI-side. This is NOT the gate `verify`
   uses — `DaemonAutoHeal.runIfNeeded` is best-effort and exit-code-neutral, and its `String?`
   return conflates "current/healed" and "XPC unreachable" (both `nil`), so it cannot drive a
   "must error" decision. The gate: (i) MAY invoke `DaemonAutoHeal.runIfNeeded` purely to
   *attempt* a heal, its return discarded; (ii) sends a FRESH `.ls` and reads
   `LsReply.featureLevel`; (iii) if the `.ls` send throws (XPC unreachable / daemon stopped)
   → "cannot reach the goh daemon" + exit 1, send nothing; if `featureLevel == nil` or `< 2`
   → "this goh daemon is too old to support `forget`; restart it: `goh daemon restart`" +
   exit 1, send nothing; only `featureLevel >= 2` proceeds. The CLI never prints a success line
   unless the daemon returned a successful `ForgetProvenanceReply` whose `forgotCount` matches
   the requested count. The non-mutating `--missing` preview and the untracked-path check need
   no live daemon. (gap #1 fix.)
2. **File-deletion safety is contractual.** Spec states: `ProvenanceStore.forget(paths:)`
   mutates `record.entries[]` ONLY and must never `unlink`/modify any file on disk. A test
   asserts that forgetting a path whose file still exists leaves the file untouched on disk.
3. **TOCTOU accepted with mitigation.** `forgetProvenance` removes exactly the canonical paths
   in the request — a pure, explicit by-path removal (matching `forget <path>` semantics). The
   mitigation for the unmounted-drive case is the preview's per-entry volume-mount annotation,
   which the user reads before passing `--confirm`. The short preview→confirm window and the
   explicit-paths contract make daemon-side re-checking unnecessary; documented as accepted.
