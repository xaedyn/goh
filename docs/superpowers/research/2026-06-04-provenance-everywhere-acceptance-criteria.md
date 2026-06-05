---
date: 2026-06-04
feature: provenance-everywhere
type: acceptance-criteria
---

# Acceptance Criteria — Provenance-everywhere (verify-only)

The slice: every download — manifest-declared (`goh sync`) **or** ad-hoc
(`goh add <url>` / foreground `goh <url>`) — automatically records
`{source URL, SHA-256, byte size, downloaded-at}` into a local offline
provenance record. `goh which` and a verify-everything path then answer
"where did this come from?" and "is this still exactly what I downloaded?"
for *everything the user has pulled*, offline, against the user's own frozen
record. **Verify-only** — no content-addressed byte storage; goh *tells* you
when a file drifted or vanished, it does not restore it.

## Acceptance Criteria

**AC1 — Every successful download is recorded.**
When a user runs `goh add <url>` or a foreground `goh <url>` and the download
completes successfully, goh writes a provenance entry
`{source URL, sha256 (lowercase hex), byte size, downloadedAt}` into the local
provenance record. Observable signal: after completion, the record store
contains exactly one entry keyed to the download's destination path with the
correct SHA-256 (matching an independent `shasum -a 256` of the file), and the
SHA-256 equals the digest the engine already streamed during the download (not
a post-hoc re-hash).

**AC2 — `goh which` answers from the record for ad-hoc downloads, offline.**
When a user runs `goh which <file>` for a file obtained via an ad-hoc download
that was never declared in any manifest, the output shows the recorded source
URL, SHA-256, and date — **not** the current `sha256: (not recorded)` xattr
fallback — and the command performs no network access. Observable signal:
`goh which` on an ad-hoc-downloaded file prints a concrete `sha256:<hex>` line
sourced from the provenance record, verified with the network disabled.

**AC3 — Verify-everything re-hashes recorded files offline against the frozen record.**
When a user runs the verify-everything path over recorded files, each recorded
file is re-hashed on disk and reported `OK` / `FAILED` (hash mismatch) /
`MISSING` (file absent), offline, against the record's *own* stored SHA-256
(never a daemon-provided or network-fetched hash). Observable signal: for a set
of recorded files where one is byte-mutated and one is deleted, the command
reports OK for the intact ones, FAILED for the mutated one, MISSING for the
deleted one, and exits with a deterministic non-zero code distinguishing
FAILED from MISSING — with the network disabled.

**AC4 — Purely additive to every frozen contract.**
The feature changes none of the frozen wire/on-disk contracts:
`protocolVersion` stays 3, `JobCatalog.currentVersion` stays 1, `JobSummary`
wire shape unchanged, `gohfile.lock` `lockfileVersion` 1 unchanged,
`DownloadCheckpoint`/`HostScheduling` v1 unchanged. The new provenance record
carries its **own** version field and round-trips through a golden-file
fixture. Observable signal: every pre-existing golden fixture is byte-identical
after this change; the new store has a `version` field and a passing
golden round-trip test; CI `-warnings-as-errors` stays green.

**AC5 — Re-download and corruption degrade safely; downloads never blocked.**
Re-downloading the same destination updates its provenance entry in place (no
duplicate-entry corruption), and a corrupt/unreadable provenance store is
handled gracefully (quarantine-to-sidecar like `HostProfileStore`) rather than
crashing the daemon or aborting/blocking the download itself. Observable
signal: downloading the same destination twice yields exactly one entry with
the latest hash/date; a deliberately corrupted store file causes the next
download to still succeed and the store to be re-initialized (corrupt file
copied to a `.corrupt-<unixtime>` sidecar, original left in place until the next
atomic overwrite), asserted by test.
