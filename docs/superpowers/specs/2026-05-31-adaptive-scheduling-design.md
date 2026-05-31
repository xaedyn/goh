---
title: Adaptive per-host range scheduling — design
phase: Strategic arc Phase 2
status: draft
round: 2 of 4 (Review — adversarial block issues addressed)
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

**Resolved sub-decisions (were Open; promoted because they are correctness/security
preconditions of the very first key the helper produces, not tunables):**
- **Credentials — strip unconditionally.** Userinfo (`user:pass@`) is removed
  before keying, always. A credential must never reach the persisted key (it would
  be written to a durable plist in cleartext). This is a hard rule, not a leaning.
- **Nil host — skip recording, never bucket.** Host extraction can yield nil
  (malformed URL, some IPv6/userinfo forms). The engine already rejects nil-host
  URLs (`URL(string:)` → `unsupportedURL`, `DownloadEngine.swift:175`), so a
  recordable (completed) download generally *has* a host — but the keying helper
  MUST still treat nil as "no key": **skip the observation entirely.** It must
  never synthesize a shared `""`/`"nil"` bucket, which would silently collapse
  unrelated hosts into one arm-set and converge the bandit to a wrong `N` with no
  error. (Selection-time nil → fall back to default 8, no profile lookup.)
- **IPv6 literals — bracketed form in the key.** Use the canonical
  `URLComponents`-bracketed host (`[2001:db8::1]`) so a literal address keys
  consistently and parses back.
- **IDN / punycode — store the ASCII (punycode) host**, so the same host keys
  identically regardless of input encoding. (Code-time detail: `URLComponents.host`
  may return the Unicode/percent-decoded form; use the encoded/punycode accessor so
  the key is stable. Does not affect the frozen format.)

**Open.**
- Scheme-in-key vs. an http→https redirect landing the same origin in two arm-sets
  — accept as harmless (each scheme genuinely behaves differently); confirm.

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

**Resolved.**
- **Filename:** `host-scheduling.plist`.
- **Corrupt-file recovery:** discard + write a `.corrupt` sidecar, matching
  `CatalogStore`/`CheckpointStore`.

**Data classification & at-rest posture (block-level — frozen on-disk format).**
The file stores, per host: the host key (scheme+host+port, credentials stripped per
D1), per-`N` throughput EWMAs, sample counts, and timestamps. The host key is
**history-adjacent metadata** (a record of which servers the user has pulled from).
- **Precedent / scope honesty.** This is *not a novel kind of data* on this machine:
  `catalog.plist` already persists the **full URL** of every download durably,
  including completed jobs (they remain in the catalog until `rm` —
  `JobStore.swift:184`), and checkpoints persist URL + destination until completion.
  The host is therefore already derivable from existing daemon state indefinitely.
  What this file *adds* is host-keyed aggregation and a bounded retention window.
- **No secrets at rest.** Credential-stripping (D1) guarantees no userinfo is keyed;
  no cookies, tokens, request bodies, or destinations are stored — only the
  origin authority and timing aggregates.
- **Permissions:** the file is daemon-internal with **no external reader**, so it is
  written **owner-only (0600)** — a deliberate tightening over the umask-default
  (~0644) that `data.write()` gives the existing catalog/checkpoint files. (Hardening
  those pre-existing files is out of scope here.)
- **Retention:** the D9 TTL is the retention control — host entries unseen for the
  TTL window are dropped on load, so the history self-expires.

### D3 — What does each per-host record store?

**Question.** Minimum fields to (a) choose an `N` and (b) keep adapting.

**Proposed answer (shape, not final Swift).**
```
HostScheduling {            // file root
  version: Int              // schema version, == 1
  hosts: [HostProfile]
}
HostProfile {
  host: String              // the D1 key (credentials stripped)
  arms: [ConnObservation]   // one per tried connection count; bounded to the
                            //   D4 candidate set (≤ its cardinality)
  updatedAt: Date
}
ConnObservation {           // one "arm" of the bandit (D4)
  connectionCount: UInt8
  throughputEWMA: Double    // bytes/sec; computed in the store as
                            //   Double(totalBytes)/seconds, then EWMA-folded
                            //   (NOT read from JobProgress.bytesPerSecond)
  sampleCount: UInt32
  updatedAt: Date
}
```
Rationale: the per-`N` `throughputEWMA` table is exactly what the adapt algorithm
(D4) needs to compare counts; `sampleCount` gates exploration.

