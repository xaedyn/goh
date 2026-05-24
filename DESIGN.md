# goh — Design

Architecture decisions, kept in sync as the project evolves. Each non-obvious
decision gets a short paragraph the day it is made. Section bodies marked _TBD_
are filled as the corresponding slice is designed.

## Architecture overview

Four targets, one repository:

- **`goh`** — CLI client. Thin. Talks to `gohd` over XPC. Exits fast.
- **`gohd`** — daemon. Runs under `launchd` as a LaunchAgent. Owns the network,
  the queue, and the disk.
- **`GohCore`** — shared library. Transport, scheduling, persistence, hashing, auth.
- **`GohTUI`** — terminal UI module. Used by `goh top`.

## Concurrency model

`goh` and `GohTUI` use `MainActor` default isolation
(`.defaultIsolation(MainActor.self)`) — main-thread work is their 80% case.
`GohCore` and `gohd` use the standard nonisolated default — off-main work is
theirs. Swift 6 language mode (the default at tools-version 6.x) already enables
complete strict-concurrency checking, so no upcoming-feature flag is set.

## Build & toolchain

- `swift-tools-version` is pinned at the **6.2 floor** — the minimum that provides
  the `.defaultIsolation` SwiftSetting. The repo builds with the current Swift
  6.3.x toolchain.
- CI pins the `macos-26` runner (GA, native arm64) rather than `macos-latest`,
  which still resolves to macOS 15 until a migration beginning 2026-06-15.
- The SwiftPM platform floor and the supported-OS policy are covered in
  **Platform support** below.

## Platform support

**Supported OS:** macOS 26.5+ (Tahoe), Apple Silicon.
**SwiftPM manifest floor:** `platforms: [.macOS("26.0")]`.

These two numbers are deliberately different, and the gap is intentional.

### Why the manifest floor is macOS 26.0, not 26.5

The manifest floor only needs to be as high as the oldest SDK that can compile
the code. Building a package that declares a 26.5 floor requires the macOS 26.5
SDK on the build machine — and on GitHub's `macos-26` runner, the only hosted
runner carrying a macOS 26 SDK, the 26.5 SDK is bundled with a beta Xcode.

Verified against the runner image manifest on 2026-05-21 — `actions/runner-images`
image `20260427.0026.1`
([macos-26-arm64 readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)):

| Xcode on `macos-26` | Default? |
| ------------------- | -------- |
| 26.5 (beta)         | no       |
| 26.4.1              | no       |
| 26.3                | no       |
| 26.2                | **yes**  |
| 26.1.1              | no       |
| 26.0.1              | no       |

Installed macOS SDKs: 26.0, 26.1, 26.2, 26.4, 26.5. The newest **stable** Xcode
is 26.4.1, which bundles the 26.4 SDK; the 26.5 SDK pairs with the beta Xcode 26.5.

A 26.5 manifest floor would therefore force CI onto a beta toolchain. GitHub
rotates and removes beta Xcodes from runner images without notice, so CI could
turn red with no change to our code. Under the "no beta toolchains" constraint, a
26.0 floor is the only value that builds on a stable Xcode today — and it costs
nothing: v0.1 code calls no API newer than macOS 26.0 yet, and the manifest floor
is a build-time minimum, not a runtime support promise.

### Floor-bump policy

The manifest floor rises to macOS 26.5 the first time code depends on a
macOS 26.5-only API. When that happens:

- Bump `platforms:` to `.macOS("26.5")` **in the same PR** as the dependent
  code — never speculatively, ahead of need.
- Do **not** introduce `#available` ladders or version-gated branches. The
  project targets a single OS floor: the floor moves as a whole, the code does
  not fork. Once the floor is 26.5, every 26.5 API is unconditionally available.

At that point the manifest floor and the supported-OS policy converge and the
gap documented above closes. The string form `.macOS("26.5")` is used
deliberately — SwiftPM's `MacOSVersion` exposes `.v26` but no `.v26_5` symbol,
and the string form matches the manifest's existing style.

## Transport

_The HTTP transport — single-connection, then range-parallel — is built in the
v0.1 download-engine slices: range-based parallelism, 8 connections default.
HTTP/3 is *not* opted into for v0.1 (a per-request `assumesHTTP3Capable` trial
regressed the saturated workload — see *URLSession quirks* below)._

### Transport mechanism revision

The brief and this document originally specified the transport as **HTTP/1.1 and
HTTP/2 over `NetworkConnection`** (Network.framework), with `URLSession` rejected
for wanting direct path control, interface selection, and `nw_path_monitor`
integration. SDK verification against macOS 26 reverses that decision.

- **The original premise was wrong.** It assumed `NetworkConnection`'s
  application-protocol slot could carry HTTP. It cannot — the protocol types
  Network.framework offers are `TLS`, `TCP`, `UDP`, `QUIC`, `QUICStream`,
  `WebSocket`, and a generic `Coder`; there is no HTTP protocol.
  `NetworkConnection<TLS>` is a TLS byte stream, and HTTP/2 over it would mean
  hand-implementing HPACK, framing, stream multiplexing, and flow control.
- **The `URLSession` rejection criteria do not survive.** *Direct path control*
  was motivated by QUIC-layer tuning — moot now that HTTP/3 is deferred to v0.2.
  *Interface selection* is available on `URLSession` via
  `URLSessionConfiguration.boundInterfaceIdentifier`. *`nw_path_monitor`
  integration* (the cellular auto-pause) is path monitoring — transport-
  independent — and pairs with `URLSession` as readily as with anything.
- **The foundation, going forward, is `URLSession` + `HTTPTypes`.** `URLSession`
  natively provides HTTP/1.1, HTTP/2, ALPN negotiation, TLS, redirects, range
  requests, and per-task progress; `swift-http-types` / `HTTPTypesFoundation`
  (already a dependency) supply the typed `HTTPRequest` / `HTTPResponse` layer.
  Range parallelism becomes N range-request tasks — over HTTP/2 they multiplex
  as streams, strictly better than N separate TCP connections.

The brief's reasoning was sound when written; it is moot once the macOS 26 API
surface is real.

### URLSession quirks the engine works around

Two non-obvious `URLSession` behaviours bit the engine on real-network testing
and forced specific configuration. Both apply to every download and are pinned
in `GohCore.downloadSessionConfiguration()`.

**`HEAD` returns `expectedContentLength = -1`** *(historical).*
`URLResponse.expectedContentLength` is populated from `Content-Length` for
`GET` responses but returns `-1` (`NSURLResponseUnknownLength`) for `HEAD`
responses even when the server sent the header (empirically verified on
macOS 26 against `dl.google.com`). The engine *used to* send a `HEAD`
capability probe and worked around this by parsing `Content-Length` from
`response.value(forHTTPHeaderField:)` directly. The engine now skips `HEAD`
entirely (see *Speculative ranged GET* below), so the quirk no longer bites
in practice. It's recorded here because the next engineer reaching for
`expectedContentLength` on a `HEAD` response should know it's unreliable.

**Auto-decompression is incompatible with ranged downloads.** `URLSession`'s
default `Accept-Encoding: gzip, deflate, br` triggers transparent
content-decoding on the response. For a whole response that is fine — but a
`Range` request over a `Content-Encoding`'d body returns a *partial slice of
the encoded stream*, not partial decoded bytes. `URLSession`'s decoder cannot
start mid-gzip-stream, so every range past the first fails with
`URLError.cannotDecodeRawData` (-1015); range 0 decodes a valid prefix whose
decoded length differs from the requested encoded length, overshooting onto
subsequent ranges' territory on disk. A download manager wants raw bytes
regardless — the file on disk should match what the server serves — so the
session configuration sends `Accept-Encoding: identity`, opting out of HTTP
content-encoding entirely.

### Speculative ranged GET

The engine skips the `HEAD` probe. The first request is `Range: bytes=0-`,
not `HEAD`. A `206` response carries the total via `Content-Range` *and*
starts range 0's bytes in the same round-trip — one RTT saved vs the older
`HEAD`-then-`GET`. Range 0 reuses that stream (truncated at its allotted
length via a `break` out of the consume loop, which cancels the task and
closes the connection slot); ranges 1..N-1 issue fresh precise ranged `GET`s.
A `200` response means the server didn't honour `Range`, so the stream is
the full body and the engine consumes it as a single connection — no second
request needed.

The initial `206` must be internally consistent for an open-ended `bytes=0-`
request: `Content-Range` has to start at 0 and end at `total - 1`. The engine
may cancel that stream after range 0's allotted slice, but the header still
proves the server accepted the open-ended request for the whole representation.
If the first response advertises only a partial subrange, the job fails instead
of inferring a total from a response shape the scheduler did not ask for.

The downside is a small bandwidth waste at cancellation time — bytes already
in flight on the open-ended stream when it's truncated, typically ≤ one TCP
window. The upside compounds: one RTT saved on every download.

### HTTP/3 — tried and reverted for v0.1

`URLRequest.assumesHTTP3Capable = true` was tried as a per-request opt-in
(URLSession has no session-wide knob on the current SDK) so URLSession would
advertise `h3` in ALPN where servers offered it, with automatic fallback to
`h2` then `http/1.1`. The intent was 0-RTT TLS resumption on repeats,
independent per-stream flow control, and connection migration.

In practice the change regressed the saturated workload measurably and with
unusual run-to-run variance against `dl.google.com` (first run close to the
HTTP/2 baseline, subsequent runs ~60 % slower) — the signature of
server-side rate-limiting kicking in against HTTP/3 traffic from this
network path. `aria2c` on HTTP/1.1 + `curl` on HTTP/2 stayed flat across the
same runs. URLSession on HTTP/2 was actually the better steady-state choice
on the workloads benchmarked. Reverted; HTTP/3 stays a v0.2 design pass when
either a different host or more diagnostic time is available.

## Persistence

`gohd` persists two daemon-owned data sets under
`~/Library/Application Support/dev.goh.daemon/`:

- `catalog.plist` — the job catalog (`JobCatalog`), written as a binary property
  list with atomic durable replacement.
- `checkpoints/` — the download-resume records drafted below.

The catalog is the user-visible job model. A checkpoint is engine-owned recovery
state: it exists only for unfinished jobs, may be rewritten often, and is deleted
when a job reaches `completed`, reaches non-resumable `failed`, or is removed
without `--keep`.

### Checkpoint / Resume Contract

This subsection is the Slice 3c implementation contract. The checkpoint format is
daemon-owned, not a public wire format, so it can migrate behind its own
`version` field without a `protocolVersion` bump. The user-visible behavior is
load-bearing: the daemon never silently discards a resumable partial and never
claims a partial is resumable when the validators do not prove it.

#### Startup reconciliation

On startup, `gohd` scans persisted jobs before scheduling any downloads:

- `active` with a valid checkpoint becomes `queued` and is immediately eligible
  for the engine. This is startup reconciliation, not a normal runtime
  `active -> queued` transition.
- `active` with a missing, corrupt, or validator-mismatched checkpoint becomes
  `failed` with `GohError.code == .connectionFailed`, a message explaining that
  resume metadata was unavailable or unsafe, and `retryEligible == true`.
- `queued` jobs keep today's behavior and are scheduled normally.
- `paused` jobs remain paused; user-paused jobs do not auto-resume, and
  network-paused jobs are resumed only by the later path-monitor slice.

Unsafe checkpoint recovery uses existing `GohError.code == .connectionFailed`.
The explanatory `message` carries the recovery detail, and `retryEligible == true`
carries the actionable signal that a fresh attempt may succeed. A dedicated error
code is deferred until there is a CLI branch that cannot be expressed by the
current code / message / `retryEligible` combination.

**Considered alternatives.**
- *Restart from byte 0* — simple, but it lies about ROADMAP §7's resume promise
  and can silently discard large partial downloads.
