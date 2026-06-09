---
date: 2026-06-09
feature: backfill-on-verify
type: design-spec
status: draft — pending adversarial-spec-review + user approval
---

# Design — Backfill Baselines on Deep Verify

## 1. Problem

The rapid fast-check (#104) only works on files that have a recorded stat baseline.
Baselines are captured at download time, so **every file downloaded before #104 reads
`notBaselined`** — and re-downloading a 68GB file just to get a baseline is absurd. We need
a way to give existing files a baseline without re-downloading.

## 2. The insight

A **successful deep verify is the ideal moment to capture a trustworthy baseline.** When
`goh verify --all` (or the tray "Verify now") re-hashes a file and it matches the recorded
SHA-256, goh has just *cryptographically confirmed the bytes are correct*. Capturing the
file's current size/mtime/inode/device at that instant yields a baseline that is trusted
**because it describes bytes that just passed a full hash check** — not unverified metadata.

So: **deep-verify once → fast-check instantly forever after.** This is the deferred D3
backfill, done in the one way that keeps the baseline meaningful.

## 3. Scope

### In scope
1. `FileDigest.sha256WithSize` optionally captures a `FileStat` via `fstat` on the open
   handle **before close** (TOCTOU-tight — the stat describes the inode whose bytes were
   just hashed).
2. `VerifyAllRunner` surfaces, for each `.ok` entry, `(destinationPath, sha256, size,
   FileStat)` via a **side channel** — NOT inside the frozen `VerifyAllReport` (see §7).
3. On a deep verify, for every `.ok` entry, record `verifiedAt` + the 5 baseline fields
   into the ledger via the existing daemon `recordVerifiedProvenance` path (extended).
   - CLI `goh verify --all`: gains an **optional** `send: Sender?` (default nil). With a
     sender, it batches the OK baselines to the daemon. `goh attest` keeps passing nil →
     stays read-only (§9).
   - Tray "Verify now": a new `recordVerifiedProvenance` client method + injection into
     `TrustWindowViewModel`; after a finished run it sends the OK baselines.
4. `VerifiedProvenanceEntry` (XPC wire) + `ProvenanceStore.recordVerified` gain the 5
   additive-optional baseline fields; the daemon populates `recordedStat*` from them.

### Out of scope (explicit)
- **`VerifyAllReport` / `--json` output** — FROZEN (`reportVersion 1`, golden fixture). The
  baseline travels a side channel, never the report (§7).
- **The deep verify algorithm / responsiveness** (#103) and **the fast-check** (#104) —
  unchanged.
- **`goh attest`** — must remain non-writing (passes nil sender).
- **Sync-skip baselines (D4)** and **chunked/BLAKE3** — separate slices.
- **`.failed` / `.missing` entries** — never get a baseline written (only `.ok`).

## 4. Success criteria (falsifiable)

- **AC1** After `goh verify --all` (with a sender) over a ledger whose entries lack
  baselines, every `.ok` entry's ledger record gains all 5 `recordedStat*` fields + a
  `verifiedAt`; a subsequent `goh verify --quick` on the same files returns `.unchanged`
  (not `.notBaselined`).
- **AC2** A `.failed` entry (bytes don't match recorded sha256) gets **no** baseline and
  **no** `verifiedAt` written.
- **AC3** A `.missing` entry writes nothing.
- **AC4** The captured `FileStat` describes the hashed bytes (fstat on the open hash handle,
  before close) — a test asserts the digest's FileStat equals an independent lstat of the
  unchanged file.
- **AC5** `goh attest` performs **no** ledger write (passes nil sender; a test asserts the
  ledger is byte-unchanged across an attest run).
- **AC6** `VerifyAllReport` / `--json` output is byte-identical to before (golden fixture +
  `--json` tests unchanged) — the baseline is never in the report.
- **AC7** With the daemon stopped / no sender, `goh verify --all` still completes and reports
  correctly (backfill is best-effort, silently skipped) — verify is never blocked by backfill.
- **AC8** `protocolVersion` stays 4; old/new peers interoperate (additive-optional wire
  fields).

## 5. Interface contracts

### 5.1 `FileDigest` (capture seam)
Add an overload or a trailing out-value. Recommended: a new method returning the stat too,
keeping the existing one intact:
```swift
public static func sha256WithSizeAndStat(
    path: String,
    onBytesHashed: ((Int) -> Void)? = nil,
    isCancelled: (() -> Bool)? = nil
) throws -> (sha256: String, size: Int, stat: FileStat)
```
Maps `fstat(handle.fileDescriptor)` → `FileStat` exactly as `LiveFileStatProbe`/`DownloadFile.fileStat`
(the parity invariant from #104 covers this mapping). The existing `sha256WithSize` stays for
callers that don't need the stat.

### 5.2 `VerifyAllRunner` (side channel)
`VerifyAllReport` stays frozen. The runner gains an optional collector so callers that want
baselines get them without touching the report:
```swift
public struct VerifiedBaseline: Sendable, Equatable {
    public let destinationPath: String
    public let url: String
    public let sha256: String
    public let size: Int
    public let stat: FileStat
}
// verifyAll gains an optional out-collection (e.g. an inout array or an onVerified
// callback) populated ONLY for .ok entries. Default nil → today's behavior, zero overhead.
```

### 5.3 Wire + store (additive-optional)
`VerifiedProvenanceEntry` gains `recordedStatSize: Int64?`, `recordedMtimeSeconds: Int64?`,
`recordedMtimeNanoseconds: Int64?`, `recordedInode: UInt64?`, `recordedDevice: Int64?` (all
defaulted nil — Codable backward-compatible, no `protocolVersion` bump; daemon+CLI ship
together). `ProvenanceStore.recordVerified` populates the entry's `recordedStat*` from them
(all-or-nothing). `CommandDispatcher` validation unchanged except it forwards the new fields.

### 5.4 CLI / tray write path
- `GohVerifyQuickCommand` unchanged. `GohVerifyAllCommand.run(...)` gains
  `send: GohCommandLine.Sender? = nil`; when non-nil and there are OK baselines, build
  `VerifiedProvenanceEntry`s (with baseline) and send `.recordVerifiedProvenance` (best-effort:
  a send failure logs a warning, never changes the verify exit code — AC7). `GohCommandLine`'s
  `.verifyAll` dispatch passes `send`. `GohAttestCommand` keeps calling the no-send form.
- Tray: `GohMenuClient` gains `func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry]) async throws`;
  `LiveGohMenuClient` implements it over XPC. `TrustWindowViewModel` is injected with the
  client (or a record closure); on `.finished(report)` it sends OK baselines (best-effort).

## 6. Capture path & TOCTOU

The baseline is captured by `fstat` on the open hash handle at the moment the digest is
finalized (before `defer { close }`), so it describes the exact inode/bytes that were hashed.
That FileStat travels with the OK result to the daemon, which records it. No re-stat at record
time (which would reopen a TOCTOU window). Same design as #104's fstat-at-finalize.

## 7. Frozen-contract handling

- `VerifyAllReport` (reportVersion 1) + the `--json` golden output are FROZEN. The baseline
  is NEVER added to `VerifyEntryResult`/the report — it travels the §5.2 side channel. AC6
  asserts the report/`--json` is byte-identical.
- `ProvenanceRecord.currentVersion` stays 1 (the baseline fields already exist from #104).
- `protocolVersion` stays 4 (additive-optional wire fields; AC8).
- Golden provenance fixture unchanged.

## 8. Rollout & compatibility

- Additive-optional everywhere; old ledgers/peers unaffected.
- A user upgrades, runs `goh verify --all` (or "Verify now") once → existing files gain
  baselines and become quick-checkable. No migration step; no re-download.
- Daemon stopped → verify still works read-only; backfill skipped (AC7).
- Rollback: the extra wire/ledger fields are ignored by old code.

## 9. Security & privacy

- **The baseline is only ever written for bytes that JUST passed a full SHA-256 check**
  against the recorded hash. Backfill never trusts unverified metadata — this is the core
  safety property. A `.failed` file gets nothing (AC2).
- `verifiedAt` is now also set by deep verify (previously only `goh sync`). This is correct —
  it *is* a verification — and matches the "verified <date>" claim's meaning. The tray's
  `verified` vs `looksUnchanged` distinction (#104) is unaffected.
- No new attack surface: reuses the existing authenticated `recordVerifiedProvenance` daemon
  command (same-team peer validation). The CLI→daemon send is the same channel `goh sync`
  already uses.
- `goh attest` stays read-only (AC5) — it must not silently start writing the ledger.
- Out-of-ledger files are untouched (the feature only iterates existing ledger entries) —
  consistent with goh never making claims about files it didn't record.

## 10. Considered alternatives

- **Daemon re-stats the file on recordVerified** (no wire change) — rejected: reopens a
  TOCTOU window between the verify hash and the daemon stat. Capturing during the hash (fstat
  on the open handle) is tight; the additive-optional wire fields are cheap.
- **Add baseline to `VerifyAllReport`** — rejected: frozen report + golden `--json`. Side
  channel instead.
- **Backfill on the fast-check path** — rejected: the fast check is a heuristic; it must not
  mint a baseline from unverified bytes. Only a deep verify earns a baseline.
- **A standalone `goh trust adopt` command** to stamp current state as baseline without a
  hash — rejected: that would trust unverified bytes, defeating the point.
```
