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

_TBD — HTTP/2 and HTTP/1.1 over `NetworkConnection` with ALPN negotiation;
range-based parallelism (8 connections default). HTTP/3 is a v0.2 design pass._

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

> **Status: design draft, under review.** Each decision is written as
> Question → Options considered → Proposed answer → Open — the format the XPC
> contract round used. Nothing here is committed until the review PR is
> resolved; once decisions land, this section is rewritten to conclusions
> (rejected options kept as *Considered alternatives* notes) and merged into
> `protocolVersion = 1`, where it freezes under the §4.3 rules.
>
> **This round freezes the job model's public surface, not only the wire
> format.** `ls`'s reply *is* the externally-visible shape of a download job —
> its identifier, states, progress, and errors. The daemon-job-model slice that
> follows implements the job's *internals* behind this surface; it does not
> re-decide identifier, state, progress, or error shape. Those are settled here
> and frozen on merge — a later slice has no authority to revisit them.

This round schematizes the five request/reply commands — `add`, `ls`, `pause`,
`resume`, `rm`. `goh top` is a server-pushed subscription (§1.3), not a
request/reply command; its `ProgressEvent` schema is a separate slice.

Command **failures** travel the §1.2 error channel: a reply envelope is
`Result<Payload, GohError>`, so a `pause` of a missing job returns `.failure`,
not a command-specific error payload. The schemas below define the **success**
payloads.

### 1 · Shared types

#### 1.1 Job identifier
**Question.** What type identifies a job — on the wire and to the user?

**Options considered.**
- (a) `UUID`, consistent with the envelope's `requestID`.
- (b) A daemon-assigned monotonic integer, persisted across daemon restarts.
- (c) A human-friendly short string (`job-42`).

**Proposed answer.** (b). A `UInt64` assigned by the daemon from a counter
persisted alongside job state — the daemon already persists state to disk, so the
counter survives restarts with no reuse and no collision. The decisive factor:
the job identifier is **typed by the user** (`goh rm 5`, `goh pause 5`), unlike
`requestID`, which is machine-only correlation — so typeability dominates and a
`UUID` is unusable at a prompt. (c) is (b) with a display prefix; the prefix is a
CLI presentation choice, not a wire concern — the wire carries the integer.

**Open.**
- Confirm `UInt64` over `UInt32`: `UInt32` (4 billion jobs) is ample, but `UInt64`
  is the natural counter width and persistence makes wraparound moot either way.

#### 1.2 Job state
**Question.** What are a job's states, and how are they carried on the wire?

**Options considered.**
- (a) A flat enum on `JobSummary`, with state-specific detail in sibling
  top-level fields.
- (b) An enum whose `paused` and `failed` cases carry associated values.

**Proposed answer.** (a) — settled by the first-round audit (A3.1). `JobState`
is a flat enum — `queued`, `active`, `paused`, `completed`, `failed` — carried
as `JobSummary.state`. State-specific detail rides in sibling top-level fields of
`JobSummary`, present only in the state they belong to:
- `pauseReason` — present when `state == paused`; a `PauseReason`, which is
  `user` or `network`. A job *waiting for a connection slot* is `queued`, not
  `paused` — `queued` is a state, not a pause reason. (`system` / sleep is not a
  distinct reason: on macOS, sleep drops the network and `nw_path_monitor`
  reports it as a `network` pause. Deferred to v0.2 if a future macOS makes the
  distinction real.)
- `error`, `retryEligible`, `failedAt`, `retryCount` — present when
  `state == failed`; their types are in §2's `JobSummary` and `error`'s shape in
  §1.4. Failure metadata is top-level, so it needs no wrapping struct and each
  field evolves additively under §3.

**Internal invariant, wire flexibility.** The wire schema permits a nonsensical
combination — `state: active` with a populated `error` — but the daemon, which
owns the job model, never emits one: a sibling field is populated *if and only
if* `state` is the state it belongs to, and consumers may rely on that. The
invariant is enforced in the daemon, not expressed in the wire type — a
deliberate trade: the flat shape carries a representable-but-never-emitted
invalid state, and in exchange gives clean `jq` access and additive evolution.

