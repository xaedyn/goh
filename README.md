# goh

> **v0.1 — in development.** The daemon, download engine, CLI controls, foreground
> progress, and `goh top` dashboard are in place. Release packaging is being
> prepared privately; no official install channel or tagged v0.1.0 artifact
> exists yet.
>
> Manifest floor: macOS 26.0 (rises to 26.5 on first dependent API).
> Supported: macOS 26.5+.

A daemon-backed download manager for Apple Silicon macOS. MIT-licensed,
written in Swift, built on Apple frameworks.

`goh` — pronounced "go." Get over here!

## What it is

A `launchd`-managed daemon (`gohd`) owns the queue, the network, and the
disk. The CLI (`goh`) and a SwiftUI menu bar companion (`goh-menu`) are both
thin XPC clients of the same daemon, so downloads survive terminal closes,
app quits, and reboots.

v0.1 ships:

- Range-parallel HTTP/2 over `URLSession` — 8 connections by default, tunable
  to 16. (HTTP/3 was tried in slice 3b and reverted; see
  [DESIGN.md §Transport](DESIGN.md#http3--tried-and-reverted-for-v01).)
- Streaming SHA-256 verification computed during the download via a
  contiguous-frontier read-back from the partial file.
- Crash-safe resume from 1 MiB checkpoints with `If-Range` strong-validator
  gating.
- Cellular auto-pause via `NWPathMonitor`; sleep assertions via `IOKit`.
- Safari `Cookies.binarycookies` import for authenticated downloads,
  fd-passed from the CLI to the daemon so the daemon doesn't need Full Disk
  Access of its own.
- Spotlight provenance — `kMDItemWhereFroms` (source URL) and
  `kMDItemDownloadedDate` xattrs on every completed file.
- A `goh top` terminal dashboard and a menu bar companion with clipboard
  quick-add and Terminal-handoff that auto-detects Ghostty, iTerm2, WezTerm,
  Alacritty, and kitty.

## Install Status

There is no official public install channel yet. The Homebrew formula, tarball,
and PKG paths are being built and verified as release-candidate machinery before
they are published.

People working directly from this GitHub repository can build and test from
source. Tagged releases, stable checksums, a public Homebrew tap, and direct
download packages will appear only after the private release gates are complete.
For private local testing, use the dogfood lane in [DOGFOOD.md](DOGFOOD.md),
including `Scripts/dogfood-acceptance.sh` as the readiness gate.

## Usage

```sh
goh <url>
goh add [--output <path>] [--connections <1-16>] [--priority low|normal|high] [--no-cookies] <url>
goh ls [--json]
goh top
goh doctor
goh pause <id>
goh resume <id>
goh rm [--keep] <id>
goh auth import safari
```

## Requirements

- macOS 26.5+ (Tahoe), Apple Silicon
- Built with Swift 6.2+ (developed against the Swift 6.3 toolchain)

The Swift package manifest declares a macOS 26.0 build floor for portability
across stable Xcode toolchains; the supported runtime OS is macOS 26.5+. See
[DESIGN.md](DESIGN.md) for the rationale.

## Status

v0.1 is under active development. See [ROADMAP.md](ROADMAP.md) for scope,
[DESIGN.md](DESIGN.md) for architecture decisions, and [RELEASE.md](RELEASE.md)
for release packaging status.

## License

MIT — see [LICENSE](LICENSE).
