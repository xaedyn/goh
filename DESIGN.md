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

_TBD — `pwrite(2)` chunk writes indexed by range offset; `F_PREALLOCATE` for
contiguous extents; `F_NOCACHE` above 1 GB; checkpoint to disk every 1 MB._

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
stay consistent for a later `resume`. Pausing an already-paused or completed job
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

## Scheduling

_TBD — job queue, range-connection scheduling, `nw_path_monitor`-driven
auto-pause on cellular._

## Auth

_TBD — Safari `Cookies.binarycookies` import behind Full Disk Access, with a
clear permission prompt and graceful handling of revocation._

## Hashing

_TBD — SHA-256 via CryptoKit, streamed through the chunk assembler during the
download rather than re-read at the end._

## TUI

_TBD — live progress rendering for `goh <url>` and the `goh top` dashboard._

## Dependencies

- **`apple/swift-http-types`** (pre-approved) — HTTP message modeling.
  Apple-published, MIT-licensed. `GohCore` re-exports `HTTPRequest`,
  `HTTPResponse`, `HTTPFields`, and `HTTPField` via explicit `public typealias`
  declarations rather than `@_exported import`. `@_exported` is an underscored,
  unsupported attribute and a likely breakage point across toolchains; explicit
  typealiases give a stable, deliberate re-export surface.
