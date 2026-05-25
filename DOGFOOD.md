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
Scripts/dogfood-acceptance.sh
```

For a shorter build/install/smoke loop while iterating:

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
- `Scripts/dogfood-acceptance.sh` is the private readiness gate. It builds,
  installs, runs doctor and smoke, checks `goh ls --json`, exercises foreground
  `goh <url>`, pauses/resumes/removes an active larger download, restarts the
  daemon, and optionally runs the live competitive benchmark with
  `--performance`. Performance runs print the benchmark table and save the same
  output under `.build/dogfood/logs/acceptance-performance-*`.
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

The acceptance script creates only uniquely named test downloads: the composed
smoke file under `.build/dogfood/downloads/smoke-*`, one foreground file under
`~/Downloads/goh-acceptance-*`, and one control download under
`.build/dogfood/downloads/acceptance-control-*`. It refuses to touch a
pre-existing foreground file and removes its own test files during cleanup. The
`--performance` mode runs real network benchmarks against `goh`, `aria2c`, and
`curl`, streams the timing output to the terminal, and records a timestamped log
under `.build/dogfood/logs/acceptance-performance-*`; leave it off for quick
readiness checks.

The unsigned release tarball and PKG are still useful for layout checks:

```bash
Scripts/dogfood-build.sh --artifacts
```

Those artifacts are inspection candidates only until Developer ID signing and
notarization are available.

## Manual Checklist

Run this before treating a local build as usable:

- Acceptance: `Scripts/dogfood-acceptance.sh`
- `Scripts/dogfood-smoke.sh`
- Doctor: `goh doctor`
- Foreground: `goh https://example.com/`
- Background: `goh add --output "$PWD/.build/dogfood/downloads/manual.html" https://example.com/`
- List: `goh ls` and `goh ls --json`
- Control: pause, resume, and `rm --keep` on a larger test download
- Dashboard: `goh top`, then stop it with Ctrl-C
- Auth: `goh auth import safari` after granting Full Disk Access
- Performance: `GOH_ACCEPTANCE_PERF_RUNS=1 Scripts/dogfood-acceptance.sh --performance`
  and inspect the printed benchmark table plus the `Performance log:` path
- Reset: `Scripts/dogfood-reset.sh`, then repeat install and smoke
