# Local Dogfood

This is the private, local-only path for using `goh` before any official
install channel exists. It does not publish artifacts, install into `/usr/local`,
or require Apple Developer credentials.

The live dogfood lane uses a local debug build. That is deliberate: unsigned
release binaries cannot pass the production XPC peer requirement, and the
development relaxation is compiled into debug builds only. The scripts set
`GOH_XPC_ALLOW_UNVALIDATED_PEERS=1` for the dogfood LaunchAgent and smoke
commands so the unsigned local `goh` and `gohd` can talk to each other.

## Quick Start

Make sure no non-dogfood `gohd` LaunchAgent is active, then run:

```bash
Scripts/dogfood-build.sh
Scripts/dogfood-install.sh
Scripts/dogfood-smoke.sh
```

For manual use in the current shell:

```bash
export PATH="$PWD/.build/dogfood/current/bin:$PATH"
export GOH_XPC_ALLOW_UNVALIDATED_PEERS=1

goh ls
goh doctor
goh add --output "$PWD/.build/dogfood/downloads/example.html" https://example.com/
goh top
```

## What The Scripts Do

- `Scripts/dogfood-build.sh` builds a local debug copy of `goh` and `gohd`,
  stages it under `.build/dogfood/install/debug`, and points
  `.build/dogfood/current` at it. Use `--artifacts` to also build and verify the
  unsigned release tarball and PKG candidates.
- `Scripts/dogfood-install.sh` writes
  `~/Library/LaunchAgents/dev.goh.daemon.plist` with a dogfood marker, the
  staged `gohd` path, dogfood log paths, and
  `GOH_XPC_ALLOW_UNVALIDATED_PEERS=1`. It refuses to overwrite an existing
  non-dogfood LaunchAgent.
- `Scripts/dogfood-smoke.sh` runs `goh doctor`, verifies the daemon is reachable
  through real `launchd`/XPC, adds a small download, waits for completion, and
  leaves the downloaded file under `.build/dogfood/downloads`.
- `Scripts/dogfood-reset.sh` unloads and removes only the marked dogfood
  LaunchAgent. Add `--data` to delete the daemon catalog and checkpoints in
  `~/Library/Application Support/dev.goh.daemon`; add `--all` to delete dogfood
  build artifacts too.

## Safety Notes

The dogfood LaunchAgent uses the real Mach service name, `dev.goh.daemon`,
because that is the production XPC surface. It also uses the real daemon support
directory:

```text
~/Library/Application Support/dev.goh.daemon
```

That means local dogfood should be the only active `gohd` on the machine while
you test. The reset script does not delete daemon data unless you pass `--data`
or `--all`.

The unsigned release tarball and PKG are still useful for layout checks:

```bash
Scripts/dogfood-build.sh --artifacts
```

Those artifacts are inspection candidates only until Developer ID signing and
notarization are available.

## Manual Checklist

Run this before treating a local build as usable:

- `Scripts/dogfood-smoke.sh`
- Doctor: `goh doctor`
- Foreground: `goh https://example.com/`
- Background: `goh add --output "$PWD/.build/dogfood/downloads/manual.html" https://example.com/`
- List: `goh ls` and `goh ls --json`
- Control: pause, resume, and `rm --keep` on a larger test download
- Dashboard: `goh top`, then stop it with Ctrl-C
- Auth: `goh auth import safari` after granting Full Disk Access
- Reset: `Scripts/dogfood-reset.sh`, then repeat install and smoke
