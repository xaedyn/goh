---
date: 2026-06-04
feature: provenance-everywhere
type: pipeline-retrospective
---

# Pipeline Retrospective — Provenance-everywhere (verify-only)

## Adversarial Review Categories That Fired

### Spec Review (2 rounds, 6 block issues total — all fixed)
- **Round 1 — Product Validity / Interface Contracts:** destinationPath
  normalization undefined; spec mis-stated the lookup key as "the target URL" →
  silent-miss risk. Fixed: single canonicalization
  (`URL(fileURLWithPath:).standardizedFileURL.path`) applied identically at
  write + read.
- **Round 1 — Completeness / Interface Contracts:** `goh verify --all` flag/verb
  wiring unspecified, conflicted with frozen `verify` parse shape. Fixed:
  distinct `verifyAll` case + separate runner; frozen `verify` untouched.
- **Round 1 — Interface Contracts:** CLI store-path resolver asserted with no
  signature/home. Fixed: `ProvenanceStoreLocation` in `GohCore`, factored from
  the daemon's `supportDirectoryURL()`.
- **Round 2 — Testability/Interface:** required `provenanceStorePath` param would
  break 8 existing `which` tests + contradict the "no tests edited" claim. Fixed:
  defaulted `provenanceStorePath: String? = nil`.
- **Round 2 — Error Handling:** "move corrupt store to sidecar" contradicted the
  mandated carbon-copy of `HostProfileStore` (which *copies*). Fixed: copy
  semantics everywhere; original remains until next `record()`.
- **Round 2 — Lifecycle:** factoring `supportDirectoryURL()` dropped the
  `dev.goh.daemon` directory creation (clean-install regression). Fixed: hard
  dir-creation requirement (daemon `create:true`, CLI `create:false`) + first-run
  test.

### Plan Review (2 rounds, 4 block issues total — all fixed)
- **Round 1 — Test Coverage:** `verify --all` parse tests resolved the *real*
  provenance store path → would re-hash the user's real files. Fixed: injectable
  `provenanceStorePathResolver` seam; tests inject temp paths.
- **Round 1 — Unstated Invariants:** a frozen-`verify` test coupled to process
  cwd. Fixed (then re-fixed — see round 2).
- **Round 1 — Code Correctness:** `lookupInLedger` re-implemented path compare
  inline, diverging from the tested `ProvenanceStore.lookup`. Fixed: routed
  through `lookup` (added `loadReadOnly`).
- **Round 2 — Concurrency/test-parallelism:** the round-1 cwd fix introduced a
  process-global `chdir` racing other non-serialized CLI suites → flaky CI.
  Fixed: removed the cwd dependency entirely (explicit absolute lockfile-path
  argument); documented that per-suite `.serialized` would NOT fix a cross-suite
  race.

## Approach Selected

**Chosen:** Approach A — The Native Ledger (a 4th daemon plist store mirroring
`HostProfileStore`).
**THE BET:** Personal-scale download counts never reach the point where an O(n)
full-plist rewrite per completion becomes user-perceptible.
**Rejected approaches:** B — Global Auto-Lock (reuse `gohfile.lock` format; welds
the auto-record to a *frozen* contract, fails AC4, heavier hot-path cost, "looks
committable but isn't" foot-gun). C — append-log (YAGNI at personal scale; folded
in as A's documented escape hatch). D — SQLite-WAL (new dependency justified only
by unneeded scaling headroom; fails the deps-need-justification rule).

## Design Validation Changes (Step 4B)

Three gaps found and folded into the design before spec writing: (1) recording
must be best-effort/non-fatal so a store error never fails a good download; (2)
the resume completion path must record too (it discarded the digest); (3) the CLI
reads the store file directly (read-only, 0600, same-user) — no new XPC surface,
and verify works with the daemon down.

## Open Risks Not Resolved

- **THE BET is unproven at extreme scale** — O(n) plist rewrite per download is
  fine at thousands–tens-of-thousands; the append-log escape hatch behind the same
  `record`/`verifyAll` interface is the documented mitigation if it ever fails.
- **Round-2 fixes (both spec and plan) were not independently re-reviewed** — the
  2-round adversarial cap was reached each time; the user accepted the mechanical
  fixes at the gate. The per-task `swift test` + two-stage review gates in
  `subagent-driven-development` are the real verification net.
- **Relative `--destination` downloads are unindexable by `goh which`** (daemon
  cwd vs shell cwd) — accepted v0.1 boundary, documented; realistic path is
  absolute/default destinations.
- **Binary-plist bit-stability across SDK 26.2 (CI) vs 26.5 (local)** — mitigated
  by the decode→re-encode→decode value-equality golden round-trip (not raw bytes),
  matching the existing `host-scheduling-v1.plist` pattern.
