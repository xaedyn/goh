---
date: 2026-06-08
feature: tiered-rapid-trust
type: design-spec
status: draft — pending adversarial-spec-review + user approval
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
| **Rapid liveness** — does it still look like the file I recorded? | O(1) | `stat`: size + mtime + inode/device vs recorded | ❌ this design |

The rapid check is a **heuristic, not a proof.** It detects deletion, truncation,
replacement, and most accidental change instantly. It **cannot** detect silent bit-rot,
nor a tamper that preserves size+mtime (`touch -r` after editing). The design's central
safety requirement is that an "unchanged" rapid result is **never** presented as
cryptographic verification — that remains the deep verify's job.

## 3. Scope

### In scope
1. Record file metadata at download time so a later `stat` can be compared: `recordedMtime`,
   `recordedInode`, `recordedDevice` on `ProvenanceEntry` (the existing `size` already
   captures byte count). **Additive-optional fields** (see §7) — `ProvenanceRecord.version`
   stays `1`, golden fixture unchanged.
2. A pure, read-only **fast-check** in GohCore: given a `ProvenanceEntry`, `stat` its
   `destinationPath` and classify `FastCheckStatus`.
3. Surface it: the tray **Trust window** shows the fast status by default (instant on open);
   "Verify integrity" stays the explicit deep action. A CLI entry point (`goh verify
   --quick`, exact spelling in §8) for the same.

### Out of scope (explicit)
- **Chunked / BLAKE3 / Merkle hashing** (parallel + localizable deep verify). Bigger payoff
  for huge files, but it changes the on-disk *hash* representation → bumps
  `ProvenanceRecord.version` → genuine four-round pass. Separate future slice.
- **Scheduled/background verify** (a "scrub" timer). Separate slice.
- **Changing the deep verify** — done in #103.
- **Attestation** — fully decoupled (separate `dev.goh.attest/` store); untouched.
- **Writing back on fast-check** — the fast check is stateless and read-only (no daemon
  round-trip, no ledger write). See §6 / Decision D3.

## 4. Success criteria (falsifiable)

- **AC1** Given a ledger of N entries with recorded metadata, a fast-check returns a status
  for every entry by doing only `stat` calls — zero file *content* reads (assert: hashing
  is never invoked on the fast path).
- **AC2** A file that is byte-identical and untouched since download → `unchanged`.
- **AC3** A file whose size, mtime, or inode/device differs from recorded → `changed`.
- **AC4** A recorded file that no longer exists at its path → `missing`.
- **AC5** An entry with no recorded metadata (pre-feature record, or sync-skip entry without
  it) → `unknown` (never silently treated as `unchanged`).
- **AC6** The UI/CLI label for `unchanged` is visibly distinct from the deep-verify
  "verified" label — an `unchanged` result is never worded as cryptographic proof.
- **AC7** Adding the new fields leaves `provenance-v1.plist` round-tripping unchanged and
  `ProvenanceRecord.currentVersion == 1` (old readers/ledgers unaffected).

## 5. Interface contracts

### 5.1 `ProvenanceEntry` (additive-optional)
```
recordedMtime:  Date?     // st_mtimespec at record time
recordedInode:  UInt64?   // st_ino
recordedDevice: UInt64?   // st_dev (inode is unique only within a device)
```
All `Optional`, default `nil`, omitted from the plist when nil (mirrors `verifiedAt`).
`size: Int` is reused as the recorded byte count (already present). Synthesized `Codable`
keeps working; unknown-key tolerance means old readers ignore them.

### 5.2 Fast-check API (GohCore, pure)
```swift
public enum FastCheckStatus: Sendable, Equatable {
    case unchanged          // size + mtime + inode + device all match recorded
    case changed(reason: FastChangeReason)   // .size | .mtime | .identity
    case missing            // stat failed: file not at recordedPath
    case unknown            // entry lacks recorded metadata → cannot fast-check
}
public enum FastCheckRunner {
    // stat-only; never reads file content. now: injected for tests.
    public static func check(_ entry: ProvenanceEntry) -> FastCheckStatus
    public static func checkAll(_ entries: [ProvenanceEntry]) -> [(ProvenanceEntry, FastCheckStatus)]
}
```
Comparison: `missing` if `stat` fails; else `changed` if any of {on-disk `st_size` ≠ `size`,
`st_mtimespec` ≠ `recordedMtime`, `(st_ino, st_dev)` ≠ `(recordedInode, recordedDevice)`};
else `unchanged`. If `recordedMtime`/`recordedInode`/`recordedDevice` are all nil → `unknown`.