**Considered alternatives.**
- *(b) Associated-value enum (`paused(PauseReason)`, `failed(GohError)`)* —
  rejected. Swift's synthesised `Codable` for associated-value enums nests the
  payload (`{"failed":{"_0":{…}}}`), hostile to `goh ls --json | jq`; and
  changing a case's associated type is a wire-incompatible change (§4.3),
  whereas a flat enum gains cases additively and sibling fields evolve under §3.
  Its one gain — unrepresentable invalid states — is recovered by the
  daemon-side invariant above, without the wire cost.

**Open.**
- None — the first-round audit (A3.1) settled this.

#### 1.3 Progress
**Question.** What does a job's progress look like in `ls`'s reply?

**Options considered.**
- (a) Aggregate only — bytes done, bytes total, throughput.
- (b) Per-connection — an array of the 8 range-connection states.
- (c) Both, per-connection nested inside aggregate.

**Proposed answer.** (a) for `ls`. `JobProgress`: `bytesCompleted: UInt64`,
`bytesTotal: UInt64?` (nil when the server sent no length), `bytesPerSecond:
UInt64`. `goh ls` is a status list; the 8-connection breakdown belongs to
`goh top`, whose `ProgressEvent` is the separate subscription slice — carrying 8
connection states in every `ls` row would bloat the common case for a view that
does not show them.

**ETA is deliberately not a field.** ETA is `(bytesTotal - bytesCompleted) /
bytesPerSecond` — a value the consumer computes trivially from the three fields
above. Carrying a derived value on the wire only invites encoder/consumer
disagreement; the CLI computes it. When `bytesTotal` is nil, ETA is unknowable
and the consumer renders an indeterminate state.

**Open.**
- Whether `goh ls --verbose` ever wants per-connection detail — if so it is an
  additive optional field later, not a v1 obligation.
- `bytesTotal` is optional — confirm `ls` and the TUI render an indeterminate
  state gracefully when it is nil.

#### 1.4 Error shape
**Question.** What is a `GohError`'s shape, and which `ErrorCode` categories must
it cover?

**Proposed answer.** `GohError` is `{ code: ErrorCode, message: String? }` — a
typed `code` the CLI branches on (exit codes, retry prompts) without parsing
prose, plus optional human-readable `message`. `ErrorCode` is a closed enum of
fifteen categories, each with a remedy path:

| `ErrorCode` | Meaning | Remedy |
|---|---|---|
| `dnsResolutionFailed` | the host name did not resolve | check the URL / connectivity |
| `connectionFailed` | TCP connection refused or unreachable | retryable — check connectivity |
| `tlsFailure` | TLS handshake or certificate failure | not retryable — the host's TLS is broken |
| `timedOut` | the connection or transfer timed out | retryable |
| `httpStatus` | the server returned a 4xx / 5xx status | depends — see `message` |
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

Three deliberate exclusions:
- **Retry-eligibility is not derived from `code`.** It is the explicit
  `retryEligible: Bool` field on a failed `JobSummary` (§1.2). The daemon decides
  it — an `httpStatus` 503 is retryable, a 404 is not, and `code` alone cannot
  tell them apart — so the daemon states it rather than the consumer inferring it.
- **`rangeNotSupported` is not an `ErrorCode`.** A server that does not honour
  `Range` is not a failure — the daemon falls back to a single connection and the
  download proceeds. The downgrade is observable as
  `JobSummary.actualConnectionCount` (§2), not as an error.
- **Daemon shutdown is not a `GohError`.** A request in flight when the daemon
  stops surfaces as an XPC *transport* error — the connection invalidates — not a
  `reply`-envelope `.failure`. `GohError` is reply-level; the transport layer is
  the IPC contract's §3.

The numeric HTTP status for an `httpStatus` error is carried in `message` (e.g.
"HTTP 404 — Not Found"). If a machine-readable status is wanted, an additive
`httpStatusCode: Int?` is a §3-compatible later addition.

**Open.**
- Confirm the fifteen-case list is complete for v0.1.

### 2 · Commands

A command's **request** is the `payload` of a `request`-kind envelope; its
**reply** is the `Result<…, GohError>` payload of a `reply`-kind envelope (§1.2).
A mutating command returns the **resulting `JobSummary`** so the CLI need not
issue a follow-up `ls`.

`JobSummary` — the job's public surface, returned by every job-bearing reply:
- `id: UInt64`, `url: String`, `destination: String`
- `state: JobState`, `progress: JobProgress`
- `createdAt: Date` — when `add` created the job
- `lastProgressAt: Date?` — when `progress` last advanced (nil if it never has).
  The *consumer* judges staleness from it (e.g. "no progress for 60 s"); the
  daemon does not decide what "stale" means.
