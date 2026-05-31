---
date: 2026-05-31
feature: in-flight-adaptive-parallelism
type: approach-decision-memos
---

# Approach Decision Memos — In-Flight Adaptive Parallelism

Three survivors along one axis: **how much engine surgery, and how much live adaptivity.**
A rejected baseline (headers-only heuristic) and the rejected `NWConnection` rewrite are noted
in the matrix, not given full memos. The seed's primary stated motivation is the **first/only
download** cold-start gap; keep that as the north star when reading these.

---

## APPROACH 1 — Probe-then-Commit ("measure the regime, fix N once") *(Recommended)*

CORE IDEA
Run a short geometric probe at the start of a download to identify the binding bottleneck
regime, commit the connection count once at the detected knee, and finish the transfer at that
fixed N — capturing the cold-start/first-only win without a live worker pool.

MECHANISM
At admission the bandit supplies a warm-start N₀ (today's behaviour). The engine starts the
download at a small N, instruments per-chunk delivery rate at the existing `flush()` chokepoint,
and waits for **steady state** (rate derivative ≈ 0 — never judging a connection still in
slow-start). It then doubles N and compares aggregate delivery rate and coarse chunk-gap RTT
against the BBR-style regime table. When the knee is reached (marginal gain below threshold, or
RTT inflated past ~1.25–2× the floor), it **commits**: it checkpoints the bytes already durable,
tears down the probe workers, and rebuilds a fresh range split over the *remaining* byte
interval at the committed N — reusing the checkpoint layer's already-N-agnostic
`missingByteRanges` machinery. From there it is an ordinary range-parallel transfer. The probe
is bounded (≤ a couple of doublings, skipped entirely when `remaining_bytes / current_rate` is
only a few seconds — tiny files run at N=1 with the governor off).

FIT ASSESSMENT
Scale fit: matches — bounded probe, one re-split, no per-download unbounded churn.
Team fit: fits — solo maintainer; reuses the resume/checkpoint path rather than inventing a pool.
Operational: no new runtime surface; `GOH_ENGINE_TRACE` gains a governor line. No wire change.
Stack alignment: fits existing — `URLSession`, `Synchronization.Mutex`, `ContinuousClock`
(made injectable), the existing `ChunkAssembler` used twice (probe slice, then remainder).

TRADEOFFS
Strong at: the seed's primary target (first/only & cold-start), lowest risk to the frozen
checkpoint/resume contract, smallest, most testable governor (the steady-state detector is
exercised in a contained phase), benchmarkable on a single LFN target.
Sacrifices: no adaptation to *mid-download* change (a competing transfer finishing, throttling
onset after commit) — it optimizes the start, not the whole timeline; the probe spends a few
seconds and a re-split RTT before reaching full speed.

WHAT WE'D BUILD
A pure `ParallelismGovernor` (rate-sample in, regime + decision out; injected RNG/clock; unit-
tested per AC3); per-chunk rate instrumentation at the `flush()` site; a one-shot "commit"
re-split that checkpoints then rebuilds the assembler over `missingByteRanges`; a redesigned
observation-feedback path that records the *committed* N (not stale `actualConnectionCount`);
a `goh-bench` LFN harness + a benchmark-sourcing runbook.

THE BET
A first/only download's binding regime is roughly stationary, so a short start-probe that fixes
N captures the large majority of the achievable win — and reusing the resume path for the
one-shot re-split avoids a core-engine rewrite. If wrong, mid-download nonstationarity leaves
material throughput on the table that only a continuous governor recovers.

REVERSAL COST
Easy. The governor is opt-in behind a flag/regime; if it underperforms, fall back to today's
static bandit N with no format or wire change. The pure governor is the substrate Approach 2
would extend, so this is not throwaway.

WHAT WE'RE NOT BUILDING
No live worker pool, no continuous re-probe, no multi-edge fan-out, no new TLS surface, no
`NWConnection`, no wire/format change.

INDUSTRY PRECEDENT
No open-downloader precedent for in-flight adaptation `[VERIFIED]`; closest is FastBioDL's
online-controller framing `[SINGLE]`. Probe-then-commit is BBR's STARTUP→DRAIN reasoning lifted
to connection count `[VERIFIED BBR structure]`.

---

## APPROACH 2 — Continuous Governor on a Dynamic Chunk Pool (full seed, single edge)

CORE IDEA
Re-architect range orchestration into a fine-grained chunk work-queue served by a dynamic pool
of workers, and let the governor add/remove workers live across the whole download with periodic
re-probing for nonstationarity.

MECHANISM
Replace the fixed N-way split with a queue of small chunks (e.g. fixed-size pieces) pulled by
workers. `ChunkAssembler` is rewritten to a byte-interval frontier over the queue rather than a
fixed indexed array. The governor runs continuously: geometric probe to the knee, then a
PROBE_BW-style cruise that periodically nudges N up by one to reclaim freed bandwidth or detect
new throttling, backing off hard on a throttle signature. Steady-state gating governs every
judgement. Checkpointing stays byte-interval based (already compatible).

FIT ASSESSMENT
Scale fit: matches and then some — handles nonstationarity today's engine can't.
Team fit: requires care — a dynamic pool + resizable assembler is the core engine's most
intricate concurrency, owned by one maintainer.
Operational: no new external surface, but a larger always-on control loop in the hot path.
Stack alignment: fits the stack but rewrites the engine's central orchestration.

TRADEOFFS
Strong at: the full seed vision minus multi-edge — adapts to mid-download change, best
steady-state on long transfers, naturally subsumes cold-start.
Sacrifices: largest blast radius on the engine; highest risk to the resume contract during the
assembler rewrite; the continuous control loop is the hardest thing to keep from oscillating.

WHAT WE'D BUILD
Everything in Approach 1, plus a chunk-queue scheduler, a rewritten interval-frontier
`ChunkAssembler`, a dynamic worker pool with safe add/drain, and the PROBE_BW cruise + back-off
state machine.

THE BET
Mid-download adaptivity and re-probing are worth rewriting the engine's core orchestration, and
the resume/hashing invariants survive that rewrite under test. If wrong, we took on core-engine
risk for a tail benefit Approach 1 mostly already captured.

REVERSAL COST
Hard. The assembler/orchestration rewrite is not behind a simple flag; reverting means restoring
the old fixed-split path wholesale.

WHAT WE'RE NOT BUILDING
No multi-edge fan-out, no new TLS surface, no `NWConnection`.

INDUSTRY PRECEDENT
Same as Approach 1; the continuous loop is closest to BBR's full PROBE_BW/PROBE_RTT cadence
`[VERIFIED structure]` and FastBioDL's online controller `[SINGLE]`.

---

## APPROACH 3 — Continuous Governor + Multi-Edge Fan-Out (full seed, the differentiator)

CORE IDEA
Approach 2 plus spreading connections across the *distinct resolved edge IPs* of one hostname —
"mirror racing inside a single hostname" — to multiply real capacity past one edge's limits.

MECHANISM
Resolve all A/AAAA records, and instead of letting `URLSession` pick one connection target,
pin workers to *distinct* edge IPs via URL-by-IP + a `Host:` override, with a new `didReceive
challenge` delegate performing a `SecTrust` evaluation against the original hostname (so an IP
URL still validates the hostname's certificate). The governor treats edges as additional
capacity axes: it fans out across edges up to (distinct IPs × small factor), capped at 16, and
attributes rate per edge.

FIT ASSESSMENT
Scale fit: highest ceiling — the only approach that beats a single edge's per-IP cap.
Team fit: requires new expertise — TLS server-trust evaluation on the daemon's most sensitive
path is exacting, security-reviewable work.
Operational: net-new attack surface (manual TLS trust), plus the hardest benchmark to source
(needs a genuinely multi-edge CDN target that doesn't collapse to H2-shared-cwnd).
Stack alignment: strains it — introduces manual certificate-trust handling goh has deliberately
never had, adjacent to the XPC peer-validation security boundary.

TRADEOFFS
Strong at: the genuinely novel, defensible differentiator; the largest possible LFN/CDN win.
Sacrifices: a new TLS-trust security surface, no production precedent to copy, content-identity
risk (different edges must serve byte-identical bytes for one SHA-256), and the most expensive,
least reproducible benchmark.

WHAT WE'D BUILD
Everything in Approach 2, plus DNS A/AAAA enumeration, per-IP request targeting with `Host:`
override, a custom `SecTrust` server-trust delegate, per-edge rate attribution, and a multi-edge
benchmark harness + cross-edge content-identity validation.

THE BET
Multi-edge fan-out is where the headline win lives, and a hand-rolled TLS-trust override on the
daemon's most sensitive path can be made safe and is worth the new surface. If wrong, we added
security risk and benchmark cost for a win Approaches 1–2 already largely delivered on
single-edge LFN paths.

REVERSAL COST
Very hard. A shipped TLS-trust delegate and DNS-pinning path are not cheaply withdrawn, and the
security surface, once added, must be maintained.

WHAT WE'RE NOT BUILDING
`NWConnection` packet-level signal (still deferred).

INDUSTRY PRECEDENT
**None** for multi-edge fan-out in open downloaders `[VERIFIED]`; Happy Eyeballs (RFC 8305)
selects one IP and cancels the rest — the opposite of fan-out `[VERIFIED]`.

---

## Comparison matrix

| Criterion | A1 Probe-then-Commit | A2 Continuous Governor | A3 + Multi-Edge |
|---|---|---|---|
| AC1 regime-aware convergence | STRONG — probe→knee→commit is exactly regime detection | STRONG — plus continuous re-probe | STRONG — plus per-edge regime |
| AC2 no saturated regression | STRONG — converges low fast, then static; smallest hot-path loop | PARTIAL — always-on loop adds oscillation risk on saturated paths | PARTIAL — same loop + fan-out overhead |
| AC3 steady-state gating (no oscillation) | STRONG — gating tested in one contained phase | PARTIAL — must hold across a continuous loop, harder to prove | PARTIAL — hardest to prove across edges |
| AC4 history unification, no format change | STRONG — records the committed N cleanly | STRONG — records converged N (curve-vs-point to resolve) | PARTIAL — per-edge N complicates the single-arm bandit model |
| AC5 win proven on sourced LFN/CDN | STRONG — single LFN target suffices | STRONG — single LFN target suffices | WEAK — needs a true multi-edge target, hardest to source |
| Scale fit | STRONG | STRONG | STRONG (highest ceiling) |
| Team fit (solo maintainer) | STRONG | PARTIAL | WEAK (TLS-trust expertise) |
| Operational burden | STRONG (no new surface) | PARTIAL (bigger hot-path loop) | WEAK (new TLS attack surface) |
| Stack alignment | STRONG | PARTIAL (engine rewrite) | WEAK (manual cert trust by the security boundary) |
| Reversal cost | Easy | Hard | Very hard |

**Rejected without a full memo:**
- *Headers-only heuristic warm start* (guess N from size/protocol/RTT) — can't find the
  server's actual tolerance without measuring; useful only as a warm-start input, already
  covered by the bandit. WEAK on every AC.
- *`NWConnection` for packet-level cwnd/RTT* — more precise signal, much larger lift, and
  against the settled transport brief (DESIGN.md §Transport). Out of scope for v1 by the seed.

## Recommendation

**Approach 1 (Probe-then-Commit).** It targets the seed's primary motivation — the first/only
download — head-on; it is STRONG on all five ACs including the gating benchmark; it avoids both
the core-engine rewrite (A2) and the new TLS security surface (A3); and its pure governor is the
exact substrate A2 would later extend, so choosing it is not a dead end. A2 becomes a clean
follow-on slice once the signal model and LFN harness are proven; A3's multi-edge fan-out — the
most novel idea but also the only one carrying new security surface and an unsourced benchmark —
should not be the slice that *introduces* the governor. Recommend shipping A1 as the v0.2
headline, with A2/A3 sequenced behind it.

## Decision (USER GATE 2)

**Selected: Approach 3 (Continuous Governor + Multi-Edge Fan-Out)** — the user chose the
end-state / most-ambitious path. A3 is the *design target*; the full A3 contract is specified
in the four-round design.

Engineering pushback recorded and accepted by the user: A3 is the only approach that introduces
**new TLS server-trust code** (a hand-rolled `SecTrust` evaluation to validate a hostname's
certificate while connecting to a raw edge IP) adjacent to the daemon's XPC security boundary —
an in-kind risk, not merely more work. De-risking carried into the spec/plan (not a scope
reduction):

1. The four-round spec covers the complete A3 end-state — governor, dynamic chunk pool,
   multi-edge fan-out, the TLS-trust mechanism, and per-edge feedback into the frozen
   `host-scheduling.plist` bandit.
2. Implementation **phases the multi-edge TLS surface last**, behind its own dedicated security
   review (the trust-core Phase 3 running-code gate is the precedent).
3. The headline performance win is **proven on a single-edge LFN target first** (so the slice
   still ships a proven v0.2 headline even if a true multi-edge benchmark cannot be sourced).

These appear as success metrics, the Security Surface section, and the plan's phase boundaries —
they do not narrow the A3 contract.
