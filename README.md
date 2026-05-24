# goh

> **v0.1 — in development.** The daemon, download engine, CLI controls, foreground
> progress, and `goh top` dashboard are in place. Release packaging is still in
> progress; no tagged v0.1.0 artifact exists yet.
>
> Manifest floor: macOS 26.0 (rises to 26.5 on first dependent API).
> Supported: macOS 26.5+.

A daemon-backed terminal download manager for Apple Silicon macOS.

`goh` — pronounced "go." Files come when you tell them to.

## Why

`curl` and `wget` have no persistence, no queue, and no resume across reboots.
`aria2` predates HTTP/3 and has no native macOS integration. Folx and Downie are
GUI tools — not scriptable, not free. `goh` is one signed, notarized binary: a
`launchd`-managed daemon, modern transport, range-based parallel downloads,
OS-keychain auth, Spotlight integration, and a terminal UI worth using.

## Install

```sh
brew install goh-cli/tap/goh
brew services start goh
```

The daemon is opt-in. `brew install` never starts a background process; you
enable it explicitly with `brew services start goh`.

## Usage

```sh
goh <url>
goh add [--output <path>] [--connections <1-16>] [--priority low|normal|high] [--no-cookies] <url>
goh ls [--json]
goh top
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

v0.1 is under active development. See [ROADMAP.md](ROADMAP.md) for scope and
[DESIGN.md](DESIGN.md) for architecture decisions.

## License

MIT — see [LICENSE](LICENSE).
