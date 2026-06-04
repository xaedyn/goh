---
date: 2026-06-03
feature: goh-diagnose
type: design-spec
status: draft
approach: Comparative Probe (Approach 2)
---

# Design Spec — `goh diagnose <url>`

## 1. Problem

A goh user whose download is slow or failing has no way to learn *why* without reading engine trace output
(`GOH_ENGINE_TRACE`, stderr-only, developer-facing). They cannot tell whether the cause is the **source server**
(no Range support, rate-limiting parallel connections, a slow origin) or their **own link** (saturated last
mile). The engine already measures all of this internally — range support, negotiated protocol, per-connection
acceptance, delivery rate — but the signal is buried. `goh diagnose <url>` surfaces it as a self-contained,
plain-English diagnostic verb, mirroring the CLI-local `goh verify` / `goh which`. It also gives goh a buried
capability worth naming at launch (ROADMAP Phase 3/5).

## 2. Approach (Comparative Probe)

A standalone probe in `Sources/GohCore/CLI/GohDiagnoseCommand.swift` that:
1. Builds its own ephemeral `URLSession` via the public `GohCore.downloadSessionConfiguration()` (keeping
   `Accept-Encoding: identity`).
2. Reuses the module-internal `URLSession.streamingResponse(for:onMetrics:)` and inlines three trivial
   `DownloadEngine` privates (a `URLRequest` builder, a `Content-Range` parser, a status→`GohError` map) rather
   than widening the engine's surface.
3. **Records every ranged-GET outcome without aborting on non-206** (the load-bearing difference from
   `downloadRange`, which throws on the first non-206 and cancels all siblings).
4. Discards all bytes (no disk write, no temp file, no sink).
5. Measures throughput at **one connection (T₁)**, then **ramps to N (Tₙ)**, and reports whether adding
   connections increased throughput — the bottleneck verdict.
6. Time-boxes to a bounded default window; `--full` runs to completion.

It does **not** reuse `DownloadEngine.run()` (which requires a `JobStore`/`JobSummary` and aborts on non-206).

### 2.1 Probe algorithm

All timing uses a monotonic `ContinuousClock` (never wall-clock), matching the engine. Every connection keeps
its own running byte counter (bytes are discarded after counting). Throughput over an interval is measured by
snapshotting the relevant counter(s) at the interval's start and end instants and dividing the byte delta by the
elapsed seconds — chunk-straddle is a non-issue because only the boundary snapshots matter.

**Phase 0 — Reachability + Range probe.** Issue `GET` with `Range: bytes=0-`, registering the `onMetrics`
callback (it fires at connection termination — see *Protocol capture* below). Inspect the *synchronously
available* `HTTPURLResponse.statusCode`:
- `206 Partial Content` → Range **supported**. Parse `Content-Range: bytes 0-…/TOTAL`. If the total is present
  and parseable, record `totalBytes`. If the header is **absent or unparseable** (the engine's `contentRange`
  returns nil), record `rangeSupported = true, totalBytes = nil` and **skip Phase 2** — offsets can't be chosen
  safely without the size; overlapping ranges would double-count.
- `200..<300` → server **ignored** Range (`rangeSupported = false`). Single-stream only; Phase 2 skipped.
- `401` / `403` → `authRequired` ("requires authentication").
- other `4xx`/`5xx` → `httpError(status)` (print the status).
- transport error (DNS/connect/TLS/timeout) → `unreachable(GohError)`.

**Typed termination drives exit codes (never `verdictText`).** The probe returns
`(DiagnosisReport, ProbeTermination)` where `enum ProbeTermination { case diagnosed; case unreachable(GohError);
case httpError(Int); case authRequired }`. The command maps termination → exit code (`diagnosed`→0,
`unreachable`→2, `httpError`→3, `authRequired`→4) — it does NOT inspect the human `verdictText` (which is
unfrozen prose, §2.5). A `DiagnosisReport` is still produced in every case (best-effort fields; `reachable=false`
on `unreachable`) to honor the always-report guarantee and feed `--json`. Malformed-URL/usage (exit 64) is
caught at the command's arg-parse layer *before* the probe runs — the probe is only reached with a parseable
absolute URL.

