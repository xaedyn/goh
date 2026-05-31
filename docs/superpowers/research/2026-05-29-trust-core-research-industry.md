# Industry-Pattern Research: goh Trust Core
**Date:** 2026-05-29  
**Branch:** fix/smooth-wordmark-vector (research only; no code changes)  
**Purpose:** De-risk the manifest+lockfile / content-addressed / TOFU design for `goh sync`, `goh verify`, `goh which`.

---

## Area 1 — Manifest + Lockfile Designs

### npm `package.json` / `package-lock.json`

**STEAL: `lockfileVersion` integer field** — npm uses a plain integer (`1`, `2`, `3`) as the first key in the lockfile. Readers reject or warn on unknown values. Cost of not doing this: you can never change the format without silent corruption. [VERIFIED: https://docs.npmjs.com/cli/v11/configuring-npm/package-lock-json/]

**AVOID: Nested/hierarchical lockfile structure** — v1 used a strictly hierarchical object that mirrored `node_modules/`; it caused cascading merge conflicts and made symlink deps unrepresentable. v2 added a flat `packages` map as the canonical source; v3 dropped the legacy tree entirely. The lesson: flat structures are merge-friendly and diff-friendly; nested structures scale poorly. [VERIFIED: npm docs, Nesbitt 2026]

**AVOID: Recording the tool version instead of the schema version** — Bundler writes `BUNDLED WITH 2.x.x`; this means every developer on a different Bundler version regenerates a dirty lockfile. Schema versions are stable; tool versions are not. Cargo gets this right. [VERIFIED: https://nesbitt.io/2026/01/17/lockfile-format-design-and-tradeoffs.html]

**STEAL: Stale-lock detection via hidden lockfile mtime** — npm keeps a shadow lockfile in `node_modules/.package-lock.json`. If its mtime predates packages it references, or if extra packages exist in `node_modules` that are not in the lockfile, the shadow file is invalidated and a full resolve runs. For `goh`: a simple strategy is to hash the manifest at lock time and store that hash in the lockfile; re-validate on every `sync`. [SINGLE: npm docs]

**STEAL: Make each lockfile entry self-contained** — every package entry must be independently addable or removable without touching other entries. This is what makes `git merge` on a lockfile tractable. [VERIFIED: Nesbitt 2026]

### Cargo (`Cargo.toml` / `Cargo.lock`)

**STEAL: Manifest holds intent (ranges); lockfile holds resolved truth (exact)** — `Cargo.toml` says `regex = "1"`, `Cargo.lock` records the exact commit SHA or version number. The two files have completely disjoint roles. [VERIFIED: https://doc.rust-lang.org/cargo/guide/cargo-toml-vs-cargo-lock.html]

**STEAL: Lockfile must be self-contained** — a lockfile should contain enough information to download all dependencies without consulting the manifest. If you need both files to fetch, you have split information that belongs together. [VERIFIED: Cargo book, Nesbitt 2026]

**STEAL: `ResolveVersion` enum in Cargo** — Cargo tracks lockfile format evolution through a typed enum with explicit schema numbers, not a freeform string. Format migrations are additive; old readers warn, not crash. [VERIFIED: https://deepwiki.com/rust-lang/cargo/3.3-lockfile-management]

### Python (`pip --require-hashes`, `pip-tools`, `poetry.lock`)

**STEAL: `--hash=sha256:<hex>` prefix pattern** — pip's requirements format uses `algorithm:value` (e.g. `sha256:2cf24dba…`). Multiple `--hash` entries are allowed per package; if any matches, the download is accepted. The algorithm is baked into the hash string, not stored separately. [VERIFIED: https://pip.pypa.io/en/stable/topics/secure-installs/]

**STEAL: All-or-nothing hash enforcement** — specifying a hash for any single package activates `--require-hashes` globally: every package, including transitive deps, must have a hash. Partial hashing is rejected. This is the correct security model: a partially-hashed file has no stronger guarantees than a file with no hashes. [VERIFIED: pip docs]

**AVOID: MD5 / SHA-1 in hashes** — pip explicitly excludes `md5` and `sha1` as too weak. Start with `sha256` as the minimum acceptable algorithm. [VERIFIED: pip docs]

**AVOID: Hash generation gaps for private/URL-based packages** — poetry.lock has well-documented open issues (GH #2060, #1627) where URL-based and private packages fail to generate hashes, leaving silent gaps in the integrity record. For `goh`: every entry in `gohfile.lock` must have a hash field; missing hash is an error, not a warning. [VERIFIED: https://github.com/python-poetry/poetry/issues/2060]

### Go (`go.mod` / `go.sum`)

**STEAL: `h1:` algorithm prefix in go.sum** — Go uses `h1:<base64>` where `h1` names the hashing scheme. Additional prefix labels are reserved for future algorithms. The prefix is a human-readable algorithm ID, not a numeric code. [VERIFIED: https://pkg.go.dev/golang.org/x/mod/sumdb/dirhash]

**STEAL: Mismatch error message text** — Go prints: *"This download does NOT match an earlier download recorded in go.sum. The bits may have been replaced on the origin server, or an attacker may have intercepted the download attempt."* This is a model for `goh`'s `verify` output: clear, non-alarmist description of what happened, with explicit guidance that the user should investigate before force-updating. [VERIFIED: Go source / sobyte.net]

**STEAL: Escape hatches for private sources** — `GONOSUMDB` / `GOPRIVATE` let users exclude specific URL prefixes from checksum database lookup. For `goh` v1 (public URLs only): not needed immediately, but the pattern to reserve: `goh verify --skip-hash <path>` or a `trust = "skip"` per-entry flag. [VERIFIED: Go docs]

**AVOID: Conflating the escape hatch with "turn it all off"** — `GONOSUMDB=*` effectively disables all verification. Users reach for this when they get a mismatch they don't understand. The right mitigation is a better error message that tells the user the escape-hatch command explicitly, rather than making them discover it. [SINGLE: Go community reports]

### Terraform (`.terraform.lock.hcl`)

**STEAL: Multi-hash-per-entry (`h1:` and `zh:` side by side)** — Terraform records multiple hashes for the same artifact: `h1:` (content hash of unpacked dir) and `zh:` (hash of the original `.zip`). This allows verification on both the download archive and the unpacked content. For `goh` v1: store one `sha256:` hash of the whole file; reserve a `chunks:` field for future chunk-level verification. [VERIFIED: https://developer.hashicorp.com/terraform/language/files/dependency-lock]

**STEAL: Cross-platform hash accumulation** — Terraform "opportunistically adds `h1:` hashes as it learns of them" across platforms. The lockfile grows over time as new platforms are encountered. For `goh`: if a URL is downloaded on multiple machines, a future `goh lock --merge` could union the known hashes. [VERIFIED: Terraform docs]

**STEAL: TOFU is explicit, not hidden** — Terraform's docs say explicitly "when you add a new provider for the first time you can verify it in whatever way you choose." The burden of initial verification is acknowledged and placed on the user, not swept under the rug. [VERIFIED: Terraform docs]

---

## Area 2 — Content-Addressed / Integrity Systems

### restic

**STEAL: Storage ID = SHA-256 hex of content, used as filename** — restic names every stored blob by `lowercase_hex(sha256(content))`. This gives free integrity checking: `sha256sum` output can be compared to the filename. For `goh`: the lock entry's `sha256` field is exactly the sha256 of the raw downloaded bytes; no separate verification step needed. [VERIFIED: https://restic.readthedocs.io/en/stable/design.html]

**STEAL: Immutable write semantics** — restic writes are atomic and files are never modified after write. This is the correct mental model for `gohfile.lock`: once written, a lock entry is immutable; updates produce a new entry with a new hash, not an in-place edit. [VERIFIED: restic design doc]

**NOTE: Chunk-level dedup** — restic uses CDC (Content Defined Chunking) with Rabin Fingerprints to deduplicate sub-file regions. This is appropriate for backup; for a download manager where each file is an atomic unit, whole-file hashing is correct for v1. [VERIFIED: restic design doc]

### Subresource Integrity (SRI)

**STEAL: `sha256-<base64>` prefix syntax** — SRI (W3C spec) uses `sha256-<base64url>` as the integrity attribute value. Multiple algorithm prefixes (`sha256`, `sha384`, `sha512`) are allowed; the UA picks the strongest one. The dash separator (not colon) is a minor variation; Go/pip use colon. For `goh`: use `sha256:<hex>` (colon, lowercase hex) to match the Go/pip convention. [VERIFIED: https://www.w3.org/TR/sri-2/, MDN]

**STEAL: Algorithm agility at format level** — both SRI and Go's `h1:` prefix show the same lesson: the hash algorithm must be part of the string, not an implicit constant in the parser. When SHA-256 is eventually superseded, the format must not change. [VERIFIED: SRI spec, Go sumdb]

### IPFS / Multihash / CIDs

**STEAL: TLV multihash encoding for algorithm agility** — IPFS CIDs encode the hash algorithm as a type prefix (varint), then the hash length, then the hash value. This is more compact than a text prefix but less human-readable. For `goh`: the text prefix (`sha256:`) is the right tradeoff for a human-readable TOML lockfile. The underlying lesson — algorithm is self-describing — still applies. [VERIFIED: https://github.com/multiformats/cid, IPFS docs]

**AVOID: CIDv0 (implicit SHA-256 with no label)** — the original IPFS CIDv0 had no algorithm prefix and assumed SHA-256. When the algorithm needed to change, a new CID version was required. This is the concrete cost of not embedding the algorithm label. [VERIFIED: IPFS docs]

### Git LFS

**STEAL: `sha256:<hex>` pointer format** — Git LFS pointer files use `oid sha256:<40-char-hex>` to identify the stored object. This is the most direct precedent for `gohfile.lock`'s hash format: plain text, colon separator, lowercase hex. [SINGLE: Git LFS pointer spec documentation]

---

## Area 3 — Trust-On-First-Use Systems

### SSH `known_hosts`

**AVOID: Presenting TOFU violation as a security alarm with no actionable resolution** — when an SSH host key changes, OpenSSH prints a large "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!" block. Users, not understanding whether this is an attack or a legitimate rotation, frequently disable `StrictHostKeyChecking` entirely. This is the TOFU footgun: the violation message triggers worse security behavior than the original vulnerability. [VERIFIED: https://www.agwa.name/blog/post/why_tofu_doesnt_work]

**STEAL: Actionable hash mismatch output** — the correct pattern (Go does this better than SSH) is to print: (1) what was expected, (2) what was found, (3) the exact command to update if intentional, (4) a pointer to docs explaining the security model. Never just say "ATTACK!" [SINGLE: Go community practice]

**AVOID: TOFU over a network path you don't control** — first-use hash recording is only trustworthy if the first download is authenticated. For `goh`: if the user provides a `sha256:` in the manifest, TOFU is irrelevant — verify strictly. If no hash is provided, record on first download and warn the user that they accepted an unverified artifact. [VERIFIED: Wikipedia TOFU article, agwa.name]

### Go Module Checksum DB + GONOSUMDB

**STEAL: Centralized transparency log as optional backstop** — Go's sum.golang.org is a merkle-tree ledger of all module version hashes. If the downloaded hash doesn't match the ledger, the build fails. For `goh` v1: no centralized DB, but the lesson is: make the escape hatch (`--no-verify`) explicit and loud, not a quiet flag. [VERIFIED: Go sumdb design doc]

**STEAL: `GONOSUMDB` prefix list for escape hatches** — rather than a global "skip all verification" toggle, Go allows per-prefix exclusion. This means private/internal URLs can bypass the public DB without disabling verification for everything else. For `goh`: per-entry `verify = false` in the manifest is the right design, not a global flag. [VERIFIED: Go docs]

### Terraform Provider Lock TOFU

**STEAL: Record ALL hash schemes on first install** — Terraform pre-populates both `h1:` and `zh:` hashes on first `terraform init`, so future runs have two independent checks. For `goh`: record the hash on first download; if the user supplied a hash in the manifest, verify against it; if not, record it and emit a "first-use recorded" log line (not a warning). [VERIFIED: Terraform docs]

**STEAL: `terraform providers lock` explicit re-hash command** — when a user needs to legitimately update a hash (e.g., upstream file republished), Terraform provides an explicit command that downloads fresh and records new hashes. For `goh`: `goh lock --update <path>` is the intentional upgrade path; it must never happen silently. [VERIFIED: Terraform docs]

---

## Area 4 — Reproducible Dataset / Asset Tooling

### DVC (`.dvc` files + `dvc.lock`)

**STEAL: Separate `.dvc` stub (manifest) from `dvc.lock` (resolved state)** — DVC uses a `.dvc` file as a human-edited stub pointing to a remote URL/path, and `dvc.lock` records the resolved content hash. This is the closest existing analogue to `gohfile.toml` + `gohfile.lock`. [VERIFIED: https://doc.dvc.org/user-guide/project-structure/dvc-files]

**AVOID: Mixed algorithm use across entries** — DVC uses `md5` for local/SSH, `etag` for HTTP/S3/Azure, `checksum` for HDFS. This means verification logic must branch per algorithm. For `goh`: SHA-256 of the whole downloaded file, regardless of transport, every time. Uniform algorithm, no branching. [VERIFIED: DVC docs]

**AVOID: ETag as a hash** — HTTP ETags are server-assigned opaque strings, not content hashes. A server can change an ETag without changing the file, or change the file without changing the ETag. DVC uses ETags as a proxy for change detection, not integrity verification. `goh` must always hash the bytes, not trust ETag. [VERIFIED: DVC docs, HTTP spec]

**STEAL: `--no-download` for hash-only update** — DVC's `--no-download` flag updates checksums in the `.dvc` file without re-fetching the data. For `goh`: `goh verify --check-only` (no re-download; compare on-disk file to lock) is the DVC analog. [VERIFIED: DVC docs]

### git-annex / DataLad

**STEAL: Content-hash as the canonical identifier** — git-annex uses the hash of the file content as its internal key; symlinks point to `.git/annex/objects/<hash>`. The filename in the working tree is separate from the content identity. For `goh`: the lock entry's hash field is the identity, not the filename or URL. [VERIFIED: DataLad handbook, git-annex docs]

**AVOID: Git-as-transport for large binary blobs** — git-annex requires Git familiarity and a functioning Git repo. DataLad inherits this complexity. Dataset practitioners routinely cite the steep learning curve as their primary frustration. For `goh`: a flat TOML file with no Git dependency is the right surface. [SINGLE: DataLad handbook FAQ, researcher feedback]

**AVOID: Partial fetch without resume tracking** — git-annex can fetch individual files but does not natively record partial download state in the manifest. If a download is interrupted, the user must re-discover which files are incomplete. For `goh sync`: track download state (pending / downloading / complete / failed) per entry in the run log, not in the lockfile itself. [SINGLE: git-annex issue tracker, community reports]

### aria2 + Metalink (RFC 5854)

**STEAL: Chunk-level checksums for large files** — Metalink4 supports per-chunk SHA-256 alongside a whole-file SHA-256. aria2 uses chunk hashes to validate in-flight segments and re-download only damaged chunks. For `goh` v1: whole-file hash only; reserve a `chunks:` field in the lock entry for future chunk verification. [VERIFIED: https://aria2.github.io/manual/en/html/aria2c.html]

**STEAL: Multiple hash algorithms per file in Metalink** — Metalink allows listing `md5`, `sha-1`, `sha-256`, `sha-512` for the same file; the downloader picks the strongest. For `goh`: if the manifest includes a hash, it is the authoritative value; goh stores it verbatim in the lock (with the `sha256:` prefix) and does not re-hash to a different algorithm. [VERIFIED: aria2 docs]

**STEAL: `.aria2` control file for resume** — aria2 writes a sidecar control file (`<filename>.aria2`) that records download progress so interrupted downloads can resume. For `goh`: a `.goh/state/<hash>.json` sidecar per in-progress download provides the same resume capability without polluting the lockfile. [VERIFIED: aria2 docs]

---

## Top 5 Format / Behavior Decisions Implied by This Research

1. **Use `sha256:<lowercase-hex>` hash format** — colon separator, algorithm prefix baked in, lowercase hex encoding. Matches Git LFS pointer format and Go/pip convention. Enables future `sha512:` substitution without format version bump. [VERIFIED: Git LFS, pip, Go sumdb, SRI]

2. **Store a `lockfileVersion = 1` integer as the first field in `gohfile.lock`** — plain integer, incremented only on schema-breaking changes (not on tool version changes). Reject future unknown values with a clear error message. [VERIFIED: npm lockfileVersion, Cargo ResolveVersion, Nesbitt 2026]

3. **Include a manifest hash in the lockfile (`manifestHash = "sha256:<hex>"`)** — hash of `gohfile.toml` at lock-generation time. On every `goh sync`, verify this hash matches the current manifest before trusting the lock. If it differs, the lock is stale and must be regenerated. [SINGLE: derived from npm hidden lockfile + Cargo stale-lock patterns]

4. **Each lock entry must be fully self-contained** — `[[file]]` entry must include `url`, `sha256`, `size`, `downloadedAt`, and `path`; no field may require reading the manifest to resolve. [VERIFIED: Cargo book, Nesbitt 2026]

5. **TOFU hash recording must be explicit and logged; mismatch output must be actionable** — on first download without a manifest-supplied hash: record hash to lock and emit `info: recorded sha256:<hash> for <path> (first use, unverified)`. On mismatch: print expected hash, actual hash, and the exact command (`goh lock --update <path>`) to intentionally accept a new hash. Never silently accept a changed hash; never print a panic-inducing security alarm with no recovery path. [VERIFIED: Go mismatch error, Terraform TOFU docs, agwa.name SSH TOFU analysis]

---

## Sources (Primary)

- npm lockfile docs: https://docs.npmjs.com/cli/v11/configuring-npm/package-lock-json/
- Cargo guide: https://doc.rust-lang.org/cargo/guide/cargo-toml-vs-cargo-lock.html
- Nesbitt lockfile tradeoffs: https://nesbitt.io/2026/01/17/lockfile-format-design-and-tradeoffs.html
- Go sumdb proposal: https://go.googlesource.com/proposal/+/master/design/25530-sumdb.md
- Go dirhash (h1: format): https://pkg.go.dev/golang.org/x/mod/sumdb/dirhash
- Terraform lock file: https://developer.hashicorp.com/terraform/language/files/dependency-lock
- restic design: https://restic.readthedocs.io/en/stable/design.html
- SRI W3C spec: https://www.w3.org/TR/sri-2/
- IPFS CID / multihash: https://github.com/multiformats/cid
- pip secure installs: https://pip.pypa.io/en/stable/topics/secure-installs/
- DVC .dvc files: https://doc.dvc.org/user-guide/project-structure/dvc-files
- aria2 Metalink: https://aria2.github.io/manual/en/html/aria2c.html
- SSH TOFU critique: https://www.agwa.name/blog/post/why_tofu_doesnt_work
- Wikipedia TOFU: https://en.wikipedia.org/wiki/Trust_on_first_use
