<p align="center">
  <img src="assets/brand/wordmark/goh-wordmark-dark.svg" alt="goh — an offline lockfile for the files you download" width="360">
</p>

# goh

**An offline lockfile for the files you download.** Pull model weights, datasets,
archives, or any large file, and `goh` records what you got — the source URL, the
SHA-256, the date — into a frozen local record. Later, on any machine, with no
network, you can answer the one question no hub can: **"is this still exactly what
I downloaded?"** — even if the upstream changed, or is gone.

`goh` — pronounced "go." Daemon-backed, Swift, Apple frameworks, MIT.

> **v0.1 — in development.** The engine, the daemon, the trust verbs below, and the
> `goh top` dashboard all work today (built from source). There is **no public
> install channel yet** — no Homebrew tap, no tagged release, no signed PKG. See
> [Install status](#install-status).
>
> Floor: **macOS 26.0+ (Tahoe), Apple Silicon** — a hard requirement of the daemon's
> macOS 26.0 secure XPC peer-validation API.

## Why this exists

Transfer speed is solved. Per-source integrity is solved too — the major hubs hash
their own blobs, verify their own layers, and sign at publish. What none of them give
you is a **vendor-neutral, offline record of what *you* pulled**, verifiable *against
your own frozen truth* rather than against a live server.

That gap is not academic. When a file is deleted from the place you got it from — 404,
no re-download — anyone who only ever trusted the upstream is stuck: there is nothing
left to verify *against*. A hub's own verify command checks its **live** server; it
can't tell you whether the bytes on your disk still match what you originally pulled.
The only thing that can answer that is **your own lockfile** — and almost nobody keeps
one for ad-hoc downloads. It's the idea reproducible build tools have leaned on for
years — pin the source, the hash; reproduce and verify offline — applied to arbitrary
downloaded assets.

## What it does today

Everything below runs **offline** and works with the daemon stopped — the trust verbs
read your records directly.

```sh
# 1. Declare what you want in a manifest, then pull it reproducibly.
#    sync is idempotent: it hashes what's already on disk and skips what matches,
#    so re-running never re-downloads a file you already have.
goh sync ./gohfile.toml

#    → writes gohfile.lock: { url, path, sha256, size, downloadedAt } per file,
#      with paths relative to the lockfile, so `git clone` + `goh verify` reproduces
#      on any machine.

# 2. Is everything still exactly what you downloaded? Offline, against YOUR record.
#    (bare `goh verify` reads ./gohfile.lock)
goh verify
#   OK ./model.safetensors
#   FAILED ./config.json expected sha256:… actual sha256:…
#   MISSING ./tokenizer.json (expected sha256:…)

# 3. Every download goh makes — sync, `goh add`, foreground, even a resume — is also
#    auto-recorded in a personal provenance ledger. Ask where any file came from:
goh which ~/Downloads/dataset.tar.zst
#   url:    https://example.com/dataset.tar.zst
#   sha256: sha256:…
#   downloaded 2026-06-05T21:13:02Z

# 4. Re-verify your whole ledger — and wire it straight into CI or a nightly cron.
goh verify --all --json | jq '.summary'
#   { "total": 42, "ok": 41, "failed": 0, "missing": 1 }
#   exit 0 all-ok · 2 a file changed · 9 a file went missing · 6 ledger error · 64 usage

# 5. Turn a verify result into a portable, tamper-evident proof — signed by a key
#    that lives inside this Mac's Secure Enclave (the private key can't leave the chip):
goh attest --output report.signed.json
#    Anyone can check it offline, on any machine, with only the file (no key of their own):
goh verify-attestation report.signed.json --expect-key <your-public-key>
#    valid & trusted → exit 0 · unpinned → exit 1 (fail-closed) · tampered → exit 2
```

That last line is the point: `goh verify --all` is a **drift detector you can put in a
pipeline**. A nightly job that re-hashes `~/datasets` and fails the build (or pages you)
the moment a file silently rots, gets truncated, or disappears — verified against the
record *you* froze, with no call to any server.

And `goh attest` makes a result **shareable**: the report is signed by a key generated
*inside* the Secure Enclave and never extractable, so you can hand a verify proof to a
collaborator or attach one to a release, and they can confirm — offline, with no account
or server — that not one byte changed since you signed it. This is the one place goh
genuinely leans on Apple Silicon: a hardware root of trust, not a label.

The hard parts are already built and hardened: streamed SHA-256 computed *during* a
range-parallel download (not a slow second pass), a TOCTOU-resistant write path, two
frozen on-disk formats (`gohfile.lock`, the provenance ledger) with loud-rejection
parsing and golden-file tests, and provenance recording on every completion path.

## Honest boundaries

- **A lockfile can't resurrect a deleted upstream.** `goh` *tells* you a file changed or
  vanished; it does not keep a second copy of the bytes. It is verify-only by design, not
  a mirror or a backup tool.
- **It records the files *you* pull.** Today that's any URL or a `gohfile.toml` manifest.
  Native smart-URL adapters for popular asset hubs are on the roadmap, not shipped — see
  [ROADMAP.md](ROADMAP.md).
- **It consumes provenance, it doesn't produce signatures.** Producing supply-chain
  signatures (who built these weights) belongs to dedicated signing ecosystems; `goh`
  stays in the lane of *your* local record.
- **An attestation is tamper-evidence, not identity.** `goh attest` proves a report hasn't
  changed since it was signed — not *who* signed it, unless you pin the signer's public key
  (`--expect-key`). `goh verify-attestation` fails closed by default: a valid-but-unpinned
  signature is a non-zero exit, so it won't quietly pass a CI gate.

## Also: a capable download engine

The lockfile sits on top of a real daemon-backed download manager. A `launchd`-managed
daemon (`gohd`) owns the queue, the network, and the disk; the CLI (`goh`) and a SwiftUI
menu bar companion (`goh-menu`) are thin XPC clients, so downloads survive terminal
closes, app quits, and reboots. v0.1 also ships:

- Range-parallel HTTP/2 over `URLSession` — 8 connections by default, tunable to 16, with
  an adaptive in-flight connection governor. (HTTP/3 was tried and reverted; see
  [DESIGN.md §Transport](DESIGN.md#http3--tried-and-reverted-for-v01).)
- Crash-safe resume from 1 MiB checkpoints with `If-Range` strong-validator gating.
- Cellular auto-pause via `NWPathMonitor`; sleep assertions via `IOKit`.
- Safari `Cookies.binarycookies` import for authenticated downloads, fd-passed from the
  CLI so the daemon never needs Full Disk Access of its own.
- `goh diagnose <url>` — plain-English link diagnostics (reachability, Range support,
  negotiated protocol, parallel-connection acceptance, throughput, bottleneck).
- A `goh top` terminal dashboard and a menu bar companion with clipboard quick-add and
  handoff that auto-detects common terminal emulators.

## Install status

There is **no official public install channel yet.** The Homebrew formula, tarball, and
signed PKG are being built and verified as release-candidate machinery before they're
published. Tagged releases, stable checksums, a public tap, and direct packages appear
only after the private release gates are complete.

Until then: build from source from this repository. For private local testing, use the
dogfood lane in [DOGFOOD.md](DOGFOOD.md) (`Scripts/dogfood-acceptance.sh` is the readiness
gate).

## Usage

```sh
# Trust layer
goh sync [<manifest>] [--base <dir>] [--accept-changed]   # reproducible bulk pull (--base is cwd-relative)
goh verify [<gohfile.lock>] [--strict-untracked]          # verify on-disk files against the lock
goh verify --all [--json]                                 # verify the whole provenance ledger
goh which <path>                                          # provenance: source, hash, date
goh attest [--output <path>]                              # Secure-Enclave-signed verify report
goh verify-attestation <file> [--expect-key <pubkey>] [--allow-untrusted-key] [--json]

# Downloads
goh <url>                                                 # foreground download with live progress
goh add [--output <path>] [--connections <1-16>] [--priority low|normal|high] [--no-cookies] <url>
goh diagnose [--full] [--json] [--connections <1-16> | -c <1-16>] <url>
goh ls [--json]   ;   goh top   ;   goh doctor
goh pause <id>    ;   goh resume <id>   ;   goh rm [--keep] <id>
goh auth import safari
```

## Requirements

- **macOS 26.0+ (Tahoe), Apple Silicon.**
- Built with Swift 6.2+ (developed against the Swift 6.3 toolchain).

The macOS 26.0 floor is a hard requirement of the daemon's macOS 26.0 XPC peer-validation
API (and conveniently the highest floor that builds on a stable Xcode toolchain). See
[DESIGN.md](DESIGN.md) for the rationale.

## Status

v0.1 is under active development. See [ROADMAP.md](ROADMAP.md) for scope,
[DESIGN.md](DESIGN.md) for architecture decisions, and [RELEASE.md](RELEASE.md) for release
packaging status.

## License

MIT — see [LICENSE](LICENSE).
