---
date: 2026-06-10
feature: goh-forget
type: research-brief
---

# Research Brief — goh forget

## Industry safety patterns for prune/forget commands

Destructive metadata-pruning CLIs cluster into two idioms:

- **Dangerous-by-default + dry-run valve** — restic `forget` [VERIFIED, restic.readthedocs.io/en/stable/060_forget.html], borg `prune` [VERIFIED, borgbackup.readthedocs.io/en/stable/usage/prune.html], `brew cleanup` [SINGLE], `npm prune` [VERIFIED], `pip cache purge` [VERIFIED]. Execute immediately; the user opts into `--dry-run`/`-n` to preview. Both restic and borg docs **recommend always running `--dry-run --list` first**.
- **Prompt-by-default + force-to-skip** — `docker image prune` ("Are you sure? [y/N]", `-f` to skip) [VERIFIED, docs.docker.com/reference/cli/docker/image/prune/], `apt autoremove` ("[Y/n]", `-y` to skip) [VERIFIED].

The git lesson [VERIFIED, git-scm.com/docs/git-gc]: **explicit removal (`git rm`) and bulk housekeeping (`git gc`) are deliberately separate verbs** — `rm` is user-intent and needs no prompt (naming the target *is* the confirmation); `gc` is maintenance.

**Synthesis for goh** [UNVERIFIED — first-principles from the above]: goh's provenance ledger is trust-proof history, and "missing" may mean "on an unmounted drive" — stakes closer to docker/apt than brew. Mapping to goh:
- `goh forget <path>` (explicit, single) → **immediate, no prompt** (git-rm model; the explicit path is the confirmation). Print one confirmation line.
- `goh forget --missing` (bulk) → **gated**: show the candidate list (ideally annotated with volume-mount status so an unmounted drive is visible), and require an explicit second signal before deleting. Two viable gates: dry-run-default + `--confirm` (restic/borg, script-clean, no new infra) vs interactive `[y/N]` + `--yes` (docker/apt, needs TTY-prompt infra goh does not have). The unmounted-drive caveat weakens interactive prompts (the user may not know a drive is detached when answering).
- **GUI** → a preview sheet listing affected entries before any destructive mutation (macOS HIG destructive-action pattern); single-entry needs only a Cancel/Remove sheet, not a redundant "are you sure".
- **Exit codes** [UNVERIFIED, POSIX]: 0 success / dry-run-with-output; non-zero for path-not-tracked or ledger error.

## Codebase dependency enumeration

**`GohMenuClient` protocol (`Sources/GohMenuBar/GohMenuViewModel.swift:5`) has 5 conformers** — adding `forget(paths:)` breaks all five until implemented:
1. `LiveGohMenuClient` — `Sources/goh-menu/main.swift:11` (production)
2. `FakeMenuClient` — `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift:18`
3. `FakeMenuClient` — `Tests/GohMenuBarTests/GohMenuViewModelTests.swift:350`
4. `LongLivedMenuClient` — `Tests/GohMenuBarTests/GohMenuViewModelTests.swift:453`
5. `SpyMenuClient` — `Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift:9`

**`Command` enum (`Sources/GohCore/Model/Command.swift`, 8 cases):** only `CommandDispatcher.reply(to:)` (`CommandDispatcher.swift:73`) is an exhaustive switch and MUST get the new case; `CommandService.handle()` (`CommandService.swift:70`) uses a `default` and is additive-safe. **Decoding an unknown `Command` case throws `DecodingError` — not graceful** — so an old daemon receiving `forgetProvenance` fails to decode. This is the existing behavior for every case; forward-compat is not free and must be handled (featureLevel skew → clear error / auto-heal before send).

**`recordVerifiedProvenance` is the exact end-to-end template** (5 files): `GohMenuViewModel` → `LiveGohMenuClient` (main.swift) → `CommandService.handle` (default →) → `CommandDispatcher.reply:225` → `ProvenanceStore.recordVerified` → `writeAtomically` → `.ack`.

**`ProvenanceStore` (`Sources/GohCore/Provenance/ProvenanceStore.swift`):** confirmed **no delete path**. `forget(paths:)` mirrors `recordVerified(entries:)` — `inner.withLock`, remove matching entries from `inner.record.entries`, call private `writeAtomically(_:)` (encode → tmp → chmod 0600 → fsync → rename → fsync dir). Entries keyed by canonical `destinationPath` via `URL(fileURLWithPath:).standardizedFileURL.path`; canonicalize in the **daemon** (per the recordVerified precedent).

**`--missing` enumeration:** cheapest absent test is `LiveFileStatProbe().probe(path) == .notFound` — one `lstat(2)`, no hashing (`FileStat.swift`/`FastCheck.swift`). `FastCheckRunner.checkAll(_:probe:)` batches it. Do **not** re-hash via `verify --all`.

**Golden fixtures:** template `envelope-v4-record-verified-provenance-{request,reply}.json` → create `envelope-v4-forget-provenance-{request,reply}.json` (request payload `forgetProvenance` with `paths: [String]`; reply is empty `.ack` payload). Invariants: ISO-8601 UTC, `.sortedKeys`, request UUID echoed in reply.

## Net compiler-breaking surface
5 conformer stubs + 1 exhaustive-switch case + 1 new `ProvenanceStore` method + 2 golden fixtures. `protocolVersion` stays 4 (additive); `ProvenanceRecord.currentVersion` stays 1 (runtime mutation, no schema change); `GohFeatureLevel.current` likely → 2 to gate stale-daemon detection before send.
