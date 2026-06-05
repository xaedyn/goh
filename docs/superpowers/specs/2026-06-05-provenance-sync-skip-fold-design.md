---
date: 2026-06-05
feature: provenance-sync-skip-fold
type: spec
status: draft
approach: The Courier + additive verifiedAt
---

# Spec — Record provenance for skipped/already-present `goh sync` files

## 1. Problem

`goh sync` records download provenance only for files it actually transfers. When it finds a
manifest entry already present on disk and matching its expected hash, it **skips** the
download (the `upToDate`, `firstUse`, and accepted-`tofuChange` paths in `GohSyncCommand`) and
writes only a `gohfile.lock` entry. Those files never enter the daemon-owned
`provenance.plist`, so `goh which <file>` answers "(not recorded)" and `goh verify --all` is
blind to them — even though sync just confirmed, seconds earlier, that they match. This breaks
the "one offline ledger for everything you pulled" promise: half a synced manifest can be
invisible to the trust commands. The fix records sync-verified files into the same ledger,
through the daemon that owns it, while keeping the honest distinction between a file goh
*downloaded* and a file goh merely *verified present*.

## 2. Success metrics

Measurable definition of done (each maps to an acceptance criterion; all are observable via the
shipped CLI + tests):

- **M1 (AC1/AC2):** After `goh sync` of a manifest whose files are already present and matching,
  100% of the skipped entries are retrievable: `goh which <file>` prints the recorded
  `{url, sha256, size}` and a date line for every such file; `goh verify --all` includes them and
  reports `OK` (recorded sha256 == on-disk sha256). Verified by an integration test driving a
  fake daemon that wires a real `ProvenanceStore`, asserting entry count == skipped count.
- **M2 (AC3):** Recording the same path twice (download then later verify, or verify then
  download) yields exactly **one** entry for that canonical path, never two. Verified by a
  store-merge unit test.
- **M3 (AC4 — the rollback/abort threshold):** Provenance recording **never** changes a sync's
  exit code or per-entry outcome. Specifically: an all-present-manifest `goh sync` run with the
  daemon stopped exits **0** (unchanged from today). If this regresses — i.e. recording failure
  makes a sync fail — that is a release blocker. Verified by a daemon-down integration test.
- **M4 (AC5):** The on-disk `ProvenanceRecord` format is unchanged: `currentVersion` stays `1`
  and the existing `provenance-v1.plist` golden round-trip stays green. Verified by the existing
  fixture test continuing to pass with the new field present (nil → omitted).
- **M5:** `goh which` distinguishes the two states: a downloaded file shows a "downloaded" date;
  a verified-present-only file shows a "verified" date; a file that was both shows both. Verified
  by `GohWhichCommand` output tests.

## 3. Data model

### 3.1 `ProvenanceEntry` (on-disk, additive)

Add one field:

```swift
public var verifiedAt: Date?   // when goh last confirmed these exact bytes present
                               // WITHOUT downloading them; nil for download-only entries
```

- **Additive-optional.** Existing records (no `verifiedAt` key) decode to `nil`. New records with
  `verifiedAt == nil` must serialize byte-identically to today (synthesized `Codable` omits a nil
  optional in binary plist). `ProvenanceRecord.currentVersion` stays `1`. **No** new on-disk
  format version is authorized by this slice.
- All other fields (`url`, `sha256` (with `"sha256:"` prefix), `size`, `downloadedAt`,
  `destinationPath`) keep their current types and meaning. `downloadedAt` stays non-optional.

### 3.2 Field semantics

| Entry kind | `downloadedAt` | `verifiedAt` |
|---|---|---|
| Downloaded by goh (existing path) | actual transfer time | `nil` |
| Verified present, goh did download these exact bytes before | preserved original transfer time | verify time |
| Verified present, goh never downloaded these bytes (firstUse, or tofu-change to new bytes, or no prior entry) | = `verifiedAt` (best "first observed") | verify time |

`downloadedAt` is never fabricated as a fetch that did not happen: when goh has no record of
transferring the current bytes, `downloadedAt == verifiedAt` and `verifiedAt != nil` together
mean "first observed at this time; not a goh download."

## 4. Wire contract (XPC)

### 4.1 New command (additive; bumps `protocolVersion` 3 → 4)