- *Leave them `active` until a command touches them* — preserves bytes but emits a
  state that is not true; no engine task owns the job after restart.
- *Add a new `interrupted` state* — clear, but adding a `JobState` case is a
  `protocolVersion` bump for v1.
- *Add a dedicated `checkpointInvalid` error code* — cleaner for machines, but a
  v1 wire bump is not justified while `.connectionFailed` plus a clear message
  and `retryEligible` are enough.

#### Checkpoint record

Use a versioned binary property list per job:
`checkpoints/<jobID>.checkpoint.plist`.

The v1 checkpoint records:

- `version`
- `jobID`
- `url`
- `destination`
- `partialFileSize`
- `totalBytes`, once known
- HTTP resume validators: strong `ETag` when present, `Last-Modified` when
  present, and `Content-Length` / `Content-Range` total
- `pieceSize == 1 MiB`
- completed pieces as sorted, non-overlapping byte intervals
- `updatedAt`

The piece map says "these byte ranges were written and made durable", not
"these bytes are cryptographically verified". End-to-end integrity still comes
from the final SHA-256 digest computed by the engine.

Sorted intervals are the v0.1 representation because they are readable in
diagnostics, easy to merge, and stable even when the scheduler changes range
splits between attempts. A compact bitset can replace the internal representation
behind a checkpoint `version` bump if large files show measurable manifest
overhead.

**Considered alternatives.**
- *Only a contiguous byte count* — safest and tiny, but range-parallel downloads
  lose already-written out-of-order pieces after a crash.
- *One file per range task* — maps to the implementation, not the file; range
  splits can change between attempts.
- *A compact bitset from the start* — space-efficient, but less transparent and
  unnecessary until measured manifest size says otherwise.

#### Piece durability

A piece becomes trusted only after:

1. the engine writes the full piece at its file offset;
2. the partial file is fsynced;
3. the checkpoint manifest is atomically and durably replaced with that piece
   marked complete.

On restart, bytes present on disk but absent from the manifest are ignored and
may be overwritten. This biases toward re-downloading at most the trailing
uncheckpointed work rather than trusting ambiguous bytes.

`DownloadFile` exposes a piece-aware sync point for this flow. The previous
cumulative 1 MiB fsync cadence was enough for write-through hygiene, but not
precise enough for a resume manifest whose entries are promises about specific
byte intervals.

The initial Slice 3c implementation saves a checkpoint after each flushed
interval is written and explicitly synced. Fresh downloads keep the
range-parallel engine path; resumed downloads fetch only the missing intervals
with `If-Range`, one interval at a time, then read the finished file back through
the normal hasher before completing. Parallel resume is a performance
optimization, not a correctness requirement, and can be added after the crash
resume contract is stable under tests.

**Considered alternatives.**
- *Mark after `pwrite` returns* — fast, but a crash can leave the manifest ahead
  of durable file bytes.
- *Mark after the normal coalesced catalog save* — mixes job state with hot engine
  checkpoints and makes the catalog save cadence a correctness boundary.
- *Resume all missing intervals in parallel immediately* — faster for sparse
  checkpoints, but it makes the first crash-resume slice share more machinery
  with live cancellation and pause. Sequential missing-interval resume is easier
  to validate and still preserves already-durable bytes.

#### HTTP resume validation

When resuming, the engine probes with a ranged request and validates the response
against the checkpoint:

- If a strong `ETag` exists, use `If-Range` with that ETag and require a `206`
  response whose `Content-Range.total` matches `totalBytes`.
- Else if `Last-Modified` exists, use `If-Range` with that date and require the
  same total.
- Else resume only inside the same daemon process; after daemon restart, fail the
  checkpoint as unsafe rather than silently stitching unvalidated bytes.
- If the server returns `200` to a resume probe, the representation changed or
  ranges are unavailable. The job fails safely; it does not overwrite the partial
  file as a hidden restart.

Weak ETags are not sufficient for crash resume in v0.1. If real benchmark
targets prove that too restrictive, the rule can be revisited with measured
hosts and explicit corruption tests.

**Considered alternatives.**
- *Trust URL + length only* — works often, but can splice bytes from two different
  representations if the server changes content at the same URL.
- *Require a strong validator for every resume* — safest, but disables resume for
  servers that omit validators.
- *Treat weak ETags as usable* — may work for many immutable assets, but weak
  validators do not prove byte-for-byte identity strongly enough for crash
  recovery.

#### Pause, resume, and kept partials

3c uses one checkpoint mechanism for every interruption path:

- `pause` asks the engine to stop at a checkpoint boundary, then transitions the
  job to `paused`.
- `resume` validates the checkpoint and re-enters the scheduler.
- `rm` without `--keep` cancels active work and deletes the checkpoint plus the
  daemon-owned partial file.
- `rm --keep` stops at a checkpoint boundary and keeps both the partial file and
  enough checkpoint metadata for a future `add` of the same URL/destination to
  adopt it.

`add` performs automatic adoption only when URL, destination, validators, and
checkpoint metadata match exactly. Otherwise it creates a fresh job and leaves
the kept file alone. No explicit "adopt partial" flag is added to the v1 request
schema. Adoption creates a new job id, rewrites the kept checkpoint under that
new id before scheduling, and removes the old checkpoint after the new one is
durably saved. The new `JobSummary` is seeded with the checkpoint's durable byte
count so `ls` reports the retained work immediately. The follow-up engine
request still uses `If-Range`; if the server returns a full `200` instead of
`206`, the resumed job fails safely rather than overwriting the kept partial.

The command path and engine coordinate through a daemon-local `DownloadControl`.
For active jobs, `pause` and `rm --keep` block the command reply until the engine
has written and checkpointed its current piece; `rm` without `--keep` uses the
same acknowledgement and then deletes the daemon-owned partial and checkpoint.
This keeps the v1 wire state honest without adding a transient `pausing` state:
when the client receives the reply, the engine has stopped touching that job's
file.

**Considered alternatives.**
- *Separate mechanisms for crash, pause, and keep-partial* — easier to stage but
  likely to diverge.
- *An explicit `add(adoptPartial:)` request field* — user-visible control, but it
  leaks checkpoint internals into the v1 IPC surface before there is a proven
  need.

## IPC

The `goh` ↔ `gohd` contract runs over the modern low-level Swift XPC API
(`XPCSession` / `XPCListener`, macOS 14+), not `NSXPCConnection`.

This section is the settled v0.1 IPC contract. Each decision states its
conclusion and keeps a **Considered alternatives** note — rejected options are
retained, not deleted, because "why not the other thing" is the expensive thing
to reconstruct a year later. Exact API spellings (Codable send/reply, audit-token
access) are confirmed against current Apple docs at implementation; this section
fixes the wire contract and the message shapes, not the call signatures.

### Threat model

Single-user macOS workstation. `gohd` runs as a per-user LaunchAgent and `goh`
runs as the same user. The threat is **other local processes, running as that
same user and not part of goh, attempting to drive or observe the daemon**. The
daemon holds sensitive state — download URLs, and (once `goh auth import` lands)
cookie-derived credentials — so same-user isolation is not a sufficient trust
boundary. This is explicitly **not** a multi-user shared-host model and **not** an
app-sandbox boundary; if a future requirement pushes either way, the §3 auth
granularity changes and must be re-surfaced.

### 1 · Message schema

#### 1.1 The envelope

Every message — request, reply, and server-initiated notification alike — is one
uniform envelope: a fixed-key XPC dictionary with exactly four keys. **This
definition is canonical; everything else in this section refers back to it.**

| Key | Swift type | Wire form |
| --- | ---------- | --------- |
| `protocolVersion` | `UInt32` | XPC unsigned integer |
| `requestID` | `UUID` | XPC string |
| `messageType` | `MessageType` (a `String`-backed enum) | XPC string |
| `payload` | a `Codable` value | XPC value via the Swift XPC API's `Codable` encoding (§5.1) |

- **`protocolVersion`** — the wire-protocol version (§4). Monotonic; bumped only
  on a wire-incompatible change (§4.3).
- **`requestID`** — correlates a reply or notification to its originating request,
  and is the correlation handle for cross-process logging (§6). Generated with
  `Foundation.UUID()`; the wire form is the standard RFC 4122 string (e.g.
  `E621E1F8-C36C-495A-93FC-0C247A3E6E5F`). The string form *is* the frozen wire
  representation — not the raw 128 bits — so both sides agree without endianness
  questions.
- **`messageType`** — discriminates the message kind: `request`, `reply`,
  `notification`, `error`. Swift models it as
  `enum MessageType: String { case request, reply, notification, error }`, but the
  *wire* type is the raw `String`. The wire strings are exactly `request`,
  `reply`, `notification`, `error`; these literals are part of the frozen contract
  (§4.3). The receiver reads that string with a primitive
  XPC accessor (§4.3) and maps it via `MessageType(rawValue:)`; an unrecognised
  value yields `nil` and is **dropped with an error, never crashed**. The split is
  deliberate: the enum gives typo-proof, exhaustively-switchable handling of
  today's four kinds; the open wire `String` keeps forward compatibility, so a
  future version can add a fifth kind and an old peer errors gracefully instead of
  decoding garbage. Defining a new `MessageType` case is backward-compatible (§4.3).
- **`payload`** — the kind-specific body. For a `request` it decodes to the
  `Command` enum (below); for a `reply`, the command's `Result` (§1.2); for a
  `notification`, a `ProgressEvent` (§1.3). The `payload` is `Codable`, encoded by
  the Swift XPC API's native `Codable` bridge, not JSON or property-list encoding
  (§5.1). The envelope dictionary may **also** carry native XPC file descriptors
  as sibling entries beside these four keys (§5.2) — those are not part of the
  `Codable` payload.

The four-key set, the key names, and their wire types are **frozen** — §4.3
governs what may and may not change. Envelope and payload types are defined once,
in `GohCore`.

For a `request`, the `Command` enum (`.add`, `.list`, `.pause`, `.resume`,
`.remove`, `.subscribe`, …) is the **single source of truth** for the command
set: the daemon switches over it exhaustively, so a new verb is one new case and
the compiler flags the switch that must handle it. `messageType` discriminates
message *kinds*, not commands — an orthogonal axis — so exactly one place
enumerates commands.

**Considered alternatives.**
- *One bespoke struct pair per command* — no uniform envelope, nowhere stable for
  cross-cutting fields, daemon dispatch fragments across many types.
- *A single command tagged-union with no envelope* — leaves nowhere stable for
  `protocolVersion` / `requestID` and entangles version negotiation with the
  command set.
- *`messageType` as a bare wire `String` with no Swift enum* — loses typo-proofing
  and exhaustive switching; the chosen design keeps `String` only as the wire form.
- *`requestID` as `UInt64`* — a compact counter needs collision-free generation
  across concurrent `goh` processes and CLI restarts; every such scheme reduces to
  a UUID with worse properties or a coordination problem. `UUID` needs zero
  coordination, and 16 bytes is irrelevant when bulk data never crosses XPC (§5.1).

**Open.**
- Whether the envelope also carries a client-info block (e.g. pid) for log
  attribution — a future *additional* key, append-only and non-breaking (§4.3);
  see §6.

#### 1.2 Error model