- `actualConnectionCount: Int` — connections currently in use (0 when not
  actively downloading); below the requested `connectionCount` when the server
  forced a single-connection fallback (§1.4).
- `pauseReason: PauseReason?` — present iff `state == paused`.
- `error: GohError?`, `retryEligible: Bool?`, `failedAt: Date?`,
  `retryCount: Int?` — present iff `state == failed`.

#### 2.1 `add`
**Question.** What are `add`'s request and reply payloads, how does it reference
imported Safari cookies, and how is a job's priority expressed?

**Options considered (cookie reference).**
- (a) A cookie-import id — `goh auth import` returns an id; `add` passes it.
- (b) URL-domain match — the daemon, holding the cookie store, automatically
  attaches cookies whose domain matches the URL.
- (c) Both.

**Proposed answer.** Request: `{ url: String, destination: String?,
connectionCount: Int?, useImportedCookies: Bool?, priority: Int? }`. Reply: the
new job's `JobSummary`, state `queued`. Defaults for absent fields are frozen
(§3): `destination` → derived from the URL; `connectionCount` → 8;
`useImportedCookies` → true; `priority` → TBD (see Open).
Cookie reference: **(b), with opt-out**. `add` carries no cookie id; the daemon
matches cookies by domain. `useImportedCookies: false` (CLI `--no-cookies`) opts
out. The v0.1 UX is "import once, then it just works" — making the user carry an
id from a prior command is friction a download manager should not impose; the
opt-out covers "do not send my cookies to this host."

**Open.**
- **Priority scale — sub-question for this round.** `priority: Int?` needs a
  defined scale: `0`–`9`, `-5`–`+5`, or a `low` / `normal` / `high` string enum.
  A string enum reads best at the CLI and on the wire and resists the "what does
  `4` mean?" problem; an integer is finer-grained but opaque. Leaning the string
  enum. The frozen default (§3) follows from the choice — `normal`, or the
  scale's midpoint.
