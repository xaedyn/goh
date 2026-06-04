---
date: 2026-05-31
feature: in-flight-adaptive-parallelism
type: design-spec
status: draft (round 2)
approach: A3 — Continuous Governor + Multi-Edge Fan-Out (multi-edge via NWConnection)
protocolVersion: 3 (unchanged)
host-scheduling.plist: version 1 (unchanged)
transport-brief: REVISED — adds a hand-rolled HTTP/1.1 range client over NWConnection<TLS> for
  multi-edge IP-pinned connections (P5); the URLSession path is unchanged for all other fetches.
---

# Design Spec — In-Flight Adaptive Parallelism

> Four-round design artifact (the bandit-feed change and the transport-brief revision both invoke
> the four-round discipline). Ships a controller that adjusts parallel-connection count **live
> during a single download**, feeds its converged count back into the per-host bandit (PR #77),
> and — in its final phase — fans out across distinct CDN edge IPs over a new NWConnection HTTP/1.1
> transport. The v0.2 performance headline. Builds on, and does not modify, the frozen
> `host-scheduling.plist` v1 format or the `protocolVersion = 3` wire contract. Grounded in the
> seed `docs/design-notes/2026-05-31-in-flight-adaptive-parallelism.md`, the research brief, and
> the design-validation artifact.

## 0. Why this spec changed between rounds (decision record)

Round-1 adversarial review + a verified-API check established that **URLSession cannot present a
hostname's TLS SNI when connecting to a raw edge IP** — a documented Apple limitation
(`[VERIFIED: Apple DevForums 82179, 780602, 809811]`); a trust-delegate override does not fix it
because the failure is in the SNI byte on the wire, not in cert evaluation. The only correct
mechanism is **NWConnection** with `sec_protocol_options_set_tls_server_name` (SNI) +
`sec_protocol_options_set_verify_block` (hostname-pinned trust) `[VERIFIED: Apple Security-framework
docs; DevForums 732646]`. Per the user decision at the multi-edge gate (build the
end-state, done the way that actually works), multi-edge is **kept** and built **correctly on
NWConnection**, accepting a revision to the URLSession-only transport brief. NWConnection also yields **separate real TCP connections** (each
its own congestion window) — the structural lever that beats HTTP/2 multiplexing and closes the
amenable gap — so the correct path also strengthens the governor. Because NWConnection carries no
HTTP layer (DESIGN.md §Transport), the edge path is a **hand-rolled HTTP/1.1 range client**; this
is bounded (range GET: request line + headers, response by `Content-Length`/`Content-Range`) and
is isolated to P5 behind its own security + transport-revision review.

## 1. Problem

The shipped per-host bandit (PR #77) only optimizes *repeat* traffic and needs several samples per
arm to converge. It does nothing for a **first/only** download (cold-start → static default 8), the
**long tail** of one-and-done downloads, or **within-download** change (a competing transfer
finishing, throttling onset). The structural "amenable gap" the 3b benchmark surfaced — one TCP
flow underfills a long-fat / loss-throttled path, and HTTP/2/3 streams share one congestion window
so they don't help — is unaddressed for the common case of grabbing a large asset once. The only
thing that optimizes a transfer you will never repeat is to adapt connection count *live*, and to
reach capacity a single edge cannot give by fanning out across the CDN's distinct edge IPs over
separate TCP connections. No mainstream open downloader (aria2, axel, curl, wget2) adapts N
in-flight `[VERIFIED]`; none fans out across a hostname's edge IPs `[VERIFIED]`.

## 2. Goals & success metrics

Numbers are accept/alert thresholds for the `goh-bench` harness.

- **SM1 — Regime-aware convergence (AC1).** `GOH_ENGINE_TRACE=1` emits governor trace lines for
  probe → knee → cruise and the converged effective N. On the saturated workload converged N ≤ 4;
  on a sourced LFN target (≥80 ms RTT, loss-throttled single flow) converged N > 8. Pass = both
  across ≥5 runs.
- **SM2 — No saturated regression (AC2).** Governed median wall-clock within **≤5%** of static-N
  median across ≥5 runs on the saturated workload. Rollback trigger: >5% regression.
- **SM3 — Steady-state gating (AC3).** A deterministic unit test feeds synthetic rate-sample
  sequences (incl. a slow-start ramp) to the **pure** governor (injected clock/RNG); it never backs
  off or removes a connection while any connection's rate derivative is above threshold.
- **SM4 — History unification, no format change (AC4).** A governor-converged N (candidate-aligned,
  §6.3) is recorded through `HostProfileStore`; a later cold download warm-starts N₀ from it
  (scheduling trace `reason=warmStart`). `host-scheduling.plist` stays v1.
- **SM5a — Single-edge win on a sourced LFN target (gating headline).** On the sourced LFN target,
  governed median throughput **strictly higher** than static N=8, **non-overlapping IQR**, ≥5 runs,
  target documented & reproducible. **The slice's headline rests on SM5a** (P1–P4, URLSession).
- **SM5b — Multi-edge win (P5, best-effort).** On a true multi-edge CDN target, multi-edge median
  throughput strictly higher than single-edge governed median. If no multi-edge target can be
  sourced, SM5b is reported unproven and the slice still ships on SM5a.
- **SM6 — TLS safety on the NWConnection edge path (security gate, P5).** A connection to an edge IP
  whose served cert does not validate against the **hostname** is **rejected** by the verify block;
  a valid hostname-matching cert is accepted; an expired/untrusted/revoked chain is rejected
  (revocation set to hard-fail, §7.3). Pass = all three.

## 3. Out of scope (v1)

- **Packet-level congestion signal beyond what NWConnection exposes.** The governor runs on
  delivery-rate + coarse chunk-timing (URLSession path) and whatever NWConnection surfaces on the
  edge path; it does **not** require per-ACK cwnd/RTT.
- **HTTP/2 or HTTP/3 over NWConnection.** The edge transport is **HTTP/1.1 only** (range GETs). The
  primary/single-edge path stays on URLSession (h1/h2 as negotiated). No HPACK/QUIC hand-rolling.
- **Replacing URLSession.** URLSession remains the default transport for the primary connection and
  all non-fan-out fetches. NWConnection is added **only** for IP-pinned edge connections (P5).
- **Bandwidth budgets / calendar scheduling** — separate backlog.
- **Wire/format changes** — no `protocolVersion`, `JobCatalog.version`, `JobSummary` wire-shape, or
  `host-scheduling.plist` schema change.

## 4. Signal model

URLSession exposes neither per-ACK delivery-rate nor loss `[VERIFIED]`;
`URLSessionTaskTransactionMetrics` arrives once, post-body. The governor derives signals from
**chunk inter-arrival timing** at the engine's `flush()` chokepoint in `consumeRange`:

- **Per-connection delivery rate** `r_i` — bytes flushed ÷ elapsed, EWMA-smoothed per worker.
- **Aggregate rate** `R = Σ r_i`.
- **Coarse RTT proxy** — smoothed chunk-gap time, used only as a *ratio* vs its own observed floor
  (the bufferbloat tell), never as an absolute. On the NWConnection edge path, connect/handshake
  timing from the establishment report refines the floor estimate (advisory).
- **Steady-state flag per connection** — `|dr_i/dt|` below threshold over window W; a connection in
  TCP slow-start is **never** judged.

`ContinuousClock` becomes an **injected** parameter of `fetchRanged`/`consumeRange` (today inline at
`DownloadEngine.swift:513`) so the pure governor + instrumentation are deterministically testable
(SM3). When the RTT proxy is too noisy on a path, the knee rule falls back to **gain-only** (§5/§11).

## 5. The controller — pure value type, three phases

`ParallelismGovernor` is a pure value type: rate/RTT/worker-set samples in, a `GovernorDecision`
(`hold` / `addWorkers(k)` / `dropWorkers(k)` / `commit(n)` / `backOffPinLow`) out. Injected RNG +
clock, no I/O, exhaustively unit-tested (SM3).

1. **Geometric probe (regime in log N).** Start at N₀ (bandit warm-start when present, else 2–4).
   Wait for **steady state** (rate derivative ≈ 0 over W — not a timer), then **double** N (doublings
   stay on the bandit candidate set 2→4→8→16). Classify against the regime table:

   | On doubling N | Binding limit | Action |
   |---|---|---|
   | per-conn rate holds, aggregate scales | single-flow ceiling (loss/window) | keep doubling |
   | aggregate flat, per-conn ∝ 1/N, RTT climbs | shared link filled (bufferbloat) | stop / back off |
   | aggregate flat, per-conn ∝ 1/N, RTT flat | per-IP server cap | stop, remember per-IP cap |
   | aggregate drops, rate variance spike | anti-abuse throttling tripped | back off hard, pin low |

   The **stop condition is robust under cause ambiguity** — "link saturated" and "per-IP cap" both
   stop; RTT only attributes cause.

2. **Knee detection.** Stop when marginal aggregate gain per added connection falls below threshold
   **or** smoothed RTT exceeds ~1.25–2× its floor. An optional single binary-search step between
   last-good and overshoot may set the *operating* N to a non-candidate value (e.g. 6) — but see
   §6.3: only candidate-aligned convergence feeds the bandit. Caps: hard **16**, the global per-host
   budget (§8), and (distinct edge IPs × small factor) on the edge path (§7).

3. **Cruise + periodic re-probe.** Hold the operating point; on a BBR `PROBE_BW`-style cadence nudge
   N up by one to reclaim freed bandwidth or detect new throttling; back off on a throttle signature
   (§11). The **representative steady-state N** during cruise is the value considered for feedback.

**Setup-cost gating.** Don't probe when `remaining_bytes / current_rate` is only a few seconds;
**tiny files run at N=1, governor off.**

## 6. Engine architecture

### 6.1 Dynamic chunk pool + interval-frontier assembler (Block 2 resolution)

Today `ByteRange.split` runs once (`DownloadEngine.swift:502`) and `ChunkAssembler` captures an
immutable co-indexed range array; `currentFrontier()` (`ChunkAssembler.swift:138`) walks
`ranges.indices` in order and breaks at the first index with `written[index] < ranges[index].length`.
That order-dependent, co-indexed, break-on-first-gap walk cannot survive a dynamic queue. Replace
it with an **interval-set frontier**:

- The remaining download is a **queue of fixed-size byte-interval chunks** (chunk size a daemon
  constant, independent of N). A worker pulls one chunk at a time and fetches it with a precise
  ranged GET.
- `ChunkAssembler` is reworked to hold a **set of completed byte intervals** under its `Mutex`
  (not a co-indexed array). On each flush a worker calls `complete(interval:)`, which inserts and
  **coalesces** the interval into the set (the same merge the checkpoint layer already does for
  `completedPieces`).
- **Frontier algorithm (new):** the contiguous frontier is the end offset of the single coalesced
  interval that starts at byte 0, or 0 if none starts at 0. **In-order streamed SHA-256 invariant:**
  the hasher consumes bytes strictly in offset order; a flush only advances the hash when it extends
  the byte-0 interval. Out-of-order completed bytes sit in the interval set, durable on disk and
  checkpointed, but are **not hashed** until the frontier reaches them — identical to today's
  read-back-from-disk behaviour, generalized from "next index" to "next contiguous interval." This
  preserves the monotonic, single-pass hash with no re-hashing.
- **End-of-download condition (new):** complete when the coalesced interval set is exactly the
  single interval `[0, total)` — replacing the old `Σ fixedLength(of: index)` end-check.
- **Add a worker** = hand it the next queued chunk. **Drop a worker** = it stops pulling after its
  current chunk; any chunks it had not yet started return to the queue head (offset-ordered).
- **Checkpoint unchanged:** completed intervals map 1:1 onto `DownloadCheckpoint.completedPieces`;
  `missingByteRanges` already derives the queue's remaining work with no knowledge of N. Re-planning
  is correct on the persistence side with **zero format change** — the key enabler.

### 6.2 Live worker-pool concurrency (Block 5 resolution)

You cannot add tasks to a `withThrowingTaskGroup` from outside its closure, and the chunk queue +
global budget are shared mutable state under nonisolated-default strict concurrency. Design:

- A single **control loop runs inside the group closure.** It owns adding/reaping workers; the
  governor never touches the `TaskGroup`.
- **Shared state** is two `Mutex`-guarded values (`Synchronization.Mutex`, the project idiom): the
  **chunk queue** and an **atomic target-worker-count** the governor writes.
- The control loop interleaves: `while group has capacity and liveWorkers < target and budget
  grants a slot → group.addTask(pull-and-fetch-one-chunk)`; and `group.next()` to reap a finished
  worker, which either pulls the next chunk (re-spawn) or, if `liveWorkers > target`, exits and is
  not replaced (a **drop**). A per-worker check of `target`/cancellation after each chunk makes
  drops cooperative — a worker finishes its current chunk (so no partial-chunk loss), then exits.
- The **governor decision** is applied by writing `target` (and signalling the loop via the queue's
  condition) — never by calling `addTask` from another task. This keeps all `TaskGroup` mutation on
  one task and satisfies `Sendable`/strict-concurrency under `-warnings-as-errors`.
- Range 0's speculative `bytes=0-` stream (DESIGN.md §Transport) is preserved: range 0 is the first
  "worker" and reuses that stream; the pool fills behind it.

### 6.3 Observation-gate redesign & bandit feedback (Blocks 3 & 10 resolution)

**`actualConnectionCount` wire field (Block 3).** It stays a non-optional `UInt8` on the wire with
its **documented meaning unchanged**: *the peak number of concurrent connections the engine used*.
Under a dynamic pool that is `max(liveWorkers)` over the transfer — a true, well-defined quantity
that existing `goh top`/TUI/`ls` readers can display unchanged. `setActualConnectionCount` is
generalized to record the running max (it currently caps at `requestedConnectionCount`; that cap is
replaced by a cap at the hard ceiling 16, since the governor — not the request — now sets N). No
reader semantics change; no version bump.

**The bandit feed is a separate, internal value (Block 10).** The bandit observation does **not**
use `actualConnectionCount`. The completion sink carries a daemon-internal `Sendable` `Governor
Outcome { effectiveN: UInt8?, stabilized: Bool }`, where `effectiveN` is the **representative
steady-state operating N during cruise, and is non-nil only when that N is a bandit candidate
{2,4,8,16}**. If the governor converged off-candidate (a binary-search refinement to 6, or a
multi-edge total that isn't a candidate), `effectiveN` is `nil` and **no observation is recorded** —
the slice never injects snapped/biased values into the frozen EWMA. `shouldRecordObservation` keeps
its existing clean-measurement predicate (success; non-resume; ≥10 s; ≥8 MiB; whole-duration solo
via the existing contended set; stable path) and adds: `effectiveN != nil && stabilized`. The
on-disk v1 format and the candidate-keyed arm model are untouched; only the daemon recording logic
changes. The `shouldRecordObservation` signature change is delivered via a **parameter struct** so
the 7 existing test sites + 1 daemon site migrate mechanically. The handler-arity change (adding
`GovernorOutcome`) is in-repo (wireup + 2 tests). All feedback is daemon-internal; **no wire field.**

**Warm-start (SM4).** Admission still resolves N₀: explicit `--connections` honoured verbatim
(governor off, `.explicit`); else the bandit's best arm seeds N₀ and the governor refines live. A
recorded candidate-aligned `effectiveN` shortens next run's search — the unification is the
warm-start (memory → search) and the candidate-only feedback (search → memory).

## 7. Multi-edge fan-out over NWConnection (P5)

### 7.1 Mechanism

- **Enumerate edge IPs.** Resolve all A/AAAA records for the hostname via `getaddrinfo` (a new,
  contained userland step; URLSession resolves internally and won't expose the set). Distinct edge
  IPs of a CDN/anycast hostname reach distinct edge machines / queues / paths.
- **Pin each edge connection to an IP with correct SNI.** For an edge worker, open an
  `NWConnection(host: <edge-IP>, port: 443)` with `NWProtocolTLS.Options` where
  `sec_protocol_options_set_tls_server_name(opts, <hostname>)` sets SNI to the **hostname**
  `[VERIFIED API]`, so the CDN selects the right cert and routes to the right virtual host. Then the
  worker writes a **hand-rolled HTTP/1.1** `GET <path> HTTP/1.1\r\nHost: <hostname>\r\nRange:
  bytes=a-b\r\n…` and reads the `206` response (status line + headers, body by `Content-Range`/
  `Content-Length`). Bodies are raw (`Accept-Encoding: identity`, matching the URLSession path).
- The governor attributes rate **per edge** and caps fan-out at (distinct IPs × small factor), the
  global 16 ceiling, and the per-host budget (§8). **Single-IP hosts degrade cleanly** to the
  URLSession single-edge governor (no NWConnection path taken).

### 7.2 TLS trust — hostname-pinned (Block 1/4 resolution, SM6)

The edge `NWProtocolTLS.Options` installs `sec_protocol_options_set_verify_block` `[VERIFIED API,
DevForums 732646]` that:

- builds `SecPolicyCreateSSL(true, <hostname>)`, sets it on the peer `SecTrust`, and runs **full
  chain evaluation against the hostname** — not the IP. Accept iff the chain is valid for the
  hostname; reject otherwise (wrong-host, expired, untrusted root).
- This is correct precisely because SNI is already the hostname (7.1) and the verify block pins the
  hostname: a **DNS-poisoned or attacker-controlled edge IP cannot MITM** — the attacker cannot
  obtain a valid certificate for the real hostname. This is the entire security justification and is
  documented in DESIGN.md as part of the transport revision.
- **No debug relaxation** on this path (unlike the DEBUG-only XPC `PeerValidationMode`, which is
  unrelated). The verify block is always strict.

### 7.3 Revocation & content identity

- **Revocation hard-fail (Block 4 / A2).** The verify block adds a revocation policy
  (`SecPolicyCreateRevocation` with `kSecRevocationRequirePositiveResponse`) so a revoked cert is
  **rejected**, not soft-failed — SM6 case (c) is then real. SM6 assertions are pinned to the
  **actual** error surfaced by the verify block's rejection, captured during the P5 spike (the exact
  `URLError`/`NWError` code is recorded then, not assumed).
- **Cross-edge content identity (G5).** All edges are pinned to the **same strong resume validator**
  (ETag / Last-Modified / total — the validators already exist for resume); an edge whose validators
  differ from the first edge's is dropped. The streamed **SHA-256 is the backstop** (a Frankenstein
  file fails verification); a pinned `gohfile` hash fails closed.

### 7.4 P5 feasibility spike (gating sub-task)

P5's first task is a spike that confirms end-to-end: NWConnection to an edge IP + hostname SNI +
verify block + an HTTP/1.1 `206` range read against a real CDN, and records the exact rejection
error for SM6. **If the spike fails** (e.g. a CDN rejects mismatched IP/SNI in a way not anticipated),
multi-edge is held at P5 and the slice ships SM5a (P1–P4); the spike result is documented. The spike
does not gate P1–P4.

## 8. Global per-host connection budget (G2)

The 16 ceiling is per download. Concurrent governed downloads to one host (each possibly fanning
across edges, and the NWConnection path no longer counted by URLSession's `httpMaximumConnections
PerHost`) could open >16 sockets to one origin and trip anti-leech. Add a **daemon-global per-host
active-connection budget** (live in-memory, like the solo/contended index), enforced where a worker
acquires a connection slot across **both** transports (URLSession workers and NWConnection edge
workers count against one budget per host key). The governor requests slots; denied requests hold N.

## 9. Security surface (summary)

- **New surface (P5 only):** the NWConnection HTTP/1.1 edge client + its hostname-pinned verify
  block. Strict, no debug relaxation, revocation hard-fail. **Independently security-reviewed before
  P5 merge** (trust-core Phase 3 running-code gate is the precedent), jointly with the DESIGN.md
  transport-brief revision.
- **New attacker-influenced input:** DNS A/AAAA resolution (a poisoned resolver picks dialled IPs).
  Neutralized by §7.2 hostname-pinned validation — and *only* by it; the verify block is therefore
  load-bearing and the spike (7.4) must prove the rejection path.
- **Hand-rolled HTTP/1.1 parsing** is new attack surface on attacker-supplied response bytes: the
  parser must bound header size, reject malformed status/length, never trust `Content-Length` beyond
  the requested range, and write only within the worker's assigned interval. These are explicit P5
  requirements with adversarial parser tests.
- **Threat model otherwise unchanged:** same-user XPC peer validation untouched; no new IPC surface,
  no new user input on the command path, no new persisted secret.
- **PII:** the governor trace carries the credential-stripped host key and edge IPs only — never a
  URL, query, or userinfo (matches the existing scheduling-trace rule; edge IPs are a new trace
  category, noted in DESIGN.md per the every-decision-gets-a-paragraph rule).
- **Good-citizen / anti-leech (G8):** RTT-inflation stop = a fairness rule; back off on throttle
  signatures, remember throttled hosts for the session, bounded doublings, 16 cap + global budget.

## 10. Rollout & backward compatibility

- **No wire/format change** → no CLI/daemon skew across `brew upgrade`. The governor and the
  NWConnection path live entirely behind the unchanged `protocolVersion = 3` wire and unchanged
  catalog/checkpoint/scheduling formats.
- **Default-on with guards:** the governor runs by default; explicit `--connections N` disables it
  (`.explicit`); a **daemon kill-switch** (env/constant) forces fallback to static bandit N. SM2 is
  the no-regression guard; >5% saturated regression is the rollback trigger. **The NWConnection
  multi-edge path is additionally gated by its own constant** (off until P5 ships and its review
  passes) so P1–P4 can ship with the path dormant.
- **Mid-download daemon restart:** governor + pool state are volatile and lost; the byte-interval
  checkpoint survives → the job resumes correctly (URLSession, static N if needed). No persistent
  format is written by the governor, so there is no corruption path.
- **Phased implementation (deployment-independent, in order):**
  - **P1** — injected clock + per-chunk rate instrumentation + the pure `ParallelismGovernor`
    (SM3). No behaviour change yet.
  - **P2** — dynamic chunk pool + interval-frontier `ChunkAssembler` + live worker-pool control loop
    (§6.1/6.2), single edge, URLSession. Behaviour-equivalent to today at fixed N until the governor
    drives it.
  - **P3** — wire the governor to the pool; observation-gate redesign + candidate-only bandit
    feedback + warm-start (§6.3, SM1/SM4); `GOH_ENGINE_TRACE` governor lines.
  - **P4** — global per-host budget (§8); LFN benchmark harness + runbook; prove SM5a, SM2. **Ships
    the headline.**
  - **P5** — NWConnection HTTP/1.1 edge transport + multi-edge fan-out (§7) + SM6 + the transport-
    brief revision. Behind the feasibility spike (7.4) and a dedicated security + transport review.
  P1–P4 are independent of P5.

## 11. Edge cases

- Tiny/short files → governor off, N=1.
- Single resolved IP → URLSession single-edge governance, no NWConnection path.
- Server returns 200 (ignored Range) → existing single-connection fallback; governor off for that
  download; the new assembler handles a single `[0,total)` interval as a degenerate one-chunk queue.
- Edge fails mid-download (G3) → dropped worker; its un-started chunks re-queue (offset-ordered);
  checkpoint guarantees no lost/duplicated bytes; a failed NWConnection edge is removed from the
  fan-out set and not retried for that download.
- Concurrent probing to one host → both may read each other as throttling and back off (safe); only
  **solo** downloads record observations, so the bandit is never polluted.
- Throttle tripped (G8) → back off hard, pin low for the host for the session.
- Cross-edge validator divergence (G5) → drop the divergent edge; SHA-256 backstop.
- Coarse RTT unusable on a path → gain-only knee rule; RTT inflation becomes advisory.
- Resume of a partial → governor may run on remaining intervals, but a resumed download is excluded
  from bandit recording (existing D8 rule).
- Malformed HTTP/1.1 response on the edge path → reject the edge (bounded parser), re-queue its work.

## 12. Benchmark-sourcing plan (gating for SM5)

Current hosts (archive.org, dl.google.com) per-stream throttle and **mask** the win. Plan:

1. **Local deterministic emulation (signal-model iteration; the deterministic test path Block 8
   demanded).** macOS `dnctl` + `pfctl` (dummynet) injecting latency/loss/bandwidth on a loopback
   nginx serving a 1 GB file: `sudo dnctl pipe 1 config bw 50Mbit/s delay 150 plr 0.005` + a PF
   anchor. `ipfw` is gone; `dnctl`+`pfctl` is current `[VERIFIED tools exist]`. **macOS 26 / Apple-
   Silicon support is `[UNVERIFIED]`** → **P1 includes a verification spike**; the **confirmed
   fallback** is a Linux VM (UTM) with `tc qdisc add dev eth0 root netem delay 150ms loss 0.5%`
   `[VERIFIED tc netem semantics]`. One of the two MUST be confirmed in P1 so SM1/SM3 have a
   hermetic, deterministic gate that does **not** depend on a live third party.
2. **Real no-throttle LFN proof (SM5a headline).** `https://sin-speed.hetzner.com/1GB.bin`
   (Singapore, real ≥150 ms RTT, direct server, no per-stream throttle) `[VERIFIED endpoint]`.
   Single-edge; proves multi-connection scaling on a genuine long-fat path. SM5a's accept rule
   includes a **re-run/quarantine policy** (Advisory A3): a single anomalous run is re-run, not
   treated as a regression, so a transient host blip doesn't fail CI.
3. **Controlled stable LFN (optional).** A ~$5/mo Hetzner Singapore VPS + nginx `limit_rate` for a
   tunable, reproducible path another engineer can re-create.
4. **Multi-edge proof (SM5b, P5, best-effort).** `speed.cloudflare.com` (`__down`) is genuinely
   multi-edge (300+ PoPs) `[VERIFIED multi-edge]`; over the NWConnection HTTP/1.1 path goh controls
   the connection per edge IP, so the H2-shared-cwnd caveat that affected a URLSession approach
   doesn't apply. If it still masks the win, source a multi-region CDN-backed large file or stand up
   two-region VPS origins behind one DNS name. If unsourceable, SM5b is reported unproven; the slice
   ships on SM5a — the perf claim is never fabricated.

Each run captured by a `goh-bench` LFN subcommand (median + IQR, ≥5 runs, governed vs static N=8);
the chosen targets + exact commands committed as a runbook.

## 13. Open questions / acknowledged unverified claims

- **Coarse chunk-timing RTT as a bufferbloat signal** `[seed open Q]` — mitigated by the gain-only
  fallback (§5/§11); NWConnection establishment timing refines the floor on the edge path. If
  gain-only is insufficient on real paths, deeper NWConnection signal is the (in-transport now)
  escalation.
- **dummynet on macOS 26 / Apple Silicon `[UNVERIFIED]`** — P1 spike + confirmed `tc netem` fallback.
- **NWConnection IP-endpoint + overridden SNI + HTTP/1.1 `206` against real CDNs** — APIs are
  `[VERIFIED]` individually; the **end-to-end** behaviour against a specific CDN is proven by the P5
  spike (7.4) before multi-edge ships.
- **HTTP/2 shared-cwnd throughput model `[UNVERIFIED — structural]`** — the governor measures actual
  aggregate rate, so it adapts correctly regardless of the theoretical model.

## 14. Considered alternatives

- **A1 Probe-then-Commit** — measure regime at start, fix N once; lowest risk, no live pool. This is
  effectively P1–P3's behaviour before cruise re-probing; retained as the kill-switch fallback shape.
- **A2 single-edge continuous governor** — exactly P1–P4; the proven-headline core. Not the end state
  (no multi-edge), so it is the phase boundary that ships SM5a, not a rejected option.
- **Multi-edge on URLSession** — **rejected: verified infeasible** (no SNI override for IP
  connections, §0). Replaced by the NWConnection edge transport.
- **Multi-edge over NWConnection HTTP/2/3** — rejected: requires hand-rolling HPACK/QUIC; HTTP/1.1
  range GETs are sufficient and are the separate-TCP model that wins the amenable case.
- **Headers-only heuristic N** — can't find the server's tolerance without measuring; only a
  warm-start input, already covered by the bandit.

## 15. DESIGN.md changes this spec will require (on implementation)

- **§Transport — transport-brief revision:** add the NWConnection HTTP/1.1 range client for
  multi-edge IP-pinned connections, with the SNI-override + hostname-pinned-verify-block rationale
  and the DNS-poisoning safety argument. The URLSession-first decision stands for all other fetches;
  this is an *addition* for the one case URLSession cannot serve, not a reversal of URLSession.
- **§Persistence / §Adaptive host scheduling:** the observation gate now feeds the bandit only on
  candidate-aligned governor convergence; `actualConnectionCount` documented as "peak concurrent
  connections used." `host-scheduling.plist` stays v1.
- **§Observability:** the governor trace line + the new edge-IP trace category.