Daemon-side failures reach the CLI as a `Codable` typed error enum conforming to
the `GohError` protocol, defined in `GohCore` and used on both sides. A `reply`
envelope's `payload` carries `Result<Success, GohError>`. In-process `GohCore`
APIs use Swift typed throws (`throws(GohError)`); across XPC the error travels as
a serialized value. The CLI distinguishes two layers: **transport errors** (peer
died, malformed message — XPC's own) and **domain errors** (`GohError`).

**Considered alternatives.**
- *Stringly-typed error messages* — not inspectable, not exhaustively handled.
- *XPC-native transport errors only* — cannot express domain failures (job not
  found, version mismatch, …).

**Open.**
- Whether to flatten transport and domain layers into one CLI-facing
  `GohClientError` (`.transport` / `.daemon` cases) for ergonomics.

#### 1.3 Progress streaming

The daemon **pushes** `ProgressEvent`s over the session for the lifetime of a
subscription; the CLI exposes them as an `AsyncStream<ProgressEvent>`. This
requires a session held open for the subscription's duration (§2.1). Events are
coalesced server-side on a timer (~100 ms) — progress is last-value-wins, so
intermediate events are dropped, not buffered.

**Considered alternatives.**
- *CLI polls a `getProgress` request on a timer* — wasteful, laggy, and the poll
  cadence fights the render cadence.

**Open.**
- Confirm coalesce-vs-buffer and the ~100 ms cadence — both cheap to tune.

#### 1.4 Cancellation semantics

Two distinct operations, deliberately separated:

- **Detach** — Ctrl-C on a foreground `goh <url>`: the CLI drops its session and
  exits; the job keeps running in the daemon. This is a **silent detach plus a
  one-line note** — no interactive prompt (Ctrl-C means "out now"). The note names
  the job, e.g. `^C — download continues in background as job 42. 'goh ls' to
  check, 'goh rm 42' to cancel.` A `--cancel-on-interrupt` flag opts into
  cancel-on-Ctrl-C; it is a flag, never a prompt.
- **Cancel** — `goh rm <id>`: the daemon stops the job, tears down its
  connections, and deletes the partial file and checkpoint by default (`--keep`
  retains them).

The daemon owns every job-state transition; the CLI only ever *requests* them.
Cancelling the client-side `Task` for an in-flight XPC request never cancels
daemon work.

**Considered alternatives.**
- *A single "cancel" verb* — conflates "stop watching" with "stop the download";
  the daemon-backed model makes those genuinely different operations.
- *An interactive detach/cancel/wait prompt on Ctrl-C* — a confirm dialog is the
  opposite of what Ctrl-C muscle memory wants.

### 2 · Connection lifecycle

#### 2.1 Connection model

**Hybrid — one session per CLI process.** Fire-and-forget verbs (`add`, `ls`,
`pause`, `resume`, `rm`) open a session, do one request/reply, close, and exit —
sub-millisecond. Subscribing commands — `goh top` and the foreground `goh <url>`,
both live-progress subscribers — hold a session open only as long as the CLI
process lives. No multiplexing across invocations, no persistent client
connection, no reconnect logic beyond §2.2. The CLI is a remote control, not a
streaming peer; XPC session setup is cheap, so multiplexing would buy efficiency
that does not matter against a real complexity cost. The split is *subscribing vs
fire-and-forget* — `goh <url>` foreground belongs with `top`, not with the verbs.

**Considered alternatives.**
- *Long-lived multiplexed connection reused across invocations* — buys negligible
  efficiency (XPC setup is cheap) and pays for reconnect logic, in-flight
  reconciliation, and daemon-restart recovery on the client.
- *Strict one-shot for everything* — cannot serve `top` / foreground progress,
  which are genuinely streaming subscribers.

#### 2.2 Daemon restart mid-download

The daemon persists job state and 1 MB checkpoints to disk (see the Persistence
section) and, on crash-only `launchd` relaunch, **unconditionally resumes**
in-progress downloads from their checkpoints.

An attached foreground `goh <url>` sees its session invalidated, prints a visible
`reconnecting…` line, and makes **one** bounded reconnection attempt: re-resolve
the daemon's Mach service, **re-validate its audit token** (§3.2 — the reattached
peer could be an impostor that claimed the name while `gohd` was down), and
re-subscribe to the same job ID. The attempt is bounded by a short wait window
(≈2–3 s) because a `launchd`-relaunched daemon is not instantly back — it must
restart, re-read job state, and re-register its listener, so an instant retry
fires too early. If the window elapses with no daemon, the CLI exits 0 with
`download continues in background — 'goh ls' to check`. One bounded attempt is the
whole of the client's reconnect logic — no multi-attempt retry state machine.

**Considered alternatives.**
- *CLI exits immediately on session loss* — needlessly abandons a foreground
  session that a ~1 s wait would have recovered.
- *Multi-attempt reconnect with backoff* — a retry state machine nobody can reason
  about, for a case the daemon already recovers from on its own.

**Open.**
- Confirm the ≈2–3 s reconnection window — the one new tunable this introduces.

#### 2.3 CLI exits mid-stream

A subscriber session that closes — CLI killed, Ctrl-C'd, terminal closed — is
detected by the daemon as peer death on the listener; the daemon stops pushing
events to that subscriber and does nothing else. **Rule: subscriber sessions are
observers — their death never changes job state**, and the daemon must tolerate a
subscriber dying mid-send.

**Considered alternatives.**
- *Treat subscriber-session death as a cancel signal* — would kill a download
  because a terminal window closed; contradicts the entire daemon-backed model.

### 3 · Authentication & trust

#### 3.1 The daemon validates the client

`gohd` binds its Mach service with `XPCListener(service:requirement:)`, passing an
`XPCPeerRequirement` — `isFromSameTeam(andMatchesSigningIdentifier:)`: our Team ID
plus the designated signing identifier, **not** a cdhash (a cdhash changes every
build). The OS evaluates the requirement against every connecting peer at
session-accept; a same-user process that is not the signed `goh` is rejected
before any command is processed. Validation is the OS's own, performed per
session — no manual audit-token handling, nothing cached.

**Considered alternatives.**
- *No validation — trust any same-user process that reaches the Mach service* —
  the threat model is same-user processes; this defends nothing.
- *Team-ID-only* — would trust any future binary signed by our team, not just
  `goh`; the requirement pins the `goh` identity.

**Resolved.**
- The dev escape hatch is implemented — `PeerValidationMode` /
  `peerValidationMode(environment:)`: a `DEBUG`-only, environment-variable-gated
  relaxation, compiled out of release builds, for unsigned development binaries
  that cannot satisfy the requirement.
- Per-connection validation cost is benchmarked (`XPCValidationBenchmarkTests`):
  an `XPCPeerRequirement` evaluation is sub-microsecond cold and warm — far
  inside the ≤5 ms invisible band, so mutual validation costs nothing visible on
  a fast-path verb.

**Open.**
- The designated signing identifier is pinned when code signing is configured.

#### 3.2 The client validates the daemon

`goh` mutually validates `gohd` the same way —
`XPCSession(machService:requirement:)` with the same `XPCPeerRequirement` — so the
daemon is validated before any message is sent. This is warranted, not paranoid,
and the reason is specific.

A Mach service name enters the bootstrap namespace only because a launchd job
declares it in its plist's `MachServices` dictionary; launchd registers and
advertises the name, and the job obtains the port's receive right via
`xpc_connection_create_mach_service` / `bootstrap_check_in`. XPC disallows ad-hoc
registration, so **runtime** squatting of `dev.goh.daemon` is impossible. But a
same-user attacker **can** write its own LaunchAgent plist into the user-writable
`~/Library/LaunchAgents/` declaring that Mach service and pointing `Program` at
malware: if goh's agent is not yet installed, the impostor claims the name
(**configuration-time** squatting). goh installs its agent via `brew services`,
which writes the plist into that same user-writable directory — not via the
tamper-resistant `SMAppService` route — so the pre-stage squat is feasible under
the threat model. (Migrating to `SMAppService` later closes this — see
`ROADMAP.md`.)

Validation is therefore **per connection, never cached**: the peer behind
`dev.goh.daemon` can change between two `goh` invocations, and most dangerously
across a §2.2 reconnect — where the "restarted daemon" could be an impostor that
grabbed the name while the real `gohd` was down. Every connection re-validates;
there is no "trusted this peer before" shortcut. The mutual check detects an
impostor before the CLI sends anything — most importantly the
`goh auth import safari` credential payload.

