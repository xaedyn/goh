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

> **Status: design draft, under review.** Each decision below is written as
> Question → Options considered → Proposed answer → Open, so rejected
> alternatives stay on the record. Nothing here is committed until the review PR
> is resolved; once decisions land, this section is rewritten down to
> conclusions — each decision keeping its rejected options as a *Considered
> alternatives* note rather than deleting them — and a separate branch
> implements it behind tests. Exact API
> spellings (Codable send/reply, audit-token access) are confirmed against
> current Apple docs at implementation — this draft commits to the *shape*, not
> the call signatures.

### Threat model (assumed)

Single-user macOS workstation. `gohd` runs as a per-user LaunchAgent and `goh`
runs as the same user. The threat is **other local processes, running as that
same user and not part of goh, attempting to drive or observe the daemon**. The
daemon holds sensitive state — download URLs, and (once `goh auth import` lands)
cookie-derived credentials — so same-user isolation is not a sufficient trust
boundary.

This is explicitly **not** a multi-user shared-host model and **not** an
app-sandbox boundary. If a future requirement pushes either way, the auth
granularity in §3 changes and must be re-surfaced.

### 1 · Message schema

#### 1.1 Request/reply envelope
**Question.** What is the top-level shape of a message?

**Options considered.**
- (a) One bespoke struct pair per command.
- (b) A single tagged-union enum carrying every command.
- (c) An envelope wrapping a command enum.

**Proposed answer.** (c). One uniform envelope for every message — request, reply,
and server notification: `{ protocolVersion, requestID, messageType, payload }`.
`protocolVersion` is the wire version (§4); `requestID` correlates a reply or
notification back to its originating request (§6); `messageType` discriminates
request / reply / notification / error; `payload` carries the type-specific body.
For a request, `payload` decodes to a `Command` enum (`.add`, `.list`, `.pause`,
`.resume`, `.remove`, `.subscribe`, …) — still a compiler-checked exhaustive switch
on the daemon. This key set is **canonical**: §4.3 freezes it, §5.2 extends it with
file-descriptor siblings. Envelope and payload types are defined once in `GohCore`.
The `payload` body is `Codable`; the envelope itself is a fixed-key XPC dictionary
(§4.3) that may *also* carry native XPC values — file descriptors — as sibling
entries (§5.2), so `Codable` covers the payload, not those siblings.

**Open.**
- Whether the envelope also carries a client-info block (e.g. pid) — settled with §6.

#### 1.2 Error model across the boundary
**Question.** How do daemon-side failures reach the CLI?

**Options considered.**
- (a) A shared typed `GohError` enum, serialized into the reply.
- (b) Stringly-typed error messages.
- (c) XPC-native transport errors only.

