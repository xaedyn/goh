---
date: 2026-06-07
feature: tray-trust-layer
type: codebase-context-brief
---

# CCB — Trust Layer in the Tray

STACK
Swift 6.2 floor / 6.3.x toolchain, Swift 6 mode, macOS 26.0. SwiftUI + AppKit menu-bar target.
`GohMenuBar` is `.defaultIsolation(MainActor.self)` with `nonisolated`+Sendable on boundary-crossing
types (GohMenuState/Health/Error/JobRow). `GohCore` is nonisolated-default. **App is NOT sandboxed**
(`app-Info.plist` has no `NSAppSandboxEnabled`) → `goh-menu` can read the user-owned, 0600
`~/Library/Application Support/dev.goh.daemon/provenance.plist` directly. Swift Testing; `-warnings-as-errors`.

EXISTING PATTERNS
- **Provenance read API (`Sources/GohCore/Provenance/ProvenanceStore.swift`):** `loadReadOnly() -> Bool`
  (CLI path; never creates dir/sidecar), `allEntries() -> [ProvenanceEntry]`, `lookup(destinationPath:)
  -> ProvenanceEntry?`. **DIRECT DISK READ — no daemon/XPC; works with the daemon stopped. Daemon is
  the SOLE WRITER.** Path via `ProvenanceStoreLocation.defaultURL(create:false)` (shared resolver).
- **`ProvenanceEntry` (ProvenanceRecord.swift):** `url: String` (verbatim, may carry query creds),
  `sha256: String` ("sha256:<hex>"), `size: Int`, `downloadedAt: Date`, `destinationPath: String`
  (canonical key), `verifiedAt: Date?` (additive-optional; nil = download-only).
- **`goh which` (GohWhichCommand.swift):** ledger-first lookup → lock → Spotlight xattr fallback; renders
  url (via `URLDisplay.sanitized`), sha256, size, + 3-way date (downloaded / verified present / both).
  Cheap (one load + linear scan, NO re-hash). Exit 0 match / 4 no record.
- **`goh verify --all` (GohVerifyAllCommand.swift + VerifyReportTypes.swift):** `VerifyAllReport`
  (`reportVersion:1`, frozen) = `summary{total,ok,failed,missing}` + `entries[]{path,url,status
  (ok|failed|missing),expectedSha256,actualSha256?}`. Exit 0 all-ok/empty · 2 mismatch · 9 missing
  (9>2>0) · 6 ledger error · 64 usage. **THE COST:** `run()` calls `FileDigest.sha256WithSize(path:)`
  on EVERY entry **synchronously in a serial for-loop** (1 MiB-chunk CryptoKit SHA-256). NO incremental
  / partial / progress / cancellation. Minutes-long for large ledgers.
- **The seam:** `GohVerifyAllCommand.run(provenanceStorePath:json:generatedAt:) -> GohCommandLineResult`
  is a static method on a pure enum (no parse side-effects) but returns rendered text/exit-code, NOT the
  `[VerifyEntryResult]`. To get structured data either call with `json:true` and decode, OR extract a new
  library helper that returns `VerifyAllReport` directly (none exists today; `payloadBytes(for:)` takes an
  already-built report).
- **How the tray gets data today:** `GohMenuViewModel` ← `GohMenuProgressStream` (XPC progress stream of
  `[ProgressSnapshot]`). **That stream carries NO provenance** (no sha256/downloadedAt/verifiedAt/status).
  Trust data is on-disk only. The menu app reads nothing from disk today except `UserDefaults`.
- **`URLDisplay.sanitized(_:)`** strips control chars + redacts credential query params; MUST wrap any URL
  shown in the tray.

RELEVANT FILES
- `Sources/GohCore/Provenance/{ProvenanceRecord,ProvenanceStore,ProvenanceStoreLocation}.swift` — read API.
- `Sources/GohCore/CLI/GohVerifyAllCommand.swift` + `VerifyReportTypes.swift` — verify model + the seam.
- `Sources/GohCore/TrustCore/FileDigest.swift` — `sha256WithSize(path:)`, the sync streamer.
- `Sources/GohCore/CLI/URLDisplay.swift` — `sanitized`.
- `Sources/GohMenuBar/GohMenuViewModel.swift` — `@MainActor`; where a trust load/verify task would live.
- `Sources/GohMenuBar/GohMenuView.swift` — popover layout (footer already has Preferences/Add-download).
- `Sources/GohMenuBar/GohMenuModels.swift` / `GohMenuPresenter.swift` — model + pure presenter (a new
  trust presenter/model belongs here).
- NEW (likely): a GohMenuBar trust-model + presenter; a trust section/sheet view; a verify-runner.

CONSTRAINTS
- **Frozen:** `ProvenanceRecord.currentVersion = 1` (plist), `VerifyAllReport.reportVersion = 1` (golden
  fixture `verify-all-report-v1.json`). Must NOT change. Per-file `GohVerifyCommand` untouched.
- **Read-only:** tray must NEVER call `record`/`recordVerified`. Only `loadReadOnly()`/`allEntries()`/
  `lookup()`. Daemon stays sole writer.
- **Re-hash cost is the central constraint:** the serial re-hash loop has no yield/cancel/progress.
  Running it on the MainActor freezes the popover. Must run off-main.
- **Known repo gotcha [[swift-sync-async-bridge-cooperative-pool-deadlock]]:** sync blocking work driven
  from the cooperative pool starved CI (#81 hung 6h). The re-hash is sync blocking I/O — run it on a
  dedicated thread (`Task.detached`) or chunk with explicit `Task.yield()`/cancellation checks; do NOT
  block a cooperative-pool worker.
- MainActor-default isolation; `nonisolated`-Sendable convention; Swift Testing; `-warnings-as-errors`;
  no `#available`.
- ROADMAP "**not a full GUI clone**": read-only status, not management. A full per-file list for huge
  ledgers risks the clone smell — prefer summary + on-demand detail.

OPEN QUESTIONS
1. **Structured-report seam:** extract a pure `VerifyAllRunner`/helper in GohCore returning a
   `VerifyAllReport` (clean, testable, reused by the CLI), vs the tray calling `run(json:true)` + decoding
   (no GohCore change but indirect). Extraction is cleaner but touches GohCore (additive only).
2. **Off-main re-hash with progress + cancel:** verify-all today is one opaque sync call. To show
   progress (n/total) and support cancel, the runner must iterate entries with per-file progress callbacks
   + cancellation checks, off the cooperative pool. Need a `VerifyProgress` model + a cancel path.
3. **Direct read vs XPC:** direct `loadReadOnly()` from the unsandboxed tray (same as CLI) — no new XPC,
   no protocolVersion bump, works daemon-down. Strongly preferred; confirm 0600 same-user read works
   (the CLI already does it).
4. **Presentation in 380pt popover:** summary badge ("47 tracked · last verify: 45 OK / 1 FAILED / 1
   MISSING") + an on-demand detail list (sheet/window, reusing the Add-Download-window pattern) vs an
   inline list. Summary + detail-on-demand is the ROADMAP-safe fit.
5. **Stale-status honesty:** the overview's at-rest status comes from `verifiedAt` (when the daemon last
   confirmed), NOT a live re-hash — must be labelled as "last recorded," distinct from a fresh "Verify
   now" result, so the UI never implies a stale OK is a live OK.
6. **Empty/absent ledger:** degrade to "No downloads recorded yet" (verify-all already treats absent/empty
   as exit 0 / empty report).
