---
date: 2026-06-07
feature: tray-download-dashboard
type: research-brief
---

# Research Brief — Professional Download Dashboard (tray)

## 1. Displayed speed = rolling window, not cumulative average (the bug)
Every established tool shows a **rolling/recent-window** speed; the cumulative `total/elapsed` average goh
uses is the wrong kind (it climbs as a multi-conn transfer ramps).
- curl: "current speed" = avg over the **last 5 seconds**, separate from its cumulative "average speed"
  [VERIFIED — everything.curl.dev/cmdline/progressmeter.html; curl/lib/progress.c].
- aria2: 10-second sliding window (`SpeedCalc`, `WINDOW_TIME = 10_s`) [VERIFIED — aria2 SpeedCalc.cc].
- wget: ~3s ring (20 slots, 150ms min sample) [VERIFIED — wget progress.c].
- **Sliding window dominates; none use EWMA** (no decay-constant tuning needed) [VERIFIED across the three].
- **ETA = remaining_bytes / rolling_speed**, NOT the average; ETA is hidden when total size is unknown
  [VERIFIED — curl progress.c + docs].
- **Recommendation for goh: a 5-second sliding window** at the ~100ms snapshot cadence (~50 samples).
  current_speed = Σ(bytes in kept window) / window_seconds_covered. Show no speed until ≥1s coverage
  (avoids ramp-up spikes). ETA = remaining/current_speed; "unknown" when bytesTotal is nil or coverage <1s.

## 2. Professional per-download row + placement
- **Two-line row** [SINGLE — Transmission #7984 / Chrome download-bubble redesign]:
  primary = file-type icon + filename (`.headline`, **middle-truncated** so the extension stays visible) +
  trailing hover actions (pause/resume, cancel); a full-width **progress bar**; secondary `.caption` muted
  line = `downloaded / total · rolling-speed · ETA · N connections` (active) or `size · finished-at` (done).
  Connections belong on the secondary line, not above the bar.
- **Progress bar:** Apple HIG — prefer **determinate** `ProgressView(value:total:)`; when `Content-Length`
  is absent use the **indeterminate spinner** `ProgressView()` (the native idiom), swapping to the bar once
  size is known [VERIFIED — Apple ProgressView docs; swiftwithmajid ProgressView].
- **Extra detail (source URL, sha256, per-connection) → expandable/inspector, never the compact row**
  [VERIFIED — Transmission compact-vs-detailed].
- **Popover vs window:** pro menu-bar utilities use a **compact popover for glance** (≤~5 items) and a
  **dedicated window** for the list-heavy dashboard (Downie, MenuBar Stats; NSPopover-vs-window guidance)
  [SINGLE — macmenubar/Downie, fleetingpixels NSPopover guide]. Fits goh's ROADMAP "opt-in window, not a
  GUI clone" framing.
- **Recommendation:** keep the popover compact (fix the collapse; show the top few downloads with
  filename + progress bar + speed), add a **"Downloads…" dedicated Window** (like the Trust/Add windows)
  for the full rich dashboard (all rows, ETA, connections, completed + verify status, expandable detail).

## 3. Design implications (settled by research)
- Rolling speed = **5s sliding window**, ETA from it, both used in the popover header aggregate AND rows.
- Row layout per §2; determinate bar / spinner-when-size-unknown.
- Popover (compact, glanceable, collapse fixed) + dedicated **Downloads window** (full dashboard).
- Completed/failed already retained by the daemon (CCB) → show them with final state; join the provenance
  ledger (`trustReader`) for completed files' verify/recorded status.

## 4. The one open fork → approaches
**Where to compute the rolling rate.** The metric is wrong product-wide (the CLI shows the same cumulative
average), so:
- **Engine-side** (DownloadEngine.progress → 5s windowed): fixes CLI **and** tray, consistent; governor is
  independent (CCB-confirmed) so it's safe — but touches the hardened engine's per-job hot path (needs a
  per-job sample buffer).
- **Menu-side** (viewmodel keeps per-job (t, bytesCompleted) history from snapshots, computes 5s rolling in
  the presenter): zero engine blast radius, fully unit-testable in GohMenuBar — but tray-only (CLI keeps the
  average → tray/CLI divergence) and the calc is superseded if the engine is later fixed.