**Frozen-surface principle (block-level — the point of the four-round pass).** The
file stores **only raw measurements** — `connectionCount`, `throughputEWMA`,
`sampleCount`, timestamps, host key. **Every *selection* knob — candidate set, ε,
α, `minSamples`, the D5 gates, the D9 TTL/cap — is a non-frozen daemon constant**,
NOT persisted. This is deliberate: tuning the algorithm later must never require a
format `version` bump. `arms` is bounded to the current candidate set's cardinality
so the structure can't grow unbounded; an arm for a `connectionCount` no longer in
the set is simply ignored at selection and aged out by D9.

**Resolved.**
- **`acceptsRanges` dropped.** The speculative `Range: bytes=0-` request detects
  206-vs-200 on *every* download already (`DownloadEngine.swift:193-210`), so a
  stored flag saves no work and only enlarges the frozen surface.

**Open.**
- Whether to additionally record last-observed file size / network class per arm to
  reduce cross-condition noise (leaning NO for v1 — the D5 duration gate + EWMA
  already reject most noise; adding it expands the frozen format).

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
- **Ceiling — RESOLVED: keep 16.** The set tops out at 16, the existing
  `maximumConnectionCount` (DESIGN §3.1), and that cap stays. Reasoning: the
  per-host connection ceiling should be governed by *server tolerance and protocol
  dynamics*, not by the client's last-mile bandwidth — and those don't loosen as
  links get faster. Past ~8–16 connections to a single host you hit diminishing-
  or-negative returns for concrete reasons: (a) servers cap concurrent connections
  per IP and treat excess as abuse (429/503, tarpit, ban — *slower or blocked*,
  not faster); (b) against an HTTP/2 origin, N TCP connections fight h2's own
  stream multiplexing and flow control (this is the documented structural gap —
  URLSession-on-h2 was the better steady-state choice on saturated hosts); (c)
  per-connection slow-start + TLS handshake overhead multiplies; (d) bufferbloat
  on the local bottleneck induces loss and latency. The real reasons parallelism
  helps at all — per-*connection* server rate limits and loss resilience on
  long-RTT/lossy paths — both saturate by ~8–16 for essentially every single host.

  **A fast pipe does not change this.** A single host is server/path-rate-limited,
  so it typically can't fill a 1 Gbps+ link no matter the connection count. The
  tool for saturating a fat pipe is **multiple independent sources at once —
  mirror racing** (already the headline v0.2 feature), not more sockets to one
  origin. Raising this cap would chase a ceiling that server limits + h2 dynamics
  make mostly unreachable while adding real risk. This phase optimizes *within*
  the 16 bound; saturating big pipes is mirror-racing's job.

### D5 — What throughput signal feeds the bandit, and how is noise rejected?

**Question.** The signal must reflect the *host's response to parallelism*, not
file size, contention, or network flaps.

**Proposed answer.** Record an observation **only when all hold**:
- the download **completed successfully** (not failed/cancelled/paused);
- the transfer ran **long enough to reach steady state** — a **duration gate, not
  a byte gate** (proposed **≥ 10 s** of active transfer). Rationale below;
- it was **the only active download to that host** for its duration (otherwise
  sibling downloads split the host's bandwidth and poison the per-`N` signal);
- the network path stayed stable (no cellular auto-pause mid-download).

**Signal & clock — RESOLVED (corrected in R2).** Signal = `Double(totalBytes) /
seconds`, computed in the `HostProfileStore` and EWMA-folded into the matching arm
(it is **not** read from `JobProgress.bytesPerSecond`, which is `UInt64` and a
sampled instantaneous rate).

`seconds` is the **transfer-phase elapsed time**. The engine already creates a
`ContinuousClock` `started` at the top of `fetchRanged` (`DownloadEngine.swift:487-488`)
and `fetchSingle` (`421-422`) — crucially **after** the speculative `Range: bytes=0-`
GET in `download()` returns, so this clock measures the parallel/single transfer
itself and **excludes** the 200/206-decision round-trip (a cleaner signal than a
whole-download clock would be). The only transient inside that window is TCP
slow-start, which at the **≥ 10 s duration gate is < ~10 % of the measured time and
is identical across arms**, so it does not bias arm-to-arm comparison.

**The required engine change (the R1 draft was wrong to claim none).** That
`started`/elapsed value is currently **phase-local and never escapes**:
`completedDownloadHandler` is `(@Sendable (JobSummary) -> Void)?`
(`DownloadEngine.swift:67`), and `clock.now - started` feeds only `progress()`
today. So the daemon **cannot** compute `seconds` from anything currently surfaced
(`completedAt − createdAt` would wrongly include queue/admission time and must NOT
be used). v1 therefore makes **one small, additive engine change**: widen the
completion sink to also carry the transfer-phase elapsed `Duration` — e.g.
`completedDownloadHandler: (@Sendable (JobSummary, Duration) -> Void)?`. This is an
**internal composition change only**; it touches no wire or on-disk contract
(`protocolVersion` stays 3, `JobCatalog.version` stays 1). The "discard the ramp
window / measure only steady state" refinement remains **deferred** — the duration
gate already makes the ramp negligible.

**Why duration, not bytes.** What we're measuring is the server's *steady-state*
response to parallelism. The first few seconds of any download are TCP slow-start
across `N` connections plus `N` TLS handshakes — a ramp transient that says
nothing about the right `N`. A measurement is only trustworthy when steady-state
transfer **dominates** that ramp, i.e. the download ran for many seconds. A fixed
byte threshold fails this test as bandwidth rises: 16 MiB finishes in ~0.13 s at
1 Gbps (all ramp, no signal), and any byte number we pick today shrinks in
relevance every year. A **duration** gate is bandwidth-proof by construction —
at 200 Mbps a 10 s transfer is ~250 MB, at 1 Gbps ~1.25 GB, at a future 10 Gbps
~12.5 GB — it always selects exactly "downloads where sustained parallelism
actually mattered," and silently ignores the rest (correctly, since for sub-ramp
downloads the connection count barely affects wall-clock anyway). A small byte
**floor** (proposed ≥ 8 MiB) is kept only to reject a degenerate stalled tiny
transfer that happens to exceed 10 s.

