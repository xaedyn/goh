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
> is resolved; once decisions land, this section is rewritten down to the
> conclusions and a separate branch implements it behind tests. Exact API
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

**Proposed answer.** (c). `GohRequest { protocolVersion, requestID, command }`,
where `command` is a `Command` enum with associated values (`.add`, `.list`,
`.pause`, `.resume`, `.remove`, `.subscribe`, …); replies are enveloped the same
way. The envelope carries cross-cutting fields (version, correlation ID); the
command enum gives the daemon a compiler-checked exhaustive switch. Defined once
in `GohCore`, all `Codable`.

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
- Ctrl-C on `goh <url>`: silent detach plus a one-line note, or an interactive
  prompt (detach / cancel / keep waiting)? Lean: silent detach + note.

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

**Proposed answer.** (c). The daemon persists job state and 1 MB checkpoints to
disk (already v0.1 scope); on crash-only relaunch it resumes in-progress
downloads from their checkpoints. An attached foreground CLI sees its session
invalidated and — consistent with "no reconnect logic" — prints `daemon
restarted; download continues — run goh ls` and exits. A reconnecting foreground
client is post-v0.1.

**Open.**
- Is exit-on-restart acceptable v0.1 UX, or is a single reconnect attempt for
  `goh <url>` worth the one piece of client reconnect logic? This is the one
  place the no-reconnect rule has a visible cost.

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
trust any future binary from our team. Enforcement happens once, at
session-accept time in the `XPCListener` handler, never per message.

**Open.**
- Dev builds (unsigned / ad-hoc-signed) will not satisfy the requirement — a
  documented dev escape hatch is needed (a debug build flag, or a dev signing
  identity). Exact requirement string confirmed at implementation.

#### 3.2 Does the CLI validate the daemon?
**Question.** Should `goh` verify it is talking to the genuine `gohd`, not an
impostor that registered the mach service name?

**Options considered.**
- (a) Trust the mach service name.
- (b) Mutually validate the daemon's audit token, the same way as 3.1.

**Proposed answer.** (b). Mutual validation. This matters most for
`goh auth import safari`, where the CLI hands cookie-derived credentials to the
daemon — sending those to a name-squatting impostor would leak them.

**Open.**
- Can a non-goh same-user process actually register `dev.goh.daemon` before
  `gohd` does, or does LaunchAgent service registration prevent it? The answer
  decides how load-bearing 3.2 is — needs a definitive answer before §3 locks.

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
envelope — just `protocolVersion` plus a `versionMismatch` marker — is declared
permanently stable and may never change shape.

**Open.**
- The exact frozen-subset definition is the load-bearing detail of this section
  and needs careful review.

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
- Two cases could still push us off pure `Codable`, both intersecting the auth
  slice: (i) `goh auth import safari` — does the CLI send parsed cookies (small,
  `Codable` — fine) or the raw `Cookies.binarycookies` blob (avoid)?
  (ii) file-descriptor passing — if the CLI holds Full Disk Access and the daemon
  does not, the CLI could open the cookie file and pass the *fd* over XPC rather
  than a path. Decide in the auth design; flagged here.

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
