---
date: 2026-06-10
feature: goh-forget
type: pipeline-retrospective
---

# Pipeline Retrospective — goh forget

## Adversarial Review Categories That Fired

### Spec Review (2 rounds → approved)
- **Cat 4 Internal Consistency / Cat 6 Technical Feasibility:** the stale-daemon gate as
  drafted reused `DaemonAutoHeal.runIfNeeded`, which is best-effort, exit-code-neutral, and
  conflates "healed" with "XPC unreachable" — it cannot drive a hard-error decision. Fixed:
  specified an explicit fresh `.ls` → `LsReply.featureLevel` compare (nil/<2 → exit 1, send
  nothing; send-throws → exit 1 unreachable; >=2 proceeds).
- **Cat 4 Internal Consistency:** `--missing --confirm` reported "Forgot N" on a bare `.ack`
  even when zero entries matched (canonicalization/TOCTOU mismatch). Fixed: dedicated
  `ForgetProvenanceReply{forgotCount}` the CLI asserts against the requested count, plus the
  invariant that `--missing` sends stored `destinationPath` strings verbatim (zero-match
  impossible by construction).
- Advisory reconciled: dispatcher returns `.failure(GohError)` on store-write throw (not the
  best-effort `.ack` that `recordVerifiedProvenance` uses), so AC4's "write throw → CLI
  non-zero" actually holds.

### Plan Review (2 rounds → 1 trivial block, fixed)
- **Round 1, Cat 3/10:** Task 3's featureLevel 1→2 bump broke `DaemonFeatureLevelTests.currentIsOne()`
  without staging the test fix into its atomic commit. Fixed.
- **Round 1, Cat 8:** `forget <path>` on a corrupt ledger silently mis-reported "not tracked"
  (exit 1) because `loadReadOnly()` collapses absent/io/corrupt/version-unknown to `false`.
  Fixed: read via `ProvenanceLedgerReader.read` and branch `.unreadable → exit 6`.
- **Round 1, Cat 3/10:** two tasks carried "broken-then-corrected" duplicate test blocks; the
  broken first version would fail under `-warnings-as-errors`. Fixed: deleted the broken blocks.
- **Round 2, Cat 3/10:** `req.request.paths` (×5) — the enum case binds the associated value
  directly, so the member is `req.paths`. Fixed post-review (mechanical, fully specified).

## Approach Selected

**Chosen:** Preview-and-Confirm.
**THE BET:** Users (and scripts) prefer an explicit two-step (`--missing` then `--confirm`)
over a one-step prompt — the safety and script-cleanliness are worth the extra invocation.
**Rejected:** Prompt-to-Proceed ([y/N] + `--yes`) — adds goh's first interactive-prompt
infrastructure, is less script-friendly, reverses the existing flag-over-prompt precedent
(`daemon restart --force`), and a prompt doesn't help the unmounted-drive case.

## Design Validation Changes
Three gaps found and fixed before spec: (1) stale-daemon must error loudly, never silently
"forgot 0" → fresh-`.ls` featureLevel gate + featureLevel 1→2 bump; (2) file-deletion safety
made contractual + tested (forget mutates `entries[]` only, never unlinks a file); (3) TOCTOU
on `--missing` accepted with the mount-annotation mitigation.

## Open Risks Not Resolved
- **TOCTOU on `--missing`:** a file can reappear (drive remounted) between the CLI preview and
  the daemon delete; mitigated by the per-entry mount annotation in the preview, accepted by
  design. The `forgetProvenance` contract is explicit by-path removal.
- **Phase-2 conformer line numbers** in the plan are illustrative; the compile-time break
  across the 5 `GohMenuClient` conformers is the real guard.