**Concurrent-same-host guard — RESOLVED: in scope.** Rejecting observations taken
while another download to the same host was active is **load-bearing** for signal
integrity (siblings split the host's bandwidth and would poison the per-`N`
arm). It is therefore an **in-scope component**: the `HostProfileStore` owner (D7)
keeps a small **in-memory** `[hostKey: activeCount]` index — incremented when a job
to that host starts, decremented on terminal transition. An observation is recorded
only if the host's active count was exactly 1 for the whole download (a flag the
engine path sets false if it ever observes a sibling). This index is **not
persisted** (it is live daemon state, rebuilt from the active set on restart). The
attribution arm is the **`actualConnectionCount` actually used**, not the requested
count. The increment/decrement is bracketed exactly like the engine's existing live
`control?.register(jobID:)` / `defer { control?.unregister(jobID:) }` pair in
`run` (`DownloadEngine.swift:129-130`), so it can never leak or underflow on a
throw / pause / cancel path.

**Resolved.**
- **Capped arm:** discard the observation when `actualConnectionCount < requested N`
  because `minChunk` reduced the split (small file → fewer ranges than asked) — that
  arm wasn't really exercised at the requested parallelism. (Mostly moot given the
  duration/size gate, but stated for correctness.)

**Open (tunable values only — non-frozen daemon constants per D3):**
- Duration gate value (10 s? 8 s? 15 s?) and whether the ≥ 8 MiB byte floor is kept.
- The steady-state-window refinement stays deferred (see Signal & clock above).

### D6 — Interaction with the explicit `--connections` override

**Question.** When does adaptation apply vs. honoring the user's explicit count?

**Proposed answer.** The wire request already carries `connectionCount: UInt8?`
(`nil` = "use default"). **No wire change.**
- **`connectionCount` set** → honor it exactly (user is the authority). Still
  *record* the resulting observation for that arm (free data).
- **`connectionCount` nil** → the daemon consults the host profile and picks `N`
  via D4, falling back to the default **8** when no profile exists or the chosen
  arm is still cold.

**Resolution point — RESOLVED, and it requires NO schema change.** Today
`CommandDispatcher` resolves `request.connectionCount ?? defaultConnectionCount`
(then caps it) into the non-optional `JobSummary.requestedConnectionCount` at
job-creation time (`CommandDispatcher.swift:51-72`); the engine later reads
`job.requestedConnectionCount` (`DownloadEngine.swift:477`). The change is to
**replace the constant fallback with a host-profile lookup at that same admission
point**: when `connectionCount` is nil, the dispatcher asks the `HostProfileStore`
for the bandit's chosen `N` (D4) — falling back to **8** only when there is no
profile or the chosen arm is cold — and stores *that* concrete value in
`requestedConnectionCount`. When `connectionCount` is set, it is honored unchanged.

This is deliberately the **least-invasive** wiring and it preserves the spec's
compatibility claims:
- `requestedConnectionCount` stays a resolved non-optional `UInt8` → **`JobSummary`
  and `JobCatalog.version` are unchanged (stays 1)**; the engine's connection-count
  *consumption* path is unchanged (it still reads `job.requestedConnectionCount`).
  The only engine touch in this whole phase is the small additive duration-surfacing
  in D5 — unrelated to connection-count wiring.
- **No need to persist an "adaptive vs explicit" distinction.** Observation
  recording (D5) attributes to the `actualConnectionCount` that ran, and records for
  *both* adapted and user-specified downloads — a user-chosen `N` is still valid
  data for that arm. So the choice's *origin* never needs to be remembered.