```swift
case recordVerifiedProvenance(request: RecordVerifiedProvenanceRequest)

public struct RecordVerifiedProvenanceRequest: Codable, Sendable, Equatable {
    public var entries: [VerifiedProvenanceEntry]
}
public struct VerifiedProvenanceEntry: Codable, Sendable, Equatable {
    public var url: String
    public var sha256: String           // EXACTLY as `FileDigest.sha256WithSize` returns it —
                                        // already `"sha256:"`-prefixed (NOT raw hex). The CLI
                                        // passes `onDisk.0` through verbatim; the daemon stores
                                        // it verbatim and does NOT re-prefix. (Verified against
                                        // FileDigest.swift: the helper returns the prefixed form.)
    public var size: Int
    public var destinationPath: String  // CLI sends its resolved dest; daemon canonicalizes
    public var verifiedAt: Date
}
```

- **Hash form (no double-prefix):** `FileDigest.sha256WithSize` already returns the
  `"sha256:"`-prefixed string, which is the same form the on-disk store uses. The CLI forwards
  it unchanged and the daemon stores/compares it **verbatim** — it must NOT prepend `"sha256:"`
  again (doing so would store `"sha256:sha256:…"`, break the merge key, and make `verify --all`
  never match). This differs from the download completion handler, which prepends because the
  *engine* hands it a raw digest; the sync path's digest is already prefixed.
- **Batch** by design: one request carries all of a sync's verified-skip entries → one
  daemon-side read-modify-write (avoids O(n²) full-plist rewrites). The daemon canonicalizes
  each `destinationPath` via `URL(fileURLWithPath:).standardizedFileURL.path` (identical to the
  download path → AC3).
- Reply: a new zero-payload `CommandOutcome.ack` + `AckReply: Codable, Sendable, Equatable {}`.
  The CLI sends with `expecting: AckReply.self`. **Wire-out:** `CommandService.encodeReply`
  switches exhaustively over `CommandOutcome`; a `.ack` arm must be added that emits the reply
  envelope with an `AckReply()` payload (omitting it is a compile failure). The CLI client path
  is generic and needs no change beyond the `expecting:` type.
- `protocolVersion` bumps to `4`. `CommandService`'s exact-equality check then emits a clean
  `protocolVersionMismatch` to any un-upgraded CLI. New `envelope-v4-record-verified-provenance-
  {request,reply}.json` golden fixtures are added; `envelope-v3-*` are retained immutable.

### 4.2 Daemon handling

