# goh

> **v0.1 — in development.** The daemon, download engine, CLI controls, foreground
> progress, and `goh top` dashboard are in place. Release packaging is being
> prepared privately; no official install channel or tagged v0.1.0 artifact
> exists yet.
>
> Manifest floor: macOS 26.0 (rises to 26.5 on first dependent API).
> Supported: macOS 26.5+.

A daemon-backed terminal download manager for Apple Silicon macOS.

`goh` — pronounced "go." Get over here!

## Why

`curl` and `wget` have no persistence, no queue, and no resume across reboots.
`aria2` predates HTTP/3 and has no native macOS integration. Folx and Downie are
GUI tools — not scriptable, not free. `goh` is a signed, notarized native install:
a `launchd`-managed daemon, modern transport, range-based parallel downloads,
OS-keychain auth, Spotlight integration, and a terminal UI worth using.

## Install Status

There is no official public install channel yet. The Homebrew formula, tarball,
and PKG paths are being built and verified as release-candidate machinery before
they are published.

People working directly from this GitHub repository can build and test from
source. Tagged releases, stable checksums, a public Homebrew tap, and direct
download packages will appear only after the private release gates are complete.

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