- **Accepted v1 limitation:** because `N` is resolved at admission, a job that sits
  `queued`/`network`-paused for a long time uses the profile as it was at admission,
  not at start — and a `network`-pause requeue does **not** re-run admission, so it
  keeps its admission-time `N` too. Acceptable for v1 (downloads typically start
  promptly); noted, not fixed.

**Open.** None — fully specified.

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

**Proposed answer.** EWMA (D4) handles recency of the *measurement*. For the *file*,
the **v1 mechanism is a single TTL-on-load**: drop host profiles whose `updatedAt`
is older than the TTL (proposed **90 days**) when the store loads. This doubles as
the retention control (D2). A hard host **cap is a deferred backstop**, not v1 — the
dataset is small (one tiny record per distinct host actually downloaded from), and a
second eviction policy is unwarranted until real host counts approach a limit.

**Open (tunable values only — non-frozen constants per D3).** TTL value; whether a
cap backstop is ever needed.

### D10 — Versioning / migration / protocol impact

**Question.** Compatibility surface.

**Proposed answer.** New file ships at `version = 1`. Missing file → empty set →
behaves exactly as today. Corrupt file → discard + sidecar. **`protocolVersion`
stays 3; `JobCatalog.version` stays 1.** No migration for existing installs.

**Open.** None expected.

---

## Success measurement (because the bar is "measurable adaptation")

**Positive signal (adaptation works).** Extend the `Benchmarks/` suite to run the
same host repeatedly from a cold profile and show (a) the chosen `N` converging and
(b) steady-state throughput at the converged `N` meeting-or-beating the static-8
baseline on the saturated workload, and *moving in the right direction* on the
amenable one. The amenable structural gap means the amenable result is reported,
not gated.

**Regression signal (adaptation went WRONG) — block-level, required.** Epsilon-greedy
on noisy, infrequent samples can settle on a worse arm or oscillate. There must be an
observable signal for that failure direction, not just for success:
- **Guard test:** the benchmark asserts converged-`N` throughput is **≥ static-8
  within a stated tolerance** on the saturated workload. A converged `N` that is
  measurably *slower* than the old fixed behavior is a **failing test**, not a silent
  ship. (This makes "don't regress the current behavior" an explicit, falsifiable
  scenario rather than an assumption.)
- **Per-download diagnostic:** extend `GOH_ENGINE_TRACE` to emit, per download, the
  host key, the chosen `N`, whether it was adapted-or-explicit-or-cold, and the arm
  EWMAs consulted — so a regression is diagnosable offline from a real run, not just
  in the benchmark.
- **Floor:** selection never drops below the cold-start default (8) purely on a
  single thin sample; an arm must reach `minSamples` before it can *displace* 8 as
  the exploit choice. This bounds worst-case regression from one noisy measurement.

## Test precedent to follow (from the grounding pass)

- `CatalogStoreTests` / `DownloadCheckpointTests`: round-trip save/load, missing →
  empty/nil, corrupt → recovery + sidecar, no temp file left behind, fsync
  durability. The new `HostProfileStore` mirrors these.
- `ByteRangeTests`: pure split logic. The bandit selection logic should be
  similarly pure + exhaustively unit-tested (deterministic given a seeded ε / fed
  observations).
- **Golden round-trip corpus — in-scope deliverable.** Per the trust-core
  post-mortem (a frozen on-disk format needs an explicit round-trip corpus, which
  the current catalog/checkpoint formats notably *lack*), `HostScheduling` v1 ships
  with a committed golden-fixture corpus and a CI round-trip guard. This is the one
  place this phase also pays down existing on-disk-format test debt.

## Cross-cutting status after Round 2 (adversarial review)

All four items below were resolved in this round (were Open in Round 1):
1. **D6 default-resolution** — resolved: relocate the nil→`N` fallback to the
   admission point as a host-profile lookup; no schema change, `JobSummary` and
   `JobCatalog.version` unchanged.
2. **`acceptsRanges`** — dropped (the speculative ranged GET already detects support).
3. **Frozen vs tunable** — resolved: the format persists only raw measurements;
   every selection knob is a non-frozen daemon constant (D3 frozen-surface principle).
4. **Active-job-by-host guard** — resolved: in scope, as an in-memory (non-persisted)
   `[hostKey: activeCount]` index owned by the `HostProfileStore` (D5/D7).

Remaining Opens are *tunable values only* (durations, ε, α, TTL, candidate-set
granularity) — explicitly non-frozen daemon constants to be settled empirically
against the benchmark suite, never requiring a format `version` bump.