- (b) is implicit — the user may not see that cookies were attached. Mitigation:
  `add` prints a one-line note when cookies matched ("attached cookies for
  example.com"). Confirm that disclosure is enough.
- A future `--expect-sha256 <digest>` (verify against a user-supplied digest) —
  not v0.1 (ROADMAP §8 *computes* SHA-256, it is not user-supplied). Additive if
  wanted; flagged so the field is not retrofitted awkwardly.

#### 2.2 `ls`
**Question.** What are `ls`'s request and reply payloads?

**Options considered.**
- (a) Empty request, full job list.
- (b) Request carries a state filter / pagination.

**Proposed answer.** (a). Request: `{}` — `ls` lists every job. Reply:
`{ jobs: [JobSummary] }` in daemon order (creation order). A download manager's
job count is small; pagination is unwarranted, and a state filter is an additive
optional request field if ever wanted. The CLI sorts/filters client-side.

**Open.**
- None — the v1 obligation is `[JobSummary]` in creation order.

#### 2.3 `pause`
**Question.** What are `pause`'s payloads, and what does it do to an in-flight
chunk?

**Proposed answer.** Request: `{ jobID: UInt64 }`. Reply: the updated
`JobSummary` — `state` `paused`, `pauseReason` `user`.
**Boundary behavior.** `pause` is **graceful**: the daemon lets the in-flight
chunk's `pwrite` complete (a ≤1 MB write — sub-millisecond, bounded), writes the
checkpoint, then transitions to `paused`. It never interrupts mid-write, so the
partial file and checkpoint stay consistent for a later `resume`. Pausing an
already-paused or completed job is a no-op returning the current summary.

**Open.**
- None.

#### 2.4 `resume`
**Question.** What are `resume`'s payloads?

**Proposed answer.** Request: `{ jobID: UInt64 }`. Reply: the updated
`JobSummary`, state `active` (or `queued` if the scheduler is at its connection
budget). `resume` clears `paused` and re-enters the scheduler; resuming a `user`-
and a `network`-paused job is the same operation; resuming a non-paused job is a
no-op returning the current summary.

**Open.**
- None.

#### 2.5 `rm`
**Question.** What are `rm`'s payloads, and what does it do to an active job's
in-flight chunk and partial file?

**Proposed answer.** Request: `{ jobID: UInt64, keepPartialFile: Bool? }`
(`keepPartialFile` nil → false; CLI `--keep`). Reply: `{ removedJobID: UInt64 }`.
**Boundary behavior.** `rm` of an active job stops it and tears down its
connections. Without `--keep`, the partial file and checkpoint are deleted — an
in-flight chunk write may be abandoned, since the file is going away. With
`--keep`, the daemon lets the in-flight chunk complete and checkpoints before
retaining the partial, so the kept file is resumable by a future `add`.

**Open.**
- `rm` of a *completed* job: proposed to drop it from the job list only — `rm`
  never deletes a finished download from disk, and `--keep` is irrelevant for a
  completed job. Confirm.

### 3 · Reply field evolution within `protocolVersion = 1`

**Question.** Are reply schemas frozen exactly, or may point releases add fields?

**Proposed answer.** Reply schemas follow the §4.3 rule already established for
the envelope: **adding an optional field is backward-compatible** within
`protocolVersion = 1` and does not bump the version; renaming, removing,
retyping, or adding a *required* field is wire-incompatible and bumps it.
Decoders **ignore unknown fields** (Codable does so by default), so a newer
daemon's added field does not break an older CLI. The reply shape is therefore
frozen against breaking changes, open to additive optional fields — not frozen
exactly.

**Frozen request defaults.** The default value applied to an *absent* optional
request field is itself part of the frozen contract. Changing a default across a
point release is wire-compatible at the type level — no field changed type — but
it silently changes behaviour for every client that relied on the old default,
which is a real-world break. **A default change therefore requires a
`protocolVersion` bump.** The frozen v1 defaults: `add.destination` → derive from
the URL; `add.connectionCount` → 8; `add.useImportedCookies` → true;
`add.priority` → TBD (§2.1); `rm.keepPartialFile` → false.

**Open.**
- None — the §4.3 rule applied to replies, plus the request-default corollary,
  stated here so neither is re-litigated.

### 4 · Adversarial stress-test

Each schema, walked against what the brief and `ROADMAP.md` say the v0.1 engine
must do — designed to the *specified* engine, not a guessed one.

**Completeness rule.** A per-command walk must check *every* field in the
relevant schema and every field a documented engine capability will produce —
not only the obvious progress fields. For `ls` specifically that means: creation
timestamp, staleness indicator, ETA (or its derivation justification),
retry-eligibility presentation, and a remedy path for every `ErrorCode`. The
first-round audit found this section had skipped exactly those; the rule exists
so the next completeness gap is caught here, not in review.

- **`add`** — the engine needs a URL, a destination, a connection count (8
  default, tunable — ROADMAP §6), cookie auth (§9), and a queue priority. The
  request carries all five. SHA-256 verification (§8) is *computed during* the
  download, not user-supplied, so no request field is needed. **Gap check: none.**
- **`ls` reply / `JobSummary`** — walked field by field. `id` / `url` /
  `destination` ✓; `state` (flat enum) ✓; `progress` —
  `bytesCompleted` / `bytesTotal` / `bytesPerSecond` ✓, ETA derived by the CLI
  (§1.3) ✓; `createdAt` ✓; `lastProgressAt` ✓ (the staleness signal, consumer-
  judged); `actualConnectionCount` ✓ (a single-connection fallback is visible);
  `pauseReason` ✓; `error` / `retryEligible` / `failedAt` / `retryCount` ✓
  (failure cause, retry-eligibility, and failure metadata all present). Every
  `ErrorCode` has a remedy path in §1.4's table. **Deliberately not in `ls`:**
  per-connection (8-way) progress and the 1 MB checkpoint offset — `goh top` /
  the subscription slice. **Gap check: none.**
- **`pause` / `resume`** — the engine needs the job ID and must distinguish user
  from network pause (§12 cellular auto-pause). Schema: `jobID` ✓, `pauseReason`
  ✓. **Gap check: none.**
- **`rm`** — the engine needs the job ID and the keep-or-delete choice for the
  partial (§1.4 cancellation). Schema: `jobID` ✓, `keepPartialFile` ✓. **Gap
  check: none.**
- **Cross-cutting** — the 1 MB checkpoint (§7) is engine-internal; it surfaces to
  the user as `bytesCompleted` and `lastProgressAt`, confirmed needing no
  separate field. Spotlight tagging, the sleep assertion, and `nw_path_monitor`
  (§10–§12) are daemon behaviors with no command-schema surface.

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
