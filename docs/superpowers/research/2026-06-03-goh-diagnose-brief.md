---
date: 2026-06-03
feature: goh-diagnose
type: research-brief
---

# Research Brief — `goh diagnose <url>`

## Industry methodology (what shapes the probe)

- **Per-phase timing is cheap and standard.** curl's `--write-out` exposes `time_namelookup`,
  `time_connect`, `time_appconnect` (TLS), `time_starttransfer` (TTFB), `speed_download`, `http_version`,
  `num_connects`. TTFB ≈ `time_starttransfer − time_appconnect`. `httpstat` makes this readable by *labeling*
  each phase (DNS / TCP / TLS / server-processing / transfer) rather than dumping numbers. [VERIFIED:
  everything.curl.dev, Cloudflare timing blog, httpstat.py]
- **Range support must be probed, not header-sniffed.** `Accept-Ranges: bytes` is server-*declared*; RFC 7233
  §4.4 explicitly permits a server to ignore `Range` and return the full `200` body. The reliable test is to
  issue `Range: bytes=0-N` and assert `206 Partial Content`. [VERIFIED: RFC 7233 §2.3, §4.1, §4.4]
- **Throughput must exclude TCP slow-start.** A new connection starts at ~10 packets and doubles per RTT;
  short samples read far below the link's real rate. Professional speed tests use a 1.5–5s warm-up they
  *discard*, then measure a sustained window; a stable estimate needs ≥~5 MB transferred. [VERIFIED:
  ThousandEyes docs; sirupsen napkin-math slow-start example]
- **aria2c does NOT probe-and-adapt per-server connection count** (default `--max-connection-per-server` 1,
  ceiling 16; retries 503, no documented 429 path). No incumbent download tool probes connection acceptance.
  [VERIFIED: aria2 manual/manpage]
- **The bottleneck verdict is novel territory.** Comparing single-connection throughput T₁ vs N-connection
  aggregate Tₙ is the sound heuristic: Tₙ ≫ T₁ ⇒ the single stream was source/path-limited (parallelism
  helps); Tₙ ≈ T₁ ⇒ link-saturated *or* the server caps aggregate. **No shipping CLI produces an automatic
  "last-mile vs source" verdict** [UNVERIFIED — first-principles; honest gap]. Implication: the verdict string
  is new design and MUST be hedged — never claim "last-mile-limited" unless throughput failed to scale with
  added accepted connections.

## Codebase reuse seams (verified against source)

- **Diagnose lives in `GohCore/CLI/`** alongside `GohVerifyCommand`/`GohWhichCommand` (a new
  `GohDiagnoseCommand`), so it can call the **module-internal** `URLSession.streamingResponse(for:onMetrics:)`
  (`StreamingDataTask.swift:22`) directly — no access-level change. It returns
  `(HTTPURLResponse, AsyncThrowingStream<Data,Error>, cancel closure)`; read `response.statusCode` WITHOUT
  throwing on non-206.
- **Session factory `GohCore.downloadSessionConfiguration()` is public** — diagnose builds its own ephemeral
  session the same way (`Accept-Encoding: identity` is load-bearing; keep it).
- **The speculative range-probe pattern** (`DownloadEngine.download` ~240-271) is exactly the range-support
  detection diagnose needs; diagnose reimplements the status switch *without* the fatal `default: throw`.
- **Three trivial `private` helpers** are inlined/duplicated rather than widened: `request(for:job:)` (4 lines,
  only reads `job.id` for cookies), `contentRange(_:)` (parses `Content-Range: …/TOTAL`, 5 lines),
  `httpFailure(statusCode:)` (5-line status→`GohError` map). Keeping `DownloadEngine`'s surface intact.
- **Protocol metrics survive cancel.** `didFinishCollecting metrics:` (`StreamingDataTask.swift:144`) fires on
  every terminal state incl. cancellation; `metrics.transactionMetrics.last.networkProtocolName` is populated
  after a ~10s mid-stream cancel. Protocol is only available **post-hoc**, not synchronously with the response.
- **Accept/reject counting is probe-level.** URLSession exposes no count of TCP/QUIC connections actually
  opened (h2/h3 multiplex over one). The meaningful signal: fire N concurrent ranged GETs, count how many
  return `206` vs `429`/4xx. `isReusedConnection` on the transaction metrics distinguishes reuse.
- **`GohError`/`ErrorCode` are public** (`httpStatus` carries `httpStatusCode`; plus `unauthorized`,
  `dnsResolutionFailed`, `connectionFailed`, `tlsFailure`, `timedOut`, `cancelled`).

## Dependency enumeration

**No existing interface, wire type, or on-disk format is modified.** `protocolVersion` 3, `JobCatalog.version`
1, `JobSummary`, lockfile/manifest formats — all untouched. Diagnose is purely additive: a new
`GohDiagnoseCommand` in `GohCore/CLI/`, a new `ParsedCommand` case + `usage()` line in `GohCommandLine.swift`,
and a new async closure wired in `goh/main.swift` (the `doctor` pattern). The only deliberate choice is to
*inline* three tiny `DownloadEngine` privates rather than widen them — chosen to avoid growing the engine's API.

## Open risk carried into the spec

The bottleneck verdict relies on an [UNVERIFIED] heuristic with no CLI precedent. The spec must (a) define the
exact signal→verdict mapping, (b) hedge language, and (c) state the limit honestly: without a high-ceiling
reference, "link-saturated" and "server caps aggregate" are indistinguishable when Tₙ ≈ T₁ — the verdict must
say so rather than guess.
