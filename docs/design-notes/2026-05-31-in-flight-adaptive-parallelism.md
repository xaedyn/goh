# Design seed — in-flight adaptive parallelism

> **Status:** design *seed*, not a contract. This has **not** been through the
> four-round design discipline and freezes nothing. It captures the reasoning for a
> future v0.2 performance slice so it isn't lost. Builds on the per-host adaptive
> scheduling bandit (PR #77) as its memory layer.
>
> **Date:** 2026-05-31. **Author context:** written after Phase 2 (per-host range
> scheduling) was implemented, in answer to "does the system pick the optimal
> connection count on a *first/only* download from a host?" — it does not.

## Problem

The shipped per-host bandit (PR #77) learns the best parallel-connection count
*across* downloads from the same host and only converges after several samples per
arm. It does nothing for:

- a **first/only** download from a host (cold start → the static default of 8), or
- the **long tail** of one-and-done downloads (the common "grab this file once"
  case), or
- **within-download** change in conditions (a competing transfer finishing, the
  server starting to throttle).

The only thing that can optimize a download you will never repeat is to **adapt the
number of connections live, during the transfer.** This note designs that
controller. Done well, it also subsumes the cold-start problem: every download
self-optimizes, and the per-host bandit just supplies a warm starting point so
repeat downloads skip the search.

## The physics — what actually caps a single-origin download

Throughput is the *minimum* of a stack of limits; which one binds decides whether
more connections help at all.

1. **Client access link** — shared across all connections. Once saturated, more
   connections only re-slice the same pie.
2. **Path bottleneck bandwidth** (peering, server egress) — BBR's "btlbw."
3. **Single-TCP-flow ceiling.** One flow delivers ≈ `window / RTT`; filling a pipe
   needs `bandwidth × RTT` (the bandwidth-delay product) in flight. A single flow
   underfills a long-fat path because:
   - **Loss-based congestion control (CUBIC/Reno):** rate ≈ `MSS / (RTT·√loss)`.
     On a high-latency path, even tiny random loss throttles one flow far below the
     link's capacity. **N *independent* flows each get their own window → ≈ N× the
     rate** until they collectively reach btlbw. *This is the entire reason
     multi-connection downloaders beat single-stream tools on long-haul transfers.*
   - Receive-window / send-buffer caps below the BDP do the same.
4. **Server-side limits:** per-connection bandwidth caps (N connections = N× up to
   a per-IP cap), per-IP caps regardless of connection count (parallelism useless),
   or active throttling/banning when one IP opens many connections (anti-leech).
5. **HTTP/2 & HTTP/3 multiplexing — the structural trap.** Many HTTP/2 *streams*
   ride **one** TCP connection with **one** congestion window, so they share the
   single-flow ceiling and buy *nothing* against a loss-throttled path. The
   window-multiplication benefit requires separate *transport connections*, not
   streams. HTTP/3/QUIC removes head-of-line blocking and has independent per-stream
   flow control, but all its streams still share one congestion controller on one
   path — same trap. This is the "amenable gap" the 3b benchmark surfaced.
6. **Multiple server IPs.** A hostname usually resolves to many edge IPs (CDN
   cluster) or is anycast. Connecting to *distinct* IPs reaches different edge
   machines and often different paths — multiplying real capacity. Almost no
   downloader exploits this; it is the biggest untapped lever.

"Optimal N" is the knee where the binding bottleneck is filled without (a) slicing
a fixed pie, (b) tripping per-IP throttling, or (c) paying setup cost that can't be
recouped. The throughput-vs-N curve is concave: rises, knees, plateaus, sometimes
declines.

## The algorithmic problem (stated honestly)

Online optimization of a **noisy, nonstationary, concave** objective with
**costly, latency-delayed, partially-irreversible** actions. Adding a connection
costs ~2 RTTs of handshake + a slow-start ramp before it reveals its steady-state
contribution — you cannot judge its effect for hundreds of milliseconds. The naïve
"+1, measure, repeat" hill-climb is therefore both too slow (one RTT-scale settle
per step) and too noisy (a single +1 can't be told from the network just speeding
up). That is why most attempts oscillate.

## The core insight

Do **not** infer the optimum from aggregate throughput alone. Watch how
**per-connection rate** and **RTT** respond when N changes — that reveals *which
bottleneck is binding*, which predicts whether more connections will help. This is
**BBR's reasoning lifted one layer up** — from "bytes in flight per connection" to
"number of connections" — using delivery rate + min-RTT inflation to find the
fill-without-queue point.

| Add connections → observe | Binding limit | Action |
|---|---|---|
| Per-conn rate **holds**, aggregate **scales** | Single-flow ceiling (loss-throttled / window-capped); parallelism multiplies | **Keep adding** |
| Aggregate **flat**, per-conn **falls ∝ 1/N**, **RTT climbs** | Shared link filled; now queuing (bufferbloat) | **Stop / back off** |
| Aggregate **flat**, per-conn **falls ∝ 1/N**, **RTT flat** | Per-IP server rate cap (not a network bottleneck) | **Stop**, remember "caps per-IP" |
| Aggregate **drops**, stalls / rate variance spike | Anti-abuse throttling tripped | **Back off hard**, stay low for this host |

The **stop condition is robust even when the cause is ambiguous**: "access link
saturated" and "per-IP cap" both show flat-aggregate + per-conn-∝-1/N, and the
action (stop) is identical; RTT inflation merely distinguishes the cause. Regime
attribution mostly governs *how aggressively to probe* and *whether to fan out to
other IPs*.

## The controller — three phases

1. **Geometric probe (find the regime in log N, not N).** Start small (N₀ = 2–4).
   Wait for **steady state** — per-connection rate derivative ≈ 0 over a window,
   **not** a fixed timer — so a connection still in slow-start is never judged.
   Then **double** N: a 2× change is trivially separable from noise, a +1 is not.
   If aggregate scales with the doubling and RTT stays near its floor, double again.
   This is slow-start applied to connection count — the knee is reached in a handful
   of steps.
2. **Knee detection.** Stop doubling when *either* marginal aggregate gain per added
   connection falls below a threshold (diminishing returns) *or* smoothed RTT
   exceeds ~1.25–2× the observed min-RTT (the bufferbloat tell). Optionally
   binary-search between last-good and overshoot. Cap at the existing **16** ceiling
   and at (distinct server IPs × small factor).
3. **Cruise + periodic re-probe (nonstationarity).** Hold the operating point;
   periodically nudge N up by one — claim bandwidth freed by a finished competing
   transfer, or detect new throttling. BBR's `PROBE_BW` cadence.

## Refinements that make it correct and differentiating

- **Steady-state gating** is the single most important correctness detail; it kills
  the "added a connection, measured before it ramped, wrongly removed it"
  oscillation that wrecks naïve implementations.
- **Multi-IP / multi-edge fan-out** — the real differentiator. Resolve all
  A/AAAA records; spread connections across *distinct* edge IPs instead of piling
  onto one. Different edges = different queues and often different paths = more
  aggregate and more resilience. Userland can't steer routing, but **choosing the
  destination IP is the one routing lever available**, and against anycast/CDN it is
  powerful. This is "mirror racing inside a single hostname."
- **Protocol-aware action semantics.** Against HTTP/2 or HTTP/3, "add parallelism"
  must mean *another transport connection*, not another stream (streams share one
  window). Many clients refuse multiple connections to one h2 host; goh should not.
  Prefer HTTP/3 for cheaper setup (0/1-RTT) so probing costs less, but judge it with
  the same throughput governor and fall back to h2 if it underperforms (the 3b trial
  showed h3 can be throttled on some paths; the per-range `protocol=` trace already
  exists to tell "h3 negotiated but slow" from "h3 didn't negotiate").
- **Setup-cost accounting.** A new connection ≈ 2 RTTs (TCP+TLS, or near-0 with TLS
  resumption / QUIC 0-RTT) before first byte, then ramp. Don't probe when
  `remaining_bytes / current_rate` is only a few seconds; tiny files use one
  connection with the governor off.
- **Good-citizen ceiling (also self-interest).** The RTT-inflation stop rule *is* a
  fairness rule — you stop where you would start hurting the shared link and other
  users, which is also where origins start banning. Keep the 16 cap; back off on
  throttle signals.
- **History seeds the search; the search trains history.** Warm-start N₀ from the
  per-host bandit profile (PR #77) when present; the converged in-flight N becomes
  the bandit observation. The two systems unify — the governor *is* the exploration
  that trains per-host memory, and memory just shortens next time's search.

## The hard constraint: what `URLSession` exposes

`URLSession` does **not** expose per-connection cwnd, per-packet RTT, or retransmit
counts. It *does* expose `URLSessionTaskTransactionMetrics` (DNS / connect / TLS /
TTFB timings, negotiated protocol, connection reuse, peer IP), and we can measure
delivered bytes/time and chunk inter-arrival ourselves. Therefore the v1 governor
must run **BBR-style on delivery-rate + coarse-RTT-from-timing + the
per-connection-scaling regime** — not on packet-level congestion signals. That is
acceptable (BBR needs no loss signal), but RTT-inflation detection will be **coarse**
(derived from chunk inter-arrival, not per-ACK).

Packet-level signal and interface/path control would require dropping to
`Network.framework`'s `NWConnection` — a much larger lift, and the transport brief
already moved *off* Network.framework (see DESIGN.md §Transport). So the
correct, shippable v1 is **delivery-rate-driven on URLSession**; `NWConnection` is a
separate, larger investigation if coarse RTT proves insufficient.

## Honest ceiling

None of this beats physics. If one connection already saturates the access link, 2
and 16 tie — the governor's value is then to *find that instantly* and not waste
sockets. If the origin caps per-IP, the governor detects it and stops. The wins
concentrate on **long-fat-network + loss-throttled-single-flow + multi-edge-CDN**
transfers — precisely large model/dataset pulls from CDNs, i.e. goh's target
workload — but it is not magic on a saturated last mile.

## Competitive positioning

- aria2 / axel / wget2 / browsers use **static, human-set or hard-capped** connection
  counts. *Any* correct online controller beats "a human picks the number" and
  adapts to mid-download change.
- Browsers cap ~6 connections/host and rarely open multiple h2 connections; goh can
  open more transport connections and fan out across edge IPs.
- The defensible, novel edges: (1) **regime-aware** fast convergence, (2)
  **multi-edge fan-out** within one hostname, (3) **history-seeded** start, (4)
  **protocol-aware** connection-vs-stream policy.

## What a real design pass must resolve

- The exact steady-state detector (window length, rate-derivative threshold) and
  how it interacts with TCP slow-start on the observed RTT range.
- The RTT-inflation threshold from coarse chunk-timing — is it a reliable bufferbloat
  signal on real paths, or does it need `NWConnection`?
- Anti-abuse safety: probing bursts (doubling) must not trip CDN leech heuristics;
  define the back-off-and-pin-low policy and how a throttled host is remembered.
- Range re-planning when the worker count changes mid-flight: chunk granularity,
  re-assigning unclaimed ranges, and interaction with the checkpoint/resume contract.
- Multi-IP fan-out: how many edges, Happy-Eyeballs-style selection, and pinning
  policy; correctness of hashing the same content fetched from different edges.
- Feedback into the bandit: is a single converged in-flight N one observation, or a
  curve? Reconcile with the frozen `host-scheduling.plist` format.
- **Benchmark sourcing (gating):** the win must be *proven* on representative
  long-fat-network / multi-edge-CDN workloads. The current benchmark hosts throttle
  and would mask it — a real, controllable LFN/CDN target (or a synthetic
  loss/latency testbed) must be sourced before this slice can claim a result.

## Considered alternatives

- **Predict optimal N upfront from headers alone** (protocol, file size, RTT) — a
  cheap heuristic warm-start, but it cannot find the server's actual tolerance point
  without measuring; useful only as an initial guess feeding the governor.
- **Per-host bandit only** (the shipped PR #77) — optimizes repeat traffic, does
  nothing for first/only downloads; this governor complements it, not replaces it.
- **Naïve +1 hill-climb** — too slow and too noisy; geometric probe + steady-state
  gating is the fix.
- **`NWConnection` for packet-level signal** — more precise, much larger lift, and
  against the transport brief; revisit only if coarse RTT proves insufficient.
