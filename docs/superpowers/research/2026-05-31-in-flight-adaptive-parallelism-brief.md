---
date: 2026-05-31
feature: in-flight-adaptive-parallelism
type: research-brief
---

# Research Brief — In-Flight Adaptive Parallelism

Synthesis of Agent A (industry + benchmark sourcing) and Agent B (codebase deep-dive).
Design-influencing claims carry source tiers; `[UNVERIFIED]` items are flagged for the spec.

## Algorithmic foundation

**BBR transfers, partially.** BBR (Cardwell et al., ACM Queue 2016; `draft-cardwell-iccrg-bbr`)
drives on `max_bw` (windowed max delivery-rate) and `min_rtt`, probing up for headroom
(PROBE_BW) and periodically draining to refresh the RTT floor (PROBE_RTT) `[VERIFIED]`. The
probe-up / observe-rate / drain-to-measure structure maps directly onto a governor that
probes *connection count* instead of *bytes in flight*. What does **not** transfer: BBR's
responsiveness needs per-ACK delivery-rate and loss samples, and `URLSession` exposes
neither — only coarse byte callbacks and one post-completion metrics record `[VERIFIED]`. So
the v1 governor is **reactive on delivery-rate + chunk-inter-arrival timing**, with loss
invisible. This is consistent with the seed's stated constraint and is acceptable (BBR
itself uses no loss signal), but RTT-inflation detection is coarse.

**The novelty claim holds.** aria2 (`--max-connection-per-server`, hard-capped at 16,
chosen once from file-size ÷ `--min-split-size`), axel (`-n`), curl `--parallel`, and wget2
all fix the connection count at invocation — **none adapt N during a transfer** `[VERIFIED:
aria2 1.37 manual; curl/axel docs]`. The only published live-adaptive downloader found is
FastBioDL (arXiv:2508.05511, genomics niche) `[SINGLE]`, plus two USPTO patents on
varying-connection-count transfer `[VERIFIED]`. So "regime-aware in-flight adaptation" is
genuinely differentiating among shipping open tools.