**Phase 1 — Single-connection sample (T₁).** Drain the open Phase-0 stream, discarding bytes. From first byte,
wait `warmupSeconds` (discarded slow-start), snapshot the counter, wait `sampleWindowSeconds`, snapshot again:
`T₁ = (snap₂ − snap₁) / sampleWindowSeconds`. If the stream reaches EOF before `warmupSeconds + sampleWindowSeconds`
elapse AND fewer than `minSampleBytes` were received, mark `singleConnMBps = nil` (insufficient).

**Phase 2 — Ramp to N (Tₙ).** Runs only when `rangeSupported`, `totalBytes != nil`, and `N ≥ 2`. Split
`[0, totalBytes)` into N contiguous parts; open `N−1` additional ranged GETs, each requesting
`bytes=partStart-partEnd`. Record per-connection acceptance from each response status: `206` → accepted;
`429`/any-other-non-206 → rejected, the status counted in `rejections` (a rejection does NOT throw, cancel
siblings, or abort the probe). All accepted connections (including conn 0) then drain concurrently. After a
`rampWarmupSeconds` settle, snapshot the **sum** of all accepted connections' counters, wait `sampleWindowSeconds`,
snapshot again: `Tₙ = (Σsnap₂ − Σsnap₁) / sampleWindowSeconds`. T₁ and Tₙ are measured in **disjoint time
windows** (conn 0 appears in both windows but is never double-counted within one window). If a connection drops
mid-window its counter simply stops advancing and Tₙ is the surviving aggregate; if the aggregate delta <
`minSampleBytes`, mark `multiConnMBps = nil`.

**`attempted` / `accepted` are precisely defined as total *connection attempts*, conn 0 inclusive.**
`attempted = N` (the N connections diagnose tried to run concurrently — conn 0, the Phase-0 `bytes=0-` probe,
counts as attempt #1; Phase 2 opens the other `N−1`). `accepted` = how many of those N returned `206` — conn 0
always counts as accepted (Phase 0 already saw its 206), plus each Phase-2 range that returned 206. So a server
allowing only the first connection and 429-ing the rest reports `accepted = 1 of N` (correct: one usable
connection). The aggregate Tₙ overlaps conn 0's open-ended range with the bounded Phase-2 ranges — harmless,
since all bytes are discarded and only delivery *rate* is measured. This definition is pinned by a test
(server accepts conn 0, rejects all Phase-2 ranges → `accepted == 1`, `rateLimited`).

**Protocol capture.** `networkProtocolName` (h3/h2/http1.1) is delivered ONLY post-hoc, via the `onMetrics`
callback that fires when a connection reaches a terminal state (cancel or EOF) — it is **NOT** available at
Phase-0 header time. The report is assembled after all connections terminate, so the value is in hand by then.
It is `String?`: when nil (served from cache, metrics absent), the report shows protocol = "unknown" and the
verdict takes the conservative multiplexed branch (§2.3).

**Time-box.** A global `defaultDeadlineSeconds` deadline bounds default mode; per-connection connect/idle
timeouts bound each connection. On the deadline, sampling stops and the report is produced from whatever was
measured. With `--full`, after the Tₙ window the probe keeps draining all connections to EOF and additionally
reports `wholeFileMBps` (still discarding bytes); the comparative verdict still comes from the early 1→N ramp.

**Guaranteed termination + always-report.** The probe ALWAYS terminates (deadline + timeouts) and ALWAYS prints
either a full report or a clear "diagnosis incomplete" message with the partial findings gathered. It never
hangs, never crashes, never prints a throughput number it could not measure (nil → "insufficient data," not 0).

### 2.2 Tunable constants (daemon-side defaults; not user-exposed in v1 except where noted)

| Constant | Default | Rationale |
|---|---|---|
| `targetConnections` (N) | 8 | matches engine default; user override via `--connections`/`-c`, clamped 1–16 |
| `warmupSeconds` | 1.5 | discard TCP slow-start (research: 1.5–5s warm-up standard) |
| `sampleWindowSeconds` | 4.0 | steady-state window per phase |
| `rampWarmupSeconds` | 1.0 | settle after opening the extra connections before the Tₙ window |
| `defaultDeadlineSeconds` | 12 | ≈ Phase0(0.5) + warmup(1.5) + window(4.0) + rampWarmup(1.0) + window(4.0) + slack; bounds default mode and is the value AC4 asserts against |
| `minSampleBytes` | 8_000_000 (8 MB) | below this a throughput estimate is unreliable (slow-start not cleared) |
| `scalingFactor` | 1.3 | Tₙ ≥ scalingFactor × T₁ ⇒ "throughput scaled" (heuristic; documented) |
| per-connection connect timeout | 10s | unreachable host fails fast |

Throughput is reported in **MB/s, decimal** (bytes ÷ 1e6 ÷ seconds) everywhere; `minSampleBytes` is a
decimal-MB byte count to match (no MB/MiB mixing).

These constants live in an injectable `DiagnoseConfig` (default = this table) so tests can shrink them (§3). The
per-connection connect/idle timeout is applied on diagnose's **own** copy of the session config (the value from
`downloadSessionConfiguration()` is mutated: `timeoutIntervalForRequest`), since the shared factory sets none.

