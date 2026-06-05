---
date: 2026-06-04
feature: provenance-everywhere
type: design-spec
status: ready-for-spec-review
approach: A — The Native Ledger (B rejected; see Approach Decision Memos)
---

# Design Spec — Provenance-everywhere (verify-only)

A daemon-owned **native ledger** that auto-records `{url, sha256, size,
downloadedAt, destinationPath}` for **every** successful download — manifest
(`goh sync`), ad-hoc (`goh add` / foreground `goh <url>`), **and resume** — into
a versioned binary-plist store, then answers "where did this come from?"
(`goh which`) and "is this still what I downloaded?" (`goh verify --all`)
offline, against the user's own frozen record. **Verify-only**: goh *tells* you
when a file drifted or vanished; it does not restore it.

The chosen approach is **A — The Native Ledger**: a fourth daemon store that is
a carbon copy of `HostProfileStore`/`CatalogStore`/`CheckpointStore`. Approach B
(promote `gohfile.lock`'s TOML to a global auto-lock) was rejected — it forfeits
an independent version field by inheriting the frozen `lockfileVersion = 1`,
welds a machine-local record to a portable frozen contract, and pays a heavier
hot-path TOML cost. See `2026-06-04-provenance-everywhere-approaches.md`.

---

## 1. Problem

goh already computes the SHA-256 of every file **during completion**
(`ChunkAssembler.hashToCompletion() -> .digest(String)`, lowercase hex — a disk
read-back hash of the assembled file, equal to `shasum -a 256`, **not** a
network-tap hash) — and then **throws it away** at all three completion sites in
`DownloadEngine`
(`fetchSingle`, `fetchRanged`, and the resume path's `verifyHash`). As a result:

- `goh which <file>` on an **ad-hoc** download (one never declared in a
  manifest) falls through to the Spotlight xattr fallback and prints
  `sha256: (not recorded)` — goh cannot tell the user the hash of a file it
  itself just hashed.
- There is **no offline source-of-truth** for everything the user has pulled.
  `goh verify` only knows about files declared in a `gohfile.lock`. A user with
  a directory of ad-hoc downloads has no way to ask goh, offline, "are these
  still byte-for-byte what I downloaded, and where did each come from?"

The user problem is an **offline, self-owned record of provenance for
everything goh has pulled** — usable with the network disabled and with the
daemon not running. It is *not* a build artifact or a developer convenience: it
is the answer to "did this file change since I got it, and where did it come
from," for any file goh downloaded, without trusting anything but the user's own
prior record.

---

## 2. Success metrics

Each metric ties to an acceptance criterion (AC1–AC5 from
`2026-06-04-provenance-everywhere-acceptance-criteria.md`) with a specific
observable signal. "Done" means every row below holds in CI.

| # | Metric (measurable done) | AC | Observable signal / number |
|---|---|---|---|
| M1 | Every successful download writes exactly one entry for its destination, carrying **the digest computed during completion** (the existing `hashToCompletion()` disk read-back hash, not a second post-hoc re-hash). | AC1 | After a download, `provenance.plist` decodes to a `ProvenanceRecord` whose `entries` contains **exactly one** entry keyed to the destination path, whose `sha256` equals an independent `shasum -a 256` of the file **and** equals the digest the engine computed during completion. Asserted by test with a captured digest. |
| M2 | `goh which <ad-hoc-file>` prints a concrete `sha256:<hex>` from the ledger, performing **zero** network access. | AC2 | `goh which` on an ad-hoc file emits a `sha256:` line sourced from the record (not `(not recorded)`), with the network disabled. Asserted by test. |
| M3 | `goh verify --all` re-hashes each recorded file offline against the record's **own** stored hash → OK/FAILED/MISSING with a deterministic exit code distinguishing FAILED (2) from MISSING (9). | AC3 | For a set of recorded files with one byte-mutated and one deleted: OK for intact, FAILED for mutated (exit 2), MISSING for deleted (exit 9), network disabled. Asserted by test. |
| M4 | **Zero frozen-contract diff.** Every pre-existing golden fixture is byte-identical; the new store has its **own** `currentVersion = 1` and a passing golden round-trip; `-warnings-as-errors` clean. | AC4 | (a) Every existing golden fixture file is unchanged (diffed in CI). (b) New `provenance.plist` golden round-trip test passes. (c) `swift build -Xswiftc -warnings-as-errors` and `swift test` both green. (d) **Test count goes up, never down** — no existing test removed or weakened (grep diff shows only additions to test targets). |
| M5 | Re-download of the same destination yields **one** entry (latest hash/date); a deliberately corrupted store re-initializes to empty and the next download still succeeds. | AC5 | Two downloads to the same destination → exactly one entry, latest hash. A corrupted `provenance.plist` → next download succeeds, in-memory store reset to empty, corrupt file **copied to** a `provenance.plist.corrupt-<unixtime>` sidecar; the corrupt original remains in place until the next `record()` overwrites it via atomic rename. Asserted by test. |

The three headline signals AC4 demands explicitly: **test-count-stays-green**
(M4d), **golden-fixture round-trip** (M4b), **zero-frozen-contract-diff** (M4a).

---

## 3. Out of scope (v1 exclusions + why)

| Excluded | Why |
|---|---|
| **Content-addressed byte storage / restore.** | Verify-only by user decision. goh reports drift/absence; it does not keep copies to restore from. Restore is a different product (a cache/CAS), with its own storage-budget and GC design. |
| **Back-fill of pre-feature downloads.** | The ledger accrues from upgrade forward. Retroactively recording older files would require re-hashing arbitrary on-disk files with no trustworthy source URL — there is no record to back-fill *from*. `goh which` on an older ad-hoc file keeps the xattr fallback (a boundary, not a defect). |
| **Auto-pruning / TTL.** | Size is bounded by *download count* (~200 B/entry → <100 MB at hundreds of thousands), not file size. Deleting an entry only "forgets provenance" (no data loss). An explicit housekeeping verb can come later; v1 ships none. Note this differs from `HostProfileStore`, which **does** TTL-evict at load (90 days) — provenance deliberately does **not**, because a forgotten host-profile arm is harmless but a forgotten provenance entry is a silent loss of the user's record. **Implementation requirement (ADVISORY E):** because `ProvenanceStore` is a carbon copy of the `HostProfileStore` idiom, the deliberate omission of the 90-day TTL eviction **must be called out in a comment in `ProvenanceStore.load()`** (e.g. "intentionally NO TTL eviction — unlike HostProfileStore; evicting would silently lose the user's record"), so a future maintainer copying the idiom does not re-introduce eviction and silently forget records. |
| **Path-keyed only (moved-file staleness accepted).** | Entries are keyed by destination path. Moving a recorded file makes `goh which <newpath>` miss and `goh verify --all` report the old path MISSING — the correct "it moved/vanished" answer for a verify-only tool. Content-key cross-reference is a future enhancement. |
| **No new XPC command.** | The CLI reads `provenance.plist` directly (read-only, 0600, same-user). Avoids adding frozen wire surface and makes the read paths work with the daemon down (design-validation fix 3). |
| **No new `JobSummary` field.** | `JobSummary` is a frozen wire type; a `sha256` field forces `protocolVersion 3→4` and touches every completed-state test. The digest is carried through the **daemon-internal** `completedDownloadHandler` instead (design-validation fix 2, and the approach memos' fixed decision). |

---

## 4. Frozen invariants (these gate review)

**Unchanged, must show zero diff:**

- `protocolVersion = 3` (`Sources/GohCore/IPC/Envelope.swift` / `CommandService.swift`).
- `JobCatalog.currentVersion = 1`; `JobSummary` wire shape (no new field).
- `gohfile.lock` `lockfileVersion = 1` (`LockfileCodec`).
- `DownloadCheckpoint` v1; `HostScheduling` v1.
- `GohEnvelope` keys.

**New frozen on-disk format (four-round discipline applies):**

- `provenance.plist` carries its **own** `ProvenanceRecord.currentVersion = 1`,
  independent of every contract above. It is a new persistent format an external
  tool might read (`plutil -p provenance.plist`), so per CLAUDE.md §"Four-round
  design discipline" it is a frozen contract: it gets a **golden round-trip
  fixture** (§7) and a *Considered alternatives* note (§7.4).

**The three mandatory design-validation fixes** (from
`2026-06-04-provenance-everywhere-design-validation.md`, non-negotiable):

1. **Best-effort / non-fatal recording.** The daemon's
   `completedDownloadHandler` wraps `provenanceStore.record(entry:)` in
   `do/catch`, logs on failure via `warn()`, and **never propagates** — exactly
   the existing `SpotlightMetadataTagger` best-effort contract one line above it.
   A transient store error (disk full, unwritable Application Support, corrupt
   store) must **never** fail an otherwise-successful download.
2. **Resume-path completions record too.** The digest is threaded through all
   **three** completion paths including resume. `verifyHash` is changed from
   `-> Void` (digest discarded) to **return the digest**, which the resume path
   then passes to `complete(...)`.
3. **Direct CLI read, no XPC.** `goh which` and `goh verify --all` read
   `provenance.plist` directly (read-only, 0600, same-user). No XPC command, no
   `protocolVersion` change; both work with the daemon down.

---

## 5. Mechanism

### 5.1 Digest capture (engine → handler)

`ChunkAssembler.hashToCompletion()` already yields `.digest(String)` (lowercase
hex, no `sha256:` prefix) — a disk read-back hash of the assembled file, equal to
`shasum -a 256`, not a network-tap hash. Today it is awaited and discarded at
three sites. The change threads it through:

- **`fetchSingle`** (`DownloadEngine.swift` ~L526) and **`fetchRanged`**
  (~L849): `assembled` is an **`async let`** awaited **exactly once**, currently
  via `if case .failed(...) = await assembled { … }` with the success path
  falling through (there is **no** `_` binding to "replace"). It must stay a
  single `await` — re-awaiting an `async let` after the failure check is wrong.
  Restructure to bind the value once and handle both arms:

  `ChunkAssemblerResult` has **exactly two** cases —
  `.digest(String)` and `.failed(GohError)` (`ChunkAssembler.swift` L36–38) —
  so the `else` arm of a `guard case .digest` is **unambiguously `.failed`**.
  Bind the value once, then handle both arms; the `.failed` arm `throw`s, which
  is what makes the construct exhaustive:

  ```swift
  // BEFORE: if case .failed(let err) = await assembled { throw err }  // success falls through
  // AFTER — one await, both arms handled, extract the digest on success:
  let outcome = await assembled                       // the ONE await
  guard case .digest(let hex) = outcome else {
      guard case .failed(let err) = outcome else {
          fatalError("unreachable: ChunkAssemblerResult has only .digest/.failed")
      }
      throw err                                       // the throw makes the guard exhaustive
  }
  // `hex` is the lowercase-hex digest; pass it to complete(..., sha256: hex, …)
  ```

  (The inner `guard … else { fatalError(...) }` is only the compiler-satisfying
  terminator for the impossible third case; the real work is the `throw err`. If
  the compiler accepts `if case .failed(let err) = outcome { throw err }` followed
  by a trailing `fatalError("unreachable")` as exhaustive, that form is equally
  acceptable — the requirement is one `await` and a `-warnings-as-errors`-clean,
  exhaustive handling of both arms.)

  **Do not** keep the old `if case .failed = await assembled` AND add a second
  `await assembled` to read the digest — that double-awaits the `async let`
  (ADVISORY B). `outcome` binds the single `await assembled`; both arms read
  `outcome`, never re-await. This success-path restructure replaces **only** the
  existing success-path `if case .failed = await assembled` checks
  (`DownloadEngine.swift` L454, L518, L840). The **catch-/cancellation-path
  `_ = await assembled` drains** (L512, L834) are a different concern — they exist
  to await the spawned `async let` on the error path and are **unchanged** by this
  feature.
- **Resume path** (~L379): `verifyHash(file:total:)` currently returns `Void` and
  drops the digest. Change its signature to
  `verifyHash(file:total:) async throws -> String` returning the lowercase-hex
  digest; the resume completion captures it and passes it to `complete(...)`.
  Inside `verifyHash`, apply the **same single-await guard** over the two-case
  `ChunkAssemblerResult` — `guard case .digest(let hex) = await assembled else { … throw the .failed error … }; return hex` — so the function awaits the
  assembler **exactly once** and returns the hex on success while throwing the
  `.failed` error, staying `-warnings-as-errors`-clean.

`DownloadEngine.complete(...)` gains a `sha256: String?` parameter:

```swift
private func complete(
    jobID: UInt64, in store: JobStore,
    transferDuration: Duration, isResume: Bool,
    sha256: String?,                          // NEW — lowercase hex, no prefix; nil if unavailable
    governorOutcome: GovernorOutcome = .governorOff
) throws {
    let completed = try store.complete(id: jobID)
    completedDownloadHandler?(completed, transferDuration, isResume, sha256, governorOutcome)
}
```

`completedDownloadHandler` widens by one argument (daemon-internal closure type,
**not** on any wire):

```swift
// before: (@Sendable (JobSummary, Duration, Bool, GovernorOutcome) -> Void)?
// after:  (@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome) -> Void)?
```

**Blast radius (enumerated in design-validation):** one production closure
(`Sources/gohd/main.swift` L144–175) gains a 5th param; four test closures in
`DownloadEngineTests.swift` (L74, L107, L1110, L1129) each add a wildcard `_`.
No other file assigns the handler. No wire type, no `JobSummary`, no on-disk
format consumes this signature.

`sha256` is `String?` (not `String`) so a future path that completes without a
streamed digest degrades to "no entry recorded" rather than forcing a fabricated
hash. When `nil`, the handler **skips** the provenance write (no entry with a
missing/placeholder hash is ever written).

### 5.2 The ledger write (handler → store)

In `gohd/main.swift`, alongside the existing best-effort Spotlight block, add a
best-effort provenance block:

```swift
if let sha256 {                                       // skip when no streamed digest
    do {
        try provenanceStore.record(
            ProvenanceEntry(
                url: completed.url,
                sha256: "sha256:" + sha256,           // stored WITH prefix — see §6.2
                size: Int(completed.progress.bytesCompleted),
                downloadedAt: completed.completedAt ?? Date(),
                // canonical absolute path — THE one canonicalization (§5.3, BLOCK-1)
                destinationPath: URL(fileURLWithPath: completed.destination)
                    .standardizedFileURL.path))
    } catch {
        warn("job \(completed.id) completed but provenance recording failed: \(error)")
    }
}
```

`ProvenanceStore` is constructed next to the other stores in `main.swift`, with
the file URL from the **shared resolver** (§5.5) so the writer and the CLI
readers cannot point at different files:

```swift
let provenanceStore = ProvenanceStore(
    fileURL: try ProvenanceStoreLocation.defaultURL(create: true))   // daemon: creates the dev.goh.daemon subdir (§5.5)
let provenanceLoad = provenanceStore.load()
if let sidecar = provenanceLoad.corruptionSidecar {
    warn("the provenance ledger was unreadable and has been reset; "
        + "the damaged file was kept at \(sidecar.path)")
}
```

`record(entry:)` updates **in place by `destinationPath`** (replace the matching
entry, else append) and performs a full atomic rewrite — byte-for-byte the
`HostProfileStore.writeAtomically` idiom: `.tmp-<UUID>` → `chmod 0600` →
`fsync(tmp)` → `rename(2)` → `fsync(dir)`. The store is a `final class: Sendable`
over `Mutex<Inner>`; the daemon is the **sole writer**, so concurrent completions
serialize through the mutex.

### 5.3 `goh which` — new ledger branch

`GohWhichCommand.run` gains a branch between the lock lookup and the xattr
fallback (the xattr fallback is the source of `sha256: (not recorded)`):

1. `gohfile.lock` lookup (unchanged).
2. **NEW: provenance-ledger lookup** — only when `provenanceStorePath != nil`
   (a `nil` argument, the parameter's default, skips this branch entirely and
   preserves today's lock→xattr→exit-4 path). Read `provenance.plist`
   (read-only), find the entry whose **canonical `destinationPath` string**
   equals the **canonicalized target path** (see canonicalization rule below),
   print `url:` / `sha256:` / `downloadedAt:`. Returns exit 0.
3. xattr fallback (unchanged).
4. exit 4 (unchanged).

**Canonicalization rule (one rule, applied identically at write and read —
BLOCK-1).** There is exactly **one** path-canonicalization in this feature, and
both the writer and every reader apply it byte-for-byte the same way:

```swift
// THE canonical form. Same call at write site and every read site.
URL(fileURLWithPath: rawPath).standardizedFileURL.path   // -> canonical absolute path String
```

- **Write (daemon).** Before `record(entry:)`, the daemon stores
  `destinationPath = URL(fileURLWithPath: completed.destination).standardizedFileURL.path`.
  The on-disk key is therefore always a canonical absolute path string.
- **Read (`goh which`).** `GohWhichCommand` already standardizes its target via
  `URL(fileURLWithPath: filePath).standardizedFileURL` (current code, L19). The
  ledger branch reuses that same standardized URL's `.path` and compares it
  **string-equal** to each entry's stored `destinationPath`. It does **not**
  compare `URL` values and does **not** re-normalize — `destinationPath` is
  already canonical on disk, so the only operation is canonicalize-the-argument
  then string-compare.
- **Read (`goh verify --all`).** Each entry's `destinationPath` is already the
  canonical key; the file is opened directly at that path. No second
  canonicalization is applied to a stored entry.

This is a **path-string** comparison, not a URL comparison: identical input
strings that differ only by `..` segments, a trailing `/`, or a relative prefix
collapse to one canonical string on both sides, so a write of
`/Users/u/Downloads/a.bin` matches a `which` argument of
`Downloads/../Downloads/a.bin` (given the same cwd) or any `..`-laden path that
canonicalizes to the same absolute path.

**Symlinks are NOT resolved (lexical canonicalization, by design — ADVISORY A2).**
`standardizedFileURL.path` is a **purely lexical** normalization: it collapses
`..`/`.`/trailing-slash but does **not** resolve symlinks (it is not
`resolvingSymlinksInPath()`/realpath). So two symlink-divergent paths to the same
underlying file — e.g. `/var/...` vs `/private/var/...` (a system symlink), or a
user-created symlink, relevant when a sync-downloaded destination was stored in
realpath-resolved form — canonicalize to **different** strings and therefore do
**not** match. This is intentional: write-side and read-side apply the identical
lexical transform, so the comparison is write/read-consistent. It is distinct
from the moved-file row in §8 (there the bytes moved; here the same bytes are
reached by a different symlink spelling, and a lexical-only canonicalization
deliberately treats it as a miss).

`ProvenanceStore.lookup(destinationPath:)` performs this canonicalization on its
argument **internally** (ADVISORY C), so neither `GohWhichCommand` nor any other
caller re-implements it — callers pass the user-supplied path and the store
canonicalizes once, compares string-equal to the (already-canonical) stored
keys, and returns the match.

The CLI resolves the store **path** via the shared `ProvenanceStoreLocation`
resolver (defined in §5.5), but **read-only** and tolerant:
missing/unreadable/corrupt store → fall through silently to the next source
(exactly how `lookupInLock` tolerates a missing lock). The same resolver is used
by `verify --all` and **mirrored by the daemon's writer**, so writer dir and
reader dir cannot diverge.

### 5.4 `goh verify --all` — new offline verify surface

New flag on the existing `verify` verb, parsed to a **distinct** case
(`.verifyAll`) dispatched to a **separate** runner
(`GohVerifyAllCommand.run(provenanceStorePath:)`) — the frozen
`GohVerifyCommand.run(lockPath:strictUntracked:)` is untouched (§7.1, BLOCK-2;
see §7.1 for the verb/flag decision). With `--all` it ignores `gohfile.lock`
entirely and instead:

1. Reads `provenance.plist` read-only. Missing/empty → exit 0, "0 recorded
   entries". Corrupt → exit 6 (mirrors `goh verify`'s "lock bad" class; the CLI
   does **not** copy-to-sidecar or reset the daemon's store — see §7.2 and §8).
2. For each entry, re-hash `destinationPath` via **`FileDigest.sha256WithSize`**
   (the project's hardened at-rest read) and compare to the entry's stored
   `sha256`:
   - hash matches → `OK <path>`
   - file present, hash differs → `FAILED <path> expected … actual …` (sets the
     FAILED flag)
   - `FileDigest.DigestError.cannotOpen` (or any read error) → `MISSING <path>`
     (sets the MISSING flag)
3. Exit code by precedence **9 > 2 > 0** (§7.2).

Network is never touched on this path (no daemon, no URLSession): true offline
verify.

### 5.5 `ProvenanceStoreLocation` — the shared store-path resolver (BLOCK-3)

The store path is resolved by **one** type that lives in **`GohCore`** so it is
reachable by both CLI commands (`goh which`, `goh verify --all`) and the daemon's
writer. This is the single anti-divergence point: writer and readers cannot point
at different files because they call the same resolver.

```swift
// Sources/GohCore/Provenance/ProvenanceStoreLocation.swift
public enum ProvenanceStoreLocation {
    /// `~/Library/Application Support/dev.goh.daemon/provenance.plist`.
    /// Resolves the support directory via the SAME mach-service-name basis the
    /// daemon uses in supportDirectoryURL(). Throws if Application Support is
    /// unavailable (CLI read paths treat a throw as "no store" and fall through).
    ///
    /// `create` controls whether the `dev.goh.daemon` subdirectory is created:
    /// the DAEMON passes `create: true` (so first-run persistence works); the
    /// CLI READ paths (`which`, `verify --all`) pass `create: false` so a
    /// read-only lookup never creates `~/Library/Application Support` (or the
    /// subdir) as a side effect — a missing dir/file is simply "no store"
    /// (ADVISORY A3).
    public static func defaultURL(create: Bool) throws -> URL {
        try supportDirectoryURL(create: create).appending(path: "provenance.plist")
    }

    /// The support directory `~/Library/Application Support/<machServiceName>`.
    /// Factored out of gohd/main.swift so daemon and CLI share ONE definition.
    /// When `create` is true, the `<machServiceName>` subdirectory is created
    /// with `withIntermediateDirectories: true` — exactly the daemon's
    /// pre-existing behaviour (gohd/main.swift L17–25, which called
    /// `createDirectory(at: directory, …)`). When false, no directory is created.
    static func supportDirectoryURL(create: Bool) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: create)
        let directory = support.appending(
            path: GohXPCService.machServiceName, directoryHint: .isDirectory)
        if create {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
```

**Factoring requirement (so they cannot diverge), and the directory-creation
HARD requirement.** The daemon's `supportDirectoryURL()` in `gohd/main.swift`
(L17–25) currently inlines the `.applicationSupportDirectory` +
`GohXPCService.machServiceName` join **and explicitly calls
`createDirectory(at: directory, withIntermediateDirectories: true)` to create
the `dev.goh.daemon` subdir**. That creation is **load-bearing**:
`CatalogStore`/`HostProfileStore`/`CheckpointStore` do **not** self-create their
parent, so on a clean install with an empty `~/Library/Application Support` the
subdir must already exist before any catalog/checkpoint/host-scheduling write.

This logic moves into `ProvenanceStoreLocation.supportDirectoryURL(create:)` in
`GohCore`. The directory-creation semantics are **MANDATORY, not optional**: the
shared resolver's `create: true` branch creates the `dev.goh.daemon`
subdirectory **exactly as the daemon does today** (with
`withIntermediateDirectories: true`). The **daemon owns creation** — it calls
the shared resolver with `create: true` (or keeps a thin `supportDirectoryURL()`
wrapper that forwards with `create: true`); dropping this creation would be a
clean-install regression. The construction in §5.2 becomes
`ProvenanceStore(fileURL: try ProvenanceStoreLocation.defaultURL(create: true))`
on the daemon side — the writer and both readers now derive the path from the
identical code, so a mismatch between writer dir and reader dir is structurally
impossible.

**CLI read paths must NOT create directories.** `goh which` and `goh verify
--all` are read-only and call `ProvenanceStoreLocation.defaultURL(create: false)`
(ADVISORY A3): a missing store file or directory is treated as "no entries / not
recorded" (silent fall-through for `which`; "0 recorded entries", exit 0 for
`verify --all`). A read-only lookup must never create
`~/Library/Application Support` or the `dev.goh.daemon` subdir as a side effect.

`GohXPCService.machServiceName == "dev.goh.daemon"`
(`Sources/GohCore/IPC/XPCService.swift` L18), so the resolved file is
`~/Library/Application Support/dev.goh.daemon/provenance.plist`.

**Call-site updates in `GohCommandLine`.** The `which` and `verify --all` parse
arms (§7.1) obtain the resolved path from `ProvenanceStoreLocation` and pass it
into the runners:

- `GohWhichCommand.run` gains a **defaulted** `provenanceStorePath: String? = nil`
  parameter (in addition to the existing `filePath:` / `lockPath:`). The default
  is load-bearing: a `nil` value means **skip the ledger lookup entirely**,
  preserving today's exact lock→xattr→exit-4 behavior, so the **8 existing
  `GohWhichCommandTests` call sites that pass only `filePath:`/`lockPath:` keep
  compiling and behaving unchanged** (no test edit, BLOCK-A). The real CLI call
  site — the `case .which` arm in `GohCommandLine.run()` — resolves
  `try? ProvenanceStoreLocation.defaultURL(create: false).path` and passes it
  explicitly (read-only: a `nil`/throw, or a missing dir/file, resolves to "no
  store" → silent fall-through; never creates the dir). New ledger behavior
  is covered by NEW tests (T6/T6b) that pass `provenanceStorePath:` explicitly.
- `GohVerifyAllCommand.run(provenanceStorePath:)` (§7.1, BLOCK-2) likewise takes
  the resolved path.

Both call sites resolve through the **same** `ProvenanceStoreLocation`, so
`which` and `verify --all` always read the file the daemon wrote.

---

## 6. Frozen format definition

### 6.1 Codable shape

```swift
/// Versioned root of the provenance ledger. Frozen on-disk format
/// (provenance.plist). currentVersion is INDEPENDENT of every other contract.
public struct ProvenanceRecord: Codable, Sendable, Equatable {
    /// The frozen format version. Bumped only via a four-round design pass.
    public static let currentVersion = 1
    public var version: Int
    public var entries: [ProvenanceEntry]
    public static let empty = ProvenanceRecord(version: currentVersion, entries: [])
}

/// One recorded download, keyed (logically) by destinationPath.
public struct ProvenanceEntry: Codable, Sendable, Equatable {
    public var url: String            // source URL as the job recorded it
    public var sha256: String         // "sha256:<lowercase-hex>" — prefixed (see §6.2)
    public var size: Int              // byte size of the completed file
    public var downloadedAt: Date     // completion time
    public var destinationPath: String // absolute destination path; the in-place key
}
```

### 6.2 Field semantics

- **`url`** — the source URL string exactly as the completed `JobSummary.url`
  carries it. May contain query-string credentials (see §9 PII).
- **`sha256`** — stored **with** the `"sha256:"` prefix, matching
  `FileDigest.sha256WithSize` output and `LockEntry.sha256`. The engine streams
  the bare hex, so the handler prepends the prefix once at the write site (§5.2).
  Storing the prefixed form means `verify --all` can compare directly against
  `FileDigest`'s prefixed return with no normalization, and `goh which` prints
  the same `sha256:<hex>` shape as the lock branch — one canonical form on disk
  and on screen.
- **`size`** — byte count of the completed file. May be `0` for a legitimately
  empty download (`Content-Length: 0`); recorded as-is.
- **`downloadedAt`** — `completed.completedAt ?? Date()`. Encoded by
  `PropertyListEncoder` in its default `Date` representation (binary plist real
  seconds-since-2001), identical to how the other daemon stores persist `Date`.
- **`destinationPath`** — the **canonical absolute path string**, the logical
  key. Stored as `URL(fileURLWithPath: completed.destination).standardizedFileURL.path`
  — THE single canonicalization (§5.3, BLOCK-1) — so the on-disk key is always a
  canonical absolute path with `..`/trailing-slash collapsed. `record(entry:)`
  replaces an existing entry with the same canonical `destinationPath` (string
  equality), else appends. Readers (`goh which`, `goh verify --all`) canonicalize
  the user-supplied path the **same** way before string-comparing; no reader
  re-normalizes a stored key (it is already canonical).

### 6.3 Binary-plist encoding

`PropertyListEncoder` with `outputFormat = .binary`, decoded by
`PropertyListDecoder` — identical to `HostScheduling`/`JobCatalog`. On `load()`:

- File absent → `ProvenanceRecord.empty`, no sidecar.
- Decode succeeds but `version != currentVersion` → **copy** the corrupt file to a
  `provenance.plist.corrupt-<unixtime>` sidecar, reset the in-memory state to
  `.empty`. The corrupt original is **left in place** (it remains until the next
  `record()` overwrites it via atomic rename).
- Decode throws → same copy-to-sidecar + in-memory reset; original left in place.

This is the verified `HostProfileStore` recovery path (L107–126, L309–319),
copied **faithfully** — `recoverToEmpty()` uses `copyItem` and **leaves the
original on disk** (it does not move/delete it); the next atomic `record()`
write is what eventually overwrites the corrupt original. The write is
`writeAtomically` (L321–343), copied: temp → `chmod 0600` → `fsync(temp)` →
`rename(2)` → `fsync(dir)`.

### 6.4 Considered alternatives (four-round discipline)

- **vs Approach B — promote `gohfile.lock` TOML to a global auto-lock.**
  Rejected. Reusing `LockEntry`/`LockfileCodec` saves reader code but forfeits
  an **independent version field**: the global file would inherit the frozen
  `lockfileVersion = 1`, so any future provenance-only field forces a
  lockfile-version bump that ripples into the *portable, committed* lock, or a
  fork that defeats the reuse. It also welds a machine-local daemon record to a
  portable user-committed contract (a "looks committable but must not be"
  foot-gun) and pays a TOML parse+serialize on the hot completion path. AC4
  demands the record carry its **own** version field, which B structurally
  cannot. (Full matrix: approaches memo.)
- **vs SQLite-WAL.** Rejected. Its only advantage is scaling headroom to
  millions of rows (Nix/Chrome). The brief shows that headroom is unneeded at
  goh's personal volumes (thousands–tens-of-thousands). A new `libsqlite3` FFI
  surface for unneeded scale fails CLAUDE.md's "Apple-frameworks-first; a
  third-party dependency needs explicit justification" on its face.
- **vs append-only log + compaction.** Rejected for v1 as YAGNI: O(1) appends
  solve a write-throughput problem goh does not have, and compaction +
  log-fold reader is net-new machinery with no on-disk idiom. It remains the
  documented **escape hatch** behind the same `record`/`verifyAll` surface if
  the personal-scale bet on O(n) rewrites ever fails — a one-file
  re-implementation, no external contract to migrate.
- **`sha256` prefixed vs bare hex on disk.** Chose prefixed (`"sha256:<hex>"`)
  to match `FileDigest` output and `LockEntry`, giving one canonical form across
  store, lock, and screen. Bare hex would force normalization at every compare
  and diverge from the lock's display.

### 6.5 Golden fixture (what the round-trip test asserts)

A checked-in golden `provenance.plist` fixture with a small, fixed set of
entries (e.g. two: one normal, one zero-size empty download). The round-trip
test asserts:

1. **Decode** of the committed fixture yields the exact expected
   `ProvenanceRecord` (version `1`, entries equal field-by-field, including the
   `sha256:` prefix and the `Date` values).
2. **Re-encode** of that decoded value is **byte-identical** to the committed
   fixture (binary-plist determinism — same key order, same `Date` encoding).
3. **`version == ProvenanceRecord.currentVersion`** so a future bump fails the
   test loudly.

If binary-plist re-encode is not bit-stable across SDKs for this shape, the test
asserts decode→re-encode→decode round-trip equality of the **decoded value**
(not raw bytes) and keeps the committed fixture as the decode anchor — same
fallback the existing store golden tests use. (Verify against the existing
catalog/host-scheduling golden tests when implementing.)

---

## 7. The verify-everything CLI surface

### 7.1 Verb and flag — `goh verify --all`

Chosen: **`goh verify --all`**.

- **vs a bare `goh verify` with no lock present** — rejected. `goh verify`'s
  contract is "verify the `gohfile.lock` in this directory"; overloading the
  bare verb to silently mean "verify the global ledger" when no lock is found
  would make one command do two unrelated things depending on cwd state, and
  would change the frozen exit-code surface of the existing verb. An explicit
  `--all` is unambiguous and leaves the lock path's contract untouched.
- **vs a brand-new verb (`goh audit`, `goh ledger`)** — rejected as needless
  vocabulary growth. The mental model — "re-hash recorded files, report
  OK/FAILED/MISSING" — is *exactly* `goh verify`'s model, just sourced from the
  ledger instead of the lock. A flag keeps it discoverable under the verb users
  already reach for.

`--all` and the existing lock-path flags are mutually exclusive: `--all` does not
read `gohfile.lock`, and combining it with `--strict-untracked` or a positional
lockfile path is a **parse error** (untracked enumeration and a lock path are
lock-directory concepts with no analogue for a path-keyed global ledger — see the
parse algorithm below).

**Parse + dispatch wiring (BLOCK-2 — the frozen `verify` shape is untouched).**
The existing parse case and runner stay **byte-for-byte unchanged**:

```swift
case verify(lockPath: String, strictUntracked: Bool)        // FROZEN — do not mutate
GohVerifyCommand.run(lockPath:strictUntracked:)             // FROZEN exit-code surface
```

`--all` is parsed into a **distinct** variant with a **separate** runner that
takes **no `lockPath`**:

- New enum case: `case verifyAll(provenanceStorePath: String)`.
- New runner: `GohVerifyAllCommand.run(provenanceStorePath:) -> GohCommandLineResult`
  (a sibling of `GohVerifyCommand`, **not** a new parameter on the frozen
  `GohVerifyCommand.run`).

Parse algorithm for `verify`:

1. If `--all` is present in the `verify` arguments, the parser emits
   `.verifyAll(provenanceStorePath:)` — resolving the path via
   `ProvenanceStoreLocation.defaultURL(create: false).path` (§5.5, read-only —
   never creates the dir). When `--all` is present
   the parser does **NOT** synthesize `lockPath = cwd` (no lock is read on this
   path), and `--strict-untracked` + a positional lockfile path are rejected as
   `unknown verify option`/incompatible-with-`--all` (untracked enumeration and a
   lock path have no meaning for the global ledger).
2. If `--all` is absent, parsing is **unchanged**: the existing loop synthesizes
   `lockPath = cwd/gohfile.lock`, honours `--strict-untracked` and an optional
   positional path, and emits the frozen `.verify(lockPath:strictUntracked:)`.

Dispatch in `GohCommandLine.run()`:

```swift
case .verify(let lockPath, let strictUntracked):                  // UNCHANGED
    return GohVerifyCommand.run(lockPath: lockPath, strictUntracked: strictUntracked)
case .verifyAll(let provenanceStorePath):                         // NEW, distinct runner
    return GohVerifyAllCommand.run(provenanceStorePath: provenanceStorePath)
```

`GohVerifyAllCommand` **mirrors but does not mutate** `GohVerifyCommand`'s exit
vocabulary. Its exit codes:

| Code | Meaning |
|---|---|
| 0 | All recorded entries OK (or zero/absent entries). |
| 2 | ≥1 hash **mismatch** (FAILED). |
| 9 | ≥1 recorded file **MISSING** on disk. |
| 6 | Ledger unreadable / unknown `version` (CLI does **not** copy-to-sidecar or reset — §8). |

**Precedence 9 > 2 > 0** (codes 7 and 10 do not apply — see §7.2). Because the
runner is separate, none of this touches `GohVerifyCommand`'s frozen exit-code
surface.

### 7.2 Exit-code mapping

Mirrors `GohVerifyCommand`'s frozen vocabulary (§9.4), using only the codes that
have meaning for the ledger:

| Code | Meaning | Source in `goh verify --all` |
|---|---|---|
| 0 | All recorded entries OK (or zero entries). | No FAILED, no MISSING. |
| 2 | At least one hash **mismatch** (FAILED). | File present, re-hash ≠ stored. |
| 9 | At least one recorded file **MISSING** on disk. | `FileDigest` cannot open. |
| 6 | Ledger unreadable / unknown `version` (corrupt). | Decode fails or version mismatch on the CLI read. |

**Precedence: 9 > 2 > 0** (identical to `goh verify`: MISSING dominates FAILED).
Codes 7 (advisory-lock busy) and 10 (`--strict-untracked`) do **not** apply —
the ledger has no `flock` sidecar (atomic `rename(2)` gives a consistent
snapshot, §8) and no untracked-enumeration concept. Code 6 on the `--all` path
means "the ledger itself could not be read," parallel to `goh verify`'s "lock
bad" — but the CLI **does not copy a sidecar or reset** the daemon's store (the
daemon owns recovery; the CLI is read-only, §8).

### 7.3 Output vocabulary

`OK` / `FAILED` / `MISSING`, one line per entry, matching `GohVerifyCommand`:

```
OK /Users/u/Downloads/a.bin
FAILED /Users/u/Downloads/b.bin expected sha256:… actual sha256:…
MISSING /Users/u/Downloads/c.bin (expected sha256:…)
```

(No `untracked` line — that is lock-path-only.)

---

## 8. Edge cases

| Case | Behavior |
|---|---|
| **Empty store** | `load()` on absent file → `ProvenanceRecord.empty`. `goh which` falls through to xattr/exit-4. `goh verify --all` → exit 0, "0 recorded entries". |
| **Corrupt store (daemon side)** | `load()` decode failure or version mismatch → **copy** the corrupt file to a `provenance.plist.corrupt-<unixtime>` sidecar, reset the in-memory state to empty (the corrupt original is **left in place**), **next download still records** (the next atomic `record()` rewrite overwrites the corrupt original with the fresh store). Never blocks a download. |
| **Corrupt store (CLI read)** | `goh which`: silent fall-through to next source. `goh verify --all`: exit 6 ("ledger unreadable"). The CLI **never copies a sidecar and never resets** — recovery is the daemon's job; the CLI is read-only and must not race the daemon's atomic writer. |
| **Concurrent completions** | Daemon is the sole writer; `record(entry:)` calls serialize through `Mutex<Inner>`. Each call does a full snapshot rewrite, so two near-simultaneous completions produce two sequential atomic rewrites, both durable. |
| **CLI read during daemon rewrite** | The daemon writes via temp → `rename(2)`. A concurrent CLI `Data(contentsOf:)` reads either the old or the new complete inode — never a torn write. Consistent snapshot guaranteed by `rename(2)` atomicity. |
| **Daemon-down read** | `goh which` / `goh verify --all` read the file directly; no daemon, no XPC. Both work with the daemon stopped (design-validation fix 3). |
| **Re-download same destination** | `record` replaces the entry whose `destinationPath` matches → **one** entry, latest hash/date. No duplicate growth (AC5). |
| **File moved after record** | Path-keyed on the **canonical** `destinationPath` string (§5.3, BLOCK-1). A `goh which <newpath>` argument canonicalizes (`URL(fileURLWithPath:).standardizedFileURL.path`) to a different string than the stored old-path key, so it misses and falls through; `goh verify --all` reports the **old** path MISSING — correct "it moved/vanished" for a verify-only tool (accepted boundary). A `which` argument that canonicalizes to the *same* stored path (e.g. a `..`-laden or relative form of the original) still **matches**. |
| **Symlink-divergent path to the same file** | `standardizedFileURL.path` is **lexical only** — it does **not** resolve symlinks (ADVISORY A2). A `which` argument reaching the recorded file by a different symlink spelling (e.g. `/var/…` vs `/private/var/…`, or a user symlink) canonicalizes to a **different** string than the stored key, so it does **not** match — by design (write/read-consistent lexical canonicalization). Distinct from the moved-file row: same bytes, different spelling. |
| **Unknown size / empty file** | `Content-Length: -1` (unknown) still completes; `size` recorded from `bytesCompleted`. `Content-Length: 0` (real empty body) → `size: 0`, hash of empty file recorded normally. Both are valid entries. |
| **Failed download** | `complete(...)` is only reached on success; failed/cancelled downloads never call the handler, so **nothing is recorded**. Only successful downloads enter the ledger (AC1). |
| **`record` throws (disk full / unwritable Application Support)** | Caught in the handler's `do/catch`, logged via `warn()`, **never propagated** — the download still reports success (design-validation fix 1). |
| **Destination already covered by `gohfile.lock`** | Orthogonal. Both the lock entry and the ledger entry may exist for the same file; no conflict. `goh which` checks the lock first (its existing precedence); `goh verify` (lock) and `goh verify --all` (ledger) are independent surfaces. |

---

## 9. Security surface

**New attack surface: effectively none.**

- **No network.** `goh verify --all` re-hashes local files; no URLSession, no
  fetch. The recorded `sha256` is the **record's own** stored hash — never a
  daemon-provided or network-fetched value (AC3).
- **No new XPC.** The CLI reads `provenance.plist` directly; no new wire
  endpoint, so the remote/abuse surface is unchanged. The absence of a new
  endpoint is an **affirmative** reason for the direct-read design — no
  misconfigured-auth-on-a-new-endpoint risk (design-validation §"Simplest
  Attack").
- **0600, same-user.** `provenance.plist` is written `0600`, readable only by
  the owning user — identical to `catalog.plist`, `host-scheduling.plist`, and
  the checkpoint plists. No cross-user leak.

**PII classification of stored data.** Stored `url` strings **can contain
secrets in query strings** (e.g. presigned-URL tokens, `?token=…`), and
`destinationPath` can reveal directory structure. This is **not new exposure**:
the existing `catalog.plist` already stores the same URLs at the same `0600`
same-user permissions, and `gohfile.lock` stores URLs too. The ledger adds no
field more sensitive than what the catalog already persists, at the same
protection level. Documented here so a future maintainer does not treat the
ledger as safe-to-share: it is **machine-local and must never be committed or
exported** (unlike the portable `gohfile.lock`).

**Same-user attacker — out of scope (DESIGN §3.2).** An attacker who can rewrite
the `0600` store to point an entry at a sensitive file is already the **same
user**, who has many other options; this is outside goh's threat model.

**At-rest read hardening.** `goh verify --all` re-hashes via the project's
existing **`FileDigest.sha256WithSize`** (1 MiB streaming, the same hardened
at-rest path `goh verify` uses) and must not follow surprising symlinks beyond
what `goh verify` already accepts. It must not introduce a weaker or ad-hoc
hashing path.

---

## 10. Rollout

- **Additive, no migration.** No existing store, format, or wire contract
  changes. `provenance.plist` is net-new and orthogonal to everything frozen.
- **First-run creates an empty store.** On daemon upgrade, `load()` finds no
  file and starts from `ProvenanceRecord.empty`; the ledger accrues from upgrade
  forward. No user action.
- **Backward compatible both directions.** Because there is **no wire change**:
  an old CLI talks to a new daemon and vice-versa exactly as before. The new
  `goh which` ledger branch and `goh verify --all` flag are purely CLI-local
  additions that degrade gracefully if the store is absent.
- **Partial failure is safe.** Best-effort recording (fix 1) means a download
  that completes but fails to record is still a successful download; the ledger
  simply lacks that one entry. No half-written global state.
- **Rollback** = stop the new daemon, delete `provenance.plist` (+ any
  `.corrupt-*` sidecars), revert the daemon. Because the change is
  daemon-internal with its own version field and no external contract, rollback
  is a file deletion plus a code revert — nothing else reads or migrates the
  ledger.

---

## 11. Test plan (Swift Testing — not XCTest)

All tests run offline; the verify tests run with the network disabled (no
URLSession is on these paths, so "offline" is structural, asserted by the
absence of any session in the surface under test).

| # | Test | Asserts |
|---|---|---|
| T1 | **Golden round-trip** | Committed `provenance.plist` fixture decodes to the expected `ProvenanceRecord`; re-encode is byte-identical (or decoded-value-equal round-trip — §6.5); `version == currentVersion`. (M4b) |
| T2 | **Corrupt → sidecar copy** | A deliberately corrupted store file → after `load()`: a `provenance.plist.corrupt-<unixtime>` sidecar **copy exists**, the in-memory state is `.empty`, and a subsequent `record` still **succeeds** (the next atomic rewrite overwrites the corrupt original). Faithful to `HostProfileStore.recoverToEmpty()`, which `copyItem`s and leaves the original — **do NOT assert the original is gone**. (M5, AC5) |
| T3 | **In-place update / dedup** | Two `record` calls with the same `destinationPath` → exactly one entry, carrying the second call's hash/date. (M5, AC5) |
| T4 | **Best-effort non-fatal** | With a `ProvenanceStore` whose write is forced to throw (e.g. unwritable directory), the daemon completion handler logs and does **not** throw; the download path still reports success. (fix 1, AC5) |
| T5 | **Resume-path recording** | A resumed download (the `verifyHash`-returning path) records an entry with the digest computed during completion. (fix 2, AC1) |
| T6 | **`goh which` reads from ledger** | `goh which <ad-hoc-file>` with a populated ledger prints `sha256:<hex>` from the record (not `(not recorded)`), exit 0, no network. (M2, AC2) |
| T6b | **`which` canonical-path match (BLOCK-1)** | An entry stored under an absolute canonical `destinationPath` is matched when `goh which` is given a **relative / `..`-laden** CLI argument that canonicalizes (`URL(fileURLWithPath:).standardizedFileURL.path`) to that same path — confirming write-side and read-side apply the **identical** single canonicalization and compare path **strings**, not URLs. (§5.3) |
| T7 | **`goh verify --all` OK / FAILED / MISSING** | Recorded set with one intact, one byte-mutated, one deleted → OK / FAILED (exit 2) / MISSING (exit 9); precedence 9>2; network disabled. (M3, AC3) |
| T7b | **`verify --all` parse + frozen-`verify` isolation (BLOCK-2)** | `verify --all` parses to `.verifyAll(provenanceStorePath:)` and dispatches to `GohVerifyAllCommand.run` (no `lockPath` synthesized); `verify` without `--all` is byte-for-byte the frozen `.verify(lockPath:strictUntracked:)` → `GohVerifyCommand.run` path; `verify --all --strict-untracked` and `verify --all <path>` are **parse errors** (exit 64). `GohVerifyCommand` source is unmodified. (§7.1) |
| T8 | **`verify --all` empty / corrupt** | Empty/absent ledger → exit 0, "0 recorded entries"; corrupt ledger on the CLI read → exit 6, **no sidecar copy and no reset** by the CLI — and the test asserts **no `provenance.plist.corrupt-*` sidecar exists** in the store directory after the CLI read (the CLI read path never copies a sidecar or resets; only the daemon's `load()` does). (§7.2, §8) |
| T9 | **Digest matches independent hash** | Recorded `sha256` equals an independent `shasum -a 256` of the file **and** equals the digest the engine computed during completion (the `hashToCompletion()` value, not a second re-hash). (M1, AC1) |
| T10 | **All frozen fixtures unchanged** | Every pre-existing golden fixture is byte-identical after the change (CI diff). (M4a, AC4) |
| T11 | **`-warnings-as-errors` clean** | `swift build`/`swift test` with `-warnings-as-errors` succeed; the widened handler and engine signatures compile with no warning across the 4 updated test closures + 1 production closure. (M4c) |
| T12 | **Test count non-decreasing** | No existing test removed or weakened. The handler/`complete` signature widening only **adds** `_` wildcards to the **4 existing `DownloadEngineTests` closures**; the **8 existing `GohWhichCommandTests` call sites are entirely unmodified** because `provenanceStorePath` is **defaulted** (`String? = nil`, BLOCK-A) — they keep passing only `filePath:`/`lockPath:` and exercise the unchanged lock→xattr→exit-4 path. All new ledger behavior is covered by NEW tests (T6/T6b/T7/T7b/T8), so test count strictly rises. (M4d) |
| T13 | **First-run on empty Application Support (BLOCK-C)** | With an **empty** support directory (no `dev.goh.daemon` subdir), resolving via `ProvenanceStoreLocation.defaultURL(create: true)` creates the subdir, and a first download still persists **catalog, host-scheduling, and provenance** correctly (the daemon's directory-creation is preserved). Separately, a CLI read via `defaultURL(create: false)` against a missing dir/file does **NOT** create the dir and returns "no store" (which → fall-through; verify --all → exit 0, "0 recorded entries"). (§5.5, ADVISORY A3) |

Mirror the existing store golden tests (catalog / host-scheduling) for T1, and
the existing `GohVerifyCommandTests` exit-code style for T7/T8.

---

## 12. What we'd build (file-level summary)

- **`Sources/GohCore/.../ProvenanceRecord.swift`** — `ProvenanceRecord`
  (versioned root, `currentVersion = 1`) + `ProvenanceEntry`.
- **`Sources/GohCore/.../ProvenanceStore.swift`** — `final class: Sendable` over
  `Mutex<Inner>`; `load()` (with corrupt→sidecar), `record(entry:)` (in-place by
  path + atomic rewrite), a read-only `lookup(destinationPath:)` (canonicalizes
  its argument internally, §5.3/ADVISORY C) and `allEntries()` for the CLI.
  Carbon copy of the `HostProfileStore` idiom **minus** the TTL eviction — with a
  source-level comment recording that omission deliberately (§3, ADVISORY E).
- **`Sources/GohCore/Provenance/ProvenanceStoreLocation.swift`** — the shared
  store-path resolver (§5.5); `supportDirectoryURL()` is factored here out of
  `gohd/main.swift` so daemon and CLI cannot diverge.
- **`DownloadEngine.swift`** — `complete(...)` + `verifyHash(...)` signature
  changes; bind the digest at the three completion sites; widen
  `completedDownloadHandler`.
- **`gohd/main.swift`** — construct `ProvenanceStore` from
  `ProvenanceStoreLocation.defaultURL(create: true)`, load + warn on sidecar,
  add the best-effort `record` block in the handler (5th param); forward
  `supportDirectoryURL()` to the shared resolver **with `create: true`** so the
  `dev.goh.daemon` subdir is still created on a clean install (BLOCK-C).
- **`GohWhichCommand.swift`** — new ledger branch between lock and xattr; `run`
  gains a **defaulted** `provenanceStorePath: String? = nil` (nil ⇒ skip the
  ledger lookup, so the 8 existing which-tests compile and run unchanged; the
  real CLI call site passes the resolved
  `ProvenanceStoreLocation.defaultURL(create: false).path`).
- **`GohVerifyAllCommand.swift`** — the **new, separate** `--all` runner
  (`run(provenanceStorePath:)`), re-hashing via `FileDigest`, OK/FAILED/MISSING,
  exit 0/2/9/6. `GohVerifyCommand.swift` is **not** modified (frozen surface).
- **`GohCommandLine.swift`** — new `.verifyAll(provenanceStorePath:)` case +
  parse arm; `which`/`verify` call sites updated to resolve and pass the store
  path (§5.5, §7.1). The `usage()` help text (L512, the `goh verify [...]` line)
  is updated to document the new `--all` flag (ADVISORY A5).
- **Tests** — T1–T12 above; a committed golden `provenance.plist` fixture.

---

## 13. Open risks

1. **Binary-plist re-encode bit-stability across SDKs.** T1's byte-identical
   assertion may be brittle across SDK 26.2 (CI) vs 26.5 (local) — the
   cross-SDK-skew gotcha. Mitigation: §6.5's decoded-value round-trip fallback,
   matching how the existing store golden tests handle this. **Confirm against
   the existing catalog/host-scheduling golden tests during implementation.**
2. **`completedDownloadHandler` call sites.** The blast radius (1 prod + 4 test
   closures) is from the design-validation enumeration at specific line numbers;
   those line numbers drift. The implementer must grep for every assignment of
   `completedDownloadHandler` rather than trust the line numbers.
3. **`sha256` prefix consistency.** The engine streams bare hex; the store holds
   prefixed; `FileDigest` returns prefixed. One mismatch (prepending twice, or
   comparing prefixed-to-bare) silently breaks `verify --all`. T9 + T7 guard it,
   but it is the most likely defect.