**Why parallelism helps (and when it can't).** The Mathis single-flow ceiling
`throughput ≤ MSS / (RTT·√p)` `[VERIFIED: Mathis et al. CCR 1997; RFC 3819 §8.5]` means one
TCP flow underfills a long-fat or lossy path; N *independent* flows each get their own
window, so aggregate ≈ N× until the bottleneck binds `[UNVERIFIED — structural, well
established]`. HTTP/2 (and HTTP/3) multiplex many streams over **one** congestion window, so
streams buy nothing against this ceiling — only separate transport *connections* do. This is
the "amenable gap" the 3b benchmark surfaced. The governor's value concentrates exactly on
**long-fat-network + loss-throttled-single-flow + multi-edge-CDN** transfers; it is **not**
magic on a saturated last mile (where it should converge low, fast, and stop wasting sockets).

**Multi-edge fan-out is the unproven frontier.** Connecting to distinct A/AAAA records of one
CDN hostname has **no open-downloader precedent** `[VERIFIED — none found in aria2/axel/curl]`.
Happy Eyeballs (RFC 8305) is the closest prior art but *cancels* losers; fan-out keeps them
all `[VERIFIED]`. Pinning a connection to an IP means the TLS SNI/cert must still match the
hostname — connecting by raw IP without a server-trust override throws
`serverCertificateUntrusted` `[UNVERIFIED — from TLS first principles, confirmed by codebase:
no trust-override delegate exists]`.

## What the codebase makes easy vs. hard

- **Range split is fixed up-front** (`DownloadEngine.swift:502`); `ChunkAssembler` captures
  an immutable range array and walks the frontier by index. Any mid-flight worker change
  requires either an `addRange`/resizable assembler or a one-shot teardown-and-rebuild.
- **The checkpoint layer is already byte-interval based and N-agnostic**
  (`DownloadCheckpoint.completedPieces`, `missingByteRanges`). Re-planning at any byte offset
  is *correct* on the resume side with no checkpoint change. **The hard coupling is entirely
  in `ChunkAssembler`, not persistence** — the single most important codebase finding.
- **Current resume is sequential** ("missing intervals, one interval at a time" — DESIGN.md
  §Piece durability); parallel resume is explicitly an un-built optimization. So "commit N
  then finish the remainder in parallel" needs either parallel resume or a fresh parallel
  assembler over the remaining interval.
- **`clock` is inline-constructed** (`DownloadEngine.swift:513`), not injected — must become a
  parameter for deterministic governor unit tests (AC3).
- **Per-chunk rate has a clean chokepoint** at the `flush()` site in `consumeRange`; a
  `(bytes, timestamp)` sample fits there without restructuring.
- **`transferDuration` includes setup** for ranges 1..N-1; a first-byte→done steady-state
  duration needs the existing `firstByteSeen` timestamp surfaced.
- **The observation gate breaks under varying N.** `shouldRecordObservation` requires
  `actualConnectionCount == requestedConnectionCount`; `setActualConnectionCount` caps at the
  requested value and silently no-ops above it. The moment N varies, `actualConnectionCount`
  is stale/meaningless and the bandit feedback (AC4) is wrong — the gate must be redesigned.
- **Multi-edge needs new security surface:** URL-by-IP + `Host:` override + a `didReceive
  challenge` `SecTrust` evaluation. None exists; this is net-new attack surface on goh's most
  sensitive path.

## Dependency enumeration (zero-silent-failures input)

- `completedDownloadHandler` `(JobSummary, Duration, Bool)` — wired at `gohd/main.swift:129`,
  called `DownloadEngine.swift:577`, asserted in 2 tests. Signature change breaks all three.
- `JobSummary` is **XPC-serialized / on the wire** — within `protocolVersion = 3` only
  *optional* additive fields are allowed; rename/retype/remove is a wire break. The governor
  should keep its feedback **daemon-internal** (engine→`recordObservation`) rather than add
  wire fields.
- `shouldRecordObservation` — 1 daemon + 7 test call sites; `recordObservation` — 1 daemon +
  3 test call sites. A new mandatory parameter breaks all of them (use defaults or a struct).
- `fetchRanged` and its `TaskGroup` are private to `download()` — restructuring is internally
  contained (no external callers).

## Benchmark sourcing (gating — AC5)

The current hosts (archive.org, dl.google.com) per-stream throttle and would mask the win.
Controllable targets, by fit:

| Option | LFN | Multi-edge | Loss inject | Cost | Reproducible |
|---|---|---|---|---|---|
| macOS `dnctl`+`pfctl` (dummynet) on a local server | synthetic | no | yes | free | yes — **verify on Apple Silicon/macOS 26 first** `[VERIFIED tools exist; macOS 26 support UNVERIFIED]` |
| Linux VM + `tc netem` | synthetic | no | yes | free | yes (safest emulation) |
| Hetzner `sin-speed.hetzner.com/1GB.bin` | real | no | no | free | yes `[VERIFIED endpoint]` |
| Cloudflare `speed.cloudflare.com` | moderate | **yes** | no | free | yes — H2-shared-cwnd caveat `[VERIFIED multi-edge; SINGLE no-throttle]` |
| Self-hosted Singapore VPS + nginx `limit_rate` | real, tunable | no | via cap | ~$5/mo | yes `[VERIFIED region]` |

**Recommended harness:** `dnctl` (or a Linux-VM `tc netem` fallback if dummynet is dead on
macOS 26) for fast deterministic local iteration of the *signal model*, plus
`sin-speed.hetzner.com/1GB.bin` as the real no-throttle LFN proof for AC5. Multi-edge testing
(Cloudflare, or multi-region VPS) is deferred until/unless a multi-edge approach is chosen.

## Open risks for the spec to acknowledge
- `[UNVERIFIED]` dummynet on macOS 26 / Apple Silicon — the benchmark plan must include a
  verification step and the `tc netem` fallback.
- Coarse chunk-timing RTT may be too noisy to detect bufferbloat reliably (the seed's own top
  open question); the spec must define the knee rule's fallback when RTT signal is unusable.
- Multi-edge correctness: hashing identical content fetched from different edges assumes the
  edges serve byte-identical representations — must be validated, not assumed.
