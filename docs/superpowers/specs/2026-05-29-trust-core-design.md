---
date: 2026-05-29
feature: trust-core
type: design-spec
status: approved
contract: FROZEN ON-DISK — gohfile.toml (manifest) + gohfile.lock (lockfile)
chosen-approach: APPROACH 1 — "the lockfile is the product" (CLI-local, no XPC change, re-hash on demand)
satisfies: AC1, AC2, AC3, AC4, AC5
---

# Trust Core — Design Spec

`goh sync` / `goh verify` / `goh which`, backed by two on-disk formats:
`gohfile.toml` (intent) and `gohfile.lock` (resolved truth).

This spec freezes two on-disk formats other tools may read. Sections 7–8 are the
frozen contract and are written to the four-round discipline (`CLAUDE.md`
§"Four-round design discipline"): every field decision keeps a *Considered
alternatives* note. The behavioral and security sections (1–6, 9) are normal
implementation cadence.

---

## 1. Problem

A goh user who curates a set of remote assets — model weights, datasets,
release tarballs, fixtures — has no way to declare that set once and get it back
**reproducibly and integrity-verified** on another machine, at another time, or
after a teammate clones the same description.

Today every download is a one-shot `goh add <url>`. The bytes land, the SHA-256
is computed during the transfer and then **discarded** (`ChunkAssembler`
returns the digest; the engine checks it only for failure). There is:

- no declarative manifest of "the assets this project depends on",
- no record of *what hash a file had when it was known-good*, so no way to later
  detect that a file rotted, was truncated, or was swapped,
- no answer to "where did this file on my disk come from?",
- no defense, when a manifest is shared, against an entry silently pointing at
  different bytes than the author intended.

The user problem is **reproducible, integrity-verified asset management from a
shareable description** — the same problem `Cargo.lock`, `dvc.lock`, and
`go.sum` solve for their domains, applied to arbitrary downloaded files. The
manifest captures *intent* (URLs, optional pins, destinations); the lockfile
captures *resolved truth* (the exact bytes, by hash and size, that were
accepted) so the set can be reproduced and continuously re-verified.

This spec does **not** describe an implementation; it describes the contract and
observable behavior that solves that problem. The chosen implementation strategy
(CLI-local, re-hash on demand) is recorded in §10 because it constrains the
contract, not because it is the problem.

---

## 2. Success metrics

Done is defined by AC1–AC5, each reduced to an observable signal. "Exit code"
means the process exit status of the `goh` CLI. All exit codes are enumerated in
§9.4 and are themselves part of the contract.

| AC | Definition of done | Observable signal |
|----|--------------------|-------------------|
| **AC1** | Reproducible, idempotent sync. `goh sync` on N public entries with no prior lock downloads all N, writes a self-contained `gohfile.lock`, exits 0. A second immediate run downloads nothing. | Run 1: exit `0`, `gohfile.lock` exists with N entries each carrying `url`/`sha256`/`size`. Run 2: **zero bytes transferred** (every entry logged `up to date`), exit `0`. |
| **AC2** | Verify detects drift. When an on-disk file no longer matches the lock's recorded hash, `verify` reports it FAILED with recorded-vs-actual and exits non-zero; all-match exits 0. | Mismatch: per-file line `FAILED <path> expected sha256:… actual sha256:…`, exit `2` (`GohError.checksumMismatch` surfaced). All match: exit `0`. |
| **AC3** | Strict-when-pinned, TOFU otherwise. A pinned entry whose download mismatches is rejected (bad file not left in place), reports `checksumMismatch`, exits non-zero. An unpinned entry records its computed hash on first download and verifies against the recorded value thereafter. | Pinned mismatch: destination absent (or `.corrupt-<unix>` quarantine), exit `2`. Unpinned first use: lock entry written, log `recorded sha256:… (first use, unverified)`, exit `0`. |
| **AC4** | Provenance lookup. `goh which <path>` prints source URL, SHA-256, downloaded date for a known file; prints `no provenance record` and exits non-zero for an unknown file. | Known: three fields printed, exit `0`. Unknown: `no provenance record for <path>`, exit `4`. |
| **AC5** | TOFU change is loud, never silent, distinct from a pinned mismatch, and only persisted on explicit opt-in. | Unpinned upstream change on re-sync: a **named** outcome `hash changed for unpinned entry` (distinct exit `3`, distinct from AC3's `2`), lock **unchanged** unless `--accept-changed` (or interactive confirm) is passed; with opt-in, lock updated and exit `0`. |

A build that exits `0` where the table demands non-zero, or vice versa, is not
done. Each row maps to at least one Swift Testing case asserting both the stdout
signal and the exit code.

---

## 3. Out of scope (v1)

Explicitly excluded. Each is reserved in a way that does not break the frozen
format when added later.

- **Authenticated / private URLs.** v1 syncs public URLs only. A per-entry
  `auth` field is a **reserved name** in the manifest (§7) — if present and
  non-null it is **rejected loudly** in v1 (reserved ≠ silently ignored, §4.4,
  §7.1), with no behavior attached. Safari cookie import (`useImportedCookies`)
  is **not** wired into `sync`.
- **Daemon-side provenance for non-`sync` downloads.** `goh which` answers only
  for files recorded in a `gohfile.lock` or carrying the Spotlight `whereFroms`
  xattr. Ad-hoc `goh add` downloads get xattr provenance (existing tagger) but
  no lock record. A future daemon registry can add this **without changing the
  lock format** (the optional `sha256` field reserved on `JobSummary` in §10 is
  the seam).
- **Batch-atomic sync.** v1 sync is a sequential per-entry loop. Partial failure
  leaves earlier entries downloaded and locked, later entries not. Recovery is
  by idempotent re-run (§5), not rollback.
- **Per-chunk repair.** A `chunks` slot is a reserved name in lock entries (§8);
  a v1 writer never emits it and a v1 reader rejects it loudly if present/non-null
  (reserved ≠ silently ignored, §8.1). No data, no behavior in v1.
- **Parallel sync.** Entries are fetched one at a time. Concurrency across
  entries is reserved; the lock format does not change to enable it later.
- **Smart-URL adapters** (`hf://`, `kaggle://`, `s3://`, git remotes). v1 takes
  literal `http(s)` URLs only. Scheme dispatch can be added behind the existing
  `url` field with no format change.

---

## 4. Security surface

Sharing a `gohfile.toml` is the point of the feature, so a **hostile manifest**
is the primary attack surface. Four boundaries:

### 4.1 Path-escape confinement (hard requirement)

A shared manifest must not be able to write outside the directory the user ran
`sync` in. Every destination is resolved under a single **declared base
directory** (default: the directory containing `gohfile.toml`; overridable with
`--base <dir>`). The base is first **expanded** (a leading `~` only — no `$VAR`,
per §7.4), then canonicalized once; that canonical path is the confinement root.
Per-entry `path`/`dest` is never expanded (literal `~`/`$`, §7.4).

**Where confinement is enforced (two layers, defense in depth).** The CLI cannot
enforce open-time safety because the **daemon** writes the downloaded file
(`DownloadEngine` → `DownloadFile`, opened daemon-side). The confinement is
therefore split:

- **CLI pre-flight (defense in depth).** Before calling `add`, the CLI canonicalizes
  the base, **lexically confines** the joined `base + path` (rules 1–2 below),
  **realpath-checks** the destination's parent against the canonicalized base, and
  passes the daemon an **absolute, already-confined** path. A pre-flight violation
  is refused CLI-side, exit `5`, before any `add` is issued.
- **Daemon write path (the moment-of-write guarantee).** The hard, TOCTOU-proof
  confinement lives at the daemon's existing write path and is **base-free** — the
  daemon never receives `base` (the `add` request / `JobSummary` carry only an
  absolute `destination`, no `base`; adding one would be the very
  `protocolVersion`/`AddRequest` change this approach forbids). `DownloadFile`
  opens `job.destination` **directly** (downloads write in place and resume
  reopens the same path to append — there is **no** download-side `.tmp` sibling)
  with `O_NOFOLLOW` added to its existing `O_RDWR | O_CREAT` (plus `O_TRUNC` only
  on a fresh download, never on resume; **no `O_EXCL`**, which would break
  create-or-resume), and **refuses any symlinked path component at open time** via
  an `openat` descent of the destination's **own** path components — anchored at a
  daemon-resolvable point (the filesystem root `/`, or the first existing real-
  directory ancestor of the destination), **not** at `base`. This is the
  instant-of-write enforcement that defeats a symlink swapped in after the CLI's
  pre-flight check (rule 3 below). *(The `.tmp`→`fsync`→`rename`→`fsync`-dir
  atomic-write pattern with `O_CREAT | O_EXCL | O_NOFOLLOW` is the **lockfile
  write (CLI-side)**, §5 — not the download.)*

The split is exact: **lexical "stay inside `base`"** needs `base` and is the
**CLI's** job (it has `base`; rules 1–2 + the realpath pre-flight below);
**"never traverse a symlinked component, TOCTOU-proof at open time"** needs only
the destination path and is the **daemon's** job (it has the path; base-free
`O_NOFOLLOW` descent above). Neither requires the daemon to know `base`.