**Proposed answer.** (a). A `Codable` typed error enum conforming to the
`GohError` protocol, defined in `GohCore` and used on both sides; the reply
envelope models outcome as `Result<Payload, GohError>`. In-process `GohCore`
APIs use Swift typed throws (`throws(GohError)`); across XPC the error travels as
a serialized value. The CLI must handle two distinct layers: **transport errors**
(peer died, malformed message — XPC's own) and **domain errors** (`GohError`).

**Open.**
- Whether to flatten both layers into one CLI-facing `GohClientError` with
  `.transport` / `.daemon` cases for ergonomics.

#### 1.3 Progress streaming
**Question.** How does the CLI get live progress for `goh <url>` and `goh top` —
push or poll?

**Options considered.**
- (a) CLI polls a `getProgress` request on a timer.
- (b) Daemon pushes progress events; CLI exposes them as an `AsyncStream`.
- (c) Hybrid.

**Proposed answer.** (b). The daemon pushes `ProgressEvent`s over the session for
the lifetime of a subscription; the CLI wraps them in an
`AsyncStream<ProgressEvent>`. This needs a session held open for the
subscription's duration (see §2). Events are coalesced server-side on a timer
(~100 ms): progress is last-value-wins, so intermediate events are dropped rather
than buffered.

**Open.**
- Confirm coalesce-vs-buffer and the ~100 ms cadence — both cheap to tune.

#### 1.4 Cancellation semantics
**Question.** Who owns cancellation, and what happens to bytes already on disk?

**Options considered.**
- (a) A single "cancel" verb.
- (b) Distinguish *detach* from *cancel*.

**Proposed answer.** (b). **Detach** — Ctrl-C on a foreground `goh <url>`: the CLI
drops its session and exits; the job keeps running in the daemon, which is the
entire point of the daemon. **Cancel** — `goh rm <id>`: the daemon stops the job,
tears down its connections, and deletes the partial file and checkpoint by
default (`--keep` retains them). The daemon owns every job-state transition; the
CLI only ever *requests* them. Cancelling the client-side `Task` for an in-flight
XPC request never cancels daemon work.

**Open.**
- Resolved (review 1): Ctrl-C is a **silent detach plus a one-line note**, never
  an interactive prompt — Ctrl-C is muscle memory for "out now," and a confirm
  dialog is the opposite of what the user wants in that moment. The note names
  the job, e.g. `^C — download continues in background as job 42. 'goh ls' to
  check, 'goh rm 42' to cancel.` Cancel-on-interrupt is a `--cancel-on-interrupt`
  flag, not a prompt.

### 2 · Connection lifecycle

#### 2.1 Connection model
**Question.** One-shot connection per CLI invocation, or a long-lived multiplexed
connection?

**Options considered.**
- (a) **Long-lived multiplexed** — one daemon connection the CLI reuses across
  work. Efficient on paper, but pays for reconnect logic, in-flight
  reconciliation, and daemon-restart recovery on the client.
- (b) **One-shot** — open, one request/reply, close, exit.
- (c) **Hybrid** — one-shot for fire-and-forget verbs; a session held open only
  for the duration of a subscribing command.

**Proposed answer.** (c). Fire-and-forget verbs (`add`, `ls`, `pause`, `resume`,
`rm`) open a session, do one request/reply, close, and exit — sub-millisecond.
Subscribing commands hold a session open only as long as the CLI process lives.
No multiplexing across invocations, no persistent client connection, no reconnect
logic. The CLI is a remote control, not a streaming peer; XPC session setup is
cheap, so multiplexing would buy efficiency that does not matter against a real
complexity cost. **Refinement of the stated lean:** the real split is
*subscribing vs fire-and-forget*, not *`top` vs verbs* — `goh <url>` in its
foreground form is also a live-progress subscriber, so it sits with `top` on the
long-lived-for-its-duration side.

**Open.**
- Confirm `goh <url>` foreground belongs on the long-lived side alongside `top`.

#### 2.2 Daemon restart mid-download
**Question.** What happens when `gohd` crashes and launchd relaunches it while a
download runs and a CLI is attached?

**Options considered.**
- (a) Attached CLI exits on session loss.
- (b) Attached CLI reconnects to the new daemon and re-subscribes.
- (c) Attached CLI reports and exits; the daemon resumes the job itself.

**Proposed answer.** A *bounded* form of (b). The daemon persists job state and
1 MB checkpoints to disk (already v0.1 scope) and, on crash-only relaunch,
unconditionally resumes in-progress downloads from their checkpoints. An attached
foreground `goh <url>` sees its session invalidated, prints a visible
`reconnecting…` line, and makes **one** reconnection attempt — re-resolve the
daemon's Mach service, **re-validate its audit token** (§3.2 — the reattached peer
could be an impostor that claimed the name while `gohd` was down), and re-subscribe
to the *same job ID*. "One attempt" is bounded
by a short wait window (≈2–3 s), because a launchd-relaunched daemon is not
instantly back: it must restart, re-read job state, and re-register its listener,
so a single instant retry would almost always fire too early. If the window
elapses with no daemon, the CLI exits 0 with `download continues in background —
'goh ls' to check`. That one bounded attempt is the whole of the client's
reconnect logic — no multi-attempt retry state machine.