- `CommandDispatcher` gains an optional `provenanceStore: ProvenanceStore?` (passed from
  `gohd/main.swift`, where the store and the dispatcher are already constructed together; `nil`
  in tests that don't exercise it). The new `case .recordVerifiedProvenance(let request):` arm is
  added to the dispatcher's **exhaustive** `reply(to:)` switch; it calls the store, wraps any
  throw in the do/catch+warn pattern, and returns `.ack`. `CommandService.handle` already routes
  unrecognized cases through its `default:` arm to `dispatcher.reply`, so no `CommandService`
  routing change is needed beyond the `encodeReply` `.ack` arm (§4.1).
- The dispatch arm calls a new `ProvenanceStore.recordVerified(entries:)` that performs the §3.2
  merge for every entry **inside one `Mutex.withLock` + one atomic write** (serialized with the
  daemon's own completion-handler writes → no lost-update). Per-entry merge rule (the request's
  `sha256` is already in stored, `"sha256:"`-prefixed form — see §4.1):

  ```
  let canonical = canonicalize(entry.destinationPath)
  if let existing = current[canonical], existing.sha256 == entry.sha256 {
      out = existing; out.verifiedAt = entry.verifiedAt; out.url = entry.url; out.size = entry.size
  } else {
      out = ProvenanceEntry(url: entry.url, sha256: entry.sha256, size: entry.size,
                            downloadedAt: entry.verifiedAt, verifiedAt: entry.verifiedAt,
                            destinationPath: canonical)
  }
  ```
- Wrapped in the daemon's existing do/catch+warn pattern — a record failure is logged, never
  propagated.

## 5. CLI behavior (`goh sync`)

- **Carrier field (the `process()` → caller data path).** `process()` is `static` and `dest` /
  `onDisk` live only there (the skip helpers do not receive `dest`). Add a field
  `var verifiedEntry: VerifiedProvenanceEntry?` to `EntryOutcome`. `process()` populates it **at
  the skip-path return sites**, where `dest`, `asset.url`, `onDisk.0` (the already-prefixed
  digest), and `onDisk.1` (size) are all in scope — it does NOT rely on the helpers carrying
  `dest`. The helpers may keep their current signatures; `process()` attaches `verifiedEntry` to
  the `EntryOutcome` they return (or builds it inline at each skip return). `verifiedAt = now`
  is stamped once per entry.
- **Which skip paths contribute.** The accepted, already-present paths only: `upToDate`
  (hash matches pin or prior lock), `firstUse` (present, unpinned, no prior lock), and the
  **accepted** branch of `tofuChange`. Paths that do NOT contribute: confinement failures and
  partials that fall through to download (no `verifiedEntry`); a `tofuChange` whose drift is
  **rejected** (it retains the OLD entry and the prior path — emitting a `verifiedAt` for the new
  on-disk bytes would contradict the rejected state, so it contributes nothing); and files that
  are actually downloaded (already recorded by the engine — never re-sent).
- **Batch send.** After the per-entry loop, `run` collects every non-nil
  `EntryOutcome.verifiedEntry` into one `recordVerifiedProvenance` request and sends it **once**
  via the existing `send` channel, **best-effort**: wrapped in do/catch; any failure (daemon
  down, `protocolVersionMismatch` during a partial upgrade, store error) prints a single
  non-fatal warning and does **not** alter any entry's exit contribution or the overall exit
  code. If the collection is empty, **no command is sent** (no empty batch).
- Ordering: the batch is sent regardless of whether the lockfile write succeeds; the two are
  independent records. (Lockfile remains sync's own artifact; provenance is the daemon's.)
- **Wire test in scope.** `CommandTests.commandRoundTrip` enumerates `Command` cases in a literal
  list (not compiler-exhaustive), so a new case would otherwise ship untested — the new
  `recordVerifiedProvenance` case MUST be added to that list as part of this work.

## 6. Reader changes

### 6.1 `goh which` precedence — ledger-first (Cat-1 fix; deliberate behavior change)

Today `GohWhichCommand.run` consults `gohfile.lock` **first** (`GohWhichCommand.swift:30-32`) and
returns on a match *before* reaching the ledger branch (`:34-38`). Every file this feature records
is ALSO written to the lockfile by sync, so as-is the lock branch always wins and the new
`verifiedAt` is dead output (M5 unreachable). Worse: the lock entry stores the **sync/verify time
mislabeled as `downloadedAt`** (`GohSyncCommand` writes `downloadedAt: iso8601Now()` on the skip
paths), so lock-first actively shows the *muddier* of the two records.

**Fix:** swap the order in `run` to **ledger-first, lock-fallback** — try `lookupInLedger` before
`lookupInLock`. Rationale: the provenance ledger is now the unified source of truth, is a superset
of the lock's `which` fields (`url, sha256, size, downloadedAt` **plus** `verifiedAt`), and is
strictly more current than any single manifest's lockfile (it is updated on every download and
every sync-verify; a lockfile is frozen at its last sync). Files present **only** in a lockfile
(never in the ledger — e.g. a pre-feature synced file whose ledger entry was never written) keep
their current lock-branch output via the fallback; files in neither still exit 4 "(not recorded)".

