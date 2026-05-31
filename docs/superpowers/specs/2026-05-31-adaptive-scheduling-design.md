---
title: Adaptive per-host range scheduling — design
phase: Strategic arc Phase 2
status: draft
round: 1 of 4 (Draft)
date: 2026-05-31
branch: design/adaptive-scheduling
---

# Adaptive per-host range scheduling — design (Round 1 draft)

## What this is

Phase 2 of the strategic arc. Today `goh` uses a fixed default of **8** parallel
range connections for every host (capped 16, overridable with `--connections`).
Slice 3b's competitive run showed no single static `N` is right for both workload
classes: 16 helps "amenable" hosts, hurts "saturated" ones. This design makes the
daemon **learn the best connection count per host empirically and persist it**, so
repeat downloads from a known host start at the count that performed best.

## Scope (pinned 2026-05-31)

- **In:** adaptive per-host connection-count selection, persisted in a
  daemon-owned on-disk record.
- **Out (own later pass):** HTTP/3 retry.
- **Definition of done:** *measurable adaptation* — `goh` demonstrably learns and
  persists a better connection count per host, with benchmark evidence it adapts.
  A win over `aria2c` on the amenable workload is the **goal, not a ship gate**
  (the gap is documented as structural: HTTP/2-multiplex vs N-TCP).
- **Visibility:** **internal only** — no new user-facing command; the record is
  private to `gohd`. This keeps the on-disk format easy to evolve.

## Why this needs the four-round design discipline

It freezes a **daemon-owned on-disk format**. Per `CLAUDE.md`, that gets the
four-round pass even though it carries its own `version` field and is *not* a wire
contract (`protocolVersion` stays **3**; `JobCatalog.version` stays **1**). The
exact precedent is `DownloadCheckpoint` / `CheckpointStore`
(`Sources/GohCore/Model/DownloadCheckpoint.swift`,
`CheckpointStore.swift`): a versioned, atomically-persisted, daemon-private format
that can migrate behind its own `version` without a `protocolVersion` bump.

---

## Decisions

Each decision: **Question / Options considered / Proposed answer / Open.**

### D1 — What keys a "host"?

**Question.** Adaptation is per-host. What string identifies a host so the same
server is recognized across downloads, and different servers are kept distinct?

**Options considered.**
1. Hostname only (`dl.example.com`).
2. Host + port.
3. Scheme + host + port (full normalized authority).
4. Registrable domain (fold subdomains: `example.com`).

**Proposed answer.** **Scheme + host + port, normalized** — key =
`"{scheme}://{host-lowercased}:{port}"` with default ports made explicit
(`:443` for https, `:80` for http). Rationale: `h2-over-TLS` (https) and `h1`
(http) behave differently for range parallelism, so scheme belongs in the key;
port distinguishes endpoints; we do **not** fold subdomains because CDNs route
per-subdomain and `cdn1.x.com` ≠ `cdn2.x.com` in practice. URLs are raw `String`
today (`JobSummary.url`) with no host extraction anywhere — this design adds a
single normalization helper (`URLComponents`-based) in `GohCore`.

**Open.**
- IDN / punycode hosts — normalize to ASCII (punycode) or store as-is?
- Userinfo/credentials in URL — strip before keying (yes, almost certainly).
- Is scheme-in-key over-splitting (a host served on both 80→443 redirect)?

### D2 — Where does the record live: in `catalog.plist`, or a sibling file?

**Question.** Extend the user-visible job catalog, or stand up a separate
daemon-private store?

**Options considered.**
1. Add `hosts: [HostProfile]` to `JobCatalog`, bump `JobCatalog.version` 1 → 2.
2. Separate sibling file (e.g. `host-scheduling.plist`) with its own `version`
   and a `HostProfileStore`, mirroring `CheckpointStore`.
3. Per-host files in a directory (like `checkpoints/`).

**Proposed answer.** **Option 2 — a separate sibling file** under
`~/Library/Application Support/dev.goh.daemon/`, with its own `version` field, via
a new `HostProfileStore` reusing the catalog/checkpoint atomic-write pattern
(temp → `fsync` → `rename(2)` → dir `fsync`). Rationale: host profiles are
high-churn engine *optimization telemetry* with a different lifecycle from the
user-visible job model; folding them into `catalog.plist` couples two schemas and
amplifies writes to the job catalog. Keeping `JobCatalog.version` at **1** also
means zero migration for existing installs — a missing file behaves exactly like
today (default 8). Option 3 (per-host files) is rejected for v1: host count is
small, one file is simpler; revisit only if write contention appears.

