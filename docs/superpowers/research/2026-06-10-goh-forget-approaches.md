---
date: 2026-06-10
feature: goh-forget
type: approach-decision-memos
---

# Approach Decision Memos — goh forget

Both approaches share the same skeleton (settled by codebase precedent, not a live choice):

- `forget <path>` (explicit, single) → **immediate, no prompt** — the named path *is* the
  confirmation (git-rm model). Works on any tracked path; a path with no ledger entry is a
  clear non-zero "not tracked" error (AC3).
- New `Command.forgetProvenance(request:)` + `ProvenanceStore.forget(paths:)` mirroring the
  `recordVerifiedProvenance` end-to-end path; canonicalization in the daemon. (Reply: spec
  review later replaced the original `.ack` with a count-bearing `ForgetProvenanceReply{forgotCount}`
  so the CLI can detect a zero/short removal — see the spec and `CommandReply.swift`.)
- `--missing` candidate set = entries whose file is absent via one `lstat` (`LiveFileStatProbe`
  → `.notFound`), never a re-hash.
- `protocolVersion` stays 4; `ProvenanceRecord.currentVersion` stays 1; `GohFeatureLevel` → 2
  so a stale daemon is detected and the CLI errors clearly (or auto-heals) before sending.
- Full surface (CLI + tray) delivered, **plan-segmented into a CLI phase and a tray phase**
  at the deployment-independence boundary.

They differ **only** in the `--missing` bulk safety gate.

---

## APPROACH 1: Preview-and-Confirm

CORE IDEA
`goh forget --missing` is dry-run by default: it prints the candidate list and changes
nothing; deletion happens only when `--confirm` is also passed.

MECHANISM
`forget --missing` reads the ledger (read-only, no daemon needed for the preview), lstat's
each entry, and prints every absent-file entry — annotated with whether its parent volume is
currently mounted, so an unplugged external drive is visible. It exits 0 having deleted
nothing. `forget --missing --confirm` performs the same enumeration and then sends one
`forgetProvenance` request with the absent paths. The tray "Forget" action opens a preview
sheet listing the affected entries with a destructive "Remove" button (the GUI analogue of
the printed candidate list). This mirrors restic/borg's recommended "always dry-run first",
but makes the preview the hard default rather than advice.

FIT ASSESSMENT
Scale fit:       matches — single-user ledger of tens–hundreds of entries; preview is cheap (lstat only).
Team fit:        fits — no new infrastructure; reuses FileStatProbing + the recordVerified wiring.
Operational:     none — no new runtime dependency; preview path needs no daemon.
Stack alignment: fits existing — flag-based, no TTY/readLine code (goh has none today).

TRADEOFFS
Strong at:  safety (impossible to bulk-delete in one keystroke), scriptability
            (`goh forget --missing` to inspect, `--confirm` in automation), and the
            unmounted-drive caveat (the annotated list lets the user notice before `--confirm`).
Sacrifices: two invocations for the common interactive case (inspect, then re-run with --confirm).

WHAT WE'D BUILD
`GohForgetCommand` (CLI runner with `<path>` and `--missing`/`--confirm` modes + volume-mount
annotation); `Command.forgetProvenance` + `ForgetProvenanceRequest{paths}`; `ProvenanceStore.forget(paths:)`;
dispatcher case; `GohMenuClient.forget(paths:)` on 5 conformers; tray preview sheet + Forget action;
2 golden fixtures; featureLevel bump + stale-daemon guard.

THE BET
Users (and scripts) prefer an explicit two-step (`--missing` then `--confirm`) over a one-step
prompt — the safety and script-cleanliness are worth the extra invocation.

REVERSAL COST
Easy — the gate is a flag check in one CLI runner; switching to a prompt later is local.

WHAT WE'RE NOT BUILDING
No interactive TTY prompt; no `readLine`/`isatty` infrastructure; no partial/auto pruning.

INDUSTRY PRECEDENT
restic `forget --dry-run`/`--prune`, borg `prune --dry-run --list` [VERIFIED]. Both are
production backup tools using exactly this preview-first model for "forget".

