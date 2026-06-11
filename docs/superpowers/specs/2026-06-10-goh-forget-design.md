---
date: 2026-06-10
feature: goh-forget
type: implementation-spec
status: ready-for-plan
chosen-approach: Approach 1 — Preview-and-Confirm
phases: [Phase 1 — CLI + daemon + store + wire, Phase 2 — tray]
---

# Implementation Spec — `goh forget`

## 1. Problem

The provenance ledger (`~/Library/Application Support/dev.goh.daemon/provenance.plist`)
records every download goh has seen: source URL, SHA-256, size, and a fast-check
stat baseline keyed by canonical `destinationPath`. The ledger is append/update
only — there is **no removal path anywhere in the product**. `ProvenanceStore`
exposes `record`, `recordVerified`, `lookup`, `allEntries` and nothing that
deletes (confirmed in `Sources/GohCore/Provenance/ProvenanceStore.swift`).

The user consequence: when a downloaded file is deleted, moved, or lived on a
drive that's been wiped or detached, its ledger entry **lingers forever**. Every
`goh verify --all` and `goh verify --quick` keeps reporting it `MISSING`; the
Trust window keeps showing a dead row. The user has no supported way to say
"I know that file is gone — stop tracking it." Their only options today are to
hand-edit a binary plist the daemon owns exclusively (which the design forbids —
the CLI is read-only, the daemon is the sole writer) or to live with permanent
`MISSING` noise that erodes the signal value of the trust layer.

`goh forget` gives the user an explicit, safe, first-class verb to remove
provenance entries they no longer want tracked — without ever touching the
files themselves.

## 2. Success metrics (definition of done, tied to AC1–AC5)

Each metric is an observable signal a test asserts. Exit codes are exact.