**Open.**
- Exact filename (`host-scheduling.plist`? `hosts.plist`?).
- Corrupt-file recovery: discard + write a `.corrupt` sidecar, matching
  `CatalogStore`/`CheckpointStore` (proposed yes).

### D3 — What does each per-host record store?

**Question.** Minimum fields to (a) choose an `N` and (b) keep adapting.

**Proposed answer (shape, not final Swift).**
```
HostScheduling {            // file root
  version: Int              // schema version, == 1
  hosts: [HostProfile]
}
HostProfile {
  host: String              // the D1 key
  acceptsRanges: Bool?      // last observed 206-vs-200; nil = unknown
  arms: [ConnObservation]   // one per tried connection count
  updatedAt: Date
}
ConnObservation {           // one "arm" of the bandit (D4)
  connectionCount: UInt8
  throughputEWMA: Double    // bytes/sec, exponentially-weighted moving avg
  sampleCount: UInt32
  updatedAt: Date
}
```
Rationale: the per-`N` `throughputEWMA` table is exactly what the adapt algorithm
(D4) needs to compare counts; `sampleCount` gates exploration; `acceptsRanges`
lets us skip a parallel attempt on hosts known to return `200`.

**Open.**
- Do we need `acceptsRanges` at all, given the speculative `Range: bytes=0-`
  request already detects support on every download? (Leaning: keep it only if it
  saves work; otherwise drop to reduce the frozen surface.)
