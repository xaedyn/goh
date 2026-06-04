---
date: 2026-06-03
feature: goh-diagnose
type: approach-decision-memos
---

# Approach Decision Memos — `goh diagnose <url>`

All three approaches share the same skeleton: a standalone probe in `GohCore/CLI/GohDiagnoseCommand.swift`
that builds its own ephemeral `URLSession` (via `downloadSessionConfiguration()`), reuses the module-internal
`streamingResponse`, records each ranged-GET outcome **without aborting on non-206**, captures the negotiated
protocol post-hoc, discards all bytes, time-boxes to ~12s (`defaultDeadlineSeconds`; `--full` runs to completion), and prints a labeled
plain-English report ending in one verdict line. They differ ONLY in **how the throughput sample is taken and
therefore how strong a bottleneck verdict can be made.**

---

## APPROACH 1: Snapshot Probe

CORE IDEA
Take one honest snapshot: probe range support + protocol, then saturate with the default connection count for
the whole sample window and report what was observed — no comparison.

MECHANISM
Issue a `Range: bytes=0-` GET, inspect status (206 ⇒ range supported, extract total from `Content-Range`;
200 ⇒ ignored). Then fire N concurrent ranged GETs (N = default 8) at distinct offsets, count how many return
206 vs 429/4xx (the accept/reject signal), drain+discard bytes for ~12s while a `ByteCounter` accumulates,
exclude a 1–2s warm-up, and report aggregate MB/s. Verdict is descriptive: "range supported, h2, ~52 MB/s over
8/8 connections" or "server accepted 6/8 connections — rate-limiting" or "range not supported — single stream."

FIT ASSESSMENT
Scale fit: matches — a 10s probe, trivial load. Team fit: fits (solo, mirrors `verify`/`which`).
Operational: none (CLI-local, ephemeral session). Stack alignment: fits existing — pure reuse of GohCore.

TRADEOFFS
Strong at: simplest, fastest to ship, lowest risk, most stable throughput number (full window on N conns).
Sacrifices: cannot answer "is it my link or the source?" — it only reports the N-connection number, so AC5's
verdict is limited to "supported/not, rate-limited/not, throughput X." It can't say parallelism would help.

WHAT WE'D BUILD
`GohDiagnoseCommand` (probe + report), a `DiagnosisReport` struct (structured fields), the concurrent-range
accept/reject counter, a warm-up-excluding throughput sampler.

THE BET
Users mostly want "does this URL work well and why is it slow/failing" — descriptive observations are enough;
they don't need an automated link-vs-source verdict.

REVERSAL COST
Easy — Approach 2/3 is a superset; the comparison can be added later behind the same report struct.

WHAT WE'RE NOT BUILDING
No 1-vs-N comparison, no scaling curve, no last-mile claim.

INDUSTRY PRECEDENT
`httpstat` (descriptive labeled metrics, no verdict) [VERIFIED]. curl `-w` [VERIFIED].

---

## APPROACH 2: Comparative Probe (1→N ramp) — RECOMMENDED

CORE IDEA
One continuous transfer that *starts at a single connection*, measures its steady rate, then *ramps to N* and
measures the new aggregate — and reports whether adding connections actually increased throughput. That single
comparison is what turns observations into a real bottleneck verdict.

MECHANISM
Range probe as in Approach 1. Then: open 1 ranged connection, exclude warm-up, sample rate T₁ over a short
window; open the remaining connections to reach N, exclude a short re-warm-up, sample aggregate Tₙ; also count
206-vs-429 acceptance during the ramp. Verdict from the sourced heuristic: **Tₙ ≫ T₁** ⇒ "source/path-limited —
parallelism helps (goh will use it)"; **Tₙ ≈ T₁ and all N accepted** ⇒ "throughput didn't scale — your
connection is likely the limit, OR the server caps total bandwidth (can't distinguish without a faster
reference)"; **rejections** ⇒ "server rate-limits parallel connections." Language stays hedged per the
[UNVERIFIED] research gap. Default ~12–15s budget split across the two phases; `--full` ramps then runs to end.

FIT ASSESSMENT
Scale fit: matches. Team fit: fits. Operational: none. Stack alignment: fits — conceptually mirrors the
governor's own "did aggregate rate rise when I added workers?" logic, applied as a one-shot diagnostic.

TRADEOFFS
Strong at: actually *diagnoses* (earns the verb name); directly answers the user's real question; AC5 verdict is
meaningful and grounded in a sound, sourced heuristic. Sacrifices: each phase's throughput number is noisier
than Approach 1's (shorter windows, two warm-up exclusions); slightly longer default runtime; one real design
tension to nail in the spec — phase windows must be long enough past slow-start to be trustworthy.

