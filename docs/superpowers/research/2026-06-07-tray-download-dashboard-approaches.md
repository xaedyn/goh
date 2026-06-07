---
date: 2026-06-07
feature: tray-download-dashboard
type: approach-decision-memos
---

# Approach Decision Memos — Professional Download Dashboard (tray)

Research settled most of the design (shared by both approaches):
- **No-row fix:** give the list real height (minHeight / VStack for small counts) — fixes the popover collapse.
- **Speed:** a **5-second sliding window** (curl's proven convention); ETA = remaining/rolling-rate, hidden
  when size unknown or window coverage <1s.
- **UI:** keep the **popover compact + glanceable** (collapse fixed; top downloads with filename + progress
  bar + speed) and add a **dedicated "Downloads" `Window`** (like Trust/Add-Download) for the full rich
  dashboard: two-line rows (filename + hover actions; determinate `ProgressView` / spinner when size unknown;
  secondary `downloaded/total · rolling-speed · ETA · N connections`), completed/failed retained (already the
  daemon's behavior) with verify/recorded status via the `trustReader` ledger join.

**The only real fork: where the rolling speed is computed.**

---

## APPROACH A — "Engine-true speed, dashboard window"

CORE IDEA
Fix the speed at the source — `DownloadEngine.progress` emits a 5s windowed rate — so the CLI and the tray
are both correct and consistent; build the dashboard on top.

MECHANISM
Add a small per-job rolling-sample buffer in the engine's download loop; `progress()` computes
`bytesPerSecond` from the last 5s of (timestamp, bytesCompleted) samples instead of cumulative/elapsed. The
frozen `bytesPerSecond` wire field is unchanged (only its value). The governor is untouched (it has its own
windowed `ByteCounter` sampler — CCB-confirmed). The menu just renders whatever rate arrives, plus the new
rich rows + dashboard window + ledger join.

FIT ASSESSMENT
Scale fit: matches. Team fit: fits. Operational: none new.
Stack alignment: touches GohCore's hardened download hot path (per-job sample state across single/ranged/
resume + pause/resume) — the most-tested, most-critical file.

TRADEOFFS
Strong at: correct **everywhere** (CLI `ls`/`top` + tray), no divergence, no throwaway calc; ETA correct in
the CLI too.
Sacrifices: engine surgery in the crown-jewel file; must get per-job buffer state right across all download
paths; broader review/test surface.

WHAT WE'D BUILD
A rolling-rate sampler in the engine; the rich row + `Window(id:"downloads")` + presenter enrichment +
ledger join in GohMenuBar.

THE BET
A windowed rate in the engine's hot path is safe (governor independent) and worth the consistency.

REVERSAL COST
Hard-ish — engine change in the download loop; reverting means re-touching that path.

WHAT WE'RE NOT BUILDING
No change to the governor; no per-connection breakdown (that's `goh top`'s schema).

INDUSTRY PRECEDENT
curl/aria2/wget all compute the windowed rate in the transfer engine itself [VERIFIED].

---

## APPROACH B — "Menu-side speed, dashboard window" (recommended)

CORE IDEA
Leave the hardened engine alone; the tray computes its own 5s rolling speed from the snapshot stream, and we
build the full dashboard. (The CLI's average-speed is noted as a separate, later, optional engine fix.)

MECHANISM
`GohMenuViewModel` keeps a small per-job ring of (arrival-timestamp, bytesCompleted) from successive
snapshots (~100ms cadence); a pure helper computes the 5s windowed rate + ETA, which the presenter puts in
rows + the header aggregate. Zero engine/daemon/wire change. Everything else (collapse fix, rich rows,
`Window(id:"downloads")`, ledger join) is GohMenuBar-only.

FIT ASSESSMENT
Scale fit: matches (a handful of jobs × ~50 samples). Team fit: fits. Operational: none new.
Stack alignment: fits — isolated to GohMenuBar; the engine (and its 715+ tests / governor / benchmarks) is
untouched.

TRADEOFFS
Strong at: **zero engine blast radius**; fully unit-testable in GohMenuBar (feed synthetic snapshot
sequences); fastest, lowest-risk path to the user's actual complaint (the tray).
Sacrifices: tray-only — the CLI keeps the cumulative-average speed (tray/CLI divergence) until a separate
engine fix; the rolling helper is superseded if the engine is later corrected.

WHAT WE'D BUILD
A pure `RollingRate` helper + per-job sample state in the viewmodel; the rich row + `Window(id:"downloads")`
+ presenter enrichment + ledger join.

THE BET
A correct tray speed now (engine untouched) is the right trade; CLI consistency can follow later.

REVERSAL COST
Easy — all additive in GohMenuBar; deletable without touching the engine.

WHAT WE'RE NOT BUILDING
No engine/CLI speed change in this slice (noted as a separate follow-up); no governor change.

INDUSTRY PRECEDENT
Front-ends computing a display rate from a status stream is common for thin clients over a daemon
[UNVERIFIED — general pattern].

---

## Comparison matrix

| Criterion | A — Engine-true speed | B — Menu-side speed (rec.) |
|---|---|---|
| AC1 rows visible (collapse fix) | STRONG | STRONG |
| AC2 rolling honest speed | STRONG — everywhere (CLI+tray) | STRONG — in the tray (CLI unchanged) |
| AC3 rich per-download info | STRONG | STRONG |
| AC4 completed stay + verify status | STRONG | STRONG |
| AC5 no contract/governor regression | PARTIAL — engine hot-path change (governor safe, but crown-jewel surgery) | STRONG — zero engine touch |
| Risk / blast radius | higher (engine) | low (GohMenuBar only) |
| Product consistency (tray vs CLI) | STRONG — consistent | PARTIAL — temporary divergence |
| Reversal cost | hard-ish | easy |

## Recommendation
**Approach B — menu-side speed.** It fixes exactly what you saw (the tray's climbing number) with **zero
risk to the hardened engine, governor, and benchmarks**, is fully unit-testable, and ships the full
professional dashboard. The cost — the CLI still shows the old average — is real but minor and cleanly
fixable later as a small, isolated engine change (at which point the tray can just consume the engine's
rate and drop its local helper). Approach A is the "fix it once, everywhere" ideal, but it means surgery in
goh's most critical, most-tested file for a *display* metric — not worth the blast radius in this slice when
B delivers the user-visible result safely.

**DECISION AT GATE (2026-06-07):** The user chose **Approach A** (engine-side) over this research
recommendation of **Approach B**. THE BET: the governor is independent (verified against the diff at the
final review — its sampler block is byte-for-byte untouched), and fixing the metric *everywhere* (CLI +
tray) in one change is worth the engine hot-path touch. This doc is a frozen point-in-time research record;
`STATE.md` and `docs/plans/2026-06-07-tray-download-dashboard-plan.md` reflect the implemented choice (A).
