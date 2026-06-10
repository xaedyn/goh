---
date: 2026-06-09
feature: daemon-upgrade-self-heal
type: design-spec
status: draft — round 2 (round-1 adversarial-spec-review block issues addressed)
---

# Design — Self-Healing Daemon Upgrade (version-skew aware)

## 1. Problem

After an upgrade, the on-disk binaries are new but the **running `gohd` is still the old
build** until it restarts. A `.pkg`/`brew` upgrade replaces the file but does NOT restart the
daemon. A new client then talks to an old daemon and **silently loses new behavior** (the
backfill-on-verify bug — old daemon dropped the new baseline fields), and an old daemon
writing the ledger can strip new additive-optional fields on round-trip. The wire
`protocolVersion` doesn't catch this (additive changes don't bump it). The user gets no signal
and no easy fix beyond a manual `launchctl kickstart -k`.

## 2. The launchd constraint that shapes the design

`Resources/dev.goh.daemon.plist`: `KeepAlive = { SuccessfulExit: false }` (relaunch on NON-zero
exit only), `RunAtLoad: true`, `MachServices: { dev.goh.daemon }`. So a clean `exit(0)` is NOT
relaunched (by design, so `brew services stop` works) — **the daemon cannot self-restart by
exiting**, and `KeepAlive: true` would break stop. Therefore the **client drives the restart**
via `launchctl kickstart -k gui/<uid>/dev.goh.daemon` (force-restart, bypasses KeepAlive),
idle-gated. The daemon barely changes — it only *reports* a feature level. Existing recovery (and its limit):
on startup the daemon runs `reconcileActiveJobsOnStartup`, which **resumes a job that was
`.active` ONLY if a safe checkpoint already exists** (checkpoints are written every 1 MiB, with a
strong validator) — re-queued at the checkpointed offset and re-scheduled. A job with **no usable
checkpoint** (e.g. a download that just started) is marked **`.failed` (retry-eligible)**, not
resumed: its un-checkpointed in-progress bytes are discarded and it awaits a manual `goh retry`.
This conditional behavior is load-bearing for §9 FM2 — the design must not over-promise "no lost
work."

## 3. The model

- **`featureLevel: Int`** — a monotonic integer (GohCore, shared by client + daemon), bumped per
  release that adds **daemon behavior a client depends on** (distinct from frozen
  `protocolVersion`; featureLevel 1 = "daemon writes stat baselines on recordVerified"). The
  daemon reports its built-in level; the client compares to its own.
- **`nil` reported == stale.** A pre-feature daemon omits the field → `nil`, which means "older
  than featureLevel 1" → **treated as stale** (NOT "unknown/do-nothing"). This is what makes the
  *first* upgrade self-heal. (`nil` can only come from an OLDER daemon; a newer daemon always
  reports a level. Old-client + new-daemon is the reverse and reads `.current` — no false skew.)
- **One round-trip tells the client everything:** the client sends `.ls` (as `goh doctor`
  already does); the `LsReply` additively carries `featureLevel`, and its `jobs` reveal the
  active-download count. So one `.ls` answers "stale?" and "idle?" together.
- **Idle-gated restart:** stale + idle → the client re-checks idle and `kickstart -k`s the
  daemon, polls for the new one, proceeds. Stale + busy → proceed against the old daemon + a
  one-line notice (no automatic restart while downloads run).

## 4. Scope

### In scope
1. `GohFeatureLevel.current: Int = 1` (GohCore). Bumped deliberately per release that changes
   client-depended daemon behavior (a documented release step, like protocolVersion).
2. `LsReply` gains `featureLevel: Int?` (additive-optional, `decodeIfPresent`; `protocolVersion`
   stays 4). The daemon sets it to `GohFeatureLevel.current`.
3. Pure skew classifier: `DaemonSkewCheck.evaluate(reported: Int?, expected: Int,
   activeDownloadCount: Int) -> DaemonSkew` →
   - `reported == nil` OR `reported < expected` → `activeDownloadCount == 0 ? .staleIdle : .staleBusy`
   - `reported >= expected` → `.current`
4. **CLI auto-heal**, scoped to the commands where skew causes silent data loss — **`verify
   --all` (backfill), `verify --quick`, and `doctor`** (NOT every verb — avoids a blanket extra
   round-trip): the client reads `.ls`, classifies, and:
   - `.staleIdle` → **re-read `.ls` to reconfirm 0 active** (tighten the TOCTOU window), then
     `launchctl kickstart -k gui/<uid>/dev.goh.daemon`, then **poll `.ls` (bounded ~5s) until the
     reply reports `featureLevel >= current`** (the NEW daemon); then proceed. If still stale or
     unreachable after the timeout → emit the notice and proceed against whatever answers
     (best-effort; the command never fails because of restart trouble).
   - `.staleBusy` → proceed + one-line stderr notice (no restart).
   - kickstart unavailable / non-launchd / `launchctl` non-zero → emit notice, proceed
     (degrade to notice-only; the command still succeeds, exit code unchanged).
