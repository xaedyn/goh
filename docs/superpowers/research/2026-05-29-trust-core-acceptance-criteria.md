---
date: 2026-05-29
feature: trust-core
type: acceptance-criteria
---

# Acceptance Criteria — Trust Core (`gohfile.toml` + `sync` / `verify` / `which`)

Adopted design direction (from user, 2026-05-29):
- Integrity model: **both** — trust-on-first-use by default, strict when a hash is supplied.
- Scope: **manifest + lockfile** split (`gohfile.toml` intent, `gohfile.lock` resolved truth); personal-and-shareable.
- Auth: **public URLs only in v1**, but a forward-compatible per-entry auth slot is reserved in the frozen format.

---

AC1 — **Reproducible, idempotent sync.**
When a user runs `goh sync ./gohfile.toml` on a manifest of N public-URL entries with no prior lockfile, goh downloads all N to their declared destinations, writes a `gohfile.lock` recording each entry's resolved URL, SHA-256, and byte size, and exits 0. Re-running `goh sync` immediately downloads nothing and reports every entry "up to date" (signal: zero bytes transferred on the second run, exit 0).

AC2 — **Verify detects drift.**
When the lockfile records a SHA-256 for an entry and the on-disk file no longer matches it, `goh verify` reports that entry as FAILED with recorded-vs-actual hash and exits non-zero (signal: `GohError.checksumMismatch` surfaced per file). When everything matches, `goh verify` exits 0.

AC3 — **Strict-when-pinned, trust-on-first-use otherwise.**
When a manifest entry specifies an expected `sha256`, `goh sync` rejects a downloaded file whose computed SHA-256 differs — the bad file is not left in the destination, the entry reports `checksumMismatch`, and the command exits non-zero. When an entry has no expected hash, `goh sync` records the computed SHA-256 into `gohfile.lock` on first download and verifies against that recorded value on every subsequent run.

AC4 — **Provenance lookup.**
When a user runs `goh which <path>` on a file goh downloaded, it prints the source URL, the SHA-256, and the downloaded date. For a file goh has no record of, it prints "no provenance record" and exits non-zero (signal: provenance read returns nil → distinct exit code).

AC5 — **TOFU hash-change is explicit, never silent.**
When the upstream content of an *unpinned* (trust-on-first-use) entry legitimately changes and the user re-syncs, goh surfaces the hash change as a distinct, named event — clearly different from both a silent overwrite and the `checksumMismatch` failure used for *pinned* entries — and updates the lockfile only when the user explicitly opts in (e.g. a flag or confirmation). (Signal: a dedicated "hash changed for unpinned entry" outcome/exit path, asserted separately from AC3's pinned-mismatch path.)

---

## Notes for downstream steps

- AC1/AC3 hinge on an unresolved fork surfaced by the CCB: the completed-download SHA-256 is **computed but discarded today**, so `verify`/`sync` must either persist it (JobSummary field + catalog version bump to 2) or re-hash on demand (no schema change, ~1 GB/s on Apple Silicon). Approaches must take a position.
- TOML parsing has **no existing dependency**; build-vs-buy under the Apple-frameworks-first policy is a load-bearing approach decision.
- `goh sync` daemon-side (batch-atomic, new `Command` + protocolVersion bump to 4) vs CLI-local (loop of `add` calls, no protocol change) is an approach decision.