This is a **contained internal hardening of the daemon's `DownloadFile`**, not a
frozen-contract change (§5, §10): `protocolVersion` stays 3, no new `Command`, no
catalog migration. Because the hardening sits in the shared write path, it
**hardens every `goh add`**, not just `sync` — a positive side effect.

For every entry, **before any byte is written**:

1. **Reject absolute paths (hard-rejected in v1).** A `path`/`dest` beginning
   with `/` (or a drive form) is a hard error; the entry is refused, exit `5`,
   no byte written. Absolute destinations are *rejected*, not "discouraged" or
   "relative-by-default"; the §7.1 schema language is identical. (A future
   opt-in flag to permit absolute destinations is out of scope for v1.)
2. **Reject `..` traversal.** After lexically normalizing the joined
   `base + path`, the result must remain lexically within `base`. Any `..` that
   climbs to or above `base` is refused, exit `5`.
3. **Reject symlinked components — enforced at open time on the daemon write
   path, not by a CLI pre-flight string check (closes the TOCTOU gap).** A
   lexical/string validation performed *before* the download, with the write
   performed *after*, leaves a time-of-check-to-time-of-use window: a symlink
   planted between the CLI's pre-flight check and the daemon's write can redirect
   the bytes outside `base`. The hard confinement is therefore **enforced at the
   moment of write, inside the daemon's `DownloadFile`** (the contained internal
   hardening above), with two parts that both MUST hold:
   - **`O_NOFOLLOW` on the final component.** `DownloadFile` opens
     `job.destination` directly with `O_NOFOLLOW` added to its existing
     `O_RDWR | O_CREAT` flags (`O_TRUNC` only on a fresh download; **never
     `O_EXCL`** — a resumed download reopens the existing file to append, so
     `O_EXCL` would make every resume fail), so an existing symlink at the
     destination's final component is **never written through** — the open fails
     rather than following the link. There is **no download-side `.tmp` sibling**;
     the bytes are written in place to `job.destination`.
   - **Symlink-component refusal / base-free `openat`-descent at open time.**
     `DownloadFile` refuses any symlinked path component at open time by walking
     the **destination's own** path components with an **`openat` descent** — the
     daemon has no `base`, so it anchors the descent at a daemon-resolvable point
     (the filesystem root `/`, or the first existing real-directory ancestor of
     `job.destination`) and walks down through the destination's components,
     opening each intermediate component with `O_NOFOLLOW | O_DIRECTORY` (so a
     symlinked or non-directory component **anywhere along the destination path**
     fails at `open` time), then opening the destination's **final component
     relative to that proven parent fd** with `O_NOFOLLOW`. Because the parent
     proof and the write descend through the same fds, they are the **same
     kernel-enforced operation**: no component of the destination path was a
     symlink at the instant of the write, so the in-place write into
     `job.destination` cannot be redirected through a symlinked component. The
     CLI's pre-flight realpath check (above) — which is what enforces lexical
     containment **inside `base`** — is **defense in depth and insufficient on its
     own** against a TOCTOU swap; the open-time daemon base-free `openat` descent
     is what satisfies this requirement. *(Lexical base-confinement is the CLI's
     concern because only the CLI has `base`; symlink-component refusal is the
     daemon's because it needs only the path it already has.)*
   This defeats a pre-planted *and* a concurrently-swapped symlink that would
   redirect a lexically-valid path out of the tree. Any failure of either part
   ⇒ refuse: the daemon returns a `GohError` for the symlink-component refusal,
   which the CLI maps to **exit `5`** (path-escape/confinement, §9.4) — **not**
   the generic download-failure exit `8`. No byte written.
4. **Confine the write.** The download writes **in place** to `job.destination`,
   opened relative to the parent fd proven by the base-free `openat` descent (rule
   3): each intermediate component of the destination's own path is opened with
   `O_NOFOLLOW | O_DIRECTORY` from the descent anchor (the filesystem root `/`, or
   the first existing real-directory ancestor — **not** `base`, which the daemon
   does not have) down to the final parent, and the final component is opened
   relative to that parent fd with `O_NOFOLLOW`. Because the destination is reached
   only through fds proven to contain no symlinked component, the daemon's in-place
   write into `job.destination` cannot be redirected through a symlink. Lexical
   containment **inside `base`** is guaranteed separately by the CLI pre-flight
   (rules 1–2 + realpath check), which is the layer that has `base`. There is
   **no** download `.tmp`/`rename` stage (downloads write and resume in place); the
   `.tmp`→`rename` atomic pattern is the lockfile write only (§5).

These checks are a hard requirement with dedicated Swift Testing cases:
absolute path, `../` escape, symlinked intermediate dir, symlinked target file,
and a **symlink-swap (TOCTOU) test** — a symlink planted at the destination's
parent or final component *after* the CLI's lexical/realpath pre-flight but
*before* the write must still be refused (exit `5`) and produce no write outside
`base`, proving the confinement is enforced at open time on the daemon write path
and not by a CLI pre-flight string check alone. The TOCTOU test **exercises the
daemon's `DownloadFile` write path** (the `O_NOFOLLOW` open + symlink-component
refusal), since that is where the moment-of-write guarantee now lives. Each must
be refused with exit `5` and produce no write.

