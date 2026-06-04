---
date: 2026-05-31
feature: in-flight-adaptive-parallelism
type: acceptance-criteria
---

# Acceptance Criteria — In-Flight Adaptive Parallelism

Scope note: this engagement produces the four-round design (spec) + a benchmark-sourcing
plan, no code. These ACs define what "solved" means for the *feature*, so the spec is
written and reviewed against them. AC5 is the gating proof the seed demands.

AC1 — **Regime-aware convergence (not a fixed schedule).**
With `GOH_ENGINE_TRACE=1`, a governed download emits a per-download governor trace showing
the probe → knee → cruise phases and the converged connection count N. On a saturated
last-mile path the converged N stays low (the trace shows the governor stopping at the knee,
not climbing to 16); on a long-fat / loss-throttled path the converged N climbs above the
N=8 cold-start default. Signal: the trace lines, asserted in a controlled test/bench run —
the converged N differs by regime, proving adaptation rather than a constant.

AC2 — **No regression on already-saturated transfers.**
On the existing saturated benchmark workload (`dl.google.com`-class), the governed engine's
median wall-clock is within a ≤5% noise band of the current static-N engine across ≥5 runs.
Signal: `goh-bench` median comparison — turning the governor on never makes a saturated
download materially slower, and it converges to a low N quickly rather than wasting sockets.

AC3 — **Steady-state gating prevents oscillation.**
The pure controller never judges or removes a connection before that connection's
delivery-rate derivative has fallen below the steady-state threshold (no connection is
judged while still in TCP slow-start). Signal: a deterministic unit test feeds synthetic
rate-sample sequences (including a slow-start ramp) to the pure governor and asserts it does
not back off during the ramp — the load-bearing anti-oscillation property.

AC4 — **History unification without a format change.**
A governor-converged N is written back as a per-host bandit observation through the existing
`HostProfileStore` path, and a later cold download from the same host warm-starts N₀ from
that value. Signal: the scheduling trace shows the second download's admission reason as a
warm-start seeded by the prior converged N — achieved with `host-scheduling.plist` still at
frozen v1 (no on-disk format change; the D5/D6 observation gate is revised, not the record).

AC5 — **The win is proven on a sourced LFN / multi-edge-CDN target (gating).**
A long-fat-network / multi-edge-CDN benchmark target is sourced and documented so another
engineer can reproduce it (the current hosts throttle and mask the win). On that target, the
governed engine's median throughput is strictly higher than the static N=8 default with
non-overlapping inter-quartile ranges across ≥5 runs. Signal: the committed benchmark
artifact + `goh-bench` output showing a statistically distinguishable win. If no such target
can be sourced, the slice does not ship a performance claim — surfaced explicitly, not hidden.
