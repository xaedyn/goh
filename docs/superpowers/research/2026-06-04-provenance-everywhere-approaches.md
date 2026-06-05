---
date: 2026-06-04
feature: provenance-everywhere
type: approach-decision-memos
---

# Approach Decision Memos — Provenance-everywhere (verify-only)

Tree-of-Thought over the **storage-substrate + reuse-strategy** axis. The
feature (verify-only, auto-record on every download) and two facts are **fixed,
not approach axes**:

- **Digest capture** = widen the daemon-internal
  `completedDownloadHandler` with `sha256: String?` (one prod closure + 4 test
  closures; no wire/on-disk contract touched). Common to all approaches.
- **The record is machine-local, daemon-owned** in
  `~/Library/Application Support/dev.goh.daemon/`; the CLI has no digest access;
  orthogonal to the portable `gohfile.lock`. Common to all approaches.

Approaches differ **only** on the substrate.

## Candidates explored, then pruned

| Seed | Verdict | Why |
|---|---|---|
| **A — New daemon plist store** (mirror `HostProfileStore`) | **SURVIVES** | Exact idiom match; zero new deps; verified skeleton on disk. |
| **B — Reuse `gohfile.lock` TOML as a global auto-lock** | **SURVIVES** | Genuine max-reuse contender; must be evaluated honestly, not strawmanned. |
| **C — Append-only log + compaction** | **PRUNED → folded as a "not building" note under A** | YAGNI at personal volumes (brief: ~200 MB at 1M entries, thousands realistic). O(1) appends solve a write-throughput problem goh does not have; compaction + log-fold reader is net-new machinery with no idiom on disk. Not a standalone survivor — recorded as the scale-escape hatch A buys time to reach. |
| **D — SQLite-WAL** | **PRUNED, with rule-honesty note** | CLAUDE.md: "Apple-frameworks-first; a third-party dependency needs explicit justification." The justification is *scaling headroom to millions of rows* (Nix/Chrome) — headroom the brief shows is unneeded at goh's volumes. A new FFI surface (`libsqlite3`) for unneeded scale fails the rule on its face. Pruned, not padded. |

Two survivors. Per instructions, not padding to three.

---

## APPROACH A — The Native Ledger

**CORE IDEA.** A fourth daemon-owned store that is a carbon copy of the three
that already live next to it. Provenance becomes "just another store in the
daemon's Application Support directory," indistinguishable in shape from
`catalog.plist`, `host-scheduling.plist`, and the checkpoint plists.

**MECHANISM.** New `ProvenanceStore` — a `Sendable` class over a
`Mutex<Inner>`, holding a versioned Codable root `ProvenanceRecord { static
currentVersion = 1; version; entries: [ProvenanceEntry] }`, persisted as a
binary property list at
`~/Library/Application Support/dev.goh.daemon/provenance.plist`. Entries keyed
by destination path; on completion the daemon's `completedDownloadHandler`
(now carrying `sha256`) calls `store.record(entry:)`, which **updates in place**
by destination path (one entry per logical destination) and does a **full
atomic rewrite**: `.tmp-<UUID>` → `chmod 0600` → `fsync(tmp)` → `rename(2)` →
`fsync(dir)`. On load, a version-mismatch or decode failure
quarantines-to-sidecar (`provenance.plist.corrupt-<unixtime>`) and resets to
empty — byte-for-byte the `HostProfileStore` recovery path verified on disk
(`Sources/GohCore/Scheduling/HostProfileStore.swift` L114, L312–318, L334–338).

**FIT ASSESSMENT.**
- **Scale** — STRONG. O(n) rewrite per download; n bounded by *download count*
  (~200 B/entry → ~200 MB at 1M downloads per brief). At thousands–tens-of-
  thousands of personal downloads, a sub-megabyte plist rewrite is imperceptible.
- **Team (solo maintainer)** — STRONG. Nothing new to learn: a fourth instance
  of a pattern the maintainer already wrote three times. New-contributor cost
  is recognition, not comprehension.
- **Operational** — STRONG. Same backup/inspect/delete story as the other
  daemon stores (`plutil -p provenance.plist`); same corrupt→sidecar safety net;
  no migration tooling, no compaction job, no FFI to keep alive.
- **Stack alignment** — STRONG. Apple-frameworks-first (`PropertyListEncoder`,
  `Darwin` rename/fsync); zero new dependencies; exact idiom match. Sails through
  every CLAUDE.md rule with nothing to justify.

**TRADEOFFS.**
- *Strong at:* lowest cognitive and operational cost; provably-correct recovery
  by copying a verified skeleton; trivially satisfies AC4 (own version field,
  golden round-trip) and AC5 (in-place update + corrupt→sidecar are native to
  the idiom).
