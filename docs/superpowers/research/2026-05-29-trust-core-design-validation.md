---
date: 2026-05-29
feature: trust-core
type: design-validation
---

# Design Validation — Trust Core (Approach 1: lockfile-as-product)

## Acceptance Criteria (from Step 2.5)

- AC1 — Reproducible, idempotent `goh sync` (writes self-contained `gohfile.lock`; second run transfers zero bytes).
- AC2 — `goh verify` detects drift (re-hash vs lock; `checksumMismatch`; non-zero exit).
- AC3 — Strict-when-pinned, trust-on-first-use otherwise.
- AC4 — `goh which <path>` prints source URL, SHA-256, downloaded date; non-zero when no record.
- AC5 — TOFU hash-change is explicit and distinct from a pinned mismatch; lock updated only on explicit opt-in.

## Dependency Enumeration

No existing interfaces modified. Approach 1 is purely additive: new CLI-local
verbs (`sync`/`verify`/`which`) reuse the existing `add` XPC command unchanged.
XPC `protocolVersion` stays 3; catalog schema stays version 1. No external
consumer of any current contract is affected.

## Questions Asked & Answers

### Zero Silent Failures
- **Existing users on upgrade?** Nothing changes. Additive commands only; no
  migration; `gohfile.toml`/`gohfile.lock` exist only if the user opts into sync.
- **Existing data/formats?** Untouched — no catalog/checkpoint schema change.
- **Existing integrations / callers?** None modified (no protocol change).
- **Partial-failure safety?** If `sync` downloads some entries then dies, files
  on disk + the lockfile must stay consistent: the lock is written **atomically**
  (`.tmp`→rename, project pattern), and a re-run is **idempotent** — it re-hashes
  existing files, skips matches, resumes the rest. An interrupted run leaves a
  valid (possibly lagging) lock; the next run reconciles. No corrupt/half state.

### Failure at Scale
- **10× volume?** Manifests are small text even at thousands of entries (load
  fully in memory is fine). Multi-TB file sets make `verify` O(total bytes) —
  bounded, expected, must show progress. `sync` is a sequential loop in v1
  (parallel batching reserved for later); document the v1 limit, don't hide it.
- **Concurrent operations?** Two `goh sync`/`verify` runs on the same
  `gohfile.lock` could race. Atomic rename prevents corruption but last-writer
  could drop an entry → take an **advisory `flock` on the lockfile** for the
  duration of a sync/verify write.
- **Daemon/network unavailable?** `sync`'s `add` calls fail per-entry → reported,
  non-zero exit, lock not corrupted. Network failure handled by the existing
  engine (resume/checkpoint).

### Simplest Attack
- **Cheapest abuse — malicious shared `gohfile.toml`.** A shared manifest with
  `path = "../../…"`, an absolute path, or a symlinked destination could write
  **outside the intended tree** (path traversal / symlink clobber). This is the
  primary attack surface because sharing manifests is the point.
- **TOFU over a compromised network.** First-use records an attacker's hash as
  trusted. Inherent to TOFU; mitigations: pinned `sha256` defeats it; first-use
  is logged loudly; mismatch output is actionable (per research).
- **Lockfile tampering.** A locally-edited `gohfile.lock` hash would pass
  `verify`. Trust boundary = the user's filesystem; pinned manifest hashes are
  the defense for shared scenarios. Documented, not "fixed" (out of scope to
  defend the user's own FS from the user).

## Gaps Found

1. **Path traversal / absolute-path / symlink escape** in destinations from a
   shared manifest. (High — security.)
2. **Concurrent sync/verify racing the lockfile.** (Medium.)
3. **Interrupted sync ↔ lockfile consistency.** (Medium.)

## Fixes Applied (folded into the design before spec writing)

1. `sync` confines every write under a single declared **base directory**;
   destinations are resolved against it and **absolute paths, `..` escapes, and
   symlinked path components are rejected** (`O_NOFOLLOW`-style discipline).
   Goes in the spec's **Security Surface** section as a hard requirement + tests.
2. **Advisory `flock`** held on `gohfile.lock` during sync/verify writes; second
   concurrent run waits or fails fast with a clear message.
3. Lockfile written **atomically**; an interrupted `sync` reconciles on re-run by
   re-hashing existing files (idempotent). Lock never left half-written.