### 2.3 Verdict mapping (hedged — no claim beyond the evidence)

Exactly one verdict, selected by a **pure function** `verdict(report) -> Verdict` (unit-tested exhaustively),
evaluated in this order:

1. `insufficientData` — `singleConnMBps == nil`: "File too small or too few bytes sampled to estimate throughput
   reliably." (Still reports range support, protocol, acceptance.)
2. `rangeUnsupported` — `rangeSupported == false`: "Server ignores Range — single connection only; extra
   connections won't help. ~T₁ MB/s."
3. `rangeSupportedSizeUnknown` — `rangeSupported == true, totalBytes == nil`: "Range supported, but the server
   didn't report a size, so parallelism couldn't be tested. ~T₁ MB/s."
4. `rateLimited` — Phase 2 ran and `accepted < attempted`: "Server rate-limits parallel range requests (accepted
   M of N). goh is limited to ~M here. ~bestObserved MB/s." — where `bestObserved = max(singleConnMBps ?? 0,
   multiConnMBps ?? 0)`, computed by `verdict()` from existing report fields (it is NOT a stored field).
5. `scaled` — Phase 2 ran, all accepted, `Tₙ ≥ scalingFactor·T₁`: "Throughput scaled with more connections — the
   source/path is the limit and parallelism helps (goh uses up to N). ~Tₙ MB/s at N connections."
6. `didNotScaleMultiplexed` — Phase 2 ran, all accepted, `Tₙ < scalingFactor·T₁`, **and protocol is h2/h3 or
   unknown**: "Throughput didn't increase, but over HTTP/2/3 parallel range requests share one connection, so
   this test can't tell whether your link or the source is the limit. ~Tₙ MB/s. (goh's multi-connection
   speedups apply to HTTP/1.1 origins.)"
7. `didNotScaleHTTP1` — Phase 2 ran, all accepted, `Tₙ < scalingFactor·T₁`, **and protocol is http/1.1**: "Adding
   real parallel connections didn't increase throughput — either your own connection is the limit or the server
   caps total bandwidth per client; these can't be told apart without a faster reference. ~Tₙ MB/s."

**The h2/h3-vs-http1.1 split is load-bearing.** Only over HTTP/1.1 does URLSession open N *separate* TCP
connections (N congestion windows), making the link-vs-server-cap dichotomy meaningful. Over h2/h3, N range
requests multiplex onto ~one connection (one congestion window), so `Tₙ ≈ T₁` is expected *regardless* of link
or source — asserting a link/server-cap cause there is a confidently-wrong verdict. The `didNotScaleHTTP1` branch is
selected ONLY when `networkProtocol == "http/1.1"` exactly; **any other value — `nil`/"unknown", "h2", "h3", or
an unexpected ALPN string such as "http/1.0" — falls to the conservative `didNotScaleMultiplexed` branch by
design** (`networkProtocolName` returns Apple-defined ALPN identifiers, so the http1 branch is allow-listed, not
deny-listed). The report always calls these "parallel range requests" (not "TCP connections") and shows the
negotiated protocol beside the connection counts.

### 2.4 CLI surface

```text
goh diagnose <url> [--full] [--json] [--connections N | -c N]
```
- `<url>` — required; malformed → exit 64.
- `--full` — drain to completion (report whole-file average too); default is the bounded sample.
- `--json` — machine-readable `DiagnosisReport` (the same structured data; for scripting / trust-layer reuse).
- `--connections N` / `-c N` — ramp target, clamped 1–16 (default 8).

Human output (default) is a labeled block: URL, server reachable, Range support, protocol, connections
attempted/accepted, T₁, Tₙ (or whole-file with `--full`), then the one verdict line. `--json` emits the
`DiagnosisReport` struct.

### 2.5 Structured result (`--json` contract)

`DiagnosisReport` is a `Codable, Sendable` value type. It is diagnose-local (NOT `EngineDiagnostics`, which stays
stderr-only; NOT any XPC wire type), but because `--json` is meant for capture it carries an explicit
`reportVersion` and is treated as a small *versioned output contract*.

| Field | Type | Semantics |
|---|---|---|
| `reportVersion` | `Int` | `1` for v1 |
| `url` | `String` | the URL as supplied (may contain query strings — see §5) |
| `reachable` | `Bool` | false only on transport failure (the process has then already exited non-zero) |
| `rangeSupported` | `Bool` | 206 to the Range probe |
| `totalBytes` | `UInt64?` | nil if 206 carried no parseable `Content-Range`, or range unsupported |
| `networkProtocol` | `String?` | "h3"/"h2"/"http/1.1"; nil → rendered "unknown" |
| `attempted` | `Int` | N when Phase 2 ran; 1 otherwise |
| `accepted` | `Int` | count of 206 responses across attempted requests |
| `rejections` | `[String:Int]` | reason-string → count: HTTP statuses as their number string (e.g. `{"429": 6}`), plus the literal key `"transport"` for connection-level failures during the ramp. **Must be `[String:Int]`**, not `[Int:Int]` (which Codable encodes as a JSON array, not an object) |
| `singleConnMBps` | `Double?` | T₁ in decimal MB/s; nil = insufficient sample |
| `multiConnMBps` | `Double?` | Tₙ in decimal MB/s; nil = Phase 2 didn't run, or insufficient |
| `wholeFileMBps` | `Double?` | only with `--full`; nil otherwise |
| `verdict` | `Verdict` | the enum case (its raw string) — see below |
| `verdictText` | `String` | the rendered human sentence |

`enum Verdict: String, Codable` cases: `insufficientData`, `rangeUnsupported`, `rangeSupportedSizeUnknown`,
`rateLimited`, `scaled`, `didNotScaleMultiplexed`, `didNotScaleHTTP1`. **The `verdict` enum raw values and the
field names/types above are the frozen v1 `--json` contract; `verdictText` is a human display string and is
explicitly NOT frozen** (copy edits to the sentence are not contract changes). `reportVersion` bumps only if a
field name/type or an enum raw value changes.

### 2.6 Wiring (additive) — and the async→sync bridge

New `ParsedCommand.diagnose(url:full:json:connections:)` case + `usage()` line in `GohCommandLine.swift`, plus a
closure injected via `GohCommandLine.init` exactly like `doctor`.

**The CLI is fully synchronous.** `GohCommandLine.run()` (`GohCommandLine.swift:45`) returns
`GohCommandLineResult` synchronously; the `Doctor`/`Top`/`Foreground` typealiases (lines 18-20) are all
synchronous `() throws -> GohCommandLineResult`; `Sources/goh/main.swift` ends in a synchronous `.run()` with no
`await`/`Task`. There is **no** async entry point and the `doctor` pattern is itself synchronous — so diagnose
must present a **synchronous** face. The async URLSession probe is therefore bridged to that synchronous boundary
**inside** `GohDiagnoseCommand`, using a `DispatchSemaphore` blocking runner (the same primitive
`GohForegroundDownload.swift:46` already uses): a `Task` runs the async probe to completion and signals the
semaphore; the synchronous `run` waits on it and returns the result. Consequently `run()`, the closure
typealias, and `main.swift` all stay synchronous and unchanged in shape — diagnose reuses the existing
`doctor`-style synchronous closure wiring with the async fully encapsulated. `GohDiagnoseCommand` returns the
standard `GohCommandLineResult { exitCode, standardOutput, standardError }`.

## 3. Success metrics

The five acceptance criteria (`…-acceptance-criteria.md`) are the measurable definition of done. Testability
rests on **separating pure logic from I/O**:
- **Pure, exhaustively unit-tested (no network):** `verdict(report) -> Verdict` (every case, incl. both
  `didNotScale*` branches and the unknown-protocol → multiplexed fallback) and `rate(byteDelta:over:) -> Double`
  (decimal MB/s). These carry the load-bearing logic.
- **Integration-tested with an in-process stub `URLProtocol`** (deterministic in CI, no real network): AC2 drives
  206-on-conn-0 + 429-on-some-ranges → asserts `accepted < attempted`, the `rejections` map, and that the probe
  *completed without aborting/throwing*. AC3 drives a 200 (Range ignored) → `rangeSupported == false` +
  `rangeUnsupported` verdict. Auth/HTTP-error/transport paths drive 401/404/connection-failure → assert exit
  4/3/2.
- **Throughput value (AC1):** exact MB/s is covered ONLY by the pure `rate(byteDelta:over:)` unit test. The
  *integration* test asserts a throughput number is produced and **non-nil** (and that the right report fields
  are populated) — it does NOT assert an exact MB/s, because `MockURLProtocol` delivers the body in one (or a
  few `usleep`-paced) chunks and cannot be made to yield bytes in lockstep with the sampler's clock. We do not
  claim a deterministic exact-rate integration test; the load-bearing rate math lives in the pure unit test, and
  verdict selection is proven by feeding synthetic `T₁`/`Tₙ` into the pure `verdict()` test.
- **Time-box (AC4):** the timing constants in §2.2 are **injectable** via a `DiagnoseConfig` (default = the
  table). Tests construct a `DiagnoseConfig` with shrunk values (e.g. deadline 0.5s, windows 0.1s) and assert,
  against a never-ending stub, that default mode returns within a bound proportional to the injected deadline,
  and that `--full` drains to the stub's EOF. This uses the real `ContinuousClock` with tiny durations — fast and
  a bounded (not exact) assertion — mirroring the engine's injectable-`chunkSize` test idiom.

"Done" = all five ACs pass as Swift Testing cases under `-warnings-as-errors` on `macos-26`, with no real-network
dependency.

## 4. Out of scope (v1 non-goals)

- **Sending cookies/credentials** during the probe — diagnose is a throwaway probe; auto-sending the user's auth
  cookies is a needless leak risk. Auth-required URLs are reported as "requires authentication" (exit 4). A
  `--cookies`/auth opt-in is deferred.
- **Scaling curve / knee detection** (Approach 3) — single 1→N comparison only.
- **Multi-edge / NWConnection** probing (that's the dormant P5 transport work).
- **A daemon-side or persisted diagnostic history** — diagnose is stateless and CLI-local.
- **External high-ceiling reference benchmarking** to disambiguate link-vs-server-cap — hence the hedged
  "can't be told apart" verdict.
- **Modifying `EngineDiagnostics`** to retain structured data — diagnose uses its own `DiagnosisReport`.

## 5. Security surface

- **New user-controlled input:** the `<url>` argument only — identical trust posture to `goh add`/`curl`; goh is
  a local CLI run as the user, not a server, so there is no new SSRF exposure beyond what `curl` already is.
- **No new auth/authz path, no endpoint, no daemon/XPC surface, no privilege.** Diagnose runs entirely
  in-process as the invoking user.
- **No disk writes** (bytes discarded in-stream) — diagnose has none of `download`'s path-traversal/symlink
  surface; it cannot create or follow files.
- **No credentials transmitted** (cookies off by default).
- **PII / sensitive URLs:** the `<url>` may carry sensitive query strings (signed tokens). **diagnose itself**
  writes nothing to disk and transmits the URL only as the HTTP request to the host being diagnosed and as its
  own stdout; it does not redact (the user supplied the URL and needs to see what was diagnosed). With `--json`,
  stdout is explicitly *designed for capture* by other tooling — **handling any sensitive query string in the
  echoed `url` field is the consumer's responsibility.** The no-persistence guarantee covers diagnose's own
  behavior, not what a downstream script does with the JSON it is handed.
- **Resource:** discards bandwidth for ~`defaultDeadlineSeconds` (12s) default (user-initiated, time-boxed);
  `--full` is explicitly proportional and documented.

## 6. Rollout

- **Purely additive**, no migration, no schema/wire change (`protocolVersion` 3, `JobCatalog.version` 1,
  `JobSummary`, lockfile/manifest formats all untouched). No feature flag needed — a new verb is invisible until
  invoked.
- **Backward compatibility:** trivially preserved; no existing command, format, or daemon behavior changes.
- **Rollback:** removing the verb is a clean revert (new files + one dispatch case + one usage line). No state
  to undo.

## 7. Edge cases

- **Empty / tiny file** (< `minSampleBytes`, or EOF before warm-up): `singleConnMBps = nil` → `insufficientData`
  verdict; still reports range support + protocol + acceptance.
- **Server ignores Range (200):** Phase 2 skipped; `rangeUnsupported` verdict.
- **206 with absent/unparseable `Content-Range`** (`totalBytes == nil`): Phase 2 skipped (no safe offsets);
  `rangeSupportedSizeUnknown` verdict on a single-stream T₁.
- **Redirect chain:** Phase 0 follows redirects (URLSession default) and records `networkProtocol`/status from
  the final response. Phase 2 issues its N ranged GETs against the *same supplied URL* and lets URLSession
  re-follow per request; the per-host connection budget applies to the resolved host. Cookies are off, so an
  off-origin redirect leaks no credentials. The report's `url` field is the URL as supplied (not the resolved
  target).
- **401/403:** "requires authentication," exit 4.
- **404 / 5xx on Phase 0:** "HTTP <code> — cannot diagnose," exit 3.
- **DNS / connection refused / TLS failure / unreachable:** mapped `GohError` code, exit 2.
- **Connection drops mid-sample:** that connection's contribution stops; the probe continues with the rest and
  notes a degraded/incomplete sample if it falls below thresholds.
- **Server hangs (no bytes):** per-connection timeout + global deadline fire; "diagnosis incomplete."
- **HTTP/2/3 multiplexing:** N range requests may share one TCP connection; report says "parallel range
  requests" and annotates the protocol; "did not scale" is a valid, meaningful finding under a shared cwnd.
- **`--connections 1`:** Phase 2 is a no-op; report is single-connection only (verdict notes parallelism
  untested).
- **Concurrent `goh diagnose` invocations:** independent ephemeral sessions, no shared state — safe.

## 8. Exit-code contract (diagnose-specific)

| Code | Meaning |
|---|---|
| 0 | Diagnosis completed — ANY finding (rate-limit / no-range / scaled / link-limited / insufficient-data) exits 0; it ran successfully |
| 1 | Unexpected internal failure — an error escaping the probe that no normal path produces (defensive catch-all) |
| 2 | Target unreachable (DNS / connection / TLS / timeout) — could not diagnose |
| 3 | HTTP error on the initial probe (4xx/5xx other than 401/403) — could not diagnose |
| 4 | Authentication required (401/403) |
| 64 | Usage error (missing/malformed URL or bad flag) |

Findings are NOT failures: a healthy diagnosis of a rate-limiting server still exits 0, so the verdict is in the
output, not the exit code. Non-zero is reserved for "the diagnosis itself could not be completed."

Codes 0/2/3/4 are produced by mapping the probe's typed `ProbeTermination` (§2.1) — `diagnosed`/`unreachable`/
`httpError`/`authRequired` — NOT by string-matching `verdictText`. Code 64 is produced at the arg-parse layer
before the probe runs. Code 1 is a defensive guard for the async→sync bridge (§2.6) returning without a captured
result — it is not reachable on any normal path and is intentionally an unverified defensive branch (no test
asserts it).
