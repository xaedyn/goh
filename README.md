# goh

> **v0.1 — in development.** Not yet usable. The package skeleton builds and the
> CI is green; the features described below do not exist yet.

A daemon-backed terminal download manager for Apple Silicon macOS.

`goh` — pronounced "go." Files come when you tell them to.

## Why

`curl` and `wget` have no persistence, no queue, and no resume across reboots.
`aria2` predates HTTP/3 and has no native macOS integration. Folx and Downie are
GUI tools — not scriptable, not free. `goh` is one signed, notarized binary: a
`launchd`-managed daemon, modern transport, range-based parallel downloads,
OS-keychain auth, Spotlight integration, and a terminal UI worth using.

## Install

> Placeholder — no release exists yet.

```sh
brew install goh-cli/tap/goh
brew services start goh
```

The daemon is opt-in. `brew install` never starts a background process; you
enable it explicitly with `brew services start goh`.

## Usage

> Placeholder — these commands are not implemented yet.

```sh
goh <url>          # foreground download with live progress
goh add <url>      # background download, returns immediately
goh ls             # list jobs
goh pause <id>     # pause a job
goh resume <id>    # resume a job
goh rm <id>        # remove a job
goh top            # live terminal dashboard
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