- Store last-observed file size / network-class with each arm to reduce noise?
- Bound `arms` to the candidate set in D4 (so it can't grow unbounded).

### D4 — The probe-and-adapt algorithm

**Question.** How does the daemon choose `N` and converge toward the best one
given noisy, infrequent, high-variance downloads?

**Options considered.**
1. Fixed exploration schedule over a candidate set, then pick best.
2. Hill-climbing from the default (try `N ± step`, keep if better).
3. **Epsilon-greedy multi-armed bandit** over a small candidate set: mostly
   exploit the best-EWMA arm, occasionally explore another; update EWMA per
   observation.

**Proposed answer.** **Option 3 — epsilon-greedy bandit** over a fixed candidate
set (proposed `{2, 4, 8, 16}`). Choose the arm with the best `throughputEWMA`
most of the time; with probability ε (proposed ~0.15) — or whenever an arm has
fewer than `minSamples` (proposed 2) observations — explore another count. EWMA
(proposed α ≈ 0.3) decays stale measurements so the host can re-converge if its
behavior changes. Hill-climbing (2) is rejected: it gets stuck in local optima and
doesn't re-explore. Fixed schedule (1) wastes downloads re-measuring settled hosts.

**Open.**
- Candidate set: `{2,4,8,16}` vs finer `{2,4,6,8,12,16}`. Finer = better optimum,
  slower convergence.
- ε value, `minSamples`, EWMA α — all need tuning against the benchmark suite.
- Should exploration prefer *neighbors* of the current best (smoother) over
  uniform-random arms?
- Cold start: first-ever download of a host uses the default **8** (an arm in the
  set) — confirm.

### D5 — What throughput signal feeds the bandit, and how is noise rejected?

**Question.** The signal must reflect the *host's response to parallelism*, not
file size, contention, or network flaps.

**Proposed answer.** Record an observation **only when all hold**:
- the download **completed successfully** (not failed/cancelled/paused);
- total size ≥ a threshold (proposed **16 MiB**, so parallelism actually engages —
  below `minChunk × few` it's all setup noise);
- it was **the only active download to that host** for its duration (otherwise
  sibling downloads split the host's bandwidth and poison the per-`N` signal);
- the network path stayed stable (no cellular auto-pause mid-download).

Signal = `totalBytes / activeWallClock` for the ranged phase. Update the matching
arm's EWMA and `sampleCount`.

**Open.**
- Threshold value (16 MiB? 32 MiB?).
- Detecting "only active download to this host" requires the daemon to track
  active jobs by host key — new in-daemon bookkeeping (not persisted). Confirm
  this is acceptable scope.
- Do we discard observations whose `actualConnectionCount` was capped below the
  requested `N` by `minChunk` (small file → fewer ranges than asked)? (Leaning
  yes — that arm wasn't really exercised.)

### D6 — Interaction with the explicit `--connections` override

**Question.** When does adaptation apply vs. honoring the user's explicit count?

**Proposed answer.** The wire request already carries `connectionCount: UInt8?`
(`nil` = "use default"). **No wire change.**
- **`connectionCount` set** → honor it exactly (user is the authority). Still
  *record* the resulting observation for that arm (free data).
- **`connectionCount` nil** → the daemon consults the host profile and picks `N`
  via D4, falling back to the default **8** when no profile exists or the chosen
  arm is still cold.

**Open.**
- Confirm the dispatcher can still distinguish nil from set after
  `CommandDispatcher` applies `defaultConnectionCount` — today it resolves nil → 8
  early (`CommandDispatcher.swift:50-72`); adaptation needs the *unresolved* nil to
  survive to the scheduler. This likely requires moving the default-resolution
  point. **Load-bearing implementation detail — flag for Round 2.**

### D7 — Concurrency, write cadence, durability

**Question.** Many downloads complete concurrently and update shared host state.

**Proposed answer.** A single serialized owner of the in-memory host map (actor or
`Mutex`-guarded store, matching existing `*Store` types), persisting via the
atomic temp→`fsync`→`rename`→dir-`fsync` pattern. Persist **only on observation
commit** (download completion), never on progress ticks — host state changes at
most once per completed download, so write amplification is low.

**Open.** Actor vs `Mutex` (match whatever the existing stores use for
consistency). Read-through cache vs read-per-decision (leaning: load once at
daemon start, keep in memory, persist on change).

### D8 — Resume path

**Question.** Resume forces 1 connection today (`DownloadEngine.swift:297`).

**Proposed answer.** **Skip observation recording on resume** — `N=1` was forced,
not chosen, so it's not a valid signal for arm 1. Resume continues to ignore the
host profile (single-connection) in v1. Adaptive resume is explicitly out of scope.

**Open.** None expected; confirm.

### D9 — Staleness, eviction, file-size bound

**Question.** Keep the file bounded and the data fresh over months.

**Proposed answer.** EWMA (D4) handles recency of the *measurement*. For the
*file*: cap total stored hosts (proposed **256**, LRU-evict by `updatedAt`), and
drop profiles older than a TTL (proposed **90 days**) on load.

**Open.** Cap and TTL values; LRU vs LFU eviction.

### D10 — Versioning / migration / protocol impact

**Question.** Compatibility surface.

**Proposed answer.** New file ships at `version = 1`. Missing file → empty set →
behaves exactly as today. Corrupt file → discard + sidecar. **`protocolVersion`
stays 3; `JobCatalog.version` stays 1.** No migration for existing installs.

**Open.** None expected.

---

## Success measurement (because the bar is "measurable adaptation")

Round 2+ should specify the concrete experiment, but the shape: extend the
`Benchmarks/` suite to run the same host repeatedly with a cold profile, and show
(a) the chosen `N` converging and (b) steady-state throughput at the converged `N`
meeting-or-beating the static-8 baseline on the saturated workload, and *moving in
the right direction* on the amenable one. The amenable structural gap means the
amenable result is reported, not gated.

## Test precedent to follow (from the grounding pass)

- `CatalogStoreTests` / `DownloadCheckpointTests`: round-trip save/load, missing →
  empty/nil, corrupt → recovery + sidecar, no temp file left behind, fsync
  durability. The new `HostProfileStore` mirrors these.
- `ByteRangeTests`: pure split logic. The bandit selection logic should be
  similarly pure + exhaustively unit-tested (deterministic given a seeded ε / fed
  observations).
- Golden fixtures: the trust-core round-trip lesson says a *frozen on-disk format
  needs an explicit round-trip corpus*. Add one for `HostScheduling` v1.

## Open cross-cutting questions for the review rounds

1. **D6's default-resolution timing** is the one place this reaches into existing
   command flow — needs a Round 2 implementation sketch.
2. Is `acceptsRanges` (D3) worth freezing, or noise?
3. Candidate set + ε + α + thresholds (D4/D5/D9) are all tunables — decide which
   are *frozen in the format* vs *daemon constants we can change freely*. (Leaning:
   the format stores only measurements; all knobs are non-frozen daemon constants.)
4. The "only active download to this host" guard (D5) adds in-daemon host-keyed
   active-job tracking — confirm scope.