- *Sacrifices:* zero format reuse with `gohfile.lock` — `goh which` /
  verify-everything get a **second** reader path (plist) alongside the existing
  TOML lock reader. Two on-disk shapes for conceptually adjacent data.

**WHAT WE'D BUILD.** `ProvenanceStore` (class), `ProvenanceRecord` (versioned
root), `ProvenanceEntry { url, sha256, size, downloadedAt, destinationPath }`,
a 5th `sha256: String?` arg on `completedDownloadHandler`, a new lookup branch
in `GohWhichCommand` (between xattr fallback and exit-4), and a
verify-everything surface (e.g. `goh verify --all`) re-hashing each recorded
path via `FileDigest.sha256WithSize` and reporting OK/FAILED/MISSING mirroring
the existing exit-code vocabulary (2 mismatch, 9 missing).

**THE BET.** Personal-scale download counts never reach the point where an
O(n) full-plist rewrite per completion becomes user-perceptible.

**REVERSAL COST.** Easy. The store is daemon-internal with its own version
field; swapping the substrate later (to a log or SQLite) is a one-file
re-implementation behind the same `record`/`lookup`/`verifyAll` surface, with
no external contract to migrate.

**WHAT WE'RE NOT BUILDING.** No append-log, no compaction job, no SQLite/FFI,
no auto-pruning at v1, no content-addressed byte storage, no sharing of the
on-disk format with `gohfile.lock`. (Approach-C's append-log is the explicit
escape hatch if the bet ever fails — reachable behind this same surface.)

**INDUSTRY PRECEDENT.** dpkg `/var/lib/dpkg/status` — a full-file flat package
record rewritten in place, no embedded database. `[VERIFIED — dpkg status
format]` Same family: Cargo.lock / pylock.toml (PEP 751, accepted Mar 2025) as
flat atomic-rewrite records. `[VERIFIED — Cargo docs; pylock.toml spec]`

---

## APPROACH B — The Global Auto-Lock

**CORE IDEA.** Don't invent a second format — promote the *existing*
`gohfile.lock` shape to a machine-global record the daemon writes for every
download. `goh which` and verify-everything already parse `LockEntry` via
`LockfileCodec`, so the readers come for free; only the writer is new.

**MECHANISM.** The daemon, in `completedDownloadHandler`, encodes a global
lock-format file (e.g.
`~/Library/Application Support/dev.goh.daemon/global.lock`) through the existing
`LockfileCodec.encode`, appending/updating a `LockEntry { url, path, sha256,
size, downloadedAt }` per completion — a **full TOML reparse + re-serialize**
each time (the lockfile codec has no incremental-append API). `goh which` and a
verify-everything path reuse `LockfileCodec.decode` and the same
`FileDigest`-based re-hash that `GohVerifyCommand` already runs against
`gohfile.lock`.

**FIT ASSESSMENT.**
- **Scale** — WEAK→PARTIAL. O(n) like A, but the constant is worse: TOML
  parse+serialize per download is heavier than binary-plist encode, and the
  daemon is on the hot completion path. Tolerable at small n; the least
  efficient survivor.
- **Team (solo maintainer)** — PARTIAL. Reader code is reused (a real saving),
  but the maintainer inherits a **conceptual hazard**: "lock = your declared
  manifest's frozen record" now coexists with "global = everything this machine
  pulled," in the *same syntax*. Future-you must hold two meanings for one file
  shape.
- **Operational** — PARTIAL. Human-readable/diffable is a genuine plus. But it
  couples the auto-record to a **FROZEN contract** (`lockfileVersion = 1`): any
  field the global record later wants (e.g. a per-entry flag) either forces a
  lockfile-version bump that ripples into the portable lock, or a fork that
  defeats the reuse rationale. Also a portability-mismatch foot-gun — the file
  *looks* like a committable lock but must never be committed.
- **Stack alignment** — PARTIAL. No new dependency (good, Apple-frameworks-
  first holds), but **violates the spirit of the frozen-contract discipline**:
  it overloads a `protocolVersion`-class on-disk format for a new purpose
  without a design pass, exactly the "muddied semantics" the brief flags.

**TRADEOFFS.**
- *Strong at:* maximum code reuse on the read side; one format to learn;
  human-inspectable record.
- *Sacrifices:* welds a machine-local, daemon-owned record to a portable,
  user-committed, frozen contract; pays the heaviest per-download cost;
  introduces a semantic collision that no version field can paper over.