| # | AC | Observable signal a test asserts |
|---|----|-----------------------------------|
| M1 | AC1 | After `goh forget <tracked-path>` returns, `ProvenanceStore.lookup(destinationPath:)` for that canonical path is `nil`; a subsequent `verify --all` and `verify --quick` over the same ledger emit **no `MISSING`/`OK` line naming that path** (a last-entry forget yields `verify --quick`'s `"0 recorded entries"`, not literally empty output). The command **exits 0** and stdout contains a one-line confirmation naming the forgotten path. |
| M2 | AC2 | `goh forget --missing` (no `--confirm`) over a ledger with K absent + P present entries: stdout lists **exactly the K absent** paths (present entries never appear), each carrying a mount annotation; the on-disk ledger is **byte-identical** before and after (nothing deleted); **exit 0**. `goh forget --missing --confirm` sends **one** `forgetProvenance` request whose `paths` is exactly those K canonical paths (the **stored `destinationPath` strings verbatim**, not re-canonicalized — see §7); the reply carries `forgotCount == K`; afterward `lookup` returns `nil` for all K and the P present entries are all still present; **exit 0**. A reply with `forgotCount < K` surfaces a non-success outcome (warn + non-zero), never a clean success line. |
| M3 | AC3 | `goh forget <untracked-path>`: ledger unchanged (byte-identical), stderr contains a clear "not tracked" message naming the path, **exit non-zero** (exit 1 — runtime "nothing to do", distinct from 64 usage). No success line on stdout. |
| M4 | AC4 | A `ProvenanceStore.forget(paths:)` that removes ≥1 entry routes through `writeAtomically` (temp → chmod 0600 → fsync(tmp) → rename(2) → fsync(dir)). A test asserts the written file decodes as a valid `ProvenanceRecord` (`version == 1`) and, given any interruption, the on-disk bytes are a complete pre- or post-forget record, never truncated. |
| M5 | AC5 (Phase 2) | In the Trust window, a row with status MISSING exposes a "Forget" affordance; invoking it opens a preview/confirm sheet, and on confirm calls `GohMenuClient.forget(paths:)`, then `loadOverview()` refreshes and the row is gone. Present-file rows expose no one-click destructive Forget without the same preview/confirm sheet. |
| M6 | gap #1 | Before any mutating forget sends `forgetProvenance`, the CLI sends a **fresh `.ls`** and reads `LsReply.featureLevel`. A stale daemon (`featureLevel == nil` OR `< 2`, i.e. predates `forgetProvenance`) drives the mutating CLI paths to emit a clear "daemon too old; restart it: `goh daemon restart`" message and **non-zero exit (1)** — and **never** print a success line, never send `forgetProvenance`. A daemon that is unreachable (the fresh `.ls` send itself throws) emits a "cannot reach the goh daemon" message and **exit 1**, sends nothing. A test injects a `send` returning `featureLevel: 1` and asserts no success output + non-zero exit, and a `send` that throws and asserts the unreachable message + exit 1. The decision is taken from the **fresh `.ls` featureLevel compare**, never from `DaemonAutoHeal.runIfNeeded`'s `String?` return. |
| M7 | gap #2 | A test forgets a path whose file **still exists on disk** and asserts the file is byte-for-byte untouched after the forget (the file-deletion-safety invariant). |

Done = M1–M7 all hold, CI green under `-warnings-as-errors`, golden fixtures
committed, `DESIGN.md` updated with the `forgetProvenance` wire paragraph and the
featureLevel-2 bump note.

## 3. Out of scope (explicit v1 exclusions)

- **No interactive TTY prompt.** No `readLine`, no `isatty`, no `--yes`. The
  gate is the `--confirm` flag (matches goh's `daemon restart --force`
  flag-over-prompt precedent; rejects Approach 2).
- **No automatic / TTL / scheduled pruning.** `forget` only ever removes on an
  explicit user request. `ProvenanceStore`'s "INTENTIONALLY NO TTL EVICTION"
  comment stands; this feature does not weaken it.
- **No `--missing` re-hash.** Absence is decided by **one `lstat`** per entry
  (`LiveFileStatProbe().probe(path) == .notFound`), never by `verify --all`
  content hashing.
- **`forget` never deletes or modifies a file on disk.** It mutates
  `record.entries[]` only. (Contractual — see §4.)
- **No `protocolVersion` bump.** `forgetProvenance` is an additive `Command`
  enum case on the existing `protocolVersion = 4` channel.
- **No `ProvenanceRecord.currentVersion` bump.** `forget` is a runtime
  `entries[]` mutation; the on-disk v1 schema is unchanged.
- **No new XPC endpoint, service, or auth path.** Rides the existing
  peer-validated `Command` channel.
- **No bulk forget by URL, host, or date.** v1 selects by explicit path or by
  `--missing` (absent-on-disk). Other predicates are future work.
- **No undo / trash / recycle.** A forgotten entry is gone from the ledger;
  re-recording happens only through the normal download/verify paths.

## 4. Security surface

- **No new attack surface.** `forgetProvenance` is a new case on the existing
  `Command` enum, dispatched through the same XPC accept that every other
  command uses — `XPCPeerRequirement` + `XPCRequirement.isFromSameTeam` mutual
  peer validation (DESIGN.md §Platform support). Only a same-team-signed peer
  (the user's own goh binaries) can send it. There is **no new endpoint and no
  new authorization seam**; the dispatcher's documented model (audit I1:
  "every command is equally available to any peer that passed XPC peer
  validation") is preserved. Erasing one's own ledger is in-scope user intent,
  not an attack.
- **File-deletion-safety invariant (gap #2, contractual + tested).**
  `ProvenanceStore.forget(paths:)` MUST mutate `record.entries[]` ONLY. It MUST
  NOT `unlink`, `removeItem`, truncate, `open(...O_TRUNC)`, or otherwise touch
  any file at any of the requested paths. The only filesystem writes it performs
  are those of `writeAtomically` against the ledger's own temp/target/dir. M7
  asserts this by forgetting a present file and checking the file survives
  untouched. (Contrast: `CommandDispatcher.rm` *does* delete partials via
  `deletePartial`; `forget` must share **none** of that machinery.)
- **Atomic, owner-only ledger writes.** Forget reuses `writeAtomically`: the
  temp file is `chmod 0600`, `fsync`'d, `rename(2)`'d, dir `fsync`'d — identical
  durability and permission posture to every existing ledger write. No widening
  of file permissions.
- **Input handling.** Request `paths` are plain strings the daemon canonicalizes
  via `URL(fileURLWithPath:).standardizedFileURL.path` (the `recordVerified`
  precedent). Canonicalization is string normalization only — no path is opened,
  followed, or stat'd by the store. A nonexistent or malformed path that matches
  no entry is simply a no-op for that path (no error, no write amplification).

## 5. Rollout

**featureLevel bump.** `GohFeatureLevel.current` goes `1 → 2`
(`Sources/GohCore/Model/GohFeatureLevel.swift`). featureLevel 2 ==
"daemon honors `forgetProvenance`". This is the skew axis the CLI uses to detect
a daemon too old to delete entries. Document the bump in `DESIGN.md` alongside
the featureLevel-1 note, exactly as the existing self-heal slice did.

**Backward compatibility during a rolling deploy.**

- *New CLI + old daemon (featureLevel 1, predates `forgetProvenance`).* Before a
  mutating forget sends the destructive command, the CLI runs a **NEW gate
  specific to `forget`** — a *fresh `.ls` + featureLevel compare*, decided
  exit-code-affecting CLI-side. This is **NOT** "the gate verify uses": verify's
  `DaemonAutoHeal.runIfNeeded` is best-effort and exit-code-neutral, and its
  `String?` return conflates "current/healed" and "XPC unreachable" (both `nil`,
  confirmed in `Sources/GohCore/CLI/DaemonAutoHeal.swift`), so it cannot drive a
  "must error" decision. The forget gate, in order:
  1. **(optional, best-effort)** MAY invoke
     `DaemonAutoHeal.runIfNeeded(send:restarter:)` purely to *attempt* a heal of
     an idle stale daemon. Its return value is **NOT** used for the decision and
     is discarded. This step may be skipped entirely without changing
     correctness — it only improves the odds the next step finds a healed daemon.
  2. sends a **FRESH `.ls`** and reads `LsReply.featureLevel`.
  3. decides, purely from that fresh `.ls`:
     - if the `.ls` send itself **throws** (XPC unreachable / daemon stopped) →
       emit `goh forget: cannot reach the goh daemon — is it running? try: goh
       daemon restart` on stderr, **exit 1**, send **NOTHING**;
     - if `featureLevel == nil` **OR** `featureLevel < 2` → emit `goh forget:
       this goh daemon is too old to support forget — restart it: goh daemon
       restart` on stderr, **exit 1**, send **NOTHING**;
     - only `featureLevel >= 2` proceeds to send the single `forgetProvenance`.
  The stale/unreachable decision is **never** routed through `runIfNeeded`'s
  notice string. (May reuse `DaemonSkewCheck.evaluate(reported:expected:
  activeDownloadCount:)` to classify the fresh featureLevel, but the
  exit-affecting branch is the explicit `nil`/`< 2` compare above, not a
  best-effort notice.)
  This NEW gate applies to **BOTH** mutating paths:
  - `forget <path>` — runs the gate **after** the CLI-side read-only `lookup`
    confirms the path is tracked (an untracked path errors exit 1 with no daemon
    contact, before the gate);
  - `forget --missing --confirm` — runs the gate after enumerating ≥1 absent
    candidate.
  It makes the "old daemon, new CLI" race a loud, actionable error — never a
  silent "forgot 0 entries". (gap #1 fix.) The non-mutating preview
  (`forget --missing` without `--confirm`) and the untracked-path check do **NOT**
  require a live daemon at all — they read the ledger directly and lstat — so they
  work regardless of daemon age.
- *Old CLI + new daemon (featureLevel 2).* Unaffected. The old CLI never emits
  `forgetProvenance`; the new daemon answers all existing commands identically.
  `LsReply.featureLevel` is additive-optional and an old CLI ignores it.
- *Decode safety.* An old daemon that somehow received `forgetProvenance` would
  throw `DecodingError` on the unknown `Command` case and return a malformed/nil
  reply — but the skew gate above prevents the CLI from ever sending it, so this
  path is defense-in-depth, not the primary guard.

**Rollback plan.** The feature is purely additive on the wire and on disk:
new enum case, new request struct, new `ForgetProvenanceReply` (+ new
`CommandOutcome.forgotProvenance` case), one new store method, a featureLevel
integer bump. Rolling back the daemon to featureLevel 1 makes
`forget` unavailable (CLI errors clearly per the skew gate) but corrupts nothing
— the ledger format is unchanged and round-trips on both versions. No data
migration, no schema fork. A forgotten entry cannot be un-forgotten by rollback
(it's already gone), but that is the intended, user-requested effect.

## 6. Interface contracts (frozen-vs-additive)

**Frozen — MUST NOT change:** `protocolVersion = 4`,
`ProvenanceRecord.currentVersion = 1` and its golden (`provenance-v1.plist`),
`VerifyAllReport` JSON + golden, the launchd plist, `machServiceName`.

**Additive — new surface.**

### Wire: new `Command` case + request struct

`Sources/GohCore/Model/Command.swift` — add to the `Command` enum:

```swift
case forgetProvenance(request: ForgetProvenanceRequest)
```

and the request payload (mirrors `RecordVerifiedProvenanceRequest` shape and doc
style):

```swift
/// The `forgetProvenance` command's request payload.
/// Removes the ledger entries whose canonical `destinationPath` matches one of
/// `paths`. The daemon canonicalizes each path via
/// `URL(fileURLWithPath:).standardizedFileURL.path` before matching (the
/// `recordVerifiedProvenance` precedent). A path matching no entry is a no-op.
/// `forgetProvenance` NEVER touches the file at any path — it removes ledger
/// entries only. Reply is `ForgetProvenanceReply`, carrying the count actually
/// removed (`forgotCount`).
public struct ForgetProvenanceRequest: Codable, Sendable, Equatable {
    public var paths: [String]
    public init(paths: [String]) { self.paths = paths }
}
```

### Wire: new reply type carrying a removed count

A bare `.ack` cannot distinguish "removed all K requested" from "removed 0" — so
`forget --missing --confirm` (and `forget <path>`) could print a clean success
on a zero-match reply (BLOCK 2 false-success). The reply therefore carries an
explicit count.

`Sources/GohCore/Model/CommandReply.swift` — add (additive, alongside `AckReply`):

```swift
/// The `forgetProvenance` command's success reply.
/// `forgotCount` is the number of ledger entries actually removed by this call
/// (entries whose canonical `destinationPath` matched a requested path). The CLI
/// asserts `forgotCount == paths.count`; a smaller count is a non-success outcome.
public struct ForgetProvenanceReply: Codable, Sendable, Equatable {
    public var forgotCount: Int
    public init(forgotCount: Int) { self.forgotCount = forgotCount }
}
```

`Sources/GohCore/Model/CommandOutcome.swift` — add an additive case:

```swift
/// `forgetProvenance` — the count of entries actually removed.
case forgotProvenance(ForgetProvenanceReply)
```

`Sources/GohCore/Model/CommandService.swift` — `encodeReply`'s switch is
exhaustive over `CommandOutcome`, so it gains one arm (mirrors `.removed`):

```swift
case .forgotProvenance(let reply):
    return try replyEnvelope(requestID: requestID, payload: reply)
```

`CommandService.handle` routes through its `default` arm to
`dispatcher.reply(to:)`, so it needs no change. (`forgetProvenance` does **not**
reuse `.ack`; `recordVerifiedProvenance` keeps `.ack` unchanged.)

### Daemon: dispatcher case

`Sources/GohCore/Model/CommandDispatcher.swift` — the **exhaustive** switch in
`reply(to:)` MUST gain a case (this is the only compile-time-forcing switch over
`Command`). It borrows `recordVerifiedProvenance`'s store-guard shape but
**deliberately diverges on error handling**: `recordVerifiedProvenance` is a
best-effort background backfill that swallows write errors and returns `.ack`;
`forgetProvenance` is a **foreground destructive command the user is synchronously
waiting on**, so a write failure MUST return a `.failure(GohError)` — not a
success — so the CLI exits non-zero (AC4: "if the write throws, the CLI exits
non-zero"). The store returns the count actually removed; the dispatcher returns
it via `.forgotProvenance`:

```swift
case .forgetProvenance(let request):
    guard let provenanceStore else {
        // No store configured (test/headless): nothing could be removed.
        // Report 0 removed rather than a phantom success.
        warn?("forgetProvenance: provenance store unavailable; skipped \(request.paths.count) path(s)")
        return .forgotProvenance(ForgetProvenanceReply(forgotCount: 0))
    }
    do {
        let forgotCount = try provenanceStore.forget(paths: request.paths)
        return .forgotProvenance(ForgetProvenanceReply(forgotCount: forgotCount))
    } catch {
        // Foreground destructive command — do NOT mirror recordVerifiedProvenance's
        // best-effort .ack-on-throw. A write failure (atomic-write / rename) is a
        // structured failure the CLI surfaces as a non-zero exit.
        warn?("forgetProvenance: provenance store write failed for \(request.paths.count) path(s): \(error)")
        return .failure(GohError(
            code: .destinationUnwritable,
            message: "could not rewrite the provenance ledger: \(error)"))
    }
```

(Canonicalization happens **inside** `ProvenanceStore.forget`, per the
precedent — see below. The dispatcher passes raw request paths through.
`ErrorCode` has no generic `.io` case; `.destinationUnwritable` is the existing
code closest to "the daemon could not write the ledger file" — confirmed against
`Sources/GohCore/Model/GohError.swift`. The plan may substitute a more specific
ledger-write code if one is added, but it MUST be a real `ErrorCode` case, never
a phantom.)

### Store: `ProvenanceStore.forget(paths:)`

`Sources/GohCore/Provenance/ProvenanceStore.swift` — new method, mirrors
`recordVerified`'s lock + canonicalize + `writeAtomically` shape:

```swift
/// Removes every entry whose canonical `destinationPath` matches one of `paths`,
/// then atomically rewrites the ledger. Empty `paths` is a no-op (no lock, no
/// write). A path matching no entry is silently skipped (idempotent).
///
/// INVARIANT (security): this method mutates `record.entries[]` ONLY. It MUST
/// NEVER unlink, truncate, or modify any file at any of `paths`. The only
/// filesystem writes are `writeAtomically`'s own temp/target/dir operations.
///
/// Each input path is canonicalized via
/// `URL(fileURLWithPath:).standardizedFileURL.path` before matching, exactly
/// as `recordVerified` / `lookup` do — stored keys are already canonical.
///
/// Returns the number of entries actually removed (the count the dispatcher
/// echoes back as `ForgetProvenanceReply.forgotCount`). On a `writeAtomically`
/// failure it **throws** (the dispatcher turns that into a failure reply — see
/// above); it does not swallow the error.
@discardableResult
public func forget(paths: [String]) throws -> Int {
    guard !paths.isEmpty else { return 0 }
    let canonical = Set(paths.map {
        URL(fileURLWithPath: $0).standardizedFileURL.path
    })
    return try inner.withLock { inner in
        let before = inner.record.entries.count
        inner.record.entries.removeAll { canonical.contains($0.destinationPath) }
        let removed = before - inner.record.entries.count
        // Only write when something actually changed — avoids a needless atomic
        // rewrite (and fsync) when no requested path was present.
        if removed != 0 {
            try writeAtomically(&inner.record)
        }
        return removed
    }
}
```

Note: when nothing matched, the method performs **no disk write** and returns
`0`. The daemon replies `.forgotProvenance(forgotCount: 0)`. For `forget <path>`
the CLI's "not tracked" verdict is decided CLI-side from a read-only `lookup`
BEFORE sending (see §7), so M3's non-zero exit does not depend on the daemon. For
`forget --missing --confirm` the CLI passes the **stored `destinationPath`
strings verbatim** (§7), so canonicalization is the identity on them and
`forgotCount` equals the requested count by construction; a `forgotCount < K`
indicates the rare lookup→forget race and is surfaced as a non-success outcome.

### Tray: `GohMenuClient.forget(paths:)` (Phase 2)

`Sources/GohMenuBar/GohMenuViewModel.swift` — add to the `@MainActor`
`GohMenuClient` protocol:

```swift
/// Removes the given paths' provenance entries via the daemon. Best-effort
/// from the UI's perspective (errors surface as a render(health:.failed)).
func forget(paths: [String]) async throws
```

This breaks **all 5 conformers** (compile-time, caught by CI) — each must
implement it:
1. `LiveGohMenuClient` — `Sources/goh-menu/main.swift:11` (production; sends
   `.forgetProvenance` via the real client).
2. `FakeMenuClient` — `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift:18`.
3. `FakeMenuClient` — `Tests/GohMenuBarTests/GohMenuViewModelTests.swift:350`.
4. `LongLivedMenuClient` — `Tests/GohMenuBarTests/GohMenuViewModelTests.swift:453`.
5. `SpyMenuClient` — `Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift:9`.

`TrustWindowViewModel` gains an `@MainActor func forget(paths:)` that calls
`menuClient?.forget(paths:)` then `await loadOverview()` to refresh. The
SwiftUI Trust window puts a "Forget" affordance on MISSING rows that first
presents a preview/confirm sheet (the GUI analogue of the CLI's printed
candidate list, per macOS HIG destructive-action pattern); present-file rows
get the same sheet — never a one-click destructive action.

## 7. CLI behavior, exit codes, and grammar

New verb parsed in `GohCommandLine.parse` (add a `ParsedCommand.forget(...)`
case and a `case .forget` dispatch arm in `run()`; new runner
`Sources/GohCore/CLI/GohForgetCommand.swift`). Add a `goh forget …` line to
`usage()`.

### Grammar

```
goh forget <path>                  remove one tracked path's entry (no prompt)
goh forget --missing               dry-run: list absent-file entries, delete nothing
goh forget --missing --confirm     delete the absent-file entries
```

Mutual exclusion and usage rules, all → **exit 64** (`ParseError`, the
established usage-error code):
- `--missing` and a positional `<path>` together → usage error.
- `--confirm` without `--missing` → usage error
  ("`--confirm` is only valid with `--missing`").
- `--confirm` with a positional `<path>` → usage error.
- unknown flag, or more than one positional → usage error.

### `goh forget <path>` (explicit, single)

1. Read-only `lookup` of the path against the ledger (canonicalized). The CLI
   resolves the ledger path via the same `provenanceStorePathResolver` seam
   `which`/`verify --all` use; it may read the ledger directly (read-only) to
   decide tracked-vs-untracked **before** sending anything.
2. **Untracked** (no matching entry) → print
   `goh forget: <path> is not tracked (no provenance entry)` to **stderr**,
   change nothing, **exit 1** (AC3 — never a silent success). No daemon contact.
3. **Tracked** → run the §5 stale-daemon gate (the NEW fresh-`.ls` +
   featureLevel check): optionally attempt a best-effort heal, then send a fresh
   `.ls`; if that send throws → "cannot reach the goh daemon" + exit 1, send
   nothing; if `featureLevel == nil` or `< 2` → "daemon too old; restart it" +
   exit 1, send nothing. Only on `featureLevel >= 2` send **one**
   `forgetProvenance` request with the single canonical path. On a successful
   reply, assert `forgotCount == 1`; if so print `Forgot <path>.` to **stdout**,
   **exit 0** (AC1). If `forgotCount == 0` (the path was un-tracked between the
   read-only lookup and the send — a rare race), print a `<path> was no longer
   tracked` notice and **exit 1**, no clean success line. On daemon failure reply
   (e.g. a ledger-write error) or transport failure, surface it via the existing
   `GohCommandLineError` path, **exit 1**, no success line.

Works whether or not the file is currently present on disk (a present-file path
is a valid explicit forget — see edge cases). The file is never touched.

### `goh forget --missing` (dry-run by default)

1. Read the ledger read-only (`ProvenanceLedgerReader.read(at:)`). On
   `unreadable(...)` → the ledger-error path → **exit 6** (matches
   `verify --quick`/`--all` ledger-error vocabulary). On `absent` or
   `entries([])` → "No tracked entries." → **exit 0**.
2. `lstat` each entry once via `LiveFileStatProbe().probe(path)`. The candidate
   set is exactly the entries whose probe is `.notFound`. (`.unreadable(errno)`
   is **present-but-unreadable** and is **not** a candidate — AC2 "absent on
   disk" means ENOENT, not EACCES.)
3. For each candidate, print the path with a **volume-mount annotation**:
   - if the entry's parent volume is currently mounted →
     `MISSING   <path>` (file gone from a mounted volume).
   - if no mounted volume is a prefix of the path →
     `MISSING   <path>   (VOLUME NOT MOUNTED)` (likely a detached external drive,
     not a deletion).

   Mount detection uses Foundation's
   `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:options:)`,
   which returns `[URL]?` (**optional**). If it returns `nil`, the annotation
   **degrades gracefully**: print the path WITHOUT any annotation (bare
   `MISSING   <path>`) — never force-unwrap, never crash.
   A path is "on a mounted volume" iff some mounted volume URL's path is a prefix
   of the entry's path **on path-component boundaries** — compared component by
   component (e.g. via `pathComponents`), NOT a raw `hasPrefix` on the string, so
   `/Volumes/Arc` does **not** falsely match `/Volumes/Archive`. Among the
   component-boundary matches, pick the **longest** matching mount.
4. Print a trailing summary line ("N entr(y/ies) missing; re-run with --confirm
   to forget them") and **delete nothing**. **Exit 0** even with candidates —
   the dry run "succeeded." (Zero candidates → "No missing entries." exit 0.)

### `goh forget --missing --confirm`

1. Same read + lstat enumeration as the dry run (re-enumerated at confirm time —
   the candidate set is recomputed, not carried from a previous invocation).
2. If zero candidates → "No missing entries." **exit 0** (nothing sent).
3. Run the §5 stale-daemon gate (the NEW fresh-`.ls` + featureLevel check):
   optionally attempt a best-effort heal, then send a fresh `.ls`. If that send
   throws → "cannot reach the goh daemon" + **exit 1**, send nothing. If
   `featureLevel == nil` or `< 2` → "daemon too old; restart it" + **exit 1**,
   send nothing. Only `featureLevel >= 2` proceeds.
4. Send **one** `forgetProvenance` request whose `paths` is exactly the K
   candidates' **stored `destinationPath` strings, passed VERBATIM** — the CLI
   does NOT re-canonicalize them (they were already stored canonical). Because the
   daemon's canonicalization is the identity on already-canonical strings, a
   zero-match is **impossible by construction** for `--missing`; this is a tested
   invariant (see §9). On the reply, assert `forgotCount == K`:
   - `forgotCount == K` → print `Forgot N entr(y/ies).` to stdout, **exit 0**
     (AC2);
   - `forgotCount < K` → a concurrent record/forget race removed fewer than
     requested; surface a non-success outcome: print `Forgot N of K entr(y/ies);
     M still tracked` (warn) and **exit non-zero**, never a clean success line.
   On a daemon failure reply (ledger-write error) or transport error → **exit 1**,
   no success line.

### Exit-code table

| Situation | Exit |
|-----------|------|
| `forget <path>` tracked, forgotten | 0 |
| `forget <path>` untracked | 1 |
| `forget --missing` dry-run (any candidate count) | 0 |
| `forget --missing` ledger unreadable/corrupt/unknown-version | 6 |
| `forget --missing --confirm` success (`forgotCount == K`) | 0 |
| `forget --missing --confirm` partial (`forgotCount < K`, record/forget race) | non-zero |
| daemon too old — fresh `.ls` reports featureLevel `nil`/`< 2` (mutating paths) | 1 |
| daemon unreachable — fresh `.ls` send throws (mutating paths) | 1 |
| daemon failure reply (ledger-write error) / transport error on `forgetProvenance` send | 1 |
| usage error (`--confirm` w/o `--missing`, both selectors, unknown flag, extra positional) | 64 |

## 8. Wire-format examples (golden fixtures)

Create `Tests/GohCoreTests/Fixtures/envelope-v4-forget-provenance-request.json`
and `…-reply.json`, mirroring the `record-verified-provenance` pair exactly
(JSON envelope, `protocolVersion: 4`, `.sortedKeys`, ISO-8601 UTC, request UUID
echoed in reply, escaped forward slashes as the existing fixtures show).

**Request** (`forgetProvenance` with two absent paths):

```json
{"messageType":"request","payload":{"forgetProvenance":{"request":{"paths":["\/Users\/testuser\/Downloads\/gone.bin","\/Volumes\/Archive\/old.iso"]}}},"protocolVersion":4,"requestID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F"}
```

**Reply** (`ForgetProvenanceReply` carrying the removed count, requestID echoed —
both requested paths matched, so `forgotCount` is 2):

```json
{"messageType":"reply","payload":{"forgotCount":2},"protocolVersion":4,"requestID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F"}
```

A golden round-trip test decodes the request fixture into
`GohEnvelope<Command>`, asserts `.forgetProvenance(request:)` with the two
paths, re-encodes, and asserts byte-equality with the fixture; and decodes the
reply fixture into `ForgetProvenanceReply` asserting `forgotCount == 2`.

## 9. Edge cases (each must be handled and tested)

| Edge case | Required behavior |
|-----------|-------------------|
| Empty ledger (`forget --missing`) | "No tracked entries." exit 0. No daemon contact. |
| Untracked path (`forget <path>`) | "not tracked" on stderr, ledger unchanged, exit 1. No send. (AC3) |
| `--missing` with zero absent entries | "No missing entries." exit 0. No send (even with `--confirm`). |
| Both selectors (`--missing` + `<path>`) | Usage error, exit 64. |
| `--confirm` without `--missing` | Usage error, exit 64. |
| Daemon stopped/unreachable (mutating path) | The fresh `.ls` gate (§5/§7) throws → "cannot reach the goh daemon" on stderr, **exit 1**, `forgetProvenance` is **never sent**, nothing removed, no success line. The `--missing` dry run and untracked-path check still work (no daemon). |
| Daemon too old (featureLevel `nil` or `< 2`, mutating path) | The fresh `.ls` gate (§5/§7) reads a stale featureLevel → "daemon too old; restart it" on stderr, **exit 1**, `forgetProvenance` is **never sent**, no success line. (gap #1.) |
| `--missing --confirm` paths sent verbatim (zero-match impossible) | The CLI sends the candidates' **stored `destinationPath` strings unchanged** (no re-canonicalization). Daemon canonicalization is the identity on already-canonical keys, so every requested path matches and `forgotCount == K`. **Tested invariant**: a `--missing --confirm` over K absent entries always yields `forgotCount == K`. |
| `forget --missing --confirm` returns `forgotCount < K` (record/forget race) | A download re-recording or a concurrent forget changed the ledger between enumerate and forget. The CLI surfaces a non-success outcome ("Forgot N of K; M still tracked", **exit non-zero**), never a clean success. |
| File reappears between preview and confirm (TOCTOU, gap #3) | **Accepted, documented.** `forgetProvenance` removes exactly the requested canonical paths (explicit by-path contract, like `forget <path>`). Mitigation is the dry run's per-entry mount annotation (`VOLUME NOT MOUNTED`) which the user reads before passing `--confirm`. No daemon-side re-stat. If a remounted file's path is in the confirmed set, its entry is removed (and the next download/verify can re-record it). |
| Forget a present-file path (`forget <path>` on an existing file) | Valid: the entry is removed; the **file is left on disk untouched** (M7 asserts this). The explicit path is the confirmation (git-rm model). |
| Path canonicalization — trailing slash | `…/dir/` and `…/dir` canonicalize identically via `standardizedFileURL`; both match the stored canonical key. |
| Path canonicalization — relative path | `URL(fileURLWithPath:)` resolves against cwd; `..`/`.` components are standardized out. A relative input that resolves to a tracked canonical path matches; one that doesn't is "not tracked" (exit 1). |
| Path canonicalization — symlink | `standardizedFileURL` does **not** resolve symlinks (no `resolvingSymlinksInPath`), matching how entries were keyed at record time. Forget matches the stored canonical string, not the symlink target — consistent with `lookup`/`record`. |
| Concurrent forget + download-completion record | `ProvenanceStore.forget` and `record`/`recordVerified` all serialize through `inner.withLock`. A forget concurrent with a completing download is ordered: either the new entry is recorded-then-removed or removed-then-re-recorded — always a consistent, complete ledger via the whole-file atomic write. Never interleaved/partial. |
| `--missing` entry whose file is present-but-unreadable (EACCES) | `.unreadable(errno)` is **not** a candidate — only `.notFound` (ENOENT) counts as absent. Not listed, not forgotten. |
| Ledger unreadable/corrupt during `--missing` | Ledger-error path, exit 6 (matches verify vocabulary). No partial action. |

## 10. Plan segmentation

The feature splits at a deployment-independence boundary; **Phase 1 is
independently shippable** and delivers AC1–AC4 + the gap fixes.

**Phase 1 — CLI + daemon + store + wire + fixtures + featureLevel.**
`GohFeatureLevel.current → 2`; `Command.forgetProvenance` + `ForgetProvenanceRequest`;
`ForgetProvenanceReply` + `CommandOutcome.forgotProvenance` + `CommandService.encodeReply` arm;
`CommandDispatcher` case (failure reply on write-throw, not best-effort `.ack`);
`ProvenanceStore.forget(paths:) -> Int` (+ file-safety test);
`GohForgetCommand` runner (path + `--missing`/`--confirm` + mount annotation +
skew gate); `GohCommandLine` parse/dispatch + usage; two golden fixtures;
DESIGN.md paragraph. AC1, AC2, AC3, AC4, gap #1, gap #2, gap #3 all land here.

**Phase 2 — tray.** `GohMenuClient.forget(paths:)` (+ 5 conformers);
`TrustWindowViewModel.forget(paths:)`; Trust-window Forget affordance on MISSING
rows + preview/confirm sheet; refresh on confirm. Delivers AC5. Depends on
Phase 1's wire being shipped in the daemon.
