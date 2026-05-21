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

## Transport

_TBD — HTTP/2 and HTTP/1.1 over `NetworkConnection` with ALPN negotiation;
range-based parallelism (8 connections default). HTTP/3 is a v0.2 design pass._

## Persistence

_TBD — `pwrite(2)` chunk writes indexed by range offset; `F_PREALLOCATE` for
contiguous extents; `F_NOCACHE` above 1 GB; checkpoint to disk every 1 MB._

## IPC

_TBD — modern low-level Swift XPC API (macOS 14+), not `NSXPCConnection`.
Audit-token code-signature validation. The `goh`/`gohd` contract is the next
slice after this bootstrap._

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