---

## APPROACH 2: Prompt-to-Proceed

CORE IDEA
`goh forget --missing` prints the candidate list and asks `Remove these N entries? [y/N]`
interactively; `--yes` (or non-TTY stdin) skips the prompt.

MECHANISM
`forget --missing` enumerates absent entries, prints them, and — when stdout is a TTY —
reads a y/N answer from stdin, deleting only on `y`. `--yes` skips the prompt for scripts;
when stdin is not a TTY and `--yes` is absent, it refuses (prints the list, exits non-zero)
rather than blocking. The tray uses a confirmation alert. This is the docker/apt idiom and
introduces goh's first interactive-prompt code path (`isatty` + `readLine`).

FIT ASSESSMENT
Scale fit:       matches — same enumeration cost as A1.
Team fit:        requires new (small) TTY-prompt infrastructure goh has never had; one more
                 thing to keep testable (inject the reader for tests).
Operational:     none at runtime.
Stack alignment: introduces a TTY/stdin-reading pattern; the rest of goh is non-interactive
                 (`daemon restart --force` chose a flag over a prompt — this reverses that precedent).

TRADEOFFS
Strong at:  single-invocation interactive ergonomics (one command, answer y).
Sacrifices: scriptability (must pass `--yes` or pipe yes), a new testable interactive seam,
            and reliability of the unmounted-drive caveat (a prompt doesn't help if the user
            doesn't realize a drive is detached when answering y).

WHAT WE'D BUILD
Everything in A1 EXCEPT the `--confirm` flag, PLUS an injectable `Confirmer`/TTY-reader seam,
`isatty` gating, and `--yes`. Tray uses an alert instead of a preview sheet.

THE BET
Users prefer a one-step interactive prompt over a two-step preview, and the new interactive
code path is worth that ergonomic gain.

REVERSAL COST
Hard-ish — once a prompt seam exists, tests and muscle memory depend on it; removing it later
is more disruptive than removing a flag.

WHAT WE'RE NOT BUILDING
No dry-run-default; no second `--confirm` step.

INDUSTRY PRECEDENT
`docker image prune` ("[y/N]", `-f`), `apt autoremove` ("[Y/n]", `-y`) [VERIFIED].

---

## Comparison Matrix

| Criterion | Approach 1: Preview-and-Confirm | Approach 2: Prompt-to-Proceed |
|---|---|---|
| AC1 (explicit forget removes entry) | STRONG — identical, immediate | STRONG — identical, immediate |
| AC2 (--missing gated, only-absent) | STRONG — dry-run default makes "nothing deleted without --confirm" structural | PARTIAL — gated by a prompt; non-TTY edge needs careful handling to avoid blocking or silent skip |
| AC3 (untracked path → clear error) | STRONG — same in both | STRONG — same in both |
| AC4 (atomic ledger write) | STRONG — reuses `writeAtomically` | STRONG — reuses `writeAtomically` |
| AC5 (tray Forget on MISSING) | STRONG — preview sheet matches macOS HIG | STRONG — alert; slightly less informative than a list sheet |
| Scale fit | STRONG — lstat-only preview | STRONG — same |
| Team fit | STRONG — no new infra | PARTIAL — adds goh's first interactive-prompt seam |
| Operational burden | STRONG — none; preview needs no daemon | STRONG — none at runtime |
| Stack alignment | STRONG — flag-based, matches `--force` precedent | WEAK — reverses goh's non-interactive precedent (`daemon restart --force`) |

**Recommendation: Approach 1 (Preview-and-Confirm).** It's structurally safer for a trust
ledger (no single-keystroke bulk delete), script-clean, adds no new interactive infrastructure,
matches goh's existing flag-over-prompt precedent, and directly serves the unmounted-drive
caveat by letting the user read the annotated candidate list before passing `--confirm`. Its
only real cost — two invocations for the interactive case — is the cost the backup tools
(restic/borg) deliberately chose for exactly this "forget" use case.