Rationale: the daemon owns download state, so a restart is not a CLI-side
recovery problem — the CLI only needs to reattach by job ID and resume streaming.
One bounded attempt is cheap; multi-attempt retry is where this becomes a state
machine nobody can reason about.

**Open.**
- Confirm the ≈2–3 s reconnection window — the one new tunable this introduces.

#### 2.3 CLI exits mid-stream
**Question.** What happens when the CLI is killed, Ctrl-C'd, or its terminal
closes during a foreground download or `top`?

**Options considered.**
- (a) The daemon treats subscriber-session death as a signal and cancels the job.
- (b) Subscriber-session death never affects job state.

**Proposed answer.** (b). The session closes; the daemon detects peer death on
the listener and stops pushing events to that subscriber. The job is unaffected
(detach, §1.4). **Rule:** subscriber sessions are observers — their death never
changes job state, and the daemon must tolerate a subscriber dying mid-send.

**Open.**
- None.

### 3 · Authentication & trust

The threat model is stated at the top of this section.

#### 3.1 Does the daemon validate the connecting client?
**Question.** Should `gohd` authenticate `goh`, and at what granularity?

**Options considered.**
- (a) No validation — trust any same-user process that reaches the mach service.
- (b) Validate the peer's code signature via its audit token, pinned to the
  genuine `goh` identity.
- (c) Validate Team ID only.

**Proposed answer.** (b). On each incoming session the listener reads the peer's
audit token and checks it against a code-signing requirement for the genuine
`goh` binary — our Team ID plus a designated requirement / identifier, **not** a
cdhash (a cdhash changes every build). A same-user process that is not the signed
`goh` cannot forge this and is rejected. Team-ID-only (c) is weaker — it would
trust any future binary from our team. Validation runs at session-accept time in
the `XPCListener` handler — on **every** incoming session, never cached across
sessions (per session, not per message).

**Open.**
- Dev builds (unsigned / ad-hoc-signed) will not satisfy the requirement — a
  documented dev escape hatch is needed (a debug build flag, or a dev signing
  identity). Exact requirement string confirmed at implementation.
- **Per-connection validation cost is unmeasured.** Reading the audit token is
  effectively free; evaluating the code-signing requirement is not — and mutual
  validation pays it *twice* per connection (daemon-validates-client §3.1 +
  client-validates-daemon §3.2), on the latency-sensitive path where every
  fire-and-forget verb opens a fresh connection. Benchmark at implementation.
  Rough triage, not a spec: under ~5 ms added to `goh ls` is invisible; ~5–20 ms
  is noticeable and worth a note; over ~20 ms needs a design response — and since
  the threat model fixes validation as per-connection, that response is cost-side
  (optimise the check), not caching.

#### 3.2 Does the CLI validate the daemon?
**Question.** Should `goh` verify it is talking to the genuine `gohd`, not an
impostor that registered the mach service name?

**Options considered.**
- (a) Trust the mach service name.
- (b) Mutually validate the daemon's audit token, the same way as 3.1.

**Proposed answer.** (b) — and the research below makes it warranted, not
paranoid. **Can a same-user process squat `dev.goh.daemon`?** Runtime squatting:
no. Configuration-time squatting: yes. Per `launchd.plist(5)`, a Mach service name
enters the bootstrap namespace only because a launchd job declares it in its
plist's `MachServices` dictionary; launchd registers and advertises the name, and
the job obtains the port's receive right via `xpc_connection_create_mach_service`
or `bootstrap_check_in`. XPC disallows ad-hoc registration — a process cannot
claim an arbitrary listener name at runtime. **But** a same-user attacker can
write its own LaunchAgent plist into `~/Library/LaunchAgents/` — a user-writable
directory, no elevation needed — declaring `MachServices: { dev.goh.daemon: true }`
with `Program` pointing at malware, and load it. If goh's own agent is not yet
installed, the attacker's job claims the name; once goh's agent is loaded, launchd
owns it and there is no runtime path to steal a live name. goh installs its agent
via `brew services`, which writes the plist into that same user-writable
`~/Library/LaunchAgents/` — not via the tamper-resistant `SMAppService` app-bundle
route — so the pre-stage squat is feasible under our threat model. Mutual
validation (b) is the mitigation: the CLI checks the daemon's audit token on
connect and detects an impostor before sending anything — most importantly the
`goh auth import safari` credential payload.

