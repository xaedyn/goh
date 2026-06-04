---
date: 2026-05-31
feature: in-flight-adaptive-parallelism
type: design-validation
---

# Design Validation — In-Flight Adaptive Parallelism (Approach 3)

## Acceptance Criteria (from Step 2.5)

- **AC1** — Regime-aware convergence: governor trace shows probe→knee→cruise; converged N stays
  low on a saturated path, climbs above the N=8 default on an LFN/loss-throttled path.
- **AC2** — No regression on saturated transfers: governed median wall-clock within ≤5% of
  static-N across ≥5 runs (`goh-bench`).
- **AC3** — Steady-state gating: pure controller never judges a connection before its
  delivery-rate derivative falls below threshold (deterministic unit test, no back-off on a ramp).
- **AC4** — History unification without a format change: governor-converged N is fed back through
  `HostProfileStore`; a later cold download warm-starts from it; `host-scheduling.plist` stays v1.
- **AC5** — Win proven on a sourced LFN/multi-edge target (gating): governed median throughput
  strictly above static N=8 with non-overlapping IQR across ≥5 runs, target documented &
  reproducible; if unsourceable, no perf claim ships.

## Dependency Enumeration

Interfaces the governor modifies, and what breaks (from Agent B):
- `completedDownloadHandler` `(JobSummary, Duration, Bool)` — `gohd/main.swift:129` (wireup),
  `DownloadEngine.swift:577` (call), 2 test closures. A signature change to carry governor
  feedback (effective N, per-edge data) breaks all three — **all in-repo, daemon-internal, no
  wire impact.** Prefer a small `Sendable` struct argument over positional growth.
- `JobSummary` — **XPC-serialized / on the wire.** Within `protocolVersion = 3` only *optional*
  additive fields are permitted; rename/retype/remove is a wire break. Governor feedback stays
  **daemon-internal** (engine → `recordObservation`); no new wire fields. `actualConnectionCount`
  keeps its wire shape; only its *meaning* is revisited internally.
- `shouldRecordObservation` (1 daemon + 7 test sites) / `recordObservation` (1 daemon + 3 test
  sites) — a new mandatory parameter breaks all sites; use a parameter struct or defaults.
- `fetchRanged` + its `TaskGroup` — private to `download()`, no external callers; the chunk-pool
  rewrite is internally contained.
- `ChunkAssembler` — the rewrite target; the checkpoint layer (`completedPieces`,
  `missingByteRanges`) is already byte-interval/N-agnostic and **does not change**.

## Questions Asked & Answers

