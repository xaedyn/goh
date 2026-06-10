---
date: 2026-06-09
feature: daemon-upgrade-self-heal
type: design-spec
status: draft — pending adversarial-spec-review + user approval
---

# Design — Self-Healing Daemon Upgrade (version-skew aware)

## 1. Problem

After an upgrade, the on-disk binaries (`goh`, `gohd`, `goh-menu`) are new but the **running
`gohd` is still the old build** until it restarts. A `.pkg`/`brew` upgrade replaces the file
but does NOT restart the daemon. Result: a new client talks to an old daemon and **silently
loses new behavior** (the backfill-on-verify bug — old daemon dropped the new baseline
fields). Worse, an old daemon writing the ledger can strip new additive-optional fields on
round-trip. The user has no signal and no easy fix beyond a manual `launchctl kickstart -k`.

## 2. The launchd constraint that shapes the design

`Resources/dev.goh.daemon.plist`: `KeepAlive = { SuccessfulExit: false }` (restart only on a
NON-zero exit), `RunAtLoad: true`, `MachServices: { dev.goh.daemon }`. So:
- A clean `exit(0)` (the daemon's SIGTERM path) is **NOT relaunched** by launchd — by design,
  so `brew services stop` can actually stop it. Flipping to `KeepAlive: true` would break stop.
- Therefore the daemon **cannot self-restart by cleanly exiting.** The restart must be driven
  externally (`launchctl kickstart -k`, which force-restarts regardless of KeepAlive).

Conclusion: **clients drive the restart** (CLI + tray), idle-gated for safety. The daemon
barely changes — it only *reports* a feature level. No risky daemon-lifecycle code.

## 3. The model

- **`featureLevel: Int`** — a monotonic integer (in GohCore, shared by client + daemon),
  bumped each release that adds **daemon behavior a client depends on** (distinct from the
  frozen wire `protocolVersion`; e.g. backfill-baseline-writing = featureLevel 1). The daemon
  reports its built-in `featureLevel`; the client compares it to its own.
- **One round-trip tells the client everything:** `goh doctor` already sends `.ls`; the
  `LsReply` additively carries `featureLevel` AND the reply's `jobs` reveal active-download
  state. So a single `.ls` answers "stale daemon?" and "idle?" together.
- **Idle-gated restart:** stale + idle (no `.active` jobs) → the client transparently
  `kickstart -k`s the daemon, waits for the new one, proceeds. Stale + busy → proceed against
  the old daemon + a one-line notice (never interrupt a download).

## 4. Scope

### In scope
1. `GohFeatureLevel.current: Int` constant in GohCore (start at 1). Bumped per release that
   changes client-depended daemon behavior.
2. `LsReply` gains `featureLevel: Int?` (additive-optional, `decodeIfPresent`; `protocolVersion`
   stays 4). The daemon populates it with `GohFeatureLevel.current`.
3. A reusable **skew check + safe-restart** helper (GohCore, pure where possible): given the
   daemon's reported level, the client's level, and the active-job count → decide
   `.current` / `.staleIdle` / `.staleBusy` / `.unknown` (old daemon reports nil → `.unknown`,
   treated like stale-but-can't-confirm-idle → notice only, never auto-restart on nil).
4. **CLI auto-heal:** before a command that needs an up-to-date daemon (at minimum the
   verify/backfill path; ideally any daemon command), the CLI reads `.ls`, and if `.staleIdle`
   it runs `launchctl kickstart -k gui/<uid>/dev.goh.daemon`, waits (bounded poll) for the new
   daemon to answer, then proceeds. `.staleBusy`/`.unknown` → proceed + a one-line stderr
   notice. Never blocks or fails the command on restart trouble (best-effort; fall back to
   proceeding against whatever daemon answers).
5. **`goh daemon restart`** — explicit, safe restart command: idle by default (refuses if
   active downloads, suggesting `--force`); `--force` restarts anyway (documented to interrupt
   in-flight downloads, which resume via checkpoint).
6. **`goh doctor`** reports the daemon `featureLevel` vs the CLI's, flags skew, and prints the
   safe restart instruction.
7. **Tray:** surfaces the same skew (a non-alarming notice in the menu/Trust window: "A newer
   background service is ready — it activates when downloads finish") and offers a Restart
   action that is idle-gated.

### Out of scope (explicit)
- **Daemon self-restart / changing the launchd plist KeepAlive** — rejected (§9): would break
  deliberate stop; clean exit isn't relaunched anyway.
- **`SMAppService` migration of the daemon** — separate, larger effort; the raw LaunchAgent
  stays.
- **Auto-bumping featureLevel** — it's a manual, deliberate release step (like protocolVersion).
- **Forcing a restart when busy** — never automatic; only via explicit `goh daemon restart --force`.

## 5. Success criteria (falsifiable)

- **AC1** The daemon includes `featureLevel == GohFeatureLevel.current` in every `LsReply`;
  an old client ignoring it still decodes the reply (additive-optional; `protocolVersion`
  stays 4).
- **AC2** The skew helper returns `.staleIdle` when reported < current AND active count == 0;
  `.staleBusy` when reported < current AND active > 0; `.current` when reported >= current;
  `.unknown` when reported is nil. (Pure, table-tested.)
- **AC3** `goh daemon restart` with no active downloads restarts the daemon (a follow-up `.ls`
  reports `featureLevel == current` / a fresh daemon); with active downloads and no `--force`
  it refuses with exit code + message and does NOT restart; with `--force` it restarts.
- **AC4** A skewed-but-idle CLI command auto-restarts then proceeds against the new daemon
  (integration-level; may be a seam test on the decision + a stubbed restart).
- **AC5** A skewed-but-busy CLI command does NOT restart, proceeds, and emits the notice; exit
  code is the command's own (the notice never changes it).
- **AC6** `goh doctor` shows the daemon featureLevel, flags skew when present, and prints the
  restart instruction.
- **AC7** Frozen: `protocolVersion` stays 4; `LsReply` change is additive-optional (golden/IPC
  tests for existing replies unchanged); no other wire/contract change.
- **AC8** The ledger is untouched by a restart (restart reloads it; a test/▶ note confirms the
  daemon reload path is the existing one) — no trust-data loss.

## 6. Interface contracts

```swift
// GohCore — the monotonic feature axis (NOT the frozen wire protocolVersion).
public enum GohFeatureLevel { public static let current: Int = 1 }   // 1 = backfill baseline writes

// LsReply (additive-optional; protocolVersion stays 4):
//   public var featureLevel: Int?   // daemon's GohFeatureLevel.current; nil from pre-feature daemons
//   decode with decodeIfPresent; old clients ignore it.

public enum DaemonSkew: Sendable, Equatable { case current, staleIdle, staleBusy, unknown }
public enum DaemonSkewCheck {
    public static func evaluate(reported: Int?, expected: Int, activeDownloadCount: Int) -> DaemonSkew
    // reported == nil → .unknown; reported < expected → (activeDownloadCount==0 ? .staleIdle : .staleBusy);
    // reported >= expected → .current
}
```
- **Restart mechanism:** `launchctl kickstart -k gui/<uid>/dev.goh.daemon` (uid from `getuid()`;
  label `GohXPCService.machServiceName`). Force-restart regardless of KeepAlive. The CLI runs it
  as a subprocess; after it returns, the CLI polls `.ls` (bounded, e.g. ~5s) until the daemon
  answers, then proceeds. All best-effort: on any failure, proceed against whatever daemon answers
  + the notice.
- **Idle source:** active count = `LsReply.jobs.filter { $0.state == .active }.count` (the client
  already has the jobs from the same `.ls`). Daemon-side `goh daemon restart` uses the same.

## 7. Frozen-contract handling
- `protocolVersion` stays 4 (the `LsReply` field is additive-optional). Existing IPC/golden tests
  for `LsReply`/other replies unchanged (AC7).
- No change to `ProvenanceRecord`/`VerifyAllReport`/governor/`JobProgress`.
- The launchd plist is NOT changed (KeepAlive semantics preserved → stop still works).

## 8. Rollout & compatibility
- New client + old daemon (the upgrade window): old daemon's `LsReply.featureLevel` is nil →
  `.unknown` → the client shows the notice and (if the user runs `goh daemon restart` or the
  idle auto-heal fires once the user is on a featureLevel-aware path) the daemon swaps. After the
  first restart, both are new. (Note: a pre-feature daemon reports nil, so the FIRST upgrade to
  this feature can't auto-confirm idle from featureLevel alone — it still has the jobs list, so
  idle detection works; `.unknown` means "can't confirm the daemon understands featureLevel," so
  auto-restart is gated to `.staleIdle` only, i.e. once daemons report a level. For the very first
  rollout, `goh doctor`/the notice guides a manual `goh daemon restart`.)
- Old client + new daemon: client ignores the new `LsReply` field; no effect.
- Restart never touches the ledger (reloaded from disk) — no trust-data loss (AC8).
- Rollback: removing the feature leaves an ignored additive field; no migration.

## 9. Security & privacy
- **No new attack surface from reporting featureLevel** (it's a constant in a reply the client
  already receives). `kickstart` targets the user's own per-user launchd domain (`gui/<uid>`);
  no privilege escalation, no sudo.
- **Restart safety:** idle-gated by default; trust ledger persists (atomic on-disk file reloaded
  on launch). `--force` is opt-in and documented to interrupt (resumable) downloads.
- **Honest skew signaling** replaces silent feature loss — the security-relevant win (a stale
  daemon that silently drops trust-baseline writes is now surfaced, and the old-daemon-strips-
  fields hazard window is minimized + visible).

## 10. Considered alternatives
- **Daemon self-restarts when idle (exit + launchd relaunch)** — REJECTED: `KeepAlive
  = SuccessfulExit:false` means a clean exit is NOT relaunched; using `exit(1)` to force relaunch
  abuses crash semantics (throttled ~10s, pollutes logs) and risks an unstoppable restart loop.
  Client-driven `kickstart -k` is cleaner and keeps lifecycle code out of the daemon.
- **`KeepAlive: true`** — REJECTED: breaks `brew services stop` (daemon would relaunch on every
  deliberate stop).
- **Installer postinstall restart** — REJECTED as the primary: blunt, can interrupt active
  downloads, and the `.pkg` is verified to have NO postinstall scripts; also doesn't fix the
  old-daemon-strips-fields hazard for non-installer paths. The client-driven idle-gated restart
  covers all entry points.
- **`SMAppService` daemon** — deferred: larger migration; not needed for this.
- **Auto-bump featureLevel from git/build** — rejected: a deliberate per-release bump (like
  protocolVersion) is clearer about when skew actually matters.
```