**This is a deliberate, documented behavior change** for the narrow divergence case (a path present
in BOTH sources with **different** recorded sha256): `which` now shows the **ledger's** values, not
the lock's. The existing test `GohWhichLedgerTests.lockPrecedence`
(`Tests/GohCoreTests/GohWhichLedgerTests.swift:128-164`) encodes the *old* lock-authoritative
invariant and **must be rewritten** to assert ledger-first (the ledger's sha256 is shown, the
lock's is the fallback only when the ledger lacks the path). The rewrite is in scope and the
DESIGN.md §Persistence note records why the precedence flipped.

### 6.2 `goh which` rendering — `lookupInLedger` body rewrite

`lookupInLedger` (`GohWhichCommand.swift:62-79`) currently emits only `url / sha256 / downloadedAt`
and never reads `verifiedAt`; its body **must be rewritten** to produce the three-way output, and a
new output-assertion test added:
- `verifiedAt == nil` → unchanged "downloaded <date>" output (download-only entry).
- `verifiedAt != nil` and `downloadedAt == verifiedAt` → a single "verified present <date>" line
  (goh did not download these bytes).
- `verifiedAt != nil` and `downloadedAt < verifiedAt` → both "downloaded <date>" and
  "last verified <date>".

The lock-fallback renderer (`lookupInLock`) is unchanged (it has no `verifiedAt` concept).

### 6.3 `goh verify --all`

Unchanged hashing/OK/FAILED/MISSING logic; the new entries are simply included. No code change
beyond decoding the additive field (free via Codable).

## 7. Out of scope

- No change to how *downloaded* files are recorded (the completion handler is untouched except
  that its entries now carry `verifiedAt == nil`).
- No `currentVersion` bump / no new on-disk format version; no migration.
- No re-recording of files sync downloads (already in the ledger via the engine).
- No content-addressed storage, no restore, no GC/TTL of provenance (verify-only, unchanged).
- No reconciliation of historical lockfiles into provenance (only files seen by *this* sync run).
- No chunking of the batch (personal-scale manifests fit one message; revisit only if needed).
- The Read-Time Reconciler and direct-CLI-write approaches are explicitly rejected (see approaches
  + research brief).

## 8. Security surface

- **New attack surface:** one new XPC command on the **existing** same-team peer-validated
  channel (`XPCPeerRequirement` / `isFromSameTeam`). No new network surface, no per-command authz
  to misconfigure (reuses `CommandService`'s peer requirement uniformly).
- **Privilege:** a same-team local process could already write the user-owned 0600 `provenance.plist`
  directly; routing through the daemon adds no privilege and ledger-poisoning is bounded to what
  the user can already do to their own file.
- **Trust:** the daemon records the CLI-provided hash without re-reading the file. Consistent with
  the trust model — the user's own CLI hashed the user's own file moments earlier; provenance is
  the user's self-attestation, not a third-party claim. The daemon does not open `destinationPath`
  during recording, so there is no path-traversal or TOCTOU-on-open vector; the path is a logical
  key only.
- **PII:** entries contain source URLs and local paths (already true today); no new class of data.

## 9. Rollout & backward compatibility

- **Rollback plan:** the feature is additive — revert the CLI batch-send and the command, and v4
  readers still read v3-shaped data; the `verifiedAt` field, if any entries carry it, is ignored
  by older readers (decodes to nil / unknown key tolerated). No data migration to undo.
- **Rolling deploy (CLI/daemon built + shipped together via brew):** during a partial upgrade a
  new CLI may hit an old daemon → `protocolVersionMismatch` on the record call → best-effort warn,
  sync unaffected. An old CLI against a new daemon never sends the new command. The bump's only
  user-visible effect during skew is a one-line "restart the daemon to record provenance" warning.
- **Existing data:** untouched; new field defaults nil; existing entries gain `verifiedAt` only
  when a future sync verifies them.

## 10. Edge cases

- **Empty state:** a sync with zero verified-skip entries sends **no command at all** (not an
  empty batch) → no provenance change. `goh which` on an unrecorded file still says "(not
  recorded)".
- **tofu-change rejected:** when `tofuChange` rejects the drift (exit-3, keeps the OLD entry and
  the prior path), it contributes **no** `verifiedEntry` — recording the new on-disk bytes as
  "verified" would contradict the rejected state. Only the accepted branch emits.
- **External readers of `provenance.plist`:** `verifiedAt != nil && downloadedAt == verifiedAt`
  is the discriminant for "goh did not download these bytes, only confirmed them present." This
  is documented in `DESIGN.md` (§Persistence) so an external tool does not misread `downloadedAt`
  as a real fetch time.
- **Daemon down (M3):** all-present sync still exits 0; batch send fails best-effort with a warning.
- **Concurrent modification:** the verified batch and a download completion writing concurrently
  are serialized by the store Mutex; merge is per-entry and idempotent (re-sending the same entry
  re-stamps `verifiedAt`, never duplicates — AC3).
- **Path that exists in the ledger with a *different* sha256** (accepted tofu-change): merge falls
  to the else-branch → `downloadedAt = verifiedAt`, sha/size refreshed (the bytes goh recorded
  before are no longer the bytes on disk; honest).
- **Hash mismatch at verify time:** does not occur on the skip paths by construction (they are
  reached *because* the on-disk hash matched the pin / prior lock); a non-match falls through to
  the download path, which records via the engine as today.
- **Batch with one bad entry:** the daemon merges entry-by-entry; a malformed individual entry is
  skipped with a warning, the rest apply (recording is never all-or-nothing-fatal).
- **`verifiedAt` round-trip:** if synthesized `Codable` ever failed to keep the nil-optional
  byte-stable against the v1 fixture, that is an implementation defect to fix within v1 (e.g.
  explicit `encodeIfPresent`), not a reason to bump the format.
- **Very large manifest:** O(n) single rewrite via the batch; the per-file O(n²) path is
  explicitly avoided.