Sources: `launchd.plist(5)`, the `MachServices` key
(<https://keith.github.io/xcode-man-pages/launchd.plist.5.html>); RDerik,
"Creating a Launch Agent that provides an XPC service on macOS"
(<https://rderik.com/blog/creating-a-launch-agent-that-provides-an-xpc-service-on-macos/>).

**Considered alternatives.**
- *Trust the Mach service name* — a planted LaunchAgent can impersonate the
  daemon; trusting the name leaks the cookie-import payload to an impostor.

**Test coverage.** Production validation is OS-enforced via the `requirement:`
initializers. The reject direction is unit-tested — `senderSatisfies` confirms an
unsigned binary fails `isFromSameTeam()`. The accept direction needs a properly
signed binary and is exercised in signed-build smoke testing, not CI — as is the
live launchd Mach-service registration. An anonymous-listener integration test
proves the validated channel's message round-trip.

### 4 · Version negotiation

The Homebrew formula installs `goh` and `gohd` together, but the daemon is
long-lived and survives `brew upgrade`: after an upgrade the new CLI talks to the
old daemon until the service is restarted. Version skew is routine, not exotic.

#### 4.1 Where the version lives

A monotonic integer **wire-protocol** version — `protocolVersion`, distinct from
the marketing version and bumped only on a wire-incompatible change (§4.3) —
travels in every envelope (§1.1). The first request/reply is itself the
handshake; there is no separate handshake round trip. The marketing version is
irrelevant to compatibility.

**Considered alternatives.**
- *A dedicated handshake message before any command* — an extra round trip the
  in-envelope version makes unnecessary, and awkward for one-shot sessions.
- *Compare full marketing versions* — couples wire compatibility to release
  numbering, which changes for reasons unrelated to the wire.

#### 4.2 Behavior on incompatible versions

For v0.1, compatibility is **exact `protocolVersion` equality** — a supported
range with an adapter layer is too much machinery this early. On mismatch the
daemon replies with an `error`-kind message carrying
`GohError.protocolVersionMismatch` (`client:` / `daemon:` versions); the CLI
prints an actionable line, e.g. `the goh daemon is running an older version —
restart it with 'brew services restart goh'`.

That mismatch reply must be decodable by **both** an old and a new CLI. The
**frozen negotiation subset** that guarantees it is `protocolVersion` and
`messageType` — both always readable by primitive accessor without decoding
`payload` (§4.3). Either side can detect the version disagreement and identify
the message kind even when it cannot parse the other's payload.

**Considered alternatives.**
- *A supported-range with an adapter layer* — real version-bridging machinery,
  unjustified for a project this young; revisit if skew becomes painful.

#### 4.3 Freezing the envelope

The envelope (§1.1) is a **fixed-key XPC dictionary** — `protocolVersion`,
`requestID`, `messageType`, `payload` — read with primitive `xpc_dictionary_get_*`
accessors before any `Codable` decode. `payload` is a `Codable` blob decoded with
the decoder chosen by `protocolVersion`; file descriptors ride as native XPC
sibling entries (§5.2), never inside the `Codable` payload.

XPC is a keyed, structured-message IPC, not a byte stream — an XPC dictionary is
unordered key-value, so reading a frozen key by name is order-independent and
stable, and adding a further key later never disturbs the existing ones. "Frozen"
is therefore a *policy*, enforced by the checklist below and the golden-file
suite — not a hand-coded byte layout.

**Wire-incompatible change checklist** — any one of these is a breaking change
and requires a new `protocolVersion`:

1. Renaming, removing, or retyping **any envelope key once it has shipped** —
   `protocolVersion`, `requestID`, `messageType`, `payload`, or any key added
   later. The envelope key set is append-only; every shipped key and its wire
   type is permanently frozen and may never be renamed or retyped.
2. Renaming or removing a field in a payload type, or changing its type, for an
   existing `protocolVersion`.
3. Adding a *required* (non-optional, no-default) field to an existing payload
   type.
4. Changing the meaning of an existing field's accepted values.
5. Changing how `protocolVersion` itself is encoded.

Adding an *optional* payload field, or defining a new `messageType` case, is
backward-compatible and does not bump the version.

**Considered alternatives.**
- *Hand-rolled byte framing* (fixed offsets, length-prefixed primitives, no
  `Codable`) — buys nothing on a keyed transport and adds a bespoke parser that
  carries its own bugs. The "Codable reorders fields" worry does not apply to
  keyed encoders (XPC dictionaries, `JSONEncoder`, `PropertyListEncoder` are all
  keyed; breakage comes from renaming/retyping/removing fields, never from order).
  Byte framing would only pay off if goh later carried this protocol over a
  non-XPC transport — not foreseen, and a transport adapter at the boundary is the
  right answer if it ever happens.

**Open.**
- The checklist is enforced by a **golden-file test suite** on the implementation
  branch — this is the checklist's CI mechanism, not a generic regression test.
  Recorded request/reply messages are committed and decoded by current code; a
  renamed or retyped envelope key, or a changed payload field, makes a recorded
  message fail to decode and fails CI.
- **Fixtures for shipped `protocolVersion` values are immutable** — a
  `protocolVersion = 1` fixture is never edited; new versions only ever *add*
  fixtures. Editing a fixture to make a test pass is exactly how a wire break
  ships: it moves the goalpost instead of catching the regression.
- Checklist item 4 (a semantic change with identical bytes) is **not** catchable
  by the golden-file suite — it requires human review against a documented
  per-version semantics note, not CI.
- Confirm at implementation that the Swift XPC API exposes top-level dictionary
  fields via primitive accessors independently of decoding `payload`.

### 5 · Serialization

#### 5.1 Codable for message bodies

Message bodies are `Codable` — it matches the envelope-plus-`Command`-enum model,
gives compiler-checked exhaustiveness, and adds no third-party dependency.
Downloaded file content **never crosses XPC**: the daemon `pwrite`s bytes straight
to disk, and the CLI receives only small control messages and progress events, so
there is no bulk-payload pressure.

Made precise — the Swift XPC API offers whole-message `Codable` transport
(`XPCSession.send` / `sendSync`), and the envelope deliberately does **not** use
it: sending the envelope as one opaque `Codable` message would defeat §4.3's
ordered primitive-accessor reads (`protocolVersion` and `messageType` before
`payload`). `payload` is encoded by a Foundation
`Codable` encoder (JSON, deterministic key ordering) to bytes, carried as an XPC
`data` value beside the primitive-typed envelope keys. `protocolVersion` is
carried as an XPC `uint64` — the only unsigned-integer XPC primitive — holding a
value validated to fit in `UInt32` on both encode and decode. `requestID` and
`messageType` are XPC strings. The four keys form the fixed-key XPC dictionary of
§4.3; file descriptors are handled per §5.2.

**Considered alternatives.**
- *Hand-built `xpc_dictionary` messages* — verbose and error-prone for no gain
  over `Codable`.
- *A nested codec (JSON, protobuf) inside XPC payloads* — a second serialization
  layer, and for protobuf a dependency; unjustified when messages are small.

#### 5.2 File descriptors and the Full Disk Access path

`goh auth import safari` reads Safari's `Cookies.binarycookies`, gated by Full
Disk Access. The lean is that **`goh` — the interactively-run binary — holds FDA,
opens the cookie file, and passes the open file descriptor to the daemon**, which
reads and parses it and never needs FDA itself. FDA on an interactive tool is a
more natural mental model than FDA on a `launchd`-managed background agent (TCC
prompting is unreliable for non-app daemons, and a permanently FDA-bearing daemon
is a broad standing capability); passing the fd rather than parsed records keeps
the `binarycookies` parser in one place (`GohCore`, daemon-side) and off the
short-lived CLI.

This is a **lean, not a binding decision — the Auth slice owns the final call.**
What it locks for *this* contract: **a file descriptor is carried as a native XPC
sibling entry in the envelope dictionary, beside `payload` — never inside the
`Codable` payload, because a file descriptor is not `Codable`.** An fd's integer
value is meaningless in another process; only XPC's native fd-passing duplicates
the real descriptor across. The envelope must permit one or more such sibling fd
entries.

**Considered alternatives.**
- *Daemon holds FDA and reads the file itself* — nothing cookie-related crosses
  XPC, but pushes the awkward FDA-on-a-background-daemon UX onto the user.
- *CLI parses `binarycookies` and sends structured `Codable` cookie records* — no
  fd needed, but duplicates the parser into the short-lived CLI and moves
  credential material through the `Codable` payload rather than as an fd.

**Open.**
- The binding FDA decision belongs to the Auth slice. For the IPC contract, only
  this is locked: the envelope can carry file descriptors as native XPC siblings
  (above). Designing that in now is cheap; retrofitting it is not.

### 6 · Observability

Both processes log through `os.Logger` under subsystem `dev.goh`, with categories
(`xpc`, `queue`, `transport`, …). `log stream --predicate 'subsystem ==
"dev.goh"'` gives one live cross-process view. Every message carries the
envelope's `requestID` (§1.1), logged on both sides, so a request and its reply
correlate across the two processes. The daemon logs every session accept/reject
(with the validated identity or rejection reason, §3) and every command.
**Privacy is a correctness requirement:** URLs and any credential-bearing fields
are logged with `privacy: .private`, so secrets never reach the system log.

Unified logging is separate from the LaunchAgent's `goh.log` stdout/stderr file:
structured, queryable logs go through `os.Logger`; the logfile catches crash
output.

**Considered alternatives.**
- *`print` / the logfile only* — not queryable, no cross-process correlation, no
  privacy redaction.
- *Signpost-based tracing as the primary mechanism* — `OSSignposter` is for
  performance instrumentation, not failure diagnosis.

**Open.**
- A verbosity control — an env var read by the daemon at launch, plus `--verbose`
  on the CLI.
- `OSSignposter` transfer-performance instrumentation — deferred to the transport
  slice.
- Whether the envelope carries a client-info block (pid) for log attribution
  (§1.1's open item) — lean yes, since the daemon already logs per-session peer
  identity; settle when the listener is implemented.

## Command schemas

This section defines the payload schemas for the five request/reply commands —
`add`, `ls`, `pause`, `resume`, `rm`. They freeze into `protocolVersion = 1` on
merge and evolve thereafter only under the wire-format rules in §4. `goh top` is
a server-pushed subscription, not a request/reply command; its `ProgressEvent`
schema is a separate slice.

The **canonical schema** (§1) is the load-bearing artifact — the authoritative
field list. §2–§3 record the rationale and the considered alternatives behind
each decision; §4 states the evolution rules; §5 is the completeness audit.

This froze the job model's **public surface**: `JobSummary` *is* the
externally-visible shape of a download job. The daemon-job-model slice that
follows implements a job's internals behind this surface and has no authority to
re-decide its identifier, state, progress, or error shape.

Command **failures** travel the error channel of the IPC contract (its §1.2): a
reply envelope is `Result<Payload, GohError>`, so a `pause` of an unknown job
returns `.failure`, not a command-specific error payload. The schemas below
define the **success** payloads. Payloads are JSON (IPC contract §5.1); `Date`
fields are ISO-8601 strings (§4).

### 1 · Canonical schema

**Enumerations** — each encoded as a wire string:

| Type | Values |
|---|---|
| `JobState` | `queued`, `active`, `paused`, `completed`, `failed` |
| `PauseReason` | `user`, `network` |
| `Priority` | `low`, `normal`, `high` |
| `ErrorCode` | the sixteen cases tabulated in §2.4 |

**`JobProgress`:**

| Field | Type | Presence | Meaning |
|---|---|---|---|
| `bytesCompleted` | `UInt64` | always | bytes written to disk so far |
| `bytesTotal` | `UInt64?` | always; `null` if unknown | total size; `null` when the server gave no length |
| `bytesPerSecond` | `UInt64` | always | current aggregate throughput |

**`GohError`:**

| Field | Type | Presence | Meaning |
|---|---|---|---|
| `code` | `ErrorCode` | always | the error category |
| `message` | `String?` | optional | human-readable detail / reason phrase |
| `httpStatusCode` | `Int?` | when `code == httpStatus` | the numeric HTTP status |

**`JobSummary`** — the job's public surface, returned by every job-bearing reply:

| Field | Type | Presence | Meaning |
|---|---|---|---|
| `id` | `UInt64` | always | daemon-assigned, monotonic, persisted |
| `url` | `String` | always | the source URL |
| `destination` | `String` | always | the local file path |
| `state` | `JobState` | always | — |
| `progress` | `JobProgress` | always | — |
| `createdAt` | `Date` | always | when `add` created the job |
| `lastProgressAt` | `Date?` | always; `null` if never | when `progress` last advanced — the staleness signal |
| `requestedConnectionCount` | `UInt8` | always | the connection count `add` was given; `1`–`16` |
| `actualConnectionCount` | `UInt8` | always | the connection count the download used — kept on a `completed` job, `0` before the engine decides and on a `failed` job; below `requestedConnectionCount` on a single-connection fallback. See §2.2, *`actualConnectionCount` lifecycle* |
| `pauseReason` | `PauseReason?` | iff `state == paused` | — |
| `completedAt` | `Date?` | iff `state == completed` | when the download finished |
| `error` | `GohError?` | iff `state == failed` | the failure |
| `retryEligible` | `Bool?` | iff `state == failed` | the daemon's judgement that a retry could succeed |
| `failedAt` | `Date?` | iff `state == failed` | when the job failed |
| `retryCount` | `UInt32?` | iff `state == failed` | retries attempted before failing |

Every `Date` field in `JobSummary` is encoded as an ISO-8601 string — see §4.

**Commands** — request payload and success reply:

| Command | Request | Success reply |
|---|---|---|
| `add` | `url: String`; `destination: String?`; `connectionCount: UInt8?`; `useImportedCookies: Bool?`; `priority: Priority?` | `JobSummary` (`state == queued`) |
| `ls` | *(empty)* | `{ jobs: [JobSummary] }` |
| `pause` | `jobID: UInt64` | `JobSummary` |
| `resume` | `jobID: UInt64` | `JobSummary` |
| `rm` | `jobID: UInt64`; `keepPartialFile: Bool?` | `{ removedJobID: UInt64 }` |

Defaults for absent optional request fields are frozen — see §4.

### 2 · Shared types — rationale

#### 2.1 Job identifier
A job is identified by a `UInt64`, assigned by the daemon from a counter
persisted alongside job state. The daemon already persists state to disk, so the
counter survives restarts with no reuse and no collision. The decisive factor:
the identifier is **typed by the user** (`goh rm 5`, `goh pause 5`), unlike the
envelope's `requestID`, which is machine-only correlation — so typeability
dominates. `UInt64` is the natural counter width; persistence makes wraparound
moot.

**Considered alternatives.**
- *`UUID`, consistent with `requestID`* — rejected: a 36-character UUID is
  unusable at a prompt, and the two identifiers have different roles (machine
  correlation vs. a user-typed handle).
- *A human-friendly short string (`job-42`)* — rejected: that is the `UInt64`
  with a display prefix. The prefix is a CLI presentation choice, not a wire
  concern; the wire carries the integer.

#### 2.2 Job state
`JobState` is a flat enum — `queued`, `active`, `paused`, `completed`, `failed` —
carried as `JobSummary.state`. State-specific detail rides in sibling top-level
fields of `JobSummary`, populated only in the state they belong to: `pauseReason`
(paused); `completedAt` (completed); `error`, `retryEligible`, `failedAt`,
`retryCount` (failed). A job *waiting for a connection slot* is `queued`, not
`paused` — `queued` is a state, not a pause reason.

`PauseReason` is `user` or `network`. The distinction is load-bearing: a
network-paused job auto-resumes when connectivity returns (ROADMAP §12); a
user-paused job must not. `system` / sleep is not a distinct reason — on macOS,
sleep drops the network and `nw_path_monitor` reports it as a `network` pause;
deferred to v0.2 if a future macOS makes the distinction real.

**Internal invariant, wire flexibility.** The wire schema permits a nonsensical
combination — `state: active` with a populated `error` — but the daemon, which
owns the job model, never emits one: a sibling field is populated *if and only
if* `state` is the state it belongs to, and consumers may rely on that. The
invariant is enforced in the daemon, not expressed in the wire type — a
deliberate trade: the flat shape carries a representable-but-never-emitted
invalid state and, in exchange, gives clean `jq` access and additive evolution.

**Retry boundary.** `failed` is terminal. `retryEligible` is *advisory* — it
indicates the failure was the kind that might succeed on a fresh attempt, not an
actionable in-place state. To retry, the consumer issues a new `add` request,
which creates a new job with a new `id`; there is no in-place retry operation and
no `retry` command.

**Priority and preemption.** `Priority` orders selection among `queued` jobs.
Running jobs are not preempted — the `active → queued` transition does not exist
outside `pause`. A `high`-priority job that arrives while the connection budget
is full waits for a running job to finish, or to be paused or removed.

**`actualConnectionCount` lifecycle.** `actualConnectionCount` records the
connection count the download used. It is `0` until the engine has probed and
decided; on a `completed` job it remains at that value — the historical record
of the parallelism the download achieved, the *actual* against the *requested* —
and on a `failed` job it resets to `0`, a count being meaningless for a download
that did not complete. The job's `state` determines the field's meaning; a
consumer branching on `actualConnectionCount` checks `state` first.

**Considered alternatives.**
- *An enum whose `paused` / `failed` cases carry associated values* — rejected.
  Swift's synthesised `Codable` for associated-value enums nests the payload
  (`{"failed":{"_0":{…}}}`), hostile to `goh ls --json | jq`; and changing a
  case's associated type is a wire-incompatible change (§4), whereas a flat enum
  keeps state-specific detail in sibling fields, which evolve additively under §4
  as ordinary optional fields. (Adding an enum *case* needs a `protocolVersion`
  bump for either form — §4 — so additive *cases* are not the flat form's
  advantage; clean `jq` access and additive sibling fields are.) Its one gain —
  unrepresentable invalid states — is recovered by the daemon-side invariant
  above, without the wire cost.
- *`actualConnectionCount` as a live count — connections in use right now, `0`
  whenever the job is not downloading* — this was §1's original specification at
  the first freeze. Rejected on amendment: a live count answers `goh top`'s
  "what is happening now" but leaves `goh ls`'s "what did this job do"
  unanswerable — a `completed` job always reads `0`, so the downgrade question
  (did the download get the parallelism `add` requested?) cannot be answered
  from a finished `JobSummary`, defeating the field's purpose. The
  historical-record semantics answer both, since an `active` job's record is
  also its live count. Amended in the same spirit as the Slice 1.5
  `invalidArgument` round: a frozen contract that mandates a behaviour defeating
  a field's purpose is a defect, and the fix is to amend the contract with the
  rationale recorded.

#### 2.3 Progress
`JobProgress` is aggregate — `bytesCompleted`, `bytesTotal` (`null` when the
server sent no length), `bytesPerSecond`. `goh ls` is a status list; the
8-connection breakdown belongs to `goh top`'s `ProgressEvent` (the subscription
slice). ETA is **not** a field: it is `(bytesTotal - bytesCompleted) /
bytesPerSecond`, computed trivially by the consumer — carrying a derived value on
the wire only invites encoder/consumer disagreement. When `bytesTotal` is `null`,
ETA is unknowable and the consumer renders an indeterminate state.

**Considered alternatives.**
- *Per-connection progress in `ls`* — rejected: carrying eight connection states
  in every `ls` row bloats the common case for a view that does not show them;
  `goh top` is where per-connection detail belongs. A `goh ls --verbose`
  per-connection field, if ever wanted, is an additive optional field (§4).

#### 2.4 Error shape
`GohError` is `{ code: ErrorCode, message: String?, httpStatusCode: Int? }` — a
typed `code` the CLI branches on (exit codes, retry prompts) without parsing
prose; an optional human-readable `message`; and `httpStatusCode`, set only when
`code == httpStatus`, so a consumer reads `select(.error.code == "httpStatus" and
.error.httpStatusCode >= 500)` directly rather than parsing a status out of
`message`. `ErrorCode` is a closed enum of sixteen categories, each with a remedy
path:

| `ErrorCode` | Meaning | Remedy |
|---|---|---|
| `dnsResolutionFailed` | the host name did not resolve | check the URL / connectivity |
| `connectionFailed` | TCP connection refused or unreachable | retryable — check connectivity |
| `tlsFailure` | TLS handshake or certificate failure | not retryable — the host's TLS is broken |
| `timedOut` | the connection or transfer timed out | retryable |
| `httpStatus` | the server returned a 4xx / 5xx status | depends — see `httpStatusCode` |
| `diskFull` | no space left on the destination volume | free space, then retry |
| `destinationUnwritable` | the destination path is invalid or read-only | correct the path |
| `destinationPermissionDenied` | macOS (TCC) denied access to the destination | grant access in System Settings |
| `checksumMismatch` | the finished file's SHA-256 did not match | the file is corrupt — retry |
| `unauthorized` | the server rejected the request's credentials | re-import cookies (`goh auth import`) |
| `unsupportedURL` | the URL's scheme or form is not supported | not retryable |
| `jobNotFound` | no job has the given identifier | — |
| `queueFull` | the daemon's job queue is at capacity | retry later |
| `protocolVersionMismatch` | the CLI and daemon disagree on `protocolVersion` | upgrade the older component |
| `cancelled` | the operation was cancelled (`rm`, shutdown) | — |
| `invalidArgument` | a request field held an invalid value | `message` names the field and what was wrong |

Three boundaries fix what `GohError` is *not*:
- **Retry-eligibility is not derived from `code`** — it is the explicit
  `retryEligible` field on a failed `JobSummary`. The daemon decides it: an
  `httpStatus` 503 is retryable, a 404 is not, and `code` alone cannot tell them
  apart, so the daemon states it rather than the consumer inferring it.
- **HTTP retry policy is status-aware** — 408, 425, 429, and 5xx are marked
  retryable; other HTTP statuses are not. 401 and 403 are not reported as
  generic `httpStatus` failures at all: they map to `unauthorized`, with no
  `httpStatusCode`, so the CLI can point users at credential import instead of a
  blind retry.
- **`rangeNotSupported` is not an `ErrorCode`** — a server that does not honour
  `Range` is not a failure; the daemon falls back to a single connection and the
  download proceeds. The downgrade is observable as `actualConnectionCount`
  differing from `requestedConnectionCount`, not as an error.
- **Daemon shutdown is not a `GohError`** — a request in flight when the daemon
  stops surfaces as an XPC *transport* error (the connection invalidates), not a
  `reply`-envelope `.failure`. `GohError` is reply-level; connection lifecycle,
  including a dropped daemon, is the IPC contract's §2.2 (reconnect).

**Considered alternatives.**
- *An untyped human-readable error string* — rejected: the CLI must branch on
  cause (exit codes, retry prompts) and a `jq` consumer must filter on it; an
  opaque string defeats both.
- *Deriving retry-eligibility from `code`* — rejected: `code` alone cannot
  separate a retryable 503 from a fatal 404 (both are `httpStatus`); the daemon,
  which holds the response, decides and states it.
- *A single collapsed `networkUnreachable` code* — rejected: DNS resolution
  failure, TCP connection failure, and TLS negotiation failure have distinct
  remedies — DNS suggests checking the URL or local network; connect suggests the
  host is unreachable or down; TLS suggests a certificate or protocol mismatch. A
  consumer branching on cause needs them separable; a single collapsed code would
  force every consumer to parse the `message` string to recover the distinction
  the three separate codes preserve structurally.
- *Reusing an existing code for an invalid request field, rather than adding
  `invalidArgument`* — rejected: no existing code fits. `unsupportedURL` is a URL
  problem (a `connectionCount` of `0` is not); `unauthorized` is an auth problem;
  and leaving the rejection codeless — for the consumer to parse out of
  `message` — defeats the purpose of a typed `code`, which is branching on cause
  without parsing prose (the reasoning that kept `httpStatusCode` structured).
- *Lenient enum decoding — an unknown `ErrorCode` decoding to a fallback rather
  than failing* — rejected; strict decode is deliberate. Lenient decoding
  silently degrades structured information: a consumer branching on a code (or on
  `JobState`) would have to treat every value as "or possibly unknown," defeating
  the flat, branchable shape the schema rounds chose. It moves a
  version-incompatibility from an explicit §4.2 negotiation error to a
  silently-degraded reply on certain jobs — the inverse of what §4.2 exists for.
  And it is a real design slice across four enums (`ErrorCode`, `JobState`,
  `PauseReason`, `Priority`), each needing its own fallback semantics. A new
  `ErrorCode` case is a `protocolVersion` change (§4); §4.2 surfaces the mismatch
  cleanly — the right mechanism for the problem lenient enums try to solve.

### 3 · Commands — rationale

A command's **request** is the `payload` of a `request`-kind envelope; its
**reply** is the `Result<…, GohError>` payload of a `reply`-kind envelope. A
mutating command returns the **resulting `JobSummary`** so the CLI need not issue
a follow-up `ls`.

#### 3.1 `add`
Request: `{ url, destination?, connectionCount?, useImportedCookies?,
priority? }`; reply: the new job's `JobSummary` (`state == queued`). The daemon
attaches imported Safari cookies by **URL-domain match** — it holds the cookie
store and attaches cookies whose domain matches the URL; `add` carries no cookie
identifier. `useImportedCookies: false` (CLI `--no-cookies`) opts out, and `add`
prints a one-line note when cookies were matched, so the attachment is not
silent. `priority` is a `Priority` enum — `low`, `normal`, `high`.

`connectionCount` is a `UInt8` constrained to `1`–`16`: `1` is a legitimate
single-connection download, `16` a ceiling past which parallel range-request
benefit saturates on real CDNs. The daemon **caps** a request above `16` at `16`
— the accepted value becomes `requestedConnectionCount`, the live count
`actualConnectionCount` (§1) — and **rejects** a request of `0` with an
`invalidArgument` error (§2.4), the `message` naming the field and rejected
value, since zero connections is nonsense, not a defaultable value.

**Considered alternatives.**
- *A cookie-import id — `goh auth import` returns an id `add` passes* — rejected:
  the v0.1 UX is "import once, then it just works"; making the user carry an id
  from a prior command is friction a download manager should not impose.
  Domain-match with an opt-out covers the "do not send my cookies here" case.
- *An integer priority scale (`0`–`9` or `−5`–`+5`)* — rejected: an integer
  pretends to be a continuum, but the daemon has three to four distinct queue
  behaviours regardless of numeric resolution, and a user typing `--priority 7`
  cannot know what `7` means. Named levels are honest about the actual choices —
  `high` / `normal` / `low` cover urgent / default / background-bandwidth and
  read cleanly on every consumer surface. If more granularity is ever needed, the
  right move is rethinking the queueing model — itself a `protocolVersion` bump —
  not slotting in a fourth named level.
- *A user-supplied `--expect-sha256 <digest>`* — deferred, not rejected: v0.1
  *computes* SHA-256 (ROADMAP §8), it is not user-supplied. An additive optional
  field later (§4), so the deferral costs no compatibility.

#### 3.2 `ls`
Request: empty; reply: `{ jobs: [JobSummary] }` in daemon (creation) order. A
download manager's job count is small, so pagination is unwarranted; the CLI
sorts and filters client-side.

**Considered alternatives.**
- *A request-side state filter or pagination* — rejected for v0.1 as unwarranted
  at the expected job count; a filter is an additive optional request field if
  ever wanted (§4).

#### 3.3 `pause`
Request: `{ jobID }`; reply: the updated `JobSummary` (`state == paused`,
`pauseReason == user`). `pause` is **graceful**: the daemon lets the in-flight
chunk's `pwrite` complete — a ≤1 MB write, sub-millisecond and bounded — writes
the checkpoint, then transitions to `paused`, so the partial file and checkpoint
stay consistent for a later `resume`. The command reply is held until that
boundary has been acknowledged, so a caller cannot immediately `resume` into a
second engine task racing the first. Pausing an already-paused or completed job
is a no-op returning the current summary.

#### 3.4 `resume`
Request: `{ jobID }`; reply: the updated `JobSummary` (`state == active`, or
`queued` if the scheduler is at its connection budget). `resume` clears `paused`
and re-enters the scheduler; resuming a `user`-paused and a `network`-paused job
is the same operation. Resuming a non-paused job is a no-op returning the current
summary.

#### 3.5 `rm`
Request: `{ jobID, keepPartialFile? }` (`keepPartialFile` default `false`; CLI
`--keep`); reply: `{ removedJobID }`. `rm` of an *active* job stops it and tears
down its connections: without `--keep` the partial file and checkpoint are
deleted (an in-flight chunk write may be abandoned, since the file is going
away); with `--keep` the daemon lets the in-flight chunk complete and checkpoints
before retaining the partial, so the kept file is resumable by a future `add`.
Like active `pause`, active `rm` replies only after the engine has acknowledged
the stop. Non-active `rm` remains a synchronous catalog mutation.

**File ownership boundary.** `rm` removes the daemon's *tracking record* for a
job. A finished file on disk is the **user's**; the daemon never deletes a file
it has finished writing. So `rm` of a *completed* job drops only the job from
`ls`, and `--keep` is irrelevant for a completed job. Deletion of a *partial*
file on `rm` of an unfinished job is not a counter-example — an abandoned partial
is daemon scratch state, not a finished artifact, and `--keep` exists precisely
to reclassify it as something the user wants kept.

### 4 · Wire-format rules

These govern how the schemas above evolve and serialize. They inherit the IPC
contract's §4.3 rules and add the corollaries this round established.

**Reply field evolution.** Reply schemas follow the IPC contract's §4.3 rule:
**adding an optional field is backward-compatible** within `protocolVersion = 1`
and does not bump the version; renaming, removing, retyping, or adding a
*required* field is wire-incompatible and bumps it. Decoders **ignore unknown
fields** (Codable does so by default), so a newer daemon's added field does not
break an older CLI. Reply shapes are frozen against breaking changes, open to
additive optional fields.

**Error-code evolution.** The sixteen `ErrorCode` cases are fixed for
`protocolVersion = 1`. Unlike an optional *field* — which an older decoder simply
ignores — an `ErrorCode` value an older consumer does not recognise fails its
strict enum decode; a seventeenth case is therefore a `protocolVersion` change,
not a point-release addition. Within v1, the daemon chooses the most specific
applicable code for each rejection cause.

**Frozen request defaults.** The default applied to an *absent* optional request
field is itself part of the frozen contract. Changing a default across a point
release is wire-compatible at the type level — no field changed type — but it
silently changes behaviour for every client that relied on the old default, a
real-world break. **A default change therefore requires a `protocolVersion`
bump.** The frozen v1 defaults: `add.destination` → derive from the URL;
`add.connectionCount` → `8`; `add.useImportedCookies` → `true`; `add.priority` →
`normal`; `rm.keepPartialFile` → `false`.

**Date encoding.** `Date` fields are encoded on the wire as ISO-8601 strings with
a timezone offset (e.g. `2026-05-21T14:32:09Z`), **not** the language's default
`Codable` representation. The daemon emits UTC; decoders accept any valid
ISO-8601 timezone. A serialization that holds only by a language default is not
part of the wire contract until stated — the same reason the envelope's
`messageType` values are pinned to explicit wire literals.

### 5 · Adversarial stress-test

Each schema, walked against what the brief and `ROADMAP.md` say the v0.1 engine
must do — designed to the *specified* engine, not a guessed one.

**Completeness rule.** A per-command walk must check *every* field in the
relevant schema and every field a documented engine capability will produce — not
only the obvious progress fields. For `ls` that means: creation timestamp,
staleness indicator, ETA (or its derivation justification), retry-eligibility
presentation, and a remedy path for every `ErrorCode`.

**Consumer requirements, not only engine requirements.** *(Added with the
`actualConnectionCount` amendment.)* This walk checks each schema against what
the *engine produces*. It must equally check what *consumers* — `goh ls`,
`goh top` — must be able to *answer* from a schema. The original walk missed
that direction: `actualConnectionCount`'s live-count semantics satisfied the
engine (it can report a live count) but not the `goh ls` consumer (a completed
job could not answer "what parallelism did this download get?"). A schema audit
walks both directions — engine production *and* consumer interrogation.

- **`add`** — the engine needs a URL, a destination, a connection count (8
  default, tunable — ROADMAP §6), cookie auth (ROADMAP §9), and a queue priority.
  The request carries all five. SHA-256 verification (ROADMAP §8) is *computed
  during* the download, not user-supplied, so no request field is needed. **Gap
  check: none.**
- **`ls` reply / `JobSummary`** — walked field by field. `id` / `url` /
  `destination` ✓; `state` ✓; `progress` — `bytesCompleted` / `bytesTotal` /
  `bytesPerSecond` ✓, ETA CLI-derived (§2.3) ✓; `createdAt` ✓; `lastProgressAt` ✓
  (staleness, consumer-judged); `requestedConnectionCount` /
  `actualConnectionCount` ✓ (a single-connection fallback shows as the pair
  differing); `pauseReason` ✓; `completedAt` ✓; `error` / `retryEligible` /
  `failedAt` / `retryCount` ✓. Every `ErrorCode` has a remedy path in §2.4.
  **Deliberately not in `ls`:** per-connection progress and the 1 MB checkpoint
  offset — `goh top` / the subscription slice. **Gap check: none.**
- **`pause` / `resume`** — the engine needs the job ID and must distinguish user
  from network pause (ROADMAP §12). Schema: `jobID` ✓, `pauseReason` ✓. **Gap
  check: none.**
- **`rm`** — the engine needs the job ID and the keep-or-delete choice for the
  partial. Schema: `jobID` ✓, `keepPartialFile` ✓. **Gap check: none.**
- **Cross-cutting** — the 1 MB checkpoint (ROADMAP §7) is engine-internal; it
  surfaces to the user as `bytesCompleted` and `lastProgressAt`, needing no
  separate field. Spotlight tagging, the sleep assertion, and `nw_path_monitor`
  (ROADMAP §10–§12) are daemon behaviours with no command-schema surface.

## Completion Metadata And Power

Slice 6 adds two daemon-local completion/runtime behaviours with no wire-schema
surface. On successful completion, `gohd` tags the destination file with
Spotlight-compatible metadata for `kMDItemWhereFroms` and
`kMDItemDownloadedDate`. Current SDK verification found public `MDItem` create
and attribute constants, but no public `MDItemSetAttribute` setter in
`MDItem.h`; the implementation therefore writes the standard
`com.apple.metadata:<key>` extended attributes as binary property lists. The
values match the SDK-declared types: `kMDItemWhereFroms` is a CFArray of
CFString and `kMDItemDownloadedDate` is a CFDate. Tagging failure is warned but
does not fail an already-completed download.

The sleep assertion is also daemon-local. `gohd` owns one
`SleepAssertionController` shared by all engine tasks. The controller reference
counts active downloads and holds at most one power assertion at a time. It uses
`IOPMAssertionCreateWithName` with `kIOPMAssertPreventUserIdleSystemSleep`,
which prevents user-idle system sleep while allowing the display to dim or
sleep; the older `kIOPMAssertionTypeNoIdleSleep` name is deprecated in the
current SDK headers. Assertion creation failure does not fail a download, and a
later active download retries assertion creation.

## Scheduling

v0.1 scheduling is daemon-local and conservative. A job that becomes `queued`
through `add`, explicit `resume`, startup reconciliation, or daemon startup is
admitted through the network policy before it is handed to the engine. When
admitted, the daemon launches an engine task; the engine's atomic `start`
transition remains the duplicate-run guard, so extra scheduling signals are
harmless.

The daemon owns one `NWPathMonitor`. The monitor callback only captures the new
path and dispatches policy work onto a dedicated serial policy queue, so a
graceful active-job stop cannot block the monitor callback and path policy still
applies in delivery order. Path updates are mapped to three internal states:

- `status != .satisfied` → downloads unavailable;
- `status == .satisfied && usesInterfaceType(.cellular)` → downloads unavailable;
- `status == .satisfied` without cellular → downloads allowed.

The cellular rule is intentionally conservative: Apple's `NWPath` documentation
defines `usesInterfaceType(_:)` as whether connections using the path may send
traffic over that interface, including paths eligible to use multiple
interfaces. If cellular is in that set, `goh` does not spend the user's metered
data. Sources: Apple `NWPathMonitor.start(queue:)`,
`NWPathMonitor.pathUpdateHandler`, `NWPath.status`, and
`NWPath.usesInterfaceType(_:)` documentation.

On an unavailable path, queued jobs transition to `paused` with
`pauseReason == network`. Active jobs first go through the same graceful stop
coordination as command-driven `pause`: the engine reaches a checkpoint
boundary, acknowledges through `DownloadControl`, then the coordinator records
the `network` pause. On a satisfied non-cellular path, only jobs paused for
`network` are resumed and rescheduled; jobs paused by the user remain paused.

Path changes are allowed to race active stop coordination. If a cellular pause
request is already waiting for the engine and Wi-Fi returns before the engine
acknowledges, the coordinator still records the checkpoint-safe network pause,
then immediately rechecks the latest path and resumes/reschedules the job. This
keeps the store out of the invalid "active but no engine owns it" shape without
stranding work on a stale cellular decision.

Before the first path observation, queued jobs are not admitted; they are held
as `network`-paused and released by the first satisfied non-cellular path. That
startup bias favors avoiding surprise cellular transfers over starting a
download a few milliseconds earlier. This behavior uses the existing
`PauseReason.network` case and does not change `protocolVersion = 1`.

## Auth

Slice 5 starts with a pure `GohCore` parser for Safari
`Cookies.binarycookies`. The parser returns in-memory `SafariCookie` records
(`domain`, `name`, `path`, `value`, flags, expiration, creation) and deliberately
does **not** introduce a daemon-persisted cookie-store format or any new IPC
command surface. That keeps the first auth commit reversible and lets the import
flow decide the final user-visible contract separately.

The parser follows the observed binarycookies shape documented by libyal's
working specification and cross-checked against yt-dlp's maintained Safari
parser: the file starts with `cook`, carries a big-endian page table, uses
little-endian page and record fields, stores record-relative NUL-terminated
string offsets, and encodes dates as Cocoa reference-date seconds. Sources:
<https://github.com/libyal/dtformats/blob/main/documentation/Safari%20Cookies.asciidoc>
and <https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/cookies.py>.

Imported-cookie attachment is also an in-memory `GohCore` primitive:
`SafariCookieJar` filters cookies for a request URL and serializes the `Cookie`
header. It follows RFC 6265 for path matching, secure-cookie exclusion on
non-HTTPS URLs, and header order (longer path first, then earlier creation
time). Domain handling is intentionally conservative because
`Cookies.binarycookies` exposes no separate host-only flag in the documented
record fields: domains beginning with `.` match the exact host and subdomains;
bare domains match only the exact host. This may under-send a cookie if Safari
stores a domain cookie without a leading dot, but it avoids leaking a host-only
cookie to sibling subdomains. Source: <https://www.rfc-editor.org/rfc/rfc6265>.

The download engine accepts a daemon-owned cookie-header provider keyed by
`jobID` and request URL. The provider is consulted for the initial speculative
range request, every follow-up range request, and resume requests, so auth does
not drift between engine paths. The engine does not own cookie storage and does
not persist credential material; it only attaches a non-empty header when the
daemon supplies one.

`gohd` owns one process-local `ImportedCookieStore` and passes it to both the
dispatcher and the engine. The dispatcher snapshots per-job headers at `add`
time; the engine reads only those already-snapshotted headers while moving
bytes. This keeps the daemon composition ready for the import command without
giving the transport layer direct access to the parsed Safari jar.

`CommandDispatcher` now bridges the already-frozen `add.useImportedCookies`
field to that volatile store. When the field is absent or `true`, `add`
snapshots the current matching `Cookie` header for the new job; when the field
is `false`, it stores nothing. `rm` clears the per-job header. This keeps the
wire default (`true`) meaningful without storing Safari cookies or derived
headers on disk. The import applies to subsequent `add` commands; existing jobs
keep the header snapshot (or lack of one) they were created with. Jobs restored
after a daemon restart lose volatile cookie headers and are not automatically
reauthenticated; a user can re-import before creating a replacement job, and a
future secure persistent credential-storage design can revisit automatic retry.

The Safari cookie-file locator is deliberately narrow: it checks the modern
container path first
(`~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies`)
and the legacy path second (`~/Library/Cookies/Cookies.binarycookies`). The
locator only finds a readable path; the interactive CLI still owns the Full Disk
Access prompt and fd-open behavior.

The still-open auth decisions are the user-visible `goh auth import safari`
command shape, the Full Disk Access prompt wording, and the revocation behavior
when the CLI can no longer open Safari's cookie file. The existing IPC lean from
§5.2 remains: prefer the interactive `goh` binary opening the file and passing a
native XPC file descriptor to `gohd`, so the daemon never needs Full Disk Access
itself. Freezing the command/reply shape is a wire-contract decision and should
be handled explicitly before the command lands.

### Auth import command contract draft — round 1, not frozen

**Question.** How should `goh auth import safari` cross the CLI/daemon boundary
without giving the daemon Full Disk Access and without weakening the frozen wire
rules?

**Options considered.**
- *Protocol v2 command with native fd sibling* — add an auth-import command in
  the next protocol version. The interactive CLI opens Safari's readable cookie
  file and sends that open descriptor as a native XPC sibling key; the daemon
  parses the file and replaces its process-local `ImportedCookieStore`.
- *Retrofit the command into `protocolVersion = 1` before v0.1 ships* — faster,
  but it mutates the already-frozen command enum and golden fixtures.
- *CLI parses cookies and sends structured cookie records* — avoids fd handling,
  but moves credential material into the JSON payload and duplicates parser
  ownership into the short-lived CLI path.
- *Daemon holds Full Disk Access and opens the file itself* — simplest IPC, but
  leaves a launchd-managed background agent with broad standing file access.

**Proposed answer.** Use a new `protocolVersion = 2` command:
`authImportSafari` with an empty JSON request payload and success reply
`{ importedCookieCount: UInt32 }`. The request envelope carries one required
native XPC sibling fd under a namespaced key such as `auth.safariCookieFile`.
The CLI obtains that fd by opening the first readable URL returned by
`SafariCookieFileLocator`; if open fails because Full Disk Access is missing or
revoked, the CLI prints the permission remedy and does not send the command.
The daemon rejects a missing or invalid fd with `invalidArgument`, parses valid
bytes with `SafariBinaryCookiesParser`, and calls
`ImportedCookieStore.replaceCookies(_:)`. Import is replace-all for v0.1, not
merge.

The platform mechanics support this shape: Apple's `xpc_fd_create` documentation
states that boxing an fd duplicates it, so the sender can close the original
after boxing; `xpc_fd_dup` returns an equivalent descriptor in the receiver,
which must close it. `FileHandle(forReadingFrom:)` creates a handle that owns its
local descriptor. Sources:
<https://developer.apple.com/documentation/xpc/xpc_fd_create%28_%3A%29?language=objc>,
<https://developer.apple.com/documentation/xpc/xpc_fd_dup%28_%3A%29?language=objc>,
and <https://developer.apple.com/documentation/foundation/filehandle/init%28forreadingfromurl%3A%29>.

**Open.**
- Confirm the exact sibling key spelling before implementation; once shipped, it
  is append-only under §4.3.
- Confirm whether `authImportSafari` should be the command enum spelling or
  whether a wider `auth` command namespace is worth the added nesting.
- Confirm the user-facing FDA prompt text and exit code when the CLI cannot open
  either Safari cookie path.
- Confirm whether the success reply needs an optional warning count for skipped
  malformed cookie records; the current parser is fail-fast, so the lean is no.

### Auth import command contract review — round 2, not frozen

**Review finding: import scope.** The Round 1 draft must not imply that a fresh
import repairs already-created jobs. The current, deliberately non-persistent
cookie model snapshots a per-job header at `add`, then the engine only reads
that snapshot. Recomputing headers later would need a stored "this job opted into
imported cookies" bit; without that bit, a later import could attach cookies to a
job that was created with `useImportedCookies: false`. Round 2 therefore narrows
the command's effect: `authImportSafari` replaces the daemon's process-local jar
for **future `add` commands only**. Existing jobs keep their original auth state,
and credentials do not survive daemon restart.

**Review finding: command shape.** Keep the command enum flat:
`authImportSafari(request: AuthImportSafariRequest)`. A nested `auth` command
namespace would add abstraction before the CLI has any other auth subcommands.
Future Chrome/Firefox import is already v0.2 scope and can justify a fresh
protocol version if it needs one.

**Review finding: fd sibling key.** Use `auth.safariCookieFile` as the exact
native XPC sibling key. It is short, scoped to auth, names the resource rather
than the implementation type, and leaves room for future siblings such as
`auth.chromeCookieDatabase` without colliding with envelope keys.

**Review finding: CLI failure behavior.** If the CLI cannot open either Safari
cookie path, it should not send an XPC request. It exits unsuccessfully after
printing the expected paths and a clear Full Disk Access remedy:
grant Full Disk Access to the terminal app (or to `goh` when it is installed as
a standalone binary), then rerun `goh auth import safari`. The exact numeric exit
code belongs to the CLI slice, which has not yet defined command-line exit
taxonomy; until then, the contract should avoid baking a number into the wire
design.

**Review finding: malformed records.** Keep the parser fail-fast for v0.1 and
return only `{ importedCookieCount }` on success. Partial import of a corrupted
credential file is surprising and harder to explain than an explicit failure.
If real Safari files later show recoverable malformed records, add an optional
warning field in a new round before implementation.

**Open after round 2.**
- Confirm that `protocolVersion = 2` is acceptable for the auth command rather
  than treating pre-v0.1 v1 as still mutable.
- Confirm the final user-facing FDA wording in the CLI implementation slice.
- Confirm whether the "future adds only" import scope is acceptable for v0.1, or
  whether we need a separate persistent job-auth-opt-in bit before shipping
  credentialed resume across daemon restarts.

### Auth import command contract conclusions — round 3, candidate text

This section rewrites the draft and review notes down to candidate conclusions.
It is still **not frozen** until the final audit and merge of the design PR.

`goh auth import safari` is a new `protocolVersion = 2` command, not a mutation
of v1. The request payload is an empty struct,
`AuthImportSafariRequest`; the success reply is
`AuthImportSafariReply { importedCookieCount: UInt32 }`. The `Command` enum case
is flat: `authImportSafari(request: AuthImportSafariRequest)`.

The request envelope carries exactly one required native XPC fd sibling under
the key `auth.safariCookieFile`. The fd points at an already-open Safari
`Cookies.binarycookies` file. The fd sibling is not represented inside the JSON
payload, because an fd's integer value is process-local and only XPC's native
fd-passing duplicates the underlying descriptor across processes.

The CLI owns the Full Disk Access boundary. It locates Safari's cookie file via
`SafariCookieFileLocator`, opens the first readable candidate, boxes the open fd
as the `auth.safariCookieFile` XPC sibling, sends `authImportSafari`, and closes
its local handle after the send path has boxed/duplicated the descriptor. If the
CLI cannot open either candidate, it does not send XPC. It exits unsuccessfully
after printing both expected paths and this remedy in substance: grant Full Disk
Access to the terminal app (or to `goh` when installed as a standalone binary),
then rerun `goh auth import safari`. The exact numeric exit-code taxonomy stays
with the CLI slice.

The daemon owns parsing and cookie replacement. It duplicates the received fd,
reads the bytes, parses with `SafariBinaryCookiesParser`, and replaces the
process-local `ImportedCookieStore` jar with the parsed cookies. A missing fd,
wrongly-typed sibling, unreadable fd, or malformed cookie file returns the
existing `invalidArgument` error code with a message naming the problem. Success
is all-or-nothing: malformed cookie files do not partially import, and the reply
does not carry warning counts in v0.1.

Import affects future `add` commands only. Existing jobs keep the per-job cookie
header snapshot (or lack of one) they were created with. Imported cookies and
derived per-job headers remain process-local and disappear on daemon restart.
Therefore v0.1 does **not** promise credentialed resume across daemon restarts.
Adding secure persistent credential storage, or even a persisted job-auth-opt-in
bit that enables post-restart re-snapshotting, is a separate load-bearing design
decision and is deferred.

**Considered alternatives.**
- *Mutate `protocolVersion = 1` because v0.1 has not shipped yet* — rejected:
  this repo has already chosen to treat v1 command schemas and fixtures as
  frozen. Keeping that discipline now prevents pre-release convenience from
  becoming the habit that later breaks users.
- *Nested command namespace such as `auth(command:)`* — rejected for v0.1:
  there is only one auth subcommand, while Chrome/Firefox import is v0.2 scope
  and may have different persistence/security mechanics.
- *CLI parses cookies and sends JSON records* — rejected: it moves credential
  material into payload JSON and splits parser ownership across short-lived CLI
  code and daemon code.
- *Daemon holds Full Disk Access* — rejected: a launchd-managed daemon with FDA
  is a broader standing capability and a worse user mental model than an
  interactive command opening one file and passing the descriptor.
- *Partial import with skipped-record warnings* — rejected for v0.1: it is
  difficult to explain and could leave the user with a subtly incomplete auth
  jar. Fail-fast is simpler and safer until real Safari files prove a recovery
  path is needed.

### Auth import command contract final audit — round 4

This pass checks the candidate contract against the §4.3 wire-change checklist
and the auth slice's security goals. It finds the contract ready to freeze once
the design PR is reviewed and merged.

- **Versioning:** adding `authImportSafari` is a new `Command` enum case, so the
  design correctly moves to `protocolVersion = 2` instead of changing v1.
- **Envelope compatibility:** the four canonical envelope keys remain unchanged.
  `auth.safariCookieFile` is an append-only native XPC sibling key, not a
  renamed or retyped envelope field.
- **Payload compatibility:** v1 payload structs are untouched. The new v2
  request is empty and the reply has one required success field,
  `importedCookieCount`, because no older v2 client exists yet.
- **Error-code compatibility:** the contract uses existing `invalidArgument`
  failures for missing/wrong/unreadable fd and malformed cookie file. No new
  `ErrorCode` case is introduced.
- **Credential boundary:** the CLI, not `gohd`, owns Full Disk Access. The daemon
  receives only an already-open fd and therefore does not need a broad standing
  TCC grant.
- **Persistence boundary:** no cookie jar, derived header, or job-auth-opt-in bit
  is persisted. The design explicitly avoids promising credentialed resume after
  daemon restart.
- **Implementation test obligations:** the implementation PR must add immutable
  v2 golden fixtures, command round-trip tests, XPC fd sibling encode/decode
  tests, daemon rejection tests for missing/wrong fd siblings, parser success and
  parse-failure command tests, and CLI-side tests for the "cannot open Safari
  cookie file, do not send XPC" path when the CLI parser exists.

No further design rounds are needed for the wire contract. The remaining FDA
prompt prose can be polished in the CLI implementation slice without changing
the request/reply schema or fd sibling key.

## CLI

Slice 7 keeps the executable target thin: `Sources/goh/main.swift` owns only
process I/O and the real XPC sender, while `GohCore` owns a testable
`GohCommandLine` runner for parsing, request construction, reply decoding, and
human output. This keeps every fire-and-forget verb unit-testable without
spawning a process or binding the Mach service, and preserves the existing
`goh auth import safari` path by routing that subcommand through the same runner.

The first CLI implementation covers the one-shot control surface: `goh add`,
`goh ls`, `goh pause`, `goh resume`, and `goh rm [--keep]`. These commands open
one XPC session, send one request, print one reply, and exit as described in IPC
§2.1. `goh <url>` is deliberately not implemented as a hidden alias for
`goh add`: the roadmap promises foreground live progress, and DESIGN already
places foreground downloads with the subscription commands. Until the progress
subscription exists, users who want a detached download use `goh add <url>`.

Exit codes are intentionally small for v0.1: success and `--help` return `0`;
local usage errors return `64` (`EX_USAGE`); daemon-domain failures, malformed
replies, and transport failures return `1`. A transport failure prints the
first-run remedy `brew services start goh`; a protocol-version mismatch prints
the restart remedy `brew services restart goh`. These are CLI presentation
choices, not wire-contract fields, and can be refined before v0.1 without a
`protocolVersion` bump.

The CLI exposes only options that already exist in the frozen command schema:
`goh add --output`, `--connections`, `--priority`, and `--no-cookies` map
directly to `AddRequest.destination`, `connectionCount`, `priority`, and
`useImportedCookies`. `goh ls --json` prints the existing `LsReply` payload using
the command JSON codec, with a trailing newline for shell ergonomics. This is a
presentation choice over the current protocol, not a new wire shape.

## Progress Subscription Contract

This section freezes the foreground `goh <url>` and `goh top` progress stream
for implementation. It is load-bearing because it adds wire payloads to the
current `Command` enum and defines the notification payload carried by
`messageType == notification`.

SDK check: the macOS 26.5 XPC Swift interface exposes client-side incoming
message handlers (`XPCSession.setIncomingMessageHandler` and initializers with
`incomingMessageHandler`) and unidirectional sends (`XPCSession.send(message:)`).
That means daemon-pushed notification envelopes over the already-open validated
session are viable without polling or a second transport.

`Command.subscribe(request:)` is a new `protocolVersion = 3` command. The
request is:

| Field | Type | Meaning |
|---|---|---|
| `scope` | `SubscriptionScope` | `job` for foreground `goh <url>`, `all` for `goh top` |
| `jobID` | `UInt64?` | required when `scope == job`, absent when `scope == all` |

`SubscriptionScope` is a flat string enum: `job`, `all`. A malformed invariant
(`scope == job` without `jobID`, or `scope == all` with `jobID`) returns
`GohError.invalidArgument`. A job-scoped request for a missing job returns
`GohError.jobNotFound`.

The daemon replies once with a sequence-0 baseline:

| Field | Type | Meaning |
|---|---|---|
| `revision` | `UInt64` | daemon progress-model revision represented by the snapshot |
| `snapshot` | `[ProgressSnapshot]` | full current snapshot for the subscription scope |

It then pushes `ProgressEvent` notification envelopes on the same session until
the client disconnects or the daemon exits. Notifications reuse the original
subscribe request's `requestID`, so one client session can correlate the stream
without a second subscription identifier.

`ProgressEvent` is:

| Field | Type | Meaning |
|---|---|---|
| `sequence` | `UInt64` | per-subscription counter, starting at `1` for the first notification after `SubscribeReply` |
| `revision` | `UInt64` | daemon progress-model revision represented by this event |
| `emittedAt` | `Date` | daemon emission time, ISO-8601 encoded by `CommandCoding` |
| `updateKind` | `ProgressUpdateKind` | `fullSnapshot` in `protocolVersion = 3` |
| `snapshot` | `[ProgressSnapshot]` | full current snapshot for the subscription scope |

`ProgressUpdateKind` is a flat string enum with one valid v3 case:
`fullSnapshot`. Future delta-capable progress sync must use a new
`protocolVersion`; v3 clients do not interpret unknown update kinds. Because v3
events are full snapshots, a removed in-scope job disappears from the next
snapshot rather than producing a delta operation. For a job-scoped subscription,
an empty snapshot means the watched job was removed by another client; for
`goh top`, replacing the whole displayed model with the new snapshot removes
stale rows.

`revision` is not a replay cursor in v3. It is a daemon-local monotonic model
revision that increments whenever the visible progress model changes. Coalescing
may cause a subscriber to observe skipped revisions; that is normal. `sequence`
is the per-subscription delivery counter for ordering events on one live
session. On reconnect, the new `SubscribeReply.revision` becomes the baseline.

`ProgressSnapshot` is:

| Field | Type | Meaning |
|---|---|---|
| `job` | `JobSummary` | the existing public job surface |
| `lanes` | `[TransferLaneProgress]` | active range/connection lanes for this job; empty when not active or before the scheduler has lane detail |

`TransferLaneProgress` is:

| Field | Type | Meaning |
|---|---|---|
| `index` | `UInt8` | stable display index within the current engine attempt |
| `state` | `TransferLaneState` | `pending`, `active`, `completed`, or `failed` |
| `rangeStart` | `UInt64?` | byte offset for the lane, when known |
| `rangeEnd` | `UInt64?` | inclusive byte offset for the lane, when known |
| `bytesCompleted` | `UInt64` | bytes written by this lane |
| `bytesTotal` | `UInt64?` | lane length, or `null` when unknown |
| `bytesPerSecond` | `UInt64` | recent lane throughput |
| `protocolName` | `String?` | observed URLSession protocol string such as `h2`, when known |
| `updatedAt` | `Date?` | last lane update time |

The lane vocabulary deliberately says "lane" instead of "connection": on
HTTP/2 the work may be multiplexed streams on one TCP connection, while the UI
still needs eight progress rows. `protocolName` is display-only and diagnostic;
the engine still does not select HTTP/1.1, HTTP/2, or HTTP/3.

A daemon-local `ProgressBroker` owns subscription fan-out. `JobStore` and the
download engine publish state changes into the broker; the broker keeps only the
latest in-scope snapshot and latest revision, then emits at most once per 100 ms
per subscriber. Intermediate updates are intentionally overwritten. Terminal
changes (`completed`, `failed`, `paused`, and `removed`) flush immediately so
the foreground CLI exits promptly and `goh top` does not display stale rows. If
a notification send fails because the peer is gone, the daemon removes that
subscriber and does not change job state. This preserves IPC §2.3's rule:
subscriber sessions are observers.

Foreground `goh <url>` sends the already-frozen `add` request, receives the new
`JobSummary`, then sends `subscribe(scope: job, jobID:)` on the same session and
renders progress until the job reaches `completed` or `failed`. Ctrl-C closes
the session and prints the detach note already specified in IPC §1.4. A later
`--cancel-on-interrupt` flag can issue `rm` before exiting, but the default is
detach.

`goh top` sends `subscribe(scope: all)` and renders every snapshot until the
user exits. It does not change job state.

If a foreground subscription loses the daemon session mid-download, the CLI uses
the existing bounded reconnect helper with a fixed 2.5 s window and 100 ms poll
interval. On reconnect, it validates the daemon by constructing a fresh
`GohXPCClient`, sends `subscribe(scope: job, jobID:)`, and resumes rendering from
the returned full baseline. If the window elapses, it exits `0` with the
existing "download continues in background" guidance. `goh top` may reconnect
the same way, but if it gives up it exits `1` because it is only a monitor, not a
foreground download that already created durable work.

**Considered alternatives.**
- *Reuse `ls` and keep the session open* — rejected: it makes a one-shot command
  carry long-lived stream semantics and turns progress into polling in disguise.
- *Add a second Mach service for progress* — rejected: mutual peer validation
  and launchd registration are already enough surface area; one validated
  session can carry the stream.
- *Deltas with update/remove operations in v3* — rejected for v0.1: they reduce
  already-small progress payloads, but they make reconnect, stale-client
  recovery, and removal semantics stateful before goh has measured scale that
  justifies it.
- *Aggregate-only job progress* — rejected: lane-level truth is how goh explains
  fast and slow downloads better than curl's local meter or aria2's polling
  status.
- *Push on every `JobStore.recordProgress` call* — rejected: it couples engine
  write cadence to terminal paint cadence and can make observers expensive.
- *Have clients poll `ls`* — rejected: it is simpler to implement but loses the
  local-native feel and wastes work when nothing changed.
- *Foreground `goh <url>` as an alias for `goh add`* — rejected: the roadmap
  promises live foreground progress, not a hidden detached add.
- *One combined `addAndSubscribe` command* — rejected: the existing `add` command
  already creates durable work; composing it with `subscribe` keeps the wire
  surface smaller and avoids a second way to create jobs.

**Final audit.**
- **Versioning:** adding `subscribe` is a new `Command` enum case and
  `ProgressEvent` is a new notification payload, so the contract correctly moves
  to `protocolVersion = 3` instead of mutating v1 or v2.
- **Envelope compatibility:** the canonical envelope keys remain unchanged.
  Progress notifications use the existing notification message kind and reuse
  the subscribe request's `requestID`; no new native XPC sibling keys are added.
- **Payload compatibility:** v1 and v2 payload structs are untouched. The new v3
  request, reply, and notification fields can be required because no v3 client or
  daemon has shipped yet.
- **Evolution:** `updateKind == fullSnapshot` makes the v3 semantics explicit,
  but adding a `delta` case or patch fields later is a new protocol-version
  decision. `revision` is explicitly not a v3 replay cursor, so reconnect cannot
  imply missed-event replay.
- **Observer safety:** subscriber sessions do not mutate job state after the
  initial foreground `add`; failed notification sends only remove subscribers.
- **Reconnect behavior:** foreground reconnect always receives a fresh full
  baseline. Skipped `revision` values are normal under coalescing and are not
  treated as lost data.

The contract is ready to implement once this design PR is reviewed and merged.

## Hashing

_TBD — SHA-256 via CryptoKit, streamed through the chunk assembler during the
download rather than re-read at the end._

## TUI

_TBD — visual rendering details for `goh <url>` and the `goh top` dashboard.
The wire contract above defines the data the TUI consumes._

## Dependencies

- **`apple/swift-http-types`** (pre-approved) — HTTP message modeling.
  Apple-published, MIT-licensed. `GohCore` re-exports `HTTPRequest`,
  `HTTPResponse`, `HTTPFields`, and `HTTPField` via explicit `public typealias`
  declarations rather than `@_exported import`. `@_exported` is an underscored,
  unsupported attribute and a likely breakage point across toolchains; explicit
  typealiases give a stable, deliberate re-export surface.