### 4.2 TOFU trust boundary

For an **unpinned** entry, first download establishes trust: goh records whatever
hash it received. A network adversary at first use can plant a hash that becomes
"trusted". This is inherent to trust-on-first-use and is **not fixed** in v1;
it is **bounded and disclosed**:

- A pinned `sha256` defeats it entirely (the manifest author asserts the bytes).
- First-use recording is logged loudly: `recorded sha256:… (first use, unverified)`.
- Any later change is surfaced as the loud, named AC5 event, never silent.

The boundary is documented in `goh sync` help and in §9.

### 4.3 Lockfile-tampering trust boundary

A locally edited `gohfile.lock` (hand-changed hash) will pass `verify` because
`verify` compares disk bytes to the lock's own recorded hash. The trust boundary
is **the user's own filesystem**: goh does not defend the user from themselves.
For shared scenarios the defense is a **pinned `sha256` in the manifest** plus
the `manifestHash` binding (§8) — the lock cannot silently disagree with the
manifest without `sync` flagging it stale. Documented, not "fixed".

### 4.4 Reserved auth field

`auth` is reserved in the manifest (§7) and **must not** trigger any credential
read, network header, or cookie use in v1. A v1 parser that encounters an `auth`
key that is **present and non-null rejects it loudly** (`'auth' is reserved and
not supported in this version of goh`, exit `1`) rather than silently ignoring
it — reserved ≠ silently accepted, so the field cannot quietly accumulate values
that do nothing (or, worse, are assumed to do something). A future version may
attach behavior and begin accepting it. No secret is ever read or written into
`gohfile.lock`.

---

## 5. Rollout

**Purely additive. No frozen-contract change. No migration.** The one daemon-side
code change is a **contained internal hardening** of the existing write path,
described below; it touches no wire format, command, or catalog schema.

- **XPC `protocolVersion` stays 3.** `sync` reuses the existing `add` command,
  one call per entry. `verify` and `which` are CLI-local and never touch XPC.
  No new `Command` case, no dispatcher change, no golden-fixture bump.
- **Catalog schema stays version 1.** No `JobSummary`/`JobCatalog` change ships
  in v1. (The optional `sha256` field discussed in §10 is *reserved*, not added.)
- **Contained internal daemon hardening (no frozen-contract change).** The
  daemon's `DownloadFile` write path gains open-time `O_NOFOLLOW` on
  `job.destination` (added to its existing `O_RDWR | O_CREAT`, keeping `O_TRUNC`
  for a fresh download and the truncate-free reopen for resume; **no `O_EXCL`**,
  which is incompatible with create-or-resume) plus symlink-component refusal via a
  **base-free** `openat` descent of the destination's own path components —
  anchored at a daemon-resolvable point (the filesystem root `/`, or the first
  existing real-directory ancestor of `job.destination`; **not** `base`, which the
  daemon never receives), each intermediate component opened
  `O_NOFOLLOW | O_DIRECTORY`, the final component opened relative to the proven
  parent fd with `O_NOFOLLOW` (§4.1.3). Lexical base-confinement is the CLI's
  pre-flight job (it has `base`; the daemon does not). Downloads write **in
  place**; there is **no** download-side `.tmp` sibling. This is **additive
  internal hardening**,
  not a contract change: `protocolVersion` stays 3, no new `Command`, no catalog
  migration, no golden-fixture bump. Because it lives in the shared write path it
  **hardens all downloads** — every `goh add`, not just `sync` — and is **fully
  tested** (the §4.1 symlink-swap TOCTOU test now exercises this daemon write
  path).
- **Backward compatible.** Existing installs are unaffected; `gohfile.toml` /
  `gohfile.lock` exist only when a user opts into `sync`. No on-disk file goh
  already owns is touched. The `DownloadFile` hardening only *refuses* unsafe
  opens (symlinked destinations); legitimate downloads are unchanged.
- **Lockfile versioning is forward-defensive.** `lockfileVersion` (§8) is the
  first field; a reader encountering an unknown integer **rejects loudly**
  (`unsupported lockfileVersion N; upgrade goh`) rather than guessing.

**Interrupted-sync recovery.** A `sync` that dies partway (network drop, daemon
down, Ctrl-C) leaves: some files downloaded and recorded, others not. The lock
is always written **atomically** (`.tmp`→`fsync`→`rename(2)`→`fsync` dir, the
project pattern); it is never half-written. Recovery is by **idempotent re-run**:
`sync` re-hashes each already-present file, skips entries whose disk bytes match
the lock (and, for pinned entries, the manifest pin), and resumes the rest. The
underlying transfer resume/checkpoint is handled by the existing engine. There is
no rollback and no separate recovery command.

---

## 6. Edge cases

