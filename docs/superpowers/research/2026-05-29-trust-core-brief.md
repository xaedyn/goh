---
date: 2026-05-29
feature: trust-core
type: research-brief
---

# Research Brief — Trust Core (`gohfile.toml` + `sync`/`verify`/`which`)

Synthesizes the codebase context brief (`-ccb.md`) and industry research
(`-research-industry.md`). Adopted direction: manifest + lockfile split, SHA-256
spine, trust-on-first-use by default with strict-when-pinned, public URLs in v1
with a reserved auth slot.

## Foundation we build on (from the codebase)

- **SHA-256 is computed during every download and then discarded.**
  `ChunkAssembler.hashToCompletion()` returns the hex digest; the engine checks
  only for failure and drops the value. The single hook where digest +
  `JobSummary` + persistence are all reachable is `completedDownloadHandler` in
  `gohd/main.swift`.
- **Atomic write pattern is established**: encode → `.tmp` sibling → fsync →
  `rename(2)` → fsync dir; corrupt files quarantined to `.corrupt-<unix>`. Reuse
  verbatim for `gohfile.lock`.
- **`GohError` already has `ErrorCode.checksumMismatch`** — directly usable for
  `verify`/`sync` mismatch reporting.
- **CLI dispatch**: extend `ParsedCommand` + `parse(_:)`. `doctor` is the model
  for a fully CLI-local verb. `which` and `verify` fit that model; `sync` can be
  CLI-local (loop of existing `add` calls) or a new daemon command.
- **Frozen / sensitive**: XPC `protocolVersion = 3` is a frozen contract (new
  daemon command ⇒ bump to 4 + golden-fixture updates). Catalog `version = 1` is
  daemon-private (migration handled in `CatalogStore.load()`). No TOML parser or
  dependency exists. No Node/Python; Apple-frameworks-first.
- **Provenance**: `SpotlightMetadataTagger` writes `kMDItemWhereFroms` /
  `kMDItemDownloadedDate` via `setxattr` but there is no reader; `which` needs a
  `getxattr` companion (new, CLI-local).

## Format decisions settled by research (apply to ALL approaches)

1. **`sha256:<lowercase-hex>`** hash strings — algorithm prefix baked in so a
   future `sha512:` needs no format-version bump. [VERIFIED: Git LFS, pip, Go, SRI]
2. **`lockfileVersion` integer as the first field** of `gohfile.lock` — schema
   version only, never tool version; unknown values rejected loudly.
   [VERIFIED: npm, Cargo]
3. **`manifestHash = "sha256:…"` in the lockfile** — hash of `gohfile.toml` at
   lock time; checked every `sync`; mismatch ⇒ "lock is stale, regenerate".
   [SINGLE: derived from npm/Cargo]
4. **Self-contained lock entries** — each carries `url`, `sha256`, `size`,
   `downloadedAt`, `path`; re-downloadable without reading the manifest.
   [VERIFIED: Cargo]
5. **All-or-nothing hash enforcement for pinned sets** — a missing hash where one
   is expected is an error, not a warning. [VERIFIED: pip `--require-hashes`]
6. **TOFU must be loud and recoverable** — log first-use recording
   (`recorded sha256:… (first use, unverified)`); on mismatch print expected +
   actual + the exact update command; per-entry `verify = false` escape hatch,
   never a global off switch (the SSH `StrictHostKeyChecking` footgun).
   [VERIFIED: Go, Terraform, agwa.name]
7. **SHA-256 of downloaded bytes always**, regardless of transport; never trust
   ETags as integrity. [VERIFIED: DVC anti-pattern]
8. **Reserve a `chunks:` field** in lock entries for future per-chunk repair; do
   not implement in v1. [VERIFIED: aria2/Metalink]
9. Closest precedent is **DVC's `.dvc` + `dvc.lock`**; biggest competitor
   friction is **requiring Git** (git-annex/DataLad) — goh's flat TOML, no-Git
   surface is the right call. [VERIFIED / SINGLE]

## The one unresolved fork → approaches

Everything above is common. Approaches differ on **where integrity/provenance
state lives and whether the daemon protocol changes**:

- **Re-hash on demand vs. persist the digest.** `verify` must read the file off
  disk to detect drift regardless (a stored hash tells you what it *was*, not
  whether the file changed), so persistence's real payoff is provenance for
  *every* download and sync-skip decisions — not avoiding the verify read.
- **`sync` CLI-local (loop of `add`, no protocol change) vs. daemon batch
  command (`protocolVersion → 4`, batch-atomic).**
- **Lockfile as the source of truth (CLI-owned) vs. daemon catalog as the
  registry** (lockfile generated from it).
- **TOML: hand-rolled minimal subset vs. vetted Swift dependency** (policy gate).

These cluster into two coherent bets, written up in `-approaches.md`.
