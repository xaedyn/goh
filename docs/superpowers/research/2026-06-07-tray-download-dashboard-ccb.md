---
date: 2026-06-07
feature: tray-download-dashboard
type: codebase-context-brief
---

# CCB — Professional Download Dashboard (tray)

STACK
Swift 6.2, SwiftUI + AppKit. `GohMenuBar` MainActor-default; `MenuBarExtra(.window)` (NSPopover-backed,
content-hugging). Separate `Window(id:)` scenes already exist ("add-download", "trust", "preferences") —
precedent for a dashboard window. GohCore nonisolated-default. Swift Testing, `-warnings-as-errors`.
`protocolVersion = 4`.

EXISTING PATTERNS
- **No-row bug (CONFIRMED):** `GohMenuView.jobs` (GohMenuView.swift:163-183) = `ScrollView { LazyVStack { ForEach rows } }.frame(maxHeight: 260)` with **no `minHeight`**, inside a content-hugging `VStack(...).frame(width: 380)`. The popover proposes ~0 height → ScrollView proposes 0 → LazyVStack measures 0 children → rows render zero-height/invisible. Header "N active" is derived independently so it still shows. Fix: give the list a `minHeight` (or use `VStack` not `LazyVStack` for the small counts).
- **Presenter** (`GohMenuPresenter.state`): `jobs = snapshots.map(\.job).sorted{by id}` (ALL states); `activeCount` = `.active` count; `rows = jobs.map(row(for:))` (no filter). Surfaces per row: id, url, destination(→filename+path), state, progress(bytesCompleted/bytesTotal/bytesPerSecond). **IGNORES**: createdAt, lastProgressAt, requestedConnectionCount, actualConnectionCount, pauseReason, completedAt, error, retryEligible, failedAt, retryCount — all available, none reach the UI.
- **Snapshots** arrive via `GohMenuProgressStream` (XPC `SubscribeRequest(scope: .all)`, seed reply + streamed `ProgressEvent.snapshot`, ~100ms cadence). **KEY: completed/failed jobs are NOT pruned** — `ProgressBroker.remove` is called ONLY on explicit user `remove` (JobStore.swift:299); `JobStore.complete()` republishes the job as `.completed`. So completed/failed stay in the snapshot/menu until the user removes them — "keep completed visible" is already the daemon's behavior.
- **Speed (the bug):** `DownloadEngine.progress(completed:total:elapsed:)` (DownloadEngine.swift:1040-1046) = `rate = completed / elapsed_seconds` where `elapsed = clock.now - jobStart`. So it's the **cumulative average since start** (climbs as the transfer ramps). `bytesPerSecond` is the frozen wire field (value can change; field can't).
- **Governor independence (blast radius = zero):** the BBR governor's rate comes from a SEPARATE windowed `ByteCounter` delta/interval in `fetchRanged` (DownloadEngine.swift:787-826, ≥0.25s window) fed to `governor.record(aggregateBytesPerSecond:)`. It does NOT use `progress()`. Changing the display rate does not touch the governor.
- **Provenance ledger** (for completed/verify status): `ProvenanceLedgerReader.read(at:) -> ProvenanceReadOutcome`; `ProvenanceEntry{url, sha256, size, downloadedAt, destinationPath, verifiedAt?}`. The menu already holds `trustReader: any ProvenanceReading` + `loadTrustOverview()`. Join completed `JobSummary.destination` → `ProvenanceEntry.destinationPath`.
- **Window/test patterns:** `Window(id:)` + `.windowResizability(.contentSize)`. Presenter tests (GohMenuPresenterTests) = Swift Testing `@Suite`, stub `ProgressSnapshot`/`JobSummary`/`JobProgress`, assert speed-text/state-text/controls/order. ViewModel tests = `@MainActor @Suite` + `FakeMenuClient`.

RELEVANT FILES
- `Sources/GohMenuBar/GohMenuView.swift` — collapsed `jobs` ScrollView + `GohMenuJobRowView`; footer/window buttons.
- `Sources/GohMenuBar/GohMenuPresenter.swift` — the only JobSummary→display mapper (rows, activeCount, speed text).
- `Sources/GohMenuBar/GohMenuModels.swift` — `GohMenuJobRow`, `GohMenuState`.
- `Sources/GohMenuBar/GohMenuViewModel.swift` — `@Published state`, `snapshots` cache, `onProgressSnapshots`, `trustReader` (menu-side rolling-rate state would live here).
- `Sources/GohCore/Engine/DownloadEngine.swift` — `progress()` (rate calc) + governor sampling (untouched).
- `Sources/GohCore/Model/{JobProgress,JobSummary}.swift` — wire types; bytesPerSecond frozen field; rich fields for the dashboard.
- `Sources/GohCore/Model/{ProgressBroker,JobStore}.swift` — completed jobs retained.
- `Sources/goh-menu/main.swift` — MenuBarExtra + Window scenes (a dashboard window would go here).
- NEW (likely): a richer row/dashboard view; rolling-rate helper; possibly a `Window(id:"dashboard")`.

CONSTRAINTS
- Frozen: `protocolVersion=4`, XPC envelope, `JobProgress`/`JobSummary` wire shapes (bytesPerSecond stays a present non-optional field; only its computed value may change). Golden fixtures are protocolVersion-3 with empty `snapshot: []` (JobProgress shape not pinned in fixtures; covered by JobModelTests).
- The governor's windowed sampling MUST NOT be touched (independent of `progress()`).
- MainActor-default; nonisolated-Sendable on presenter/models; Swift Testing; `-warnings-as-errors`; no `#available`.
- ROADMAP "not a full GUI clone": a full dashboard is in tension; framing it as a separate opt-in `Window` (like Trust) preserves the constraint. The popover already shipped (MB1).

OPEN QUESTIONS
1. **Rolling-rate: engine-side vs menu-side.** Engine-side (ring buffer of (t, bytesCompleted) per job; emit rolling `bytesPerSecond`) fixes BOTH the CLI and tray consistently, but touches GohCore + the daemon's emission. Menu-side (menu keeps per-job (t, bytesCompleted) history from successive snapshots, computes rolling rate in the viewmodel/presenter) has ZERO engine blast radius but only fixes the tray (CLI keeps the average → tray/CLI inconsistency). Window size? (~3-5s; cadence ~100ms.) THE primary approach fork.
2. **Completed-visible: already free** (daemon retains). Open: show provenance/verify status for completed rows via a `trustReader` join (destination↔destinationPath)?
3. **Placement:** richer popover (needs more height; fixes the collapse) vs a dedicated resizable `Window(id:"dashboard")` (roomier; ROADMAP-safer as opt-in).
4. **ETA:** `(bytesTotal - bytesCompleted)/rollingRate`; when `bytesTotal == nil` → "unknown"/omit. Elapsed from `createdAt`/`lastProgressAt`. Menu-side calc.
5. **Tests to update:** no engine test pins the cumulative rate numerically; `GohMenuPresenterTests` passes through whatever speed the snapshot carries (would pass regardless). New tests needed for the rolling-rate calc + the rich row.