| Case | Behavior | Exit |
|------|----------|------|
| **Empty manifest** (no `[[asset]]`) | Valid. `sync` writes a lock with `manifestHash` and zero entries; logs `nothing to sync`. `verify` reports `0 entries, all verified`. | `0` |
| **Manifest changed, lock stale** | `sync` computes `manifestHash` of the current `gohfile.toml`; if it differs from the lock's `manifestHash`, the lock is treated as stale: changed/new entries are re-resolved, the lock is regenerated. `verify` with a stale lock errors `lock is stale (manifestHash mismatch); run goh sync`. | sync `0`; verify `6` |
| **Pinned mismatch** (entry has `sha256`, download differs) | Download rejected, bad bytes not left at destination (quarantined `.corrupt-<unix>` per project pattern), entry reports `checksumMismatch`. *Distinct from AC5.* | `2` |
| **Unpinned TOFU change** (no `sha256`, recorded hash differs from new download) | Named event `hash changed for unpinned entry <path>`: old `sha256:…` → new `sha256:…`. Lock **not** updated unless `--accept-changed` / interactive confirm. *Distinct from pinned mismatch.* | `3` (without opt-in); `0` (with opt-in) |
| **Concurrent sync/verify** on the same lock | Each holds an **advisory `flock`** (`LOCK_EX`) on `gohfile.lock` for the duration of its read-modify-write. A second process waits briefly then fails fast: `another goh sync/verify is running on this lockfile`. Atomic rename + flock together prevent a lost update. | `7` (could not acquire lock) |
| **Missing lock** | `verify` / `which` (lock path): `no gohfile.lock; run goh sync first`. `sync`: treated as first sync (TOFU for all unpinned). | verify `6`; sync `0` |
| **Corrupt lock** (unparseable / bad `lockfileVersion`) | Quarantine to `gohfile.lock.corrupt-<unix>` (project recovery pattern), then: `sync` rebuilds from manifest + disk; `verify` errors `corrupt lockfile`. Unknown `lockfileVersion` is *not* corruption → `unsupported lockfileVersion` instead. | sync `0`; verify `6`; unknown-version `1` |
| **File present but unrecorded** (on disk, not in lock) | `verify` lists it `untracked <path>` (informational, does not fail the run unless `--strict-untracked`). `which` on it falls back to the xattr provenance reader; if neither lock nor xattr has it → `no provenance record`. | verify `0` (or `10` with `--strict-untracked`); which `4` |
| **Locked entry's file missing on disk** (in lock, absent on disk) | `verify`: distinct signal `MISSING <path> (expected sha256:…)`, **not** a content mismatch — `verify` is read-only and does not re-download. `sync`: the same absence is repaired (re-downloaded, §9.1 step 4). | verify `9`; sync `0` (re-downloaded) |
| **Interrupted-download remnant present** (file on disk hashes to neither the pinned nor the locked value, e.g. a truncated partial) | `sync` treats it as not-present and **re-downloads** (reconcile/repair — §9.1 step 4), *not* a verify-style failure and *not* an AC5 change event. `verify` (read-only) reports the disagreement as `FAILED`. | sync `0` (after re-download); verify `2` |
| **Network / daemon down mid-sync** | The per-entry `add` call fails; that entry is reported `FAILED <path>: <reason>`, the loop continues to a clean stop, the lock retains all entries completed before the failure (atomic), exit non-zero. Re-run resumes. | `8` (one or more entries failed) |
| **Daemon open-time symlink/confinement refusal** (a symlinked path component is detected by `DownloadFile`'s base-free `O_NOFOLLOW` descent at write time, e.g. a TOCTOU swap after the CLI pre-flight) | The `add`'s job fails with a confinement `GohError`; the CLI maps it to a **path-escape**, not a generic download failure — `FAILED <path>: path-escape (symlinked component refused)`, no byte left outside the proven parent. *Distinct from a network/daemon failure.* | `5` (path-escape/confinement, §4.1) |

---

## 7. FROZEN FORMAT — `gohfile.toml` (manifest)

The manifest is **intent**, authored by a human, committed to a repo, shared.
TOML for human-friendliness and comments. UTF-8, LF.

### 7.1 Schema

Top-level (table) fields:

| Field | Type | Req | Meaning |
|-------|------|-----|---------|
| `version` | integer | optional (default `1`) | Manifest schema version. Unknown ⇒ reject loudly. Separate from `lockfileVersion`. |
| `base` | string | optional | Default destination base dir, relative to the manifest file. CLI `--base` overrides. A leading `~` MAY be used and is expanded to the user's home directory; `$VAR` env-var expansion is **not** supported (a literal `$` is a normal character). Expansion happens **before** confinement, and the expanded result is then canonicalized and used as the base (§4.1, §7.4). |

`[[asset]]` array of tables — one per asset:

| Field | Type | Req | Meaning |
|-------|------|-----|---------|
| `url` | string | **required** | Absolute `http(s)` URL. The only fetch source in v1. |
| `path` | string | **required** | Destination, **always a relative segment**, resolved under `base`. An **absolute** `path` (leading `/` or a drive form) is **hard-rejected** in v1 — exit `5`, never written — not merely discouraged (an opt-in flag to permit absolute destinations is a possible *future* addition, out of scope for v1). `dest` is an accepted alias (exactly one of `path`/`dest` per entry; both ⇒ error). `..`-traversal and symlinked components are likewise refused (§4.1). A literal `~` or `$` in `path` is an ordinary character, **never expanded** (§7.4). |
| `sha256` | string | optional | Expected hash, `sha256:<64-lowercase-hex>`. **Presence = pinned/strict** (AC3). Absence = trust-on-first-use. |
| `verify` | boolean | optional (default `true`) | Per-entry escape hatch. `verify = false` skips integrity enforcement **for this entry only**. There is **no global off switch** (the SSH `StrictHostKeyChecking=no` footgun is deliberately avoided). |
| `auth` | (reserved) | optional | **Reserved name — must be absent/null in v1.** Present and non-null ⇒ **rejected loudly** (`'auth' is reserved and not supported in this version of goh`), exit `1`. Reserved ≠ silently ignored: a v1 build attaches no behavior, so accepting the key would give a false sense it does something. Documented as the forward slot for private URLs. |

Unknown top-level or per-asset keys: **rejected loudly**
(`unknown key 'foo' in [[asset]]`). This keeps the frozen format honest — a typo
in `sha256` does not silently degrade to unpinned. The **reserved** key `auth` is
a recognized name but is *also* rejected when present/non-null (see its row): it
is neither silently accepted nor confused with an unknown-key typo — it gets its
own "reserved, not supported in this version" error so it cannot become a silent
dumping ground before behavior is attached in a future version.

### 7.2 Example

```toml
version = 1
base = "assets"

[[asset]]
url    = "https://example.org/datasets/mnist.tar.gz"
path   = "datasets/mnist.tar.gz"
sha256 = "sha256:6f1e2a...c9"          # pinned → strict (AC3)

[[asset]]
url  = "https://example.org/weights/model-latest.bin"
path = "weights/model-latest.bin"      # no sha256 → trust-on-first-use

[[asset]]
url    = "https://example.org/big-volatile.img"
path   = "scratch/big-volatile.img"
verify = false                          # per-entry escape hatch only

# Reserved for a future private-URL release. The `auth` key is a reserved
# NAME: if uncommented in v1 (present and non-null) sync rejects it loudly
# ('auth' is reserved and not supported in this version of goh). It is shown
# commented here only to document the forward slot.
# [[asset]]
# url  = "https://private.example.org/secret.bin"
# path = "secret.bin"
# auth = "env:EXAMPLE_TOKEN"
```

### 7.3 Considered alternatives (frozen-format notes)

- **`sha256` as a bare hex string vs. `sha256:<hex>`** — chose the prefixed form
  so a future `sha512:` needs no format-version bump (Git LFS / pip / SRI
  precedent, brief decision 1).
- **Pin = explicit `pinned = true` vs. presence of `sha256`** — chose presence;
  it is impossible to supply a hash and not mean it, and it removes a
  contradictory state (`pinned = true` with no hash).
- **`auth` omitted entirely vs. reserved now** — reserved *name* now so adding
  private URLs later is additive, not a format break (AC scope decision).
  Reserving is not silent acceptance: present/non-null `auth` is rejected loudly
  in v1 (§4.4, §7.1) so it can't accumulate meaningless values.
- **JSON/YAML manifest vs. TOML** — TOML: comments, trailing-comma-free, least
  surprising for a hand-edited dependency file; matches Cargo/`pyproject`.

### 7.4 Path expansion (`~` / environment variables) — frozen

Expansion rules are part of the frozen contract because they change what bytes a
shared manifest writes where, and they run **before** confinement validation:

- **`base`** MAY begin with a single leading `~`, expanded to the current user's
  home directory (`~/x` → `<home>/x`; a non-leading `~` is literal). **`$VAR`
  environment-variable expansion is NOT supported** anywhere — a literal `$` (and
  any `${…}`) is an ordinary character, never substituted. Rationale: a leading
  `~` is the one ergonomic case for a per-user base dir; env-var expansion would
  make a shared manifest's destination depend on the runner's environment, an
  escape/ambiguity vector, so it is excluded.
- **Per-entry `path`/`dest`** is **always treated literally as a relative
  segment**: a leading or embedded `~` or `$` is a normal filename character,
  **never expanded**. (A file literally named `~cache` is written as `~cache`.)
- **Order and re-validation:** expansion (the `base` `~` case only) happens
  **first**; the expanded, canonicalized `base` is then the confinement root, and
  every resolved `base + path` is re-validated against it per §4.1. No expanded
  result may escape the canonicalized base. The CLI `--base` argument follows the
  same rule (leading `~` expanded; no `$VAR`).

---

## 8. FROZEN FORMAT — `gohfile.lock` (lockfile)

The lock is **resolved truth**, machine-written by `sync`, committed alongside
the manifest, and the portable self-contained artifact (Cargo's lesson).
**The lock is TOML**, same as the manifest — chosen for **consistency** (one
parser, one mental model, human-diffable in review) over a binary plist or JSON.
Justification: the manifest already forces a TOML reader into the build (§9.5),
so a TOML lock adds **zero** new parsing surface; a second on-disk format
(plist/JSON) would add one for no benefit. The lock is human-readable on purpose
— a reviewer should be able to read a hash change in a PR diff.

### 8.1 Schema

Top-level, **`lockfileVersion` first** (schema version only, never tool version;
unknown ⇒ reject loudly):

| Field | Type | Req | Meaning |
|-------|------|-----|---------|
| `lockfileVersion` | integer | **required, first** | Format version. v1 = `1`. Unknown ⇒ `unsupported lockfileVersion N`. |
| `manifestHash` | string | **required** | `sha256:<hex>` of the `gohfile.toml` bytes at lock time. Checked every `sync`/`verify`; mismatch ⇒ "lock is stale, regenerate". |

`[[entry]]` array — one self-contained record per resolved asset (re-downloadable
**without** reading the manifest, per brief decision 4):

| Field | Type | Req | Meaning |
|-------|------|-----|---------|
| `url` | string | **required** | Resolved source URL. |
| `path` | string | **required** | Destination, relative to base (same confinement as §4.1 on read-back). |
| `sha256` | string | **required** | `sha256:<hex>` of the accepted bytes. |
| `size` | integer | **required** | Byte length of the accepted file. |
| `downloadedAt` | string | **required** | RFC 3339 / ISO 8601 UTC timestamp of acceptance. |
| `chunks` | (reserved) | optional | **Reserved name — must be absent/null in v1.** For future per-chunk repair (aria2/Metalink precedent, brief decision 8). A v1 writer never emits it; a v1 reader that finds `chunks` **present and non-null rejects it loudly** (`'chunks' is reserved and not supported in this version of goh`) — handled as corrupt-lock per §6 — rather than silently ignoring it (reserved ≠ silent dumping ground). |

### 8.2 Example

```toml
lockfileVersion = 1
manifestHash    = "sha256:a3f9...20"

[[entry]]
url          = "https://example.org/datasets/mnist.tar.gz"
path         = "datasets/mnist.tar.gz"
sha256       = "sha256:6f1e2a...c9"
size         = 11594722
downloadedAt = "2026-05-29T14:08:51Z"

[[entry]]
url          = "https://example.org/weights/model-latest.bin"
path         = "weights/model-latest.bin"
sha256       = "sha256:0b4477...e1"      # recorded on first use (TOFU)
size         = 438291104
downloadedAt = "2026-05-29T14:11:03Z"
```

### 8.3 Considered alternatives (frozen-format notes)

- **`lockfileVersion` first vs. anywhere** — first, so a reader can version-gate
  before parsing the rest (npm/Cargo precedent, brief decision 2).
- **Self-contained entries vs. lock referencing manifest by index** — self-
  contained; the lock must reproduce the set with the manifest deleted (Cargo,
  brief decision 4).
- **`manifestHash` present vs. absent** — present; it is the cheap, decisive
  staleness check that ties the two files together (brief decision 3) and is
  half of the §4.3 tamper defense.
- **Binary plist / JSON lock vs. TOML** — TOML, for the single-parser /
  human-diff reasons above. A binary plist would match the catalog/checkpoint
  convention but is opaque in review and adds a second format; the lock's value
  is being *readable and portable*, which outweighs convention here.
- **`chunks` reserved vs. omitted** — reserved; per-chunk repair is a known
  future want and reserving the *name* keeps it additive. Reserving the name does
  **not** mean silently accepting it: a v1 reader rejects `chunks` if present and
  non-null (§8.1), so the slot can't become a dumping ground before behavior
  exists.

---

## 9. Behavior specs

### 9.1 `goh sync [<path-to-gohfile.toml>] [--base <dir>] [--accept-changed]`

1. Resolve manifest path (default `./gohfile.toml`). Parse; reject unknown keys
   and malformed `sha256` loudly.
2. Acquire advisory `flock(LOCK_EX)` on `gohfile.lock` (create-if-absent). If
   held by another process: fail fast, exit `7`.
3. Compute `manifestHash`. Load existing lock if present (quarantine if corrupt;
   reject unknown `lockfileVersion`).
4. For each `[[asset]]`, in order:
   - Resolve + confine the destination (§4.1). Violation ⇒ refuse, exit `5`.
   - **If the file exists on disk:** re-hash it at the confined destination path.
     - Pinned: matches manifest `sha256` ⇒ `up to date`, skip. Matches neither
       the manifest `sha256` **nor** the lock-recorded `sha256` (e.g. a
       present-but-incomplete file from an interrupted prior `sync`) ⇒ treat as
       **not present**: re-download (step 4 "absent" path) and re-check.
       Persistent mismatch against the pin after a fresh download ⇒
       `checksumMismatch`, exit `2`. **This is the sync ↔ verify distinction:**
       `sync` *reconciles and repairs* (a hash matching neither expected value is
       a download to redo, never a failure to report), whereas `verify` (§9.2) is
       *read-only and reports* (the same disagreement is a `FAILED` line).
     - Unpinned: matches lock-recorded hash ⇒ `up to date`, skip. Differs from a
       *recorded* hash, **and the file is otherwise complete** ⇒ the AC5 path
       (handled in step 6). Differs from the recorded hash because the file is a
       present-but-incomplete remnant of an interrupted prior `sync` (size below
       the lock's `size`, or no `size` recorded yet) ⇒ treat as **not present**:
       re-download, not an AC5 event. (An interrupted partial is repaired, not
       surfaced as an upstream change.)
   - **If absent (or reclassified as not-present above):** enqueue the download
     via the existing `add` XPC call (one `add` per entry; the `add` reply is a
     `JobSummary` carrying the daemon-assigned `id`, `state`, and resolved
     `destination`). Then **detect completion of that specific job** and
     **re-hash the file at its confined destination path** — see step 4a. The
     SHA-256 is *never* obtained from the daemon; it is recomputed CLI-side from
     the bytes on disk after the job reaches a terminal state.

4a. **Completion detection + digest acquisition (concrete mechanism, Approach 1).**
   Obtaining the digest *from* the daemon is **out of scope** under Approach 1 —
   the `add` reply (`JobSummary`) carries no `sha256`, and adding one is a
   catalog/`protocolVersion` change this approach forbids (§5, §10). The CLI
   therefore acquires the digest by re-hashing the completed file itself. The
   completion signal uses **only commands that already exist** at
   `protocolVersion = 3`:
   - **Primary mechanism — poll `ls` by job `id`.** After `add` returns the
     `JobSummary.id`, the CLI issues the existing `ls` command and reads the
     matching entry's `JobSummary.state`. The **only terminal states are
     `completed` and `failed`** (`JobState` = {`queued`, `active`, `paused`,
     `completed`, `failed`} — there is no `cancelled`). The poll resolves on one
     of three terminal conditions:
       - **`completed`** ⇒ proceed to re-hash.
       - **`failed`** ⇒ report `FAILED <path>: <reason>`, exit contribution `8`
         — **except** when the failure's `GohError` is the daemon's open-time
         symlink-component / confinement refusal (§4.1.3): that is a path-escape,
         so the CLI maps it to exit contribution **`5`**, not `8`.
       - **Job `id` absent from the `ls` reply** (the job was removed via `rm`, or
         lost on a daemon restart, and will therefore never reach a state) ⇒ treat
         that entry as failed: report `FAILED <path>: job disappeared`, exit
         contribution `8`. This is an explicit terminal branch so a vanished job
         can never hang the poll.
     Polling is bounded by a short backoff, and by an overall **per-entry
     no-progress watchdog**. **The watchdog default is defined once here and reused
     by both completion paths: no observed state/byte advance for 120 s ⇒ the entry
     fails, report `FAILED <path>: timed out (no progress)`, exit contribution
     `8`.** The watchdog resets on any observed progress, so a slow but live
     download is not killed; only a wedged job times out. `sync` is already a
     sequential per-entry loop (§3), so one in-flight job at a time keeps this
     simple.
   - **Alternative (lower latency, also already present) — `subscribe`.** The
     existing `subscribe` progress-notification stream (`Command.subscribe`,
     server-initiated `notification` envelopes via `ProgressBrokerHub`) MAY be
     used instead of polling to await the terminal transition for the job `id`.
     The same three terminal conditions and the **same per-entry no-progress
     watchdog defined above** apply: `completed` ⇒ re-hash; `failed` ⇒ exit
     contribution `8`; and because a removed/lost job **stops appearing in the
     stream** (no further notifications), the watchdog firing (the no-progress
     default above) is what converts that silence into
     `FAILED <path>: job disappeared`, exit contribution `8` — the subscribe path
     must not block forever on a job that vanished. Either mechanism is acceptable;
     both ship today. No new command, reply field, or `protocolVersion` bump is
     introduced by either.
   - **Then re-hash at the destination.** Once the job for `id` is confirmed
     `completed`, the CLI re-hashes the finished file **at its confined
     destination path** to obtain the entry's `sha256` and `size`. It uses a
     **small new CryptoKit SHA-256 streaming wrapper** (CryptoKit's `SHA256`
     incrementally over file-read chunks) — *not* `ChunkAssembler`, which is
     download-bound (tied to a live `DownloadFile` and its in-flight ranges) and is
     therefore not a file-digest entry point. No standalone at-rest file-digest
     primitive exists today, so this wrapper is written as part of this work; it
     streams the completed file through CryptoKit SHA-256. This recomputed digest —
     not any daemon-provided value — is what acceptance (steps 5–6) checks and what
     is written to the lock.
   - *Non-normative performance note:* immediately after completion the bytes are
     typically still warm in the page cache, so the re-hash read is usually cheap.
     This is a performance observation only and is **not** part of the contract;
     correctness does not depend on cache residency, and a cold re-read is
     equally valid.
5. **Pinned acceptance (AC3):** computed hash must equal manifest `sha256`, else
   the file is **not** left at the destination (quarantine `.corrupt-<unix>`),
   entry reports `checksumMismatch`, exit `2`. `verify = false` skips this check
   for that entry only.
6. **Unpinned acceptance (TOFU, AC3/AC5):**
   - First use (no recorded hash): record it, log
     `recorded sha256:… (first use, unverified)`.
   - Recorded hash exists and **differs** from the new bytes: emit the named
     event `hash changed for unpinned entry <path>: sha256:OLD → sha256:NEW`.
     **Do not** update the lock unless `--accept-changed` (or interactive
     confirmation on a TTY) is given. Without opt-in: exit `3`. With opt-in:
     update the lock entry, exit contribution `0`.
7. Write each accepted entry into the in-memory lock; persist the whole lock
   **atomically** (`.tmp`→`fsync`→`rename`→`fsync` dir) with the current
   `manifestHash`. Release `flock`.
8. Exit `0` only if every entry was accepted or up to date; otherwise the highest-
   precedence failure code among `{2,3,5,8}` (precedence `5 > 2 > 3 > 8`, most-
   security-relevant first).

Idempotency (AC1): a second run finds every file present and matching ⇒ zero
bytes transferred, all `up to date`, exit `0`.

### 9.2 `goh verify [<path-to-gohfile.lock>] [--strict-untracked]`

1. Load lock (missing ⇒ exit `6`; corrupt ⇒ exit `6`; unknown version ⇒ exit `1`).
2. Acquire advisory `flock(LOCK_SH)`.
3. If a `gohfile.toml` is alongside, recompute `manifestHash`; mismatch ⇒
   `lock is stale (manifestHash mismatch); run goh sync`, exit `6`.
4. For each `[[entry]]`: confine path (§4.1), re-hash on disk, compare to
   recorded `sha256`. Three distinct per-entry outcomes:
   - **Present and matching** ⇒ `OK <path>`.
   - **Present and content-mismatched** ⇒
     `FAILED <path> expected sha256:… actual sha256:…` (surfacing
     `GohError.checksumMismatch`). Contributes exit `2`.
   - **Absent (locked entry whose file is missing on disk)** ⇒ a *distinct*
     observable signal `MISSING <path> (expected sha256:…)` — **not** a content
     mismatch. `verify` is read-only and never downloads, so a missing file is
     reported, not repaired (contrast `sync`, which re-downloads it). Contributes
     exit `9`. This is deliberately separate from `2` so a caller can tell "the
     file rotted/was swapped" (`2`) from "the file is gone" (`9`).
   Show byte progress for large files.
5. Files on disk under base but not in the lock ⇒ `untracked <path>`
   (informational; fails the run only with `--strict-untracked`).
6. Exit `0` if all entries are `OK` (and, under `--strict-untracked`, none
   untracked). Otherwise the highest-precedence failure code among the outcomes
   present, precedence `9 > 2 > 10` (a missing file is the most fundamental fault,
   then content drift, then a merely-untracked file): any `MISSING` ⇒ exit `9`;
   else any `FAILED` ⇒ exit `2`; else (only untracked files present, under
   `--strict-untracked`) exit `10`. Plain `verify` (no `--strict-untracked`) never
   exits `10`; untracked files stay informational.

### 9.3 `goh which <path>`

CLI-local, no XPC. For the given file:
1. If a `gohfile.lock` records this `path`: print `url`, `sha256`, `downloadedAt`.
2. Else read Spotlight provenance via a **new `getxattr` reader**
   (`kMDItemWhereFroms` / `kMDItemDownloadedDate`, the reverse of the existing
   tagger): print URL + downloaded date (no recorded hash → print
   `sha256: (not recorded)`).
3. Neither source has it ⇒ `no provenance record for <path>`, exit `4`.
   Found ⇒ exit `0`.

### 9.3a Lock location and entry-path resolution (cross-machine reproduce)

`verify` and `which` locate the lock at an **explicit path argument** if given,
else `./gohfile.lock` in the current directory. Entry `path`s are **relative
segments** (§7.1, §8.1) and are resolved — and re-confined per §4.1 — under the
**directory containing the lock** (or under `--base <dir>` when supplied), *not*
under the process's current directory. This is what makes a committed
manifest + lock reproduce after a fresh clone on another machine: a teammate who
clones the repo and runs `goh verify path/to/gohfile.lock` gets every entry
resolved relative to that lock's directory, so the same bytes are checked at the
same relative destinations regardless of where the clone lives or what the cwd
is. The base used for read-back resolution is recorded/derived the same way
`sync` derived it, and the §4.1 confinement is applied identically on read-back
(no entry may resolve outside the lock's directory / `--base`).

### 9.4 Exit codes (frozen)

Every exit code referenced anywhere in this spec appears in this table exactly
once, with one unambiguous meaning; no code carries two meanings.

| Code | Meaning |
|------|---------|
| `0` | Success / all up to date / all verified / provenance found. |
| `1` | Usage error, unparseable args, unsupported `lockfileVersion`/`version`, or the manifest reserved-field rejection (`auth` present and non-null, §4.4/§7.1). *(The lock reserved field `chunks` present/non-null is handled as a corrupt lock, exit `6`, not `1` — §8.1, §6.)* |
| `2` | Integrity failure — pinned mismatch or `verify` content drift (`checksumMismatch`). |
| `3` | Unpinned TOFU hash change without opt-in (AC5, **distinct from `2`**). |
| `4` | No provenance record (`which`). |
| `5` | Path-escape / confinement violation (§4.1) — refused with no byte written outside the confined tree. Raised by **either** layer: the **CLI pre-flight** (absolute path, `..` escape, or realpath outside `base`; rules 1–2), **or** the **daemon's open-time** base-free `O_NOFOLLOW`/`openat`-descent refusal of a symlinked path component (rule 3 / §4.1.3), whose `GohError` the CLI maps here rather than to the generic download-failure code `8`. |
| `6` | Lock missing / corrupt / stale (`manifestHash` mismatch). |
| `7` | Could not acquire advisory lock (concurrent run). |
| `8` | One or more entries failed to download (network/daemon failure, job disappeared, or per-entry no-progress timeout). |
| `9` | `verify`: one or more locked entries are **missing** on disk (**distinct from `2`** content mismatch). |
| `10` | `verify --strict-untracked`: one or more files on disk are **untracked** (present under base, absent from the lock), with no `MISSING` or content `FAILED` outcome present. **Distinct from `2`** integrity drift. |

### 9.5 TOML parsing — build vs. buy (decision, committed)

**Decision: hand-rolled minimal TOML subset reader+writer, no third-party
dependency.** Justification under the Apple-frameworks-first / dependency policy
(`CLAUDE.md` §Hard constraints):

- Apple ships no TOML parser; the policy requires explicit justification for any
  third-party dependency, and the only current dependency is `swift-http-types`.
- The grammar goh needs is **tiny and fully controlled by these two frozen
  schemas**: top-level integer/string/boolean key-values, arrays of tables
  (`[[asset]]` / `[[entry]]`), string/integer/boolean scalars, comments, UTF-8.
  No dotted keys, no inline tables, no datetime *types* (timestamps are stored as
  strings), no multiline arrays required. A general TOML library (e.g. TOMLKit)
  is far larger than this surface and adds a supply-chain + version-skew burden
  for capability goh will never use.
- goh **owns both formats**, so the writer and reader are co-designed; we never
  have to round-trip arbitrary third-party TOML.
- Unknown-key-rejection and `sha256:`-shape validation are first-class
  requirements (§7.1), which a hand-rolled reader enforces directly rather than
  layering atop a permissive general parser.

**Dependency sequencing (committed):** the hand-rolled TOML reader+writer is a
**prerequisite, built and golden-tested FIRST**, before `sync`/`verify`/`which`
behavior is implemented. Both frozen formats (§7, §8) sit on top of it, so it is
the bottom of the dependency graph; its golden-file fixtures (below) must pass
before any command that parses a manifest or lock is written. Nothing in §9.1–9.3
is "done" while the parser is unverified.

**Frozen accepted grammar subset.** The reader accepts exactly this TOML subset,
and **nothing else**:

- UTF-8, LF line endings.
- Top-level key/value pairs where the value is one of: a basic string
  (double-quoted), a decimal integer, or a boolean (`true`/`false`).
- Arrays of tables only in the two fixed forms `[[asset]]` (manifest) and
  `[[entry]]` (lock); inside them, the same scalar value types.
- `#` line comments and blank lines.
- **Explicitly excluded** (not accepted, even though they are valid TOML):
  dotted keys, inline tables (`{ … }`), array values (`[ … ]`), standard tables
  (`[table]`), multiline / literal (single-quoted) / multiline-literal strings,
  native TOML datetimes (timestamps are stored as **strings**), float values,
  hex/octal/binary or underscore-separated integers.

**Error behavior for valid-TOML-but-outside-the-subset (frozen).** Input that is
*well-formed TOML* yet uses a construct outside the accepted subset is **rejected
loudly with a specific, named error** — never silently mis-parsed and never
accepted as if the construct meant something. The error identifies the construct
and points the user back to the supported subset, e.g.
`unsupported TOML construct 'inline table' at line N; goh accepts only <subset>`,
`unsupported TOML construct 'dotted key'`, `unsupported value type 'float'`,
`unsupported value type 'array'`. This guarantees a user who pastes otherwise-valid
TOML gets a clear, specified diagnostic rather than a silent misparse. Exit `1`
(usage/parse error) for `sync`; corrupt-lock handling (§6) for a lock that parses
as TOML but violates the subset.

Mitigation of the "brittle hand-roll" risk: the reader/writer is covered by
**golden-file fixtures** (CLAUDE.md test discipline — "golden-file fixtures for
any wire format") for both schemas, including malformed inputs (bad hash shape,
unknown key, missing required field, unknown version), **valid-TOML-outside-the-
subset inputs** (inline table, dotted key, array value, float, native datetime —
each asserting the specific "unsupported construct/value" error), and the
**reserved-field rejection** cases (§7.1, §8.1 — `auth`/`chunks` present and
non-null), each asserting the exact error and exit code. The accepted subset is
documented in code as the contract; inputs outside it are rejected loudly, never
silently mis-parsed.

---

## 10. Implementation constraints carried from the approach (non-frozen)

Recorded because they shape the contract; not themselves frozen.

- **CLI-local, re-hash on demand.** `sync` loops the existing `add` XPC call
  (one per entry), awaits each job's terminal state via a mechanism that already
  exists at `protocolVersion = 3` — **polling `ls` by the `JobSummary.id` the
  `add` reply returns** (primary), or the existing `subscribe` progress stream
  (alternative) — then **re-hashes the file at its destination path** to obtain
  the `sha256`/`size` (§9.1 step 4a). Terminal states are exactly `completed` and
  `failed` (there is no `cancelled` in `JobState`); a job that **disappears** from
  `ls`/the stream (removed or lost on daemon restart) and a per-entry no-progress
  timeout are both treated as terminal failures (exit contribution `8`, §9.1
  step 4a) so completion detection cannot hang. The digest is **never** read from
  the daemon: the `add`/`ls` `JobSummary` carries no hash, and adding one would be
  a catalog/`protocolVersion` change Approach 1 forbids. `verify`/`which` are
  CLI-local. No `protocolVersion` bump (stays 3), no catalog migration. Re-hash
  is bounded (~1 GB/s on Apple Silicon; a 70 GB verify ≈ 70 s) and `verify` must
  re-read the file anyway to detect drift, so persisting the digest buys nothing
  for this feature.
- **Contained daemon write-path hardening (no frozen-contract change).** The one
  daemon-side code change in v1 is internal: the daemon's `DownloadFile` opens
  `job.destination` **directly** (downloads write in place; resume reopens the
  same path to append — there is **no** download-side `.tmp` sibling) with
  `O_NOFOLLOW` added to its existing `O_RDWR | O_CREAT` flags (keeping `O_TRUNC`
  for a fresh download and the truncate-free reopen for resume; **no `O_EXCL`** —
  it is incompatible with create-or-resume), and refuses symlinked path components
  at open time via a **base-free** `openat` descent of the destination's own path
  components — anchored at a daemon-resolvable point (the filesystem root `/`, or
  the first existing real-directory ancestor of `job.destination`; **not** `base`,
  which the daemon never receives — `AddRequest`/`JobSummary` carry only an
  absolute `destination`, and adding `base` would be the catalog/`protocolVersion`
  change this approach forbids) — each intermediate component opened
  `O_NOFOLLOW | O_DIRECTORY`, the final component opened relative to the proven
  parent fd with `O_NOFOLLOW` (§4.1.3). A daemon symlink-component refusal returns
  a `GohError` that the CLI maps to **exit `5`** (§9.4), not the generic
  download-failure exit `8`. This is **additive internal hardening** —
  `protocolVersion` stays 3, no new `Command`, no catalog migration — and because
  it lives in the shared write path it **hardens every `goh add`**, not just
  `sync`. The CLI owns the complementary half: it canonicalizes + lexically
  confines (rules 1–2) + pre-flight realpath-checks the destination's parent
  against `base` before calling `add` (the layer that has `base`) and passes the
  daemon an absolute, already-lexically-confined path.
- **Reuse, don't reinvent:** at-rest SHA-256 via CryptoKit streaming over a file
  read — **not** `ChunkAssembler`, which is download-bound (tied to a live
  `DownloadFile` and its in-flight ranges) and is not a file-digest entry point.
  **Note this is a SMALL NEW CryptoKit SHA-256 streaming wrapper to be written:**
  no standalone at-rest file-digest primitive exists today (the only SHA-256 path
  in the tree is `ChunkAssembler`'s download-bound one), so "reuse the primitive"
  means *reuse CryptoKit's `SHA256` incrementally over file-read chunks* — a small
  new helper — not call an existing entry point. The at-rest re-hash streams the
  finished file through that wrapper. Also reuse: the
  `.tmp`→`fsync`→`rename`→`fsync`-dir atomic write **for the lockfile write
  (CLI-side) only** — downloads write in place to `job.destination`, with no
  `.tmp`/`rename` stage; `.corrupt-<unix>` quarantine for corrupt locks and
  rejected pinned downloads; `GohError.checksumMismatch` for integrity failures;
  the `doctor`-style CLI-local verb pattern in `parse(_:)`/`ParsedCommand`; a new
  `getxattr` companion to the Spotlight tagger for `which`.
- **Reserved future seam (not built):** an optional `sha256` field on
  `JobSummary` would later give provenance to non-`sync` downloads **without
  changing the lock format**. v1 does **not** add it and does **not** bump the
  catalog version.
- **Dependency sequencing:** the hand-rolled TOML reader+writer (§9.5) is built
  and golden-tested **first**, as a prerequisite, before any
  `sync`/`verify`/`which` behavior — both frozen formats depend on it.
- **Testing:** Swift Testing (not XCTest); golden fixtures for both wire formats
  including valid-TOML-outside-the-accepted-subset inputs (each asserting the
  specific "unsupported construct/value" error, §9.5) and reserved-field
  rejection (`auth`/`chunks` present and non-null, §7.1/§8.1); one test per AC
  row in §2 asserting stdout signal + exit code; the §4.1 confinement attack
  cases **including the symlink-swap (TOCTOU) test**; the `verify` MISSING-file
  case (exit `9`, distinct from `2`); the interrupted-`sync` reconcile case (a
  remnant matching neither pinned nor locked value is re-downloaded, not failed);
  the completion-detection path (`add` → poll `ls`/`subscribe` by job `id` →
  re-hash at destination); concurrent-`flock`; `-warnings-as-errors`, `Sendable`
  clean.