**WHAT WE'D BUILD.** A `GlobalLockWriter` over `LockfileCodec.encode` wired
into `completedDownloadHandler`; in-place `LockEntry` update by path; new
read branches in `GohWhichCommand` and verify-everything pointed at
`global.lock`; a golden fixture for the global file. (Note: reuses `LockEntry`
but cannot give the global record its *own* version field without diverging
from `lockfileVersion 1` — see REVERSAL COST and the AC4 row.)

**THE BET.** The semantic and frozen-contract coupling between a portable lock
and a machine-local global record stays benign — the two never need to diverge
in shape, so the shared format never becomes a liability.

**REVERSAL COST.** Hard. Once `goh which` and verify-everything read
`global.lock` in the field, moving off the lock format means migrating live
user data *and* deciding whether the global file's version tracks
`lockfileVersion` (frozen) or breaks away — the coupling that made it cheap to
build makes it expensive to leave.

**WHAT WE'RE NOT BUILDING.** No new on-disk format (that's the whole point);
no plist store; no SQLite; no content-addressed storage; no auto-pruning at v1.

**INDUSTRY PRECEDENT.** No clean precedent for promoting a *portable* lockfile
into a *machine-local* global ledger of the same syntax. The closest analogues
are deliberately the *opposite* split: npm separates `package-lock.json`
(committed, portable) from the per-machine cache index, and Cargo separates
`Cargo.lock` from `~/.cargo`'s registry state — i.e. the ecosystem *avoids*
overloading the lock for machine-local bookkeeping. `[SINGLE — argument from
absence of precedent; npm/Cargo split is VERIFIED but is counter-evidence, not
support]`

---

## Comparison matrix

Rows: AC1–AC5 (acceptance-criteria file) + the four fit criteria. Cells:
STRONG / PARTIAL / WEAK + one-sentence reason.

| | **A — Native Ledger** | **B — Global Auto-Lock** |
|---|---|---|
| **AC1** — every download recorded | STRONG — handler `record(entry:)` writes the streamed digest, no re-hash. | STRONG — same handler hook writes a `LockEntry` with the streamed digest. |
| **AC2** — `goh which` offline from record | STRONG — new plist lookup branch, no network. | STRONG — reuses `LockfileCodec.decode`, no network. |
| **AC3** — verify-everything OK/FAILED/MISSING | STRONG — re-hash via `FileDigest`, mirror exit codes; clean new surface. | STRONG — reuses the exact `gohfile.lock` re-hash path. |
| **AC4** — purely additive, own version field | STRONG — own `currentVersion=1` root + golden round-trip, zero frozen contracts touched. | WEAK — reusing `LockEntry` means no independent version field without diverging from frozen `lockfileVersion 1`; AC4 demands the record carry its *own* version. |
| **AC5** — re-download/corruption safe, never blocks | STRONG — in-place update + corrupt→sidecar are native to the copied idiom. | PARTIAL — in-place update works, but corrupt-recovery for `global.lock` must be built fresh (lock codec has no sidecar path) and TOML rewrite sits on the hot path. |
| **Scale fit** | STRONG — binary-plist O(n) rewrite, n bounded by download count. | PARTIAL — O(n) with a heavier TOML parse+serialize constant on the completion path. |
| **Team fit (solo)** | STRONG — fourth copy of a known pattern. | PARTIAL — reader reuse, but two meanings for one file shape to carry. |
| **Operational burden** | STRONG — same inspect/backup/recovery as existing stores; nothing new to run. | PARTIAL — diffable, but couples to a frozen contract and a portability foot-gun. |
| **Stack alignment** | STRONG — Apple-first, no dep, exact idiom, nothing to justify. | PARTIAL — no dep, but overloads a frozen-contract format without a design pass. |

---

## Recommendation

Pick **Approach A — The Native Ledger.** The single most important reason: it
is the only survivor that satisfies **AC4** cleanly — a record with its *own*
version field that touches **none** of the frozen contracts — because B's entire
value proposition (reuse the `gohfile.lock` shape) is exactly what forces it to
inherit the frozen `lockfileVersion 1` and forfeit an independent version field.
A's "reuse" is the *store idiom* (`HostProfileStore`'s verified
`Mutex`/atomic-rewrite/corrupt→sidecar skeleton), not a frozen *format* — which
is the reuse that pays off without the coupling that costs. B's read-side code
savings are real but are bought with a semantic collision and a frozen-contract
coupling that the brief explicitly warns against and that no version field can
undo. Approach C (append-log) is not a third option but A's documented
escape hatch behind the same `record`/`verifyAll` surface, reachable only if
A's personal-scale bet ever fails.

**The user chooses.** If human-readable, diffable, single-format inspection of
the global record is judged to outweigh the AC4 coupling and the hot-path TOML
cost, B is a coherent — if precedent-thin — alternative.