Validation is **per connection**, never cached. Because the squat is a planted
LaunchAgent rather than a runtime race, the peer behind `dev.goh.daemon` can
change between two `goh` invocations — and, most dangerously, across a §2.2
reconnect, where the "restarted daemon" the CLI reattaches to could be an impostor
that claimed the name while the real `gohd` was down. Every connection
re-validates the peer's audit token; there is no "we trusted this peer before"
shortcut.

Sources: `launchd.plist(5)`, the `MachServices` key
(<https://keith.github.io/xcode-man-pages/launchd.plist.5.html>); RDerik,
"Creating a Launch Agent that provides an XPC service on macOS"
(<https://rderik.com/blog/creating-a-launch-agent-that-provides-an-xpc-service-on-macos/>).

**Open.**
- None — the squat question is settled and (b) stands. The exact code-signing
  requirement string and the dev-build escape hatch are shared with §3.1.

### 4 · Version negotiation

The Homebrew formula installs `goh` and `gohd` together, so they ship at the same
version — but the daemon is long-lived and survives `brew upgrade`. After an
upgrade the *new* CLI talks to the *old* daemon until the service is restarted.
Skew is routine, not exotic.

#### 4.1 Where the version lives, and how mismatch is detected
**Question.** How do the two sides discover they disagree?

**Options considered.**
- (a) A `protocolVersion` integer in every envelope.
- (b) A dedicated handshake message before any command.
- (c) Compare full marketing versions.

**Proposed answer.** (a). A monotonic integer **wire-protocol** version — distinct
from the marketing version, bumped only when the XPC contract changes — travels
in the envelope on every request and reply. The first request/reply is itself the
handshake; no extra round trip. Marketing version is irrelevant to compatibility.

**Open.**
- In-band versus a dedicated handshake — in-band is simpler and works for
  one-shot sessions; leaning in-band.

#### 4.2 Behavior on incompatible versions
**Question.** What happens when the two versions differ?

**Options considered.**
- (a) Exact-equality compatibility.
- (b) A supported-range with an adapter layer.

**Proposed answer.** (a) for v0.1 — a range/adapter layer is too much machinery
this early. On mismatch the daemon replies
`GohError.protocolVersionMismatch(client:daemon:)` and the CLI prints an
actionable line: `the goh daemon is running an older version — restart it with
'brew services restart goh'`. **The crux:** that mismatch reply must be decodable
by *both* an old and a new CLI, so a tiny **frozen negotiation subset** of the
envelope — `protocolVersion` and `messageType` (which carries the
`versionMismatch` marker) — is declared permanently stable and may never change
shape.

**Open.**
- The encoding of that frozen subset is its own decision — see §4.3.

#### 4.3 Encoding the frozen negotiation subset
**Question.** The mismatch reply (§4.2) must stay decodable by every past and
future version. How is that frozen subset encoded so an envelope refactor cannot
silently break the wire contract?

**Options considered.**
- (a) **Hand-rolled byte framing.** The envelope is a fixed byte layout —
  `protocolVersion` as a 4-byte big-endian `UInt32` at offset 0, `messageType` as
  a length-prefixed UTF-8 string, payload after — encoded and decoded by hand,
  never through `Codable`.
- (b) **Fixed-key XPC dictionary.** The envelope is a native XPC dictionary with
  a permanently fixed key set — `protocolVersion`, `requestID`, `messageType`,
  `payload` (§1.1) — read with primitive `xpc_dictionary_get_*` accessors before
  any `Codable` decode. The `payload` value is a `Codable` blob, decoded with the
  decoder chosen by `protocolVersion`; the envelope may *also* carry native XPC
  values — file descriptors (§5.2) — as sibling entries beside these keys, which
  are not part of the `Codable` payload.

**Proposed answer.** (b) — and this diverges from the review-1 lean toward (a),
so it is flagged for argument. The *instinct* behind (a) is correct and adopted:
freeze the envelope, isolate it from payload evolution, and always be able to
read the version even off a message you otherwise cannot decode. The *mechanism*
is where (b) wins. XPC is not a raw byte stream; it is a keyed, structured-message
IPC, and an XPC dictionary is unordered key-value — reading the frozen keys by
name is order-independent and stable, and adding a further key later never
disturbs the existing ones. Hand-rolled byte framing buys nothing
over that on a keyed transport and adds a bespoke length-prefix parser that can
carry its own bugs. The "Codable reorders fields" failure mode also does not apply
to keyed encoders — XPC dictionaries, `JSONEncoder`, and `PropertyListEncoder` are
all keyed; Codable wire breakage comes from renaming a property without
`CodingKeys`, retyping a field, or removing a required one — never from field
order. "Frozen" therefore means a policy enforced by the checklist below and the
golden-file tests, not a hand-coded layout. The one case that would revive (a):
if goh ever expects to carry this protocol over a non-XPC transport, byte framing
becomes transport-independent — but that is not foreseen, and designing for it now
is premature.

**Wire-incompatible change checklist** — any one of these is a breaking change and
requires a new `protocolVersion`:
- Renaming, removing, or retyping **any envelope key once it has shipped** —
  `protocolVersion`, `requestID`, `messageType`, `payload`, or any key added
  later. The envelope's key set is append-only; every shipped key and its
  primitive type is a permanent part of the frozen contract and may never be
  renamed or retyped.
- Renaming or removing a field in a payload type, or changing its type, for an
  existing `protocolVersion`.
- Adding a *required* (non-optional, no-default) field to an existing payload type.
- Changing the meaning of an existing field's accepted values.
- Changing how `protocolVersion` itself is encoded.

Adding an *optional* field to a payload type, or defining a new `messageType`, is
backward-compatible and does not bump the version.

**Open.**
- The wire-incompatibility checklist above is enforced by a **golden-file test
  suite** on the implementation branch — it is the checklist's CI mechanism, not a
  generic regression test. Recorded request/reply messages are committed to the
  repo and decoded by current code; a renamed or retyped envelope key, or a
  changed payload field, makes a recorded message fail to decode and fails CI.
- **Fixtures for shipped `protocolVersion` values are immutable.** A
  `protocolVersion = 1` fixture is never edited — new versions only ever *add*
  fixtures. Editing an existing fixture to make a test pass is the exact pattern
  that ships a wire break: it moves the goalpost instead of catching the regression.
- Checklist item 4 — *changing the meaning of an existing field's accepted
  values* — is **not** catchable by the golden-file suite: the bytes are
  identical, only the semantics moved. It requires human review against a
  documented per-version semantics note, not CI.
- Confirm at implementation that the Swift XPC API exposes top-level dictionary
  fields via primitive accessors independently of decoding the payload value.

### 5 · Serialization

#### 5.1 Codable as the default codec
**Question.** `Codable` over the Swift XPC API, or something else — and what would
force us off it?

**Options considered.**
- (a) `Codable` message types via the Swift XPC API's Codable support.
- (b) Hand-built `xpc_dictionary` messages.
- (c) A nested codec (JSON, protobuf) inside XPC payloads.

**Proposed answer.** (a). `Codable` end to end — it matches the envelope plus
command-enum model, gives compiler-checked exhaustiveness, and adds no
third-party dependency. Crucially, **downloaded file content never crosses XPC**:
the daemon `pwrite`s bytes straight to disk, and the CLI receives only small
control messages and progress events. There is no bulk-payload pressure that
would justify (b) or (c).

**Open.**
- The one case that could push us off pure `Codable` is the Full Disk Access
  cookie path — see §5.2, which decides whether the XPC layer must also carry a
  file descriptor.

#### 5.2 File descriptors and the Full Disk Access path
**Question.** `goh auth import safari` reads Safari's `Cookies.binarycookies`,
which is gated by Full Disk Access. Which process holds FDA and does the read,
and what crosses XPC?

**Options considered.**
- (a) **Daemon reads.** The user grants Full Disk Access to `gohd`; the CLI sends
  `importCookies(.safari)` and the daemon opens, reads, and parses the file.
  Nothing cookie-related crosses XPC.
- (b) **CLI reads, passes the fd.** `goh` — the binary the user actually runs —
  holds FDA; on `goh auth import safari` it opens the cookie file and passes the
  open *file descriptor* over XPC. The daemon reads and parses from the fd and
  never needs FDA.
- (c) **CLI reads and parses, sends structured cookies.** `goh` holds FDA, parses
  `binarycookies` itself, and sends a `Codable` array of cookie records. Only
  structured data crosses XPC — no file, no fd.

**Proposed answer (tentative — the Auth slice owns the final call).** Lean (b).
Granting FDA to the interactively-run `goh` is a more natural mental model than
FDA on a launchd-managed background agent — TCC prompting is unreliable for
non-app daemons, and a permanently FDA-bearing daemon is a broad standing
capability. Passing the fd rather than parsed records (b over c) keeps the
`binarycookies` parser in one place — `GohCore`, daemon-side, next to where
cookies are used — and off the short-lived CLI; an fd is a small XPC primitive,
not a bulk blob. (a) is simplest for the XPC contract but pushes the awkward
FDA-on-a-daemon UX onto the user. The binding decision is **deferred to the Auth
slice**; it is surfaced here because it settles one thing for *this* contract —
whether the XPC layer must carry a file descriptor.

**Open.**
- The binding call belongs to the Auth slice. For the IPC contract, lock only
  this: the envelope must be able to carry one or more file descriptors as native
  XPC sibling entries beside its `payload` (§1.1, §4.3) — *not* inside the
  `Codable` payload, since a file descriptor is not `Codable`. Option (b) needs
  this, and fd-passing is plausibly useful elsewhere; allowing sibling fd entries
  in the envelope now is cheap, retrofitting it is not.

### 6 · Observability

#### 6.1 Debugging a failed XPC interaction
**Question.** When an XPC exchange goes wrong, how do we see why?

**Options considered.**
- (a) `print` / the LaunchAgent logfile only.
- (b) Structured unified logging.
- (c) Signpost-based tracing.

**Proposed answer.** (b). Structured logging via `os.Logger` under subsystem
`dev.goh` with categories (`xpc`, `queue`, `transport`, …), in both processes.
`log stream --predicate 'subsystem == "dev.goh"'` then gives one live
cross-process view. Every message carries the envelope's `requestID`, logged on
both sides, so a request and its reply correlate across the two processes. The
daemon logs every session accept/reject (with the validated identity or rejection
reason, §3) and every command. **Privacy is a correctness requirement:** URLs and
any credential-bearing fields are logged with `privacy: .private` so secrets never
reach the system log.

**Open.**
- A verbosity control — an env var read by the daemon at launch, plus `--verbose`
  on the CLI.
- `OSSignposter` transfer-performance instrumentation — lean: defer to the
  transport slice.
- Unified logging is separate from the LaunchAgent's `goh.log` stdout/stderr file;
  the split (queryable structured logs vs crash output) is stated here once
  decisions land.

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