### 5.3 No wire/protocol change
`protocolVersion` (4) unchanged: the fast-check is CLI/tray-local (reads the ledger + stats
the local filesystem, same access pattern as `goh which`/`verify --all`). The daemon's
`record(entry:)` gains the stat fields it already must compute (§6). The XPC
`VerifiedProvenanceEntry` (sync path) is addressed in Decision D4.

## 6. Daemon write path

`gohd` records a `ProvenanceEntry` after each completed download (`gohd/main.swift` ~172).
Today `size` comes from the download byte counter, and there is **no** `stat` (the file
handle is already closed → must be a path-based `stat(2)`, not `fstat`). Add one `stat(2)`
on `completed.destination` to capture `st_mtimespec` / `st_ino` / `st_dev`. If the `stat`
fails (race: file moved/removed between finish and record), store the entry with nil
metadata → it simply reads back as `unknown` (graceful; never blocks recording).

## 7. Rollout & compatibility

- **Format:** additive-optional → `ProvenanceRecord.version` stays `1`; `provenance-v1.plist`
  golden fixture is unchanged; existing readers (`goh which`, `verify --all`, tray) ignore
  the new keys. **Per the project's own rule (DESIGN.md frozen-contract invariant), an
  additive-optional field needs no version bump and no four-round pass** — the `verifiedAt`
  field set this precedent. The *new semantics* (a heuristic trust tier) are what this spec
  + adversarial-spec-review exist to validate.
- **Existing entries** (downloaded before this ships) have nil metadata → `unknown` on fast
  check until re-recorded. Acceptable: `unknown` truthfully says "no baseline to compare."
  Optional backfill (a deep verify writing the stat baseline) is Decision D3.
- **Rolling deploy:** an old `gohd` + new CLI, or vice-versa, both work — new fields are
  optional in both directions.
- **Rollback:** dropping the feature leaves the extra plist keys as harmless ignored data.

## 8. Open decisions (for the review + user)

- **D1 — CLI surface.** `goh verify --quick` (fast) alongside default deep `goh verify
  --all`? Or a separate `goh status`? Recommendation: `goh verify --quick` (discoverable,
  same noun). Deep stays the default so existing scripts/`attest` are unchanged.
- **D2 — Tray default.** Trust window shows fast status automatically on open (instant), with
  "Verify integrity" as the explicit deep action. Recommendation: yes — that's the whole
  point ("rapid").
- **D3 — Backfill old entries.** Should a deep verify (or a one-shot) write the stat baseline
  back into the ledger so old entries become fast-checkable? Recommendation: defer — keep
  v1's fast check strictly read-only; revisit if `unknown` entries are common in practice.
- **D4 — Sync-skip entries.** `VerifiedProvenanceEntry` (XPC wire type, `protocolVersion 4`)
  could also carry the stat fields. Adding them risks a wire bump unless done as true
  optionals with defaults. Recommendation: out of scope for v1 (sync entries read back as
  `unknown`); fold in later with any other protocol change.
- **D5 — mtime comparison.** Exact equality vs tolerance. Recommendation: exact — a
  legitimate content change rewrites mtime, and `changed` (→ prompt a deep verify) is the
  safe direction. Document that a `touch -r` replay defeats it (the known heuristic limit).

## 9. Security surface

- **New attack surface:** none. The fast check is read-only (`stat` + ledger read), same
  trust boundary as `goh which`. No new IPC, no new input parsing, no new write on the read
  path.
- **Primary risk — misrepresentation.** The danger is *product*, not memory-safety: showing
  a heuristic `unchanged` as if it were cryptographic proof. Mitigations: (a) distinct
  wording/iconography for `unchanged` ("looks unchanged since <date>") vs deep "verified
  <date>"; (b) deep verify always available and clearly the stronger claim; (c) document the
  `touch -r`/bit-rot limitation in `--quick` help text and the design.
- **Inode/device reuse:** comparing `(st_ino, st_dev)` (not inode alone) avoids cross-volume
  inode collisions. APFS clones/CoW copies get a new inode → `changed` (correct: it's a new
  instance).

## 10. Considered alternatives

- **Sample hashing** (hash first/last N MiB + size): faster than full, catches truncation,
  but probabilistic and misses targeted middle tampering — too weak to label "verified" and
  not meaningfully cheaper than the `stat` heuristic for the routine case. Rejected.
- **Filesystem checksums (ZFS-style):** APFS does not checksum file *data* by default; can't
  rely on it. Rejected.
- **BLAKE3/Merkle now:** real speedup for deep verify, but a frozen-format hash change
  (four-round). Deferred to its own slice, not bundled with the cheap win.
```