5. **`goh daemon restart`** — a new top-level verb `daemon` with subcommand `restart` and an
   optional `--force` flag (grammar/help in §6). Idle by default: refuses with a clear message +
   a fixed non-zero exit code (64-class usage refusal) when downloads are active and `--force`
   is absent; `--force` restarts regardless (documented: interrupts in-flight downloads — a
   download with an existing checkpoint resumes from it on startup; one without (e.g. just
   started) is marked failed-retryable and its un-checkpointed bytes are lost, needing `goh
   retry`).
6. **`goh doctor`** reports the daemon's `featureLevel` vs the CLI's, flags skew, prints the safe
   restart instruction.
7. **Tray:** surfaces the same skew (a neutral notice: "A newer background service is ready — it
   activates when downloads finish") with an idle-gated Restart action; never alarming.

### Out of scope (explicit)
- **Daemon self-restart / plist `KeepAlive` change / `SMAppService` migration** — §10.
- **Auto-bumping featureLevel** — deliberate per-release step.
- **Automatic restart while downloads are active** — only `goh daemon restart --force` interrupts
  (and even then the startup reconciliation resumes).

## 5. Success criteria (falsifiable)

- **AC1** The daemon includes `featureLevel == GohFeatureLevel.current` in every `LsReply`; an
  old client ignoring it still decodes the reply (additive-optional; `protocolVersion` stays 4).
- **AC2** `DaemonSkewCheck.evaluate` table: `(nil, 1, 0) → .staleIdle`; `(nil, 1, 2) → .staleBusy`;
  `(0, 1, 0) → .staleIdle`; `(1, 1, 0) → .current`; `(2, 1, 0) → .current` (old client/new daemon).
  Pure, no I/O.
- **AC3** `goh daemon restart` with 0 active downloads restarts the daemon (a follow-up `.ls`
  reports `featureLevel == current` from a fresh daemon); with active downloads and no `--force`
  it refuses (fixed non-zero exit, message, daemon NOT restarted); with `--force` it restarts.
- **AC4** (integration/▶-tier) After installing a newer daemon binary, an idle auto-heal command
  triggers a kickstart and the follow-up `.ls` reports the new `featureLevel` — i.e. the real
  restart swaps the binary (not just a stubbed seam). A unit-tier seam test covers the
  decision→action wiring with an injected restarter.
- **AC5** A `.staleBusy` command does NOT restart, proceeds, emits the notice; its exit code is
  the command's own (notice never changes it).
- **AC6** `goh doctor` shows the daemon featureLevel, flags skew when present, prints the restart
  instruction.
- **AC7** kickstart-unavailable (injected failing restarter) → the auto-heal command degrades to
  notice-only, still succeeds, exit code unchanged.
- **AC8** Reconcile behavior is asserted for BOTH branches: a download `.active` across a restart
  **with a safe checkpoint** is re-queued at the checkpoint offset AND re-scheduled on daemon
  startup (the end-to-end re-schedule, beyond the existing `JobStoreStartupReconciliationTests`
  unit branches); a download `.active` **without a usable checkpoint** is marked `.failed`
  (retry-eligible), surfaced (logged), NOT silently lost. The auto-heal invariant is therefore:
  *idle-gated + re-checked, so it doesn't hit an active download in steady state; in the rare
  race a caught download either resumes (if checkpointed) or is left failed-retryable and
  surfaced — never silently dropped.*
- **AC9** Frozen: `protocolVersion` stays 4; the `LsReply` change is additive-optional (existing
  IPC/reply-decoder/golden tests unchanged); no other wire/contract change; the ledger is
  byte-identical across a restart (assert post-restart read == pre-restart).

## 6. Interface contracts

```swift
public enum GohFeatureLevel { public static let current: Int = 1 }   // 1 = backfill baseline writes
// NOTE: deliberately Int (a fresh feature axis), NOT the wire protocolVersion (UInt32).

// LsReply (additive-optional; protocolVersion stays 4):
//   public var featureLevel: Int?    // daemon's GohFeatureLevel.current; nil from pre-feature daemons
//   encode always; decode with decodeIfPresent. Old clients ignore it.

public enum DaemonSkew: Sendable, Equatable { case current, staleIdle, staleBusy }
public enum DaemonSkewCheck {
    public static func evaluate(reported: Int?, expected: Int, activeDownloadCount: Int) -> DaemonSkew
}
// Restart seam (injectable for tests): a `DaemonRestarting` protocol with a live impl that runs
//   `launchctl kickstart -k gui/<uid>/dev.goh.daemon` (uid = getuid(); label =
//   GohXPCService.machServiceName) as a subprocess and returns success/failure. Tests inject a
//   stub (success / failure / records calls).
```
- **CLI grammar:** `goh daemon restart [--force]`. New `daemon` verb parsed in `GohCommandLine.parse`;
  unknown `daemon` subcommands → usage error (exit 64). `goh daemon restart` help line added.
- **Poll-after-kickstart:** loop `.ls` with a pinned budget — **5.0s total, 250ms interval**;
  success = reply `featureLevel >= current`; on timeout → notice + proceed. If the OLD daemon
  answers mid-poll (nil or < current), keep polling until new-or-timeout (don't accept stale).
  (`kickstart -k` is immediate — launchd's crash-relaunch throttle does NOT apply to it — so 5s
  comfortably covers re-exec latency.)
- **Idle source:** `LsReply.jobs.filter { $0.state == .active }.count`. `.queued` does NOT block:
  a queued job killed by a restart simply re-queues (it never started) — and `reconcileActiveJobsOnStartup`
  re-admits it. Only `.active` (a live transfer) is the thing worth avoiding, and §9/AC8 cover the
  rare race.

## 7. Frozen-contract handling
- `protocolVersion` stays 4 (the `LsReply` field is additive-optional; existing reply-decoder /
  golden / IPC tests unchanged — AC9).
- No change to `ProvenanceRecord` / `VerifyAllReport` / governor / `JobProgress`.
- The launchd plist is NOT changed (KeepAlive semantics preserved → `brew services stop` works).

## 8. Rollout & compatibility
- **First upgrade to this feature** (the case that matters): the running old daemon omits
  `featureLevel` → `nil` → `.staleIdle`/`.staleBusy`. When idle, the next scoped command
  (`verify`/`doctor`) auto-restarts it → the new daemon now reports level 1. When busy, the notice
  guides the user (or `goh daemon restart`). So self-heal works from the first upgrade (FM1 fixed).
- New client + old daemon: handled as above. Old client + new daemon: client ignores the new
  field; daemon reports a level the old client never reads — no effect.
- A restart never touches the ledger (reloaded from disk) — no trust-data loss. Active downloads:
  a checkpointed one resumes on startup; an un-checkpointed (just-started) one is left
  failed-retryable and surfaced (not silently lost). The idle gate + pre-kickstart re-check make
  hitting an active download a rare sub-second race, not the steady-state path. Brew and pkg
  installs both load the LaunchAgent into `gui/<uid>`, so the kickstart label is identical across
  install methods.
- Rollback: removing the feature leaves an ignored additive field; no migration.

## 9. Security & privacy
- featureLevel reporting adds no attack surface (a constant in an already-received reply).
  `kickstart` targets the user's own `gui/<uid>` launchd domain — no sudo, no escalation.
- **FM2 (idle/restart race), bounded honestly:** auto-restart is idle-gated with a re-check
  immediately before kickstart, so in steady state it never targets an active download. If a
  download nonetheless starts in that sub-second window and is killed by the restart, the new
  daemon's `reconcileActiveJobsOnStartup` **resumes it IF it had already written a checkpoint**
  (≥1 MiB in); a just-started download with no checkpoint is instead marked **failed-retryable
  and surfaced** (logged; `goh retry` resumes it) — its un-checkpointed bytes are lost, but the
  job is never silently dropped. Honest invariant: *auto-restart doesn't interrupt downloads in
  steady state; a transfer caught in the rare race is resumed-if-checkpointed, else
  failed-retryable-and-surfaced — never silent loss.* `--force` interrupts deliberately with the
  same semantics. This residual is acceptable because it's rare (idle-gated + re-checked),
  recoverable, and visible — not a silent data loss.
- Honest skew signaling replaces silent feature loss (the security-relevant win: a stale daemon
  silently dropping trust-baseline writes is now surfaced and auto-corrected when idle).

## 10. Considered alternatives
- **Daemon self-restarts by exiting** — REJECTED: `KeepAlive=SuccessfulExit:false` won't relaunch
  a clean exit; `exit(1)` to force relaunch abuses crash semantics (throttle, log noise, loop risk).
- **`KeepAlive: true`** — REJECTED: breaks `brew services stop`.
- **Installer postinstall restart** — REJECTED as primary: blunt, can interrupt downloads, the
  `.pkg` is verified to have NO postinstall, and it misses non-installer paths. Client-driven
  idle-gated restart covers every entry point.
- **`.unknown` "do nothing" on nil** — REJECTED (round-1 FM1): nil means older-than-level-1 =
  stale; doing nothing leaves the first upgrade permanently un-healed.
- **Auto-heal on every CLI verb** — REJECTED: needless per-command round-trip; scoped to the
  commands where skew causes silent data loss (§4.4).
- **Checkpoint-on-pause before a forced restart** (to shrink the un-checkpointed-bytes loss
  window for `--force` / the rare race) — DEFERRED as a future option, not built here (YAGNI): the
  residual is rare, recoverable, and surfaced; a pause-and-flush handshake before kickstart is a
  separate enhancement if it ever proves necessary.
```
