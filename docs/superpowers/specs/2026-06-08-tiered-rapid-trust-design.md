---
date: 2026-06-08
feature: tiered-rapid-trust
type: design-spec
status: draft — round 2 (round-1 adversarial-spec-review block issues addressed)
---

# Design — Tiered "Rapid Trust"

## 1. Problem

Today goh answers exactly one trust question — "are these bytes identical to what I
recorded?" — with exactly one mechanism: re-hash the whole file (SHA-256). That is the
right tool for a cryptographic *integrity* proof, but it is O(file size): a 68GB file
takes ~minutes (read-bound; there is no cryptographic shortcut — you cannot prove a file
intact without reading every byte). Because it is the *only* mechanism, a routine "is my
library still here and intact?" glance costs exactly as much as a full forensic proof.

Users need a **rapid** trust signal for everyday use, reserving the expensive proof for
when it actually matters (suspected tampering, periodic scrub, before relying on a file).

## 2. The model — trust is three different questions

| Question | Cost | Mechanism | Status today |
|---|---|---|---|
| **Origin** — do I trust where this came from? | cheap, once | sha256 + optional Secure-Enclave attestation recorded at download | ✅ exists |
| **Integrity** — identical to what I recorded? | O(size), slow | full re-hash (now responsive: live bar/ETA/cancel) | ✅ exists (#103) |
| **Rapid liveness** — does it still look like the file I recorded? | O(1) | `lstat`: size + mtime(sec,nsec) + inode/device vs recorded baseline | ❌ this design |

The rapid check is a **heuristic, not a proof.** It detects deletion, truncation,
replacement, and most accidental change instantly. It **cannot** detect silent bit-rot,
nor a tamper that preserves size+mtime (`touch -r` after editing). The design's central
safety requirement: a rapid `unchanged` result is **never** presented as cryptographic
verification — enforced at the model layer (§5.4), not just copy.

## 3. Scope

### In scope
1. Capture a **stat baseline** at download finalization (`fstat` on the still-open fd, so the
   baseline describes exactly the bytes that were hashed — see §6) and store it as
   additive-optional fields on `ProvenanceEntry` (§5.1). `ProvenanceRecord.version` stays
   `1`; golden fixture unchanged (§7).
2. A **pure, injectable** fast-check in GohCore (§5.2–5.3): compares a recorded baseline
   against a current `FileStat` and returns a `FastCheckStatus`. The real filesystem probe
   is injected, so the comparison logic is unit-tested with zero real files.
3. Surface it: the tray **Trust window** (target module **GohMenuBar**, not GohTUI — GohTUI
   is the separate terminal dashboard) shows the fast status by default on open; "Verify
   integrity" stays the explicit deep action. A CLI entry point `goh verify --quick` (§8 D1).

### Out of scope (explicit)
- **Chunked / BLAKE3 / Merkle hashing** (parallel + localizable deep verify). Changes the
  on-disk *hash* representation → bumps `ProvenanceRecord.version` → genuine four-round pass.
  Separate future slice.
- **Scheduled/background verify** (a "scrub" timer). Separate slice.
- **Changing the deep verify** — done in #103.
- **Attestation** — fully decoupled (separate `dev.goh.attest/` store); untouched.
- **Writing back on fast-check** — the fast check is stateless and read-only (no daemon
  round-trip, no ledger write). See Decision D3.
- **Backfilling baselines into pre-feature entries** — they read as `notBaselined` (D3).

## 4. Success criteria (falsifiable)

- **AC1** A fast-check over N entries does only `lstat` calls — zero file *content* reads
  (test: inject a probe that records calls; assert no hashing/`read` occurs).
- **AC2** A file whose current `FileStat` integer-matches the recorded baseline
  (statSize, mtimeSec, mtimeNsec, inode, device) → `.unchanged`. (Tested purely via injected
  `FileStat` — no `Date`/plist round-trip in the path, so no precision loss; see §5.3/§6.)
- **AC3** Any single baseline field differing → `.changed(reason:)` with the matching reason
  (`.size` / `.mtime` / `.identity`).
- **AC4** `lstat` fails with `ENOENT` → `.missing`.
- **AC5** `lstat` fails with any other errno (e.g. `EACCES`, `ELOOP`, `ENOTDIR`) →
  `.indeterminate` (NOT `.missing`); a present-but-unreadable file is never reported gone.
- **AC6** An entry missing any required baseline field → `.notBaselined` (never silently
  `.unchanged`).
- **AC7** The path object is no longer a regular file (now a symlink/dir/device) →
  `.changed(.identity)`.
- **AC8** The presenter maps `.unchanged` and the deep-verify "verified" state to **distinct**
  display tokens (case + label + icon); a test asserts the two are never equal (§5.4).
- **AC9** Adding the new fields leaves `provenance-v1.plist` round-tripping unchanged and
  `ProvenanceRecord.currentVersion == 1`.

## 5. Interface contracts

### 5.1 `ProvenanceEntry` (additive-optional baseline)
Stored as raw integers (exact through binary plist — Swift `Date` would lose `st_mtimespec`
nanoseconds to a Double, the round-1 blocker):
```
recordedStatSize:        Int64?    // st_size at finalize (off_t), authoritative for fast-check
recordedMtimeSeconds:    Int64?    // st_mtimespec.tv_sec
recordedMtimeNanoseconds: Int64?   // st_mtimespec.tv_nsec
recordedInode:           UInt64?   // st_ino (ino_t = __uint64_t)
recordedDevice:          Int64?    // st_dev (dev_t = Int32) widened losslessly to Int64
```
All `Optional`, default `nil`, omitted when nil (mirrors `verifiedAt`). The existing `size:
Int` (download byte counter) is retained unchanged for display/`goh which`; the fast-check
uses `recordedStatSize` so it compares stat-to-stat (apples to apples — avoids the
counter-vs-`st_size` mismatch, incl. sparse files). A "baseline" is present iff all five
fields are non-nil.

### 5.2 `FileStat` + probe (pure, injectable)
```swift
public struct FileStat: Sendable, Equatable {
    public let size: Int64            // st_size
    public let mtimeSeconds: Int64    // st_mtimespec.tv_sec
    public let mtimeNanoseconds: Int64// st_mtimespec.tv_nsec
    public let inode: UInt64          // st_ino
    public let device: Int64          // st_dev (widened)
    public let isRegularFile: Bool    // S_ISREG(st_mode)
}
public enum FileProbeResult: Sendable, Equatable {
    case stat(FileStat)
    case notFound            // lstat errno == ENOENT
    case unreadable(Int32)   // any other errno (EACCES/ELOOP/ENOTDIR/...)
}
public protocol FileStatProbing: Sendable {
    func probe(path: String) -> FileProbeResult   // uses lstat(2); does NOT follow symlinks
}
public struct LiveFileStatProbe: FileStatProbing { public init() {} /* lstat(2) */ }
```

### 5.3 Fast-check API (GohCore, pure)
```swift
public enum FastChangeReason: Sendable, Equatable { case size, mtime, identity }
public enum FastCheckStatus: Sendable, Equatable {
    case unchanged
    case changed(FastChangeReason)
    case missing            // probe → notFound
    case indeterminate      // probe → unreadable(errno)
    case notBaselined       // entry lacks a complete baseline
}
public enum FastCheckRunner {
    public static func check(_ entry: ProvenanceEntry, probe: any FileStatProbing) -> FastCheckStatus
    // results in INPUT order, 1:1 with entries:
    public static func checkAll(_ entries: [ProvenanceEntry], probe: any FileStatProbing) -> [(ProvenanceEntry, FastCheckStatus)]
}
```
**Comparison (pure, integer-exact):**
1. If the entry's baseline is incomplete (any of the five fields nil) → `.notBaselined`.
2. `probe.probe(path: entry.destinationPath)`:
   - `.notFound` → `.missing`
   - `.unreadable(_)` → `.indeterminate`
   - `.stat(s)`:
     - `!s.isRegularFile` → `.changed(.identity)`
     - `(s.inode, s.device) != (recordedInode, recordedDevice)` → `.changed(.identity)`
     - `s.size != recordedStatSize` → `.changed(.size)`
     - `(s.mtimeSeconds, s.mtimeNanoseconds) != (recordedMtimeSeconds, recordedMtimeNanoseconds)` → `.changed(.mtime)`
     - else → `.unchanged`
   (Reason precedence identity > size > mtime, so the most fundamental change is reported.)

### 5.4 Presenter contract (anti-misrepresentation — model-level, testable)
GohMenuBar gains a distinct display status the UI renders from; `.unchanged` and the
deep-verify result MUST be different cases so a future UI change cannot collapse them:
```swift
// nonisolated to match the existing GohMenuBar trust types (constructible from the
// presenter's nonisolated seam and from tests).
nonisolated public enum TrustDisplayStatus: Sendable, Equatable {
    case verified(at: Date)        // deep re-hash matched (the cryptographic claim)
    case looksUnchanged           // rapid heuristic only — NOT a proof
    case changed(FastChangeReason)
    case missing
    case indeterminate
    case notBaselined
    case recordedOnly             // existing "recorded, never verified" (verifiedAt == nil, no fast run)
}
```
AC8 test asserts `verified` and `looksUnchanged` produce different label + icon tokens.
`.notBaselined` renders **neutral/informational** (never an alert color) — on first release
a Trust window can be entirely `.notBaselined` (pre-feature entries have no baseline), and
that is normal, not alarming. Its label: "no baseline recorded — re-download to enable the
rapid check."
`--quick` CLI help text and the `looksUnchanged` label state the limitation ("looks
unchanged since <date> — not a full integrity check; run a deep verify to detect bit-rot or
tampering that preserves size & timestamp").

### 5.5 No wire/protocol change
`protocolVersion` (4) unchanged: the fast-check is CLI/tray-local (ledger read + local
`lstat`, same trust boundary as `goh which`). The daemon `record(entry:)` gains the baseline
it captures in §6. The XPC `VerifiedProvenanceEntry` (sync skip-path) is Decision D4.

## 6. Capture path — baseline = hashed bytes (closes TOCTOU)

Round-1 flagged: statting at *record* time (after the file handle closed) opens a window
where the file could be replaced between hash-finalize and stat. Fix: capture the baseline
with **`fstat` on the engine's still-open file descriptor at the moment SHA-256 is
finalized**. Verified against the real code: `DownloadFile` opens `job.destination`
directly and writes in place via `pwrite` (no `.part`+`rename(2)`), so the open fd and the
final on-disk file are the **same inode** — an `fstat` at finalize matches a later `lstat`
(inode/size/mtime stable). The three concrete seams to add (the round-1 spec hand-waved
these; here are the exact contracts against the current engine):

**6.1 `DownloadFile.fileStat()` accessor.** `DownloadFile` holds `private let descriptor:
Int32`. Add:
```swift
public func fileStat() throws -> FileStat   // fstat(descriptor); maps struct stat → FileStat
```
Call it at each finalization point **while the fd is still open, before `file.finish()`**:
single (~`DownloadEngine.swift` L552–564), ranged-assembly (~L889–900), resume (~L393–394).
Use `try? file.fileStat()` → an `FileStat?` (nil on the should-never-happen fstat failure →
`.notBaselined`, never blocks the download).

**6.2 Widen the completion seam.** The real handler is
`completedDownloadHandler: (@Sendable (JobSummary, Duration, Bool, String?, GovernorOutcome)
-> Void)`, invoked from `complete(jobID:in:transferDuration:isResume:sha256:governorOutcome:)`
*after* `file.finish()` closes the fd. Append the captured baseline:
- `complete(... , governorOutcome:, fileStat: FileStat?)` gains a trailing `fileStat`
  parameter (the value captured in 6.1 before `finish()`).
- `completedDownloadHandler` becomes `(JobSummary, Duration, Bool, String?, GovernorOutcome,
  FileStat?)` — additive trailing arg.

**6.3 Route into `ProvenanceEntry`.** The daemon's `record(entry:)` handler
(`gohd/main.swift`) constructs the `ProvenanceEntry` from the handler's `FileStat?`:
populate `recordedStatSize`/`recordedMtimeSeconds`/`recordedMtimeNanoseconds`/`recordedInode`/
`recordedDevice` from it, or leave all nil when the baseline is nil. The daemon does **NOT**
add its own path `stat` — that would reopen the TOCTOU window *and* race the post-completion
Spotlight `setxattr` (see §9). The baseline must arrive via the handler from the engine fd.

**6.4 Sync path (D4).** For `recordVerifiedProvenance`, the daemon can `fstat` is not
available (no engine fd); it may `lstat` the path itself at record time (the file is at rest,
already hash-verified by `goh sync`) or leave the baseline nil → `.notBaselined`. Decision
D4; v1 default = `.notBaselined` for sync-skip entries.

## 7. Rollout & compatibility

- **Format:** additive-optional integer fields → `ProvenanceRecord.version` stays `1`;
  `provenance-v1.plist` golden fixture unchanged; existing readers ignore the new keys.
  Per DESIGN.md's frozen-contract invariant, additive-optional needs no version bump and no
  four-round pass (the `verifiedAt` precedent). The *new semantics* are what this spec +
  adversarial-spec-review validate.
- **Existing entries** (pre-feature) have nil baseline → `.notBaselined` until re-recorded.
  Truthful ("no baseline to compare"); backfill is deferred (D3).
- **Rolling deploy:** old `gohd` + new CLI (or vice-versa) both work — fields optional in
  both directions; an old daemon simply writes no baseline.
- **Rollback:** dropping the feature leaves the extra integer keys as harmless ignored data.

## 8. Open decisions (for review + user)

- **D1 — CLI surface.** `goh verify --quick` (fast) alongside default deep `goh verify --all`.
  Recommendation: yes — same noun, discoverable; deep stays default so existing scripts /
  `goh attest` are unchanged.
- **D2 — Tray default.** Trust window shows fast status automatically on open; "Verify
  integrity" is the explicit deep action. Recommendation: yes (that's the "rapid" point).
- **D3 — Backfill old entries.** Defer — keep v1 fast-check strictly read-only; revisit if
  `.notBaselined` is common in practice.
- **D4 — Sync-skip entries.** `VerifiedProvenanceEntry` (XPC, protocolVersion 4) could carry
  the baseline too, but the daemon can `fstat` the file itself when handling
  `recordVerifiedProvenance` (it has the path), avoiding any wire change. Recommendation:
  daemon-side `fstat` on the sync record path if cheap; else `.notBaselined` for sync entries
  in v1.
- **D5 — mtime comparison.** Exact integer equality on (tv_sec, tv_nsec). Recommendation:
  exact — legitimate content change rewrites mtime; `changed` (→ prompt deep verify) is the
  safe direction. Document the `touch -r` limit.

## 9. Security & privacy at design time

- **New attack surface:** none. Read-only `lstat` + ledger read, same trust boundary as
  `goh which`. No new IPC, no new input parsing, no write on the read path. GohCore probe
  uses Darwin `lstat` directly (no new dependency).
- **Primary risk — misrepresentation** (the central safety requirement): a heuristic
  `unchanged` must never read as cryptographic proof. Enforced by §5.4's distinct
  `TrustDisplayStatus` cases (`looksUnchanged` ≠ `verified`) with AC8 asserting different
  tokens, plus limitation wording in the label and `--quick` help. Deep verify remains and
  is clearly the stronger claim.
- **TOCTOU:** closed at capture time by fstat-at-finalize (§6); the baseline provably
  describes the hashed bytes.
- **ctime vs mtime / post-completion `setxattr`:** after the engine closes the fd, the daemon
  runs `tagCompletedDownload` which issues Spotlight `setxattr` calls on the destination.
  `setxattr` bumps only `st_ctime`, not `st_mtimespec`/`st_size`/`st_ino`/`st_dev` — so the
  baseline (mtime, not ctime) is stable across the tagging. This is the concrete reason the
  baseline uses mtime, and the concrete reason §6.3 forbids a daemon path-`stat` (it would
  race that `setxattr` and could capture a post-tag ctime/timestamp skew).
- **Inode/device:** compared as a `(st_ino, st_dev)` pair (not inode alone) to avoid
  cross-volume collisions. APFS clone/CoW copy → new inode → `.changed(.identity)` (correct:
  a new instance). A backup/restore that changes inode without content change → false
  `.changed` (safe direction: it prompts a deep verify, never a false `unchanged`).
- **Symlink:** `lstat` (not `stat`) so a path swapped to a symlink is detected as non-regular
  → `.changed(.identity)` rather than silently following to another object.

## 10. Considered alternatives

- **Store mtime as `Date`** — rejected: lossy through PropertyListEncoder (Double seconds)
  vs nanosecond `st_mtimespec`; would mark unchanged files as changed. Raw integer tv_sec/
  tv_nsec instead.
- **Path `stat` at record time** — rejected: TOCTOU window vs the hashed bytes; fstat at
  finalize instead.
- **Sample hashing** (first/last N MiB + size) — probabilistic, misses middle tampering, not
  meaningfully cheaper than `lstat` for the routine case. Rejected.
- **Filesystem checksums (ZFS-style)** — APFS doesn't checksum file data by default. Rejected.
- **BLAKE3/Merkle now** — real deep-verify speedup but a frozen-format hash change
  (four-round). Deferred to its own slice.
```