WHAT WE'D BUILD
Everything in Approach 1, plus a two-phase ramped sampler (1→N on one continuous transfer) and the
signal→verdict mapping table.

THE BET
A single 1-vs-N comparison, hedged honestly, is enough signal to give a *useful and trustworthy* bottleneck
verdict for the common case — and "could not distinguish" is an acceptable, honest answer for the ambiguous one.

REVERSAL COST
Easy/Hard — can fall back to Approach 1's descriptive verdict by dropping the ramp; can grow to Approach 3's
full curve. Same report struct throughout.

WHAT WE'RE NOT BUILDING
No multi-step scaling curve / knee detection; no external high-ceiling reference download.

INDUSTRY PRECEDENT
1-vs-N comparison heuristic [SINGLE: parallel-download research]. No CLI precedent for the auto-verdict
[UNVERIFIED — the honest novelty, hedged].

---

## APPROACH 3: Scaling-Curve Probe (ramp {1,2,4,8})

CORE IDEA
Probe the full connection-scaling curve: measure throughput at 1, 2, 4, 8 connections and report the curve and
its knee — the most informative possible diagnosis.

MECHANISM
Range probe, then sequential (or staged) sampling at each rung of {1,2,4,8}, excluding warm-up at each rung,
recording rate and acceptance per rung. Report the curve ("1→28, 2→44, 4→53, 8→54 MB/s — knee at 4") and a
verdict naming the knee and whether the server rejected rungs. Essentially a one-shot, read-only mini-governor.

FIT ASSESSMENT
Scale fit: arguably overengineered for a diagnostic verb. Team fit: fits but more test surface. Operational:
none. Stack alignment: fits (closest to the governor) but most code.

TRADEOFFS
Strong at: richest data; shows exactly where returns diminish; best "10-star" answer. Sacrifices: longest
runtime (4 warm-up exclusions eat the budget — hard to fit in ~12s; realistically 20–30s or `--full`-only for
the full curve); most complexity and test surface for a feature whose job is a quick answer; risk of presenting
a noisy curve as precise.

WHAT WE'D BUILD
Everything in Approach 2, plus a multi-rung sampler, per-rung accounting, and curve/knee reporting + rendering.

THE BET
Users want the full scaling curve from a diagnostic, not just a verdict — worth the extra runtime and code.

REVERSAL COST
Hard — the most code to unwind; the multi-rung sampler is materially more complex to get statistically honest.

WHAT WE'RE NOT BUILDING
External reference benchmarking; continuous re-probing.

INDUSTRY PRECEDENT
None for a download CLI [UNVERIFIED]. Conceptually adjacent to the in-flight governor's own probe.

---

## Comparison matrix

| Criterion | A1 Snapshot | A2 Comparative (rec.) | A3 Scaling-Curve |
|---|---|---|---|
| AC1 range/protocol/throughput report | STRONG — full-window N-conn number is the most stable | STRONG — same report, slightly noisier number | STRONG — richest, but per-rung noise |
| AC2 accept/reject without abort | STRONG — counts 206 vs 429 across N | STRONG — counts during ramp | STRONG — counts per rung |
| AC3 no-range → single-stream verdict | STRONG | STRONG | STRONG |
| AC4 ~12s default / `--full` | STRONG — clean single window | PARTIAL — needs the full ~12s for two honest phases | WEAK — full curve hard to fit in ~12s |
| AC5 grounded bottleneck verdict | WEAK — descriptive only, no link-vs-source | STRONG — sound 1-vs-N heuristic, hedged | STRONG — curve + knee, but over-precise risk |
| Scale fit | STRONG | STRONG | PARTIAL — overengineered for a quick verb |
| Team fit | STRONG | STRONG | PARTIAL — more test surface |
| Operational burden | STRONG — none | STRONG — none | STRONG — none |
| Stack alignment | STRONG | STRONG — mirrors governor logic | STRONG |

**Recommendation: Approach 2 (Comparative).** It's the one that earns the name `diagnose` — it answers the
user's actual question ("is it me or the source?") with a sound, sourced heuristic, while staying honest where
the signal is ambiguous. A1 is descriptive-only (under-delivers on AC5); A3 over-delivers at the cost of fitting
the ~12s budget and materially more complexity. A2 is a strict superset of A1 and a clean subset of A3, so the
reversal cost in either direction is low.
