# CLAUDE.md — goh operating manual

The manual a fresh Claude Code session reads to understand how this project
works. Read it first, then `STATE.md`, `DESIGN.md`, `ROADMAP.md` — in that order
— at the start of every session (see **Session rituals**).

## Project identity

`goh` is a daemon-backed terminal download manager for macOS 26.5+ on Apple
Silicon, building toward v0.1. The name is short and lowercase, pronounced
"go." Keep all naming, copy, and visuals original and neutral: no catchphrases,
no third-party franchise or brand allusions, and no borrowed iconography in
code, comments, documentation, or artwork.

## Stack

Verified May 2026 against `Package.swift`, `DESIGN.md`, and `ci.yml`.

- **Swift** — `swift-tools-version` 6.2 (the `.defaultIsolation` floor); the repo
  builds with the Swift 6.3.x toolchain. Swift 6 language mode with per-target
  `.defaultIsolation`: MainActor-default on `goh` and `GohTUI`,
  nonisolated-default on `GohCore` and `gohd`. No upcoming-feature flags.
- **HTTP transport** — `URLSession`, with `apple/swift-http-types`
  (`HTTPRequest` / `HTTPResponse`).
- **IPC** — the modern low-level Swift XPC API (`XPCSession` / `XPCListener`,
  macOS 14+), with `XPCPeerRequirement` for mutual peer validation.
- **Hashing** — `CryptoKit` SHA-256, streamed during the download.
- **Tests** — Swift Testing (not XCTest).
- **Distribution** — a `launchd` LaunchAgent, installed via `brew services`.
- **Platform** — SwiftPM manifest floor `platforms: [.macOS("26.0")]`; supported
  OS macOS 26.5+. The floor rises to `.macOS("26.5")` in the same PR as the
  first 26.5-only API — never speculatively, and with no `#available` ladders
  (the floor moves as a whole; the code does not fork). See `DESIGN.md`
  §Platform support.

## Hard constraints

- `URLSession` was originally banned by the project brief; that decision was
  reversed during Slice 3a verification — see `DESIGN.md` §Transport,
  "Transport mechanism revision."
- CI runs the stable default Xcode only. No beta toolchains, ever.
- No Electron, no Node, no Python at runtime.
- Apple frameworks first; a third-party dependency needs explicit justification.
- License: MIT.

## Working style

- **Propose, don't commit, on anything load-bearing.** Surface a decision as a
  question *before* acting on it when any of these three triggers holds:
  1. it cannot be reversed in a single commit;
  2. it conflicts with `DESIGN.md` or `ROADMAP.md`;
  3. it is being made because of a stated rule of the user's — confirm the rule
     before treating it as binding.
  Everything else is judgment, recorded with a note in the PR description.
- Verify framework behaviour against current Apple docs before locking it in.
- Small, atomic commits; Conventional Commit messages; feature branches always,
  never a direct commit to `main`.
- `DESIGN.md` stays current — every non-obvious decision gets a paragraph the
  day it is made.

## Four-round design discipline

Returns **only** for load-bearing decisions that ship into a frozen contract —
wire formats, persistent on-disk formats an external tool might read, anything
in `protocolVersion = N` for the current `N`. The pattern:

1. Draft — each decision as Question / Options considered / Proposed answer / Open.
2. Review rounds, until convergence.
3. Rewrite down to conclusions, each keeping a *Considered alternatives* note.
4. Final audit pass.
5. Merge — the contract is frozen.

Normal implementation slices use normal review cadence; no four-round overhead.

## Test discipline

- Swift Testing, not XCTest.
- CI builds with `-warnings-as-errors`.
- Exhaustive transition tests wherever a state machine exists.
- Golden-file fixtures for any wire format.
- CI runs on the `macos-26` runner — not `macos-latest`, which still resolves to
  macOS 15 until a migration beginning 2026-06-15, and macOS 15 carries no
  macOS 26 SDK and no Swift 6.2+.

## Branch discipline

Feature branches always — never commit to `main` directly:

- `feat/<slice>` — features
- `fix/<defect>` — defects
- `chore/<task>` — housekeeping
- `docs/<topic>` — docs-only changes
- `design/<contract>` — design rounds on frozen-contract work

## Known recurring gotchas

- **Cross-SDK skew on C-bridged Apple APIs.** Some C-imported signatures differ
  between SDKs — e.g. `xpc_dictionary_set_data`'s `bytes` parameter is
  non-optional under one SDK and optional under another (SDK 26.2 vs 26.5). Fix
  portably by unwrapping to a non-optional pointer. Recurs until the manifest
  floor bumps to 26.5.
- **`XPCListener` and `XPCSession` are active on creation.** Calling
  `activate()` on them trips `_xpc_api_misuse`. Do not call it.
- **Toolchain selection.** The user runs
  `sudo xcode-select --switch /Applications/Xcode.app` manually; setting
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` is the fallback for
  a `swift` invocation that needs the full Xcode toolchain.

## Session rituals

**At the start of every session:** read `CLAUDE.md`, `STATE.md`, `DESIGN.md`,
`ROADMAP.md`, in that order. Summarize back to the user — current project
state, current slice, next planned action, any pending questions — and do not
start work until the user confirms the summary matches their understanding.

**At the end of every session:** update `STATE.md` with the current state.
Commit and push all in-progress work to the feature branch, with a `WIP:` prefix
on the commit when the work is incomplete. Write a *Next-session handoff* note
at the bottom of `STATE.md` saying what to pick up next.

## Keeping these files current

- **`STATE.md`** is updated at the start of every PR (new branch, new slice) and
  at the end of every session (progress, handoff note).
- **`CLAUDE.md`** is updated when a working-style rule changes, the stack
  evolves, or a new recurring gotcha is found worth recording.
- In short: `STATE.md` is *where we are now*; `CLAUDE.md` is *how we work*;
  `DESIGN.md` is the architectural decisions; `ROADMAP.md` is the scope.
