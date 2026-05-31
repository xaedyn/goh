---
date: 2026-05-29
feature: trust-core
type: approaches
---

# Approaches — Trust Core

Two coherent bets. Both adopt every "settled format decision" from the research
brief; they differ only on where state lives and whether the frozen XPC contract
changes.

---

## APPROACH 1 — "The lockfile is the product" (CLI-local)

CORE IDEA
`gohfile.lock` is the single, portable source of truth; `sync`/`verify`/`which`
run entirely in the CLI process and the daemon is left untouched.

MECHANISM
`goh sync` reads `gohfile.toml`, and for each entry issues the existing `add`
XPC call to the daemon to download it; after each file lands, the CLI hashes the
bytes (still warm in page cache) and writes a self-contained entry into
`gohfile.lock` (atomic `.tmp`→rename, reusing the project pattern). Pinned
entries are verified against their expected `sha256` before being accepted;
unpinned entries are trust-on-first-use (hash recorded, logged). `goh verify`
re-hashes the on-disk files and compares to the lock. `goh which` reads
provenance from the lock (and the Spotlight xattr via a new `getxattr` reader).
No daemon command, no `protocolVersion` change, no catalog migration.

FIT ASSESSMENT
Scale fit:       Matches. Re-hash is ~1 GB/s on Apple Silicon; a 70 GB verify ≈ 70 s, bounded and acceptable.
Team fit:        Fits. Pure additive CLI code in the established `doctor`-style local-verb pattern.
Operational:     Nothing new to run. State is a text file beside the user's data.
Stack alignment: Fits. Only new dependency is a TOML reader (hand-rolled minimal subset → zero third-party deps).

TRADEOFFS
Strong at:  Zero frozen-contract churn; the lockfile is portable and self-contained (Cargo's lesson); fastest to ship; trivially testable with golden files.
Sacrifices: `sync` is not batch-atomic (partial failure leaves some entries done); provenance only covers files pulled via `sync`, not ad-hoc `goh add`; `verify` always reads the file (unavoidable for drift detection anyway).

WHAT WE'D BUILD
Minimal TOML reader; `gohfile.toml`/`gohfile.lock` codecs; `GohSync`,
`GohVerify`, `GohWhich` CLI-local commands; a `getxattr` provenance reader.

THE BET
Re-hashing on demand is fast enough that persisting digests buys nothing for
this feature, and a self-contained lockfile beside the data is more valuable
than a daemon-side registry.

REVERSAL COST
Easy. If we later want a daemon registry, we add it without changing the
lockfile format (the format is the durable artifact).

WHAT WE'RE NOT BUILDING
No `protocolVersion` bump; no catalog schema change; no batch-atomic enqueue; no
provenance for non-sync downloads (yet).

INDUSTRY PRECEDENT
DVC (`.dvc` + `dvc.lock`), Cargo (`Cargo.lock`) — manifest+lock with
self-contained entries, no daemon. [VERIFIED]

---

## APPROACH 2 — "The daemon is the registry" (daemon-tracked)

CORE IDEA
Make the daemon the durable integrity/provenance registry for *every* download;
the lockfile is a projection of catalog state.

MECHANISM
Persist the completed SHA-256 into `JobSummary` (catalog `version` → 2, with a
migration branch in `CatalogStore.load()`), captured at
`completedDownloadHandler`. Add a `Command.syncManifest` daemon command
(`protocolVersion` → 4) that enqueues a whole manifest batch-atomically.
`goh which` and `goh verify` query the daemon catalog for recorded hashes and
provenance; `gohfile.lock` is generated from that catalog state. `verify` still
re-hashes files on disk to detect drift, comparing against the catalog record.

FIT ASSESSMENT
Scale fit:       Matches, with more moving parts; catalog grows with history.
Team fit:        Heavier — touches the frozen XPC surface and persistence migration; needs golden-fixture + transition tests.
Operational:     Daemon now owns provenance; catalog migration must be correct on upgrade.
Stack alignment: Fits Swift, but expands the frozen-contract footprint.

TRADEOFFS
Strong at:  Provenance/integrity for *all* downloads (add and sync); batch-atomic sync; daemon is one source of truth.
Sacrifices: Frozen `protocolVersion` bump (3 → 4) + catalog migration now; larger surface and review burden; slower to ship; lockfile is secondary to daemon state (less portable mental model).

WHAT WE'D BUILD
`sha256` field on `JobSummary` + catalog v2 migration; `Command.syncManifest`
+ dispatcher + `protocolVersion` 4 + golden fixtures; catalog-query paths for
`which`/`verify`; TOML codecs; lockfile generator.

THE BET
First-class provenance for every download and batch atomicity are worth taking
on frozen-contract churn now rather than later.

REVERSAL COST
Hard. A shipped `protocolVersion = 4` and a migrated catalog are frozen
contracts; backing them out is a second migration.

WHAT WE'RE NOT BUILDING
No standalone-lockfile-first model; the daemon is required for provenance.

INDUSTRY PRECEDENT
Go module sum DB (a service-side checksum registry) — but Go also keeps a
self-contained `go.sum` in-repo, which is closer to Approach 1. [VERIFIED]

---

## Comparison matrix

| Criterion | A1 — Lockfile is the product | A2 — Daemon is the registry |
|---|---|---|
| AC1 (reproducible idempotent sync) | STRONG — lock drives skip decisions directly | STRONG — catalog drives skip; lock projected |
| AC2 (verify detects drift) | STRONG — re-hash vs lock | STRONG — re-hash vs catalog record |
| AC3 (strict-pinned / TOFU) | STRONG — enforced in CLI at write time | STRONG — enforced daemon-side |
| AC4 (provenance `which`) | PARTIAL — only sync'd files + xattr; not ad-hoc `add` | STRONG — every download has a catalog record |
| AC5 (TOFU change is loud) | STRONG — CLI owns the messaging path | STRONG — daemon emits, CLI surfaces |
| Scale fit | STRONG — bounded re-hash | PARTIAL — catalog history growth |
| Team fit | STRONG — additive CLI only | WEAK — frozen XPC + migration |
| Operational burden | STRONG — a text file | PARTIAL — daemon-owned migration |
| Stack alignment | STRONG — optional zero new deps | PARTIAL — bigger frozen footprint |

**Recommendation: Approach 1.** It ships the frozen *format* (the thing we must
get right and cannot change later) without touching the frozen *XPC contract*
(the thing the project most wants to avoid churning); re-hash is genuinely fast
enough; and the self-contained lockfile is the portable artifact the research
endorses. Approach 2's real advantage — provenance for non-`sync` downloads — is
separable and can be added later **without breaking the lockfile format**, so we
do not pay its cost now. One concession to A2 worth folding into A1: reserve an
optional `sha256` field on `JobSummary` as a *future* provenance hook, but do not
bump the catalog version or protocol for it in v1.