### Zero Silent Failures
- **What happens to existing users on ship?** Every default download (no explicit
  `--connections`) runs the governor instead of the static bandit N. An explicit `--connections N`
  is honoured verbatim and **turns the governor off** (matching today's `.explicit` reason). A
  daemon kill-switch (env/constant) forces fallback to static bandit N. The governor is
  *best-effort optimization, never a correctness dependency* — same posture as the host-scheduling
  record. → AC2 is the no-regression guard.
- **Existing data / formats?** `host-scheduling.plist` stays frozen v1; `JobCatalog.version`
  stays 1; checkpoint format unchanged. The observation-gate logic changes (not the record). The
  `protocolVersion` stays 3.
- **Existing integrations / callers?** All governor feedback is daemon-internal; the only
  signature churn is in-repo (handler + observation calls). No CLI/daemon wire skew: after a
  `brew upgrade` a new daemon with an old CLI (or vice versa) still works — governor logic lives
  entirely behind the unchanged wire.
- **Partial-deploy / mid-download daemon restart?** Governor in-flight state is volatile and lost
  on restart; the byte-interval checkpoint survives, so the job resumes correctly (at static N if
  need be). No corruption path: the governor never writes the checkpoint or catalog formats.

### Failure at Scale
- **10× volume / concurrency?** The 16 ceiling is *per download*. N concurrent governed downloads
  to the same host — each fanning out to multiple edges — could open far more than 16 sockets to
  one origin and trip CDN anti-leech. → **Gap G2:** a *global per-host* connection budget across
  jobs, enforced above the per-download cap.
- **Concurrent probing interference?** Two governed downloads to one host see each other's load as
  throttling and both back off — suboptimal but safe. The existing solo/contended gate means
  **only solo downloads record observations**, so concurrent probing never pollutes the bandit.
- **External dependency (DNS / an edge) unavailable?** If DNS yields one IP, multi-edge degrades
  to single-edge cleanly. If a pinned edge fails mid-download → **Gap G3:** treat as a worker
  drop, re-queue its unclaimed bytes to surviving connections; checkpoint guarantees correctness.

### Simplest Attack
- **The TLS-trust override (A3's defining risk).** Cheapest abuse: if the custom `SecTrust`
  evaluation is wrong, an attacker who can answer at a goh-chosen IP could present a cert for a
  *different* host (or any cert) and be accepted — a TLS-verification bypass on a tool handling
  cookies. → **Gap G4 (critical):** the override must build the policy with
  `SecPolicyCreateSSL(true, <original hostname>)`, run **full chain validation against the
  hostname** (exactly URLSession's default behaviour, only with the hostname substituted for the
  IP), and **reject** wrong-host / invalid / expired certs. With correct hostname-pinned
  validation, a **DNS-poisoned edge IP cannot MITM** — the attacker cannot obtain a valid cert for
  the real hostname — which is precisely why fan-out-by-IP is safe *iff* G4 holds. The spec's
  Security Surface section owns this; a test asserting a wrong-host cert is rejected is mandatory.
- **Amplification / DoS?** goh only ever connects to the host the user is downloading from — not an
  amplifier. The 16 cap + global per-host budget (G2) + back-off-on-throttle keep it a good
  citizen. → **Gap G8:** probing bursts (doublings) must not look like a leech; define a
  back-off-and-pin-low policy and remember throttled hosts.
- **Corrupted-edge content?** Multi-edge fetches one file from several IPs; a stale/compromised
  edge could serve divergent bytes → a Frankenstein file. The final streamed SHA-256 catches it
  (verification fails), and a pinned `gohfile` hash fails closed. But without a pinned hash there's
  no expected digest. → **Gap G5:** pin all edges to the **same strong resume validator**
  (ETag/Last-Modified/total — the machinery already exists for resume); fail the edge if its
  validators diverge. Final SHA-256 is the backstop.

## Gaps Found

- **G1** — A continuous/binary-searched converged N may not be in the bandit's candidate set
  `{2,4,8,16}`; feeding arm=6 into a selector that only picks candidates is incoherent.
- **G2** — No global per-host connection budget across concurrent downloads (only per-download 16).
- **G3** — No defined edge-failure / worker-drop re-queue semantics for multi-edge.
- **G4 (critical)** — The TLS-trust override must be hostname-pinned full-chain validation, not an
  IP-based relaxation; otherwise it is a TLS bypass.
- **G5** — Cross-edge content identity is unguarded between fan-out start and final hash.
- **G6** — `actualConnectionCount == requestedConnectionCount` observation gate is semantically
  broken once N varies; "one observation or a curve" is unresolved.
- **G7** — Governor default-on needs an explicit-N opt-out and a kill-switch; AC2 is the guard.
- **G8** — Probe bursts risk CDN anti-leech; no back-off-and-pin-low / throttled-host memory.

## Fixes Applied (design decisions carried into the spec — none narrow the A3 contract)

- **G1** → Geometric probing stays on candidate-set doublings (2→4→8→16, all candidates). The
  governor climbs the candidate ladder, so the converged operating N is itself a candidate. The
  value fed back to the bandit is **candidate-only**: `GovernorOutcome.effectiveN` is non-nil ONLY
  when the converged N is a bandit candidate {2,4,8,16}; an off-candidate convergence records **no**
  observation (`effectiveN = nil`) rather than snapping to the nearest arm — so it cannot bias the
  per-host EWMA. Warm-start reads the best arm as N₀ only from actually-recorded observations.
  (Spec resolves the seed's "observation vs curve" as: record the *representative steady-state
  candidate N*, one observation, candidate-aligned; an off-candidate result records nothing.)
- **G2** → Spec adds a daemon-global per-host active-connection budget, enforced where the engine
  acquires connections; the per-download 16 ceiling remains.
- **G3** → A failed edge is a dropped worker; its unclaimed byte intervals return to the pool and
  are re-assigned; checkpoint keeps correctness. Specified in the chunk-pool section.
- **G4** → Security Surface mandates `SecPolicyCreateSSL(true, hostname)` + full chain validation +
  explicit reject tests; documents the DNS-poisoning safety argument. Multi-edge is the final,
  separately security-reviewed implementation phase (trust-core Phase 3 precedent).
- **G5** → All edges pinned to one strong validator (reuse resume validators); divergence drops
  the edge; final SHA-256 is the backstop. A pinned `gohfile` hash fails closed.
- **G6** → The observation gate is redesigned: record only when the download ran *clean* (solo,
  ≥thresholds, success, non-resume) **and** the governor reached a stable representative N; record
  that representative N, not the stale admission value. `actualConnectionCount` wire field is
  unchanged; its internal use is replaced by a governor-reported effective N.
- **G7** → Explicit `--connections N` disables the governor (verbatim, `.explicit`); a daemon
  kill-switch forces static-bandit fallback; AC2 enforces no saturated regression.
- **G8** → Define a back-off-and-pin-low policy on a throttle signature (aggregate drop / rate
  variance spike) and remember throttled hosts for the session; doublings are bounded.

**Conclusion:** No gap requires abandoning or shrinking A3. G4 is the critical one and is
resolvable with the standard hostname-pinned `SecTrust` pattern. Proceed to spec.
