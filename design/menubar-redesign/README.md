# Handoff: goh menu bar — Apple-native (HIG) redesign

## Using this package with Claude Code
See **`CLAUDE_CODE.md`** for the step-by-step workflow and a ready-to-paste kickoff prompt.
In short: drop this folder into the `goh` repo, open the repo in Claude Code, and point it
at this README + the `goh menu bar (prototype).html` reference, surface by surface.

## Overview
A redesign of the **goh** macOS menu-bar companion (`goh-menu` / the `GohMenuBar` module)
built to look like Apple shipped it. The design language follows the **macOS 26 Human
Interface Guidelines** — it is intentionally quiet: the content and controls carry the
design, the chrome gets out of the way.

This supersedes an earlier “editorial” exploration (serif wordmark, mono numerals, paper
light mode), archived as `goh Editorial (archived).html`. **Build the Apple-native version.**

The authoring/reference file is `goh menu bar (prototype).html` — open it and toggle
**Tweaks** to exercise every surface (Popover / Add Download / Trust / Settings /
Notification), state (Busy / Light / First-run), menu-bar icon state, and appearance
(Dark / Light).

## About the design files
These are **design references authored in HTML/React (JSX)** — they show intended look and
behavior. **Not production code.** The app is **SwiftUI + AppKit** (Swift 6.2+, macOS 26+,
Apple Silicon). Rebuild the views in SwiftUI with the app’s established patterns, binding to
the **existing** view-model and data types (see “Mapping to the codebase”). No web view.

## Fidelity
High-fidelity, but expressed in **native components**. Prefer real SwiftUI controls
(`Toggle`, `Stepper`, `Picker`/menu, `Button`, `List`, `Form`, `.menuBarExtra` popover,
`Settings` scene) and **system materials / semantic colors** over hand-built look-alikes.
The pt values below are targets; let native metrics win where they differ.

---

## The design language (what makes it Apple, not “designed”)
1. **One type family — SF.** SF Pro for everything in running UI. **No serif, no
   monospaced typeface** in text. Numbers use SF with **monospaced digits**
   (`.monospacedDigit()` / `tnum`). The *only* non-SF element is the **`goh` brand wordmark**,
   which appears solely inside the Liquid Glass tile (menu-bar status item + popover header)
   and the app icon.
2. **Grouped inset modules.** Content lives in rounded “cards” with inset hairline
   separators — like Control Center, Settings, and Safari’s Downloads popover. Separation
   comes from grouping + spacing, not from rules everywhere.
3. **Semantic color.** `systemGreen` = success/verified, `systemRed` = failure/changed,
   the **label hierarchy** (primary/secondary/tertiary) for text, `separatorColor` for
   lines. The brand contributes exactly one thing: the **green is tuned to the brand hue**
   and used as the app’s `accentColor` (progress, primary buttons, the live arrow).
4. **The brand lives in the wordmark tile.** The full **`goh` wordmark** (italic-serif, the
   phosphor arrow through the *o*) sits in a small **Liquid Glass tile** as the menu-bar
   status item and the popover header — the only branded chrome. The arrow lights green when
   downloads are live. Everything else is neutral SF + semantic color.
5. **Determinate progress is static.** Solid accent fill, no shimmer/animation. (Only the
   menu-bar icon’s completion moment animates — see below.)
6. **Plain language.** “2 downloading · 6.4 MB/s”, “42.6 of 68.4 GB — 5.1 MB/s — 1m 12s
   left”, “Show All”. No `§`, no `No. 04`, no `PROVENANCE LEDGER` chrome.

---

## Tokens

### Color (semantic; resolve from the system, don’t hardcode where a system color exists)
| Role | Dark | Light | Native |
|---|---|---|---|
| label (primary) | white @ 92% | black @ 88% | `.primary` / `labelColor` |
| secondary | white @ 55% | black @ 50% | `.secondary` / `secondaryLabelColor` |
| tertiary | white @ 28% | black @ 28% | `tertiaryLabelColor` |
| separator | white @ 10% | black @ 9% | `separatorColor` |
| module fill | white @ 6% | `#FFFFFF` @ ~60% | secondary grouped background |
| **accent / green** | `#34D266` | `#28A85A` | app `accentColor` = brand green (≈ `systemGreen` tuned) |
| error / changed | `#FF453A` | `#FF3B30` | `systemRed` |
| popover surface | dark vibrant | **bright neutral** vibrant | `.popover`/`.hudWindow` material |
| window surface | `#1E1F23` | `#ECECEE` | `windowBackgroundColor` |

**Light mode is neutral and bright** — system grays with true translucency. **Never paper /
sepia / oat.** The popover is a translucent light-gray glass that lets the wallpaper tint
through; windows use the same translucent Liquid Glass material (slightly more opaque
than the popover), with grouped cards as semi-translucent fills on top.

### Type
- **SF Pro** everywhere; **SF Pro Rounded** only for the popover’s `goh` title.
- Numbers: SF + **monospaced digits**. No mono typeface anywhere in the UI.
- Sizes (pt): header title 16/600 (rounded); row title 13; secondary 11–12; module headers
  13/600; group labels 11/600 uppercase.

### Material & geometry
- **Popover:** width ~320, radius 18, highly translucent vibrant material (heavy blur
  ~72 + saturation ~185% so the desktop tints through — the macOS 26 “Liquid Glass” look),
  bright top highlight, soft shadow. The menu-bar status item shows a neutral rounded
  highlight while open.
- **Modules:** radius 10–12, inset 10–14 from popover edge, 0.5px separators between rows.
- **Windows:** radius 12, 44pt title bar with traffic lights, **translucent Liquid Glass**
  material (blur ~72 + saturation ~185%, like the popover) so the desktop tints through;
  grouped cards sit on it as semi-translucent fills. Optional toolbar (Settings tabs / Trust
  summary) below the title bar.
- **Progress bar:** 4pt, radius 2, solid accent fill (paused → secondary), static.
- **Controls:** circular 22pt stop/pause/resume buttons (Safari-style, thin ring + glyph);
  `Toggle` switches; segmented/`Picker` where 2–3 options.

---

## Surfaces

### 1. Menu-bar status item
A small **Liquid Glass tile bearing the full `goh` wordmark** (the arrow runs through the
*o*) — a translucent rounded chip that tints with the wallpaper, not a flat template glyph.
States: **idle** (no arrow), **active** (green arrow), **done** (full green, held ~600 ms
after the last completes, then recedes), **paused** (arrow @ ~45% + small pause overlay),
**error** (arrow → `systemRed` +
small × overlay). Completion animation: arrow brightens with progress, blooms briefly at
100%, recedes — the *only* sanctioned motion; honor `prefers-reduced-motion`. Reference:
`goh Icon Lifecycle.html`.

### 2. Popover (primary) — `.menuBarExtra(...) { } .menuBarExtraStyle(.window)`
- **Header:** the **`goh` wordmark in a Liquid Glass tile** (same tile as the menu-bar item;
  arrow lights green when active) + plain-language status (“2 downloading · 6.4
  MB/s”; “Reconnecting…” with a pulsing dot; “Service unreachable” in red); trailing `+`
  (Add) and `⋯` buttons, with a **Downloads Folder** button between them. The `⋯` opens an
  overflow menu: **All Downloads… · Verify &
  Trust… · Open in Terminal · — · Settings… · — · Quit goh** (this is where Trust, Terminal,
  and Quit live — keep it an `NSMenu`).
- **Clipboard CTA:** when a URL is detected on the pasteboard, a tappable module appears
  near the top — clipboard glyph + “Download from Clipboard” + the URL + a green download
  button. Hidden when nothing is detected.
- **Hero active module:** the foremost active download in its own rounded card — name, %,
  static accent bar, “42.6 of 68.4 GB — 5.1 MB/s — 1m 12s left”, circular pause. On hover the
  row reveals **Copy URL** and **Remove** glyph buttons (Safari-style); the primary
  pause/resume/stop control stays visible. Same hover affordance on the “Downloading” rows.
- **“Downloading” group:** remaining active/paused/queued rows (name, mini bar, secondary
  status line, circular pause/resume). Section header “Downloading”.
- **“Recent” group** with a green **Show All** action: completed rows show date + a green
  checkmark.circle; failed rows show **Failed** + red exclamationmark.circle (`systemRed`).
- **Footer:** none — the popover ends after Recent. (Add / Downloads Folder / overflow all
  live in the header cluster.)
- **First-run (empty):** friendly empty module (“Paste a URL to begin”) + the clipboard CTA.
- **Daemon unreachable:** swap the live region for a recovery module (red-tinted: “Background
  service unreachable”, “Open doctor” / “Copy command”); Recent still renders (reads offline).

### 3. Add Download window
Grouped `Form`: **URL** field (focus ring in accent), **Save to** menu (Downloads),
**Automatic connections** toggle (+ stepper when off), an inline reassurance line (“Hashed
in-flight and recorded…”). Footer: Cancel + green **Add**.

### 4. Trust window
A **master-detail** window: a summary toolbar (“48 tracked · 41 verified · 6 download-only ·
1 changed”) + search, a left **list** of tracked files (status icon + name + size), and a
right **inspector** for the selected file. The inspector shows: status pill, **Source**
(URL · size · downloaded · last-checked), **Integrity** — the full SHA-256 (with “Matches
the recorded signature” for verified), **Attestation** (Secure Enclave kid), and a
**History** timeline. For a **changed** file it surfaces a red warning banner and a
**hash diff** — Recorded vs. Current (on disk) with the differing characters highlighted —
plus recovery actions (Re-download / Update Record / Reveal). Window footer: Attest… +
green **Verify All**.

### 5. Downloads window
The **All Downloads** destination (opened from the popover’s `⋯` → All Downloads… and the
Recent “Show All”): a filterable list of every transfer. Toolbar: segmented filter
(All / Downloading / Completed / Failed) + search. Body: a scrollable grouped `List` —
**Downloading** (active/queued rows with progress + pause), **Recent/Completed**
(verified rows with host · size · sha256 · date, Reveal on hover), and **Failed** (its own
section/tab — rows show the error reason + a **Retry** button).
Footer: total summary + Open Folder + Clear Completed. This is where scale lives (48+ items).

### 6. Settings window (`Settings` scene)
Toolbar tabs **General / Downloads / Trust / Advanced** (active icon tinted accent), grouped
rows of label + control (`Toggle`/`Stepper`/menu/push button). Footer build line.

### 7. Completion notification
`UNUserNotificationCenter` banner: glyph + “Download Complete” + filename + green
checkmark + “Verified · 6.94 GB”.

---

## Mapping to the codebase
The data plumbing already exists; these designs replace the view bodies.

| Surface | Rebuild | Bind to |
|---|---|---|
| Popover | `GohMenuView.swift` | `GohMenuViewModel.state` (`GohMenuState`, `GohMenuJobRow`) |
| Add Download | `AddDownloadView.swift` | `AddDownloadViewModel` |
| Trust | `TrustWindowView.swift` | `GohTrustOverview`, `GohTrustEntryRow` |
| Settings | `GohMenuPreferencesView.swift` | `GohMenuPreferences` |
| Status item + states | menu-bar setup (presenter) | `GohMenuHealth`, job states |
| Notification | `GohMenuNotifications*` | completion payload |

`GohMenuJobRow` already exposes `progressFraction`, `sizeText`, `etaText`, `connectionText`,
`stateText`, `speedText`, `verifyStatus`, `destination`, `url`, `orderedControls`.
`GohTrustEntryRow` exposes `displayPath`, `sanitizedURL`, `sha256`, `downloadedAt`,
`verifiedAt`. Keep `GohMenuPresenter` for health copy + per-state controls; only the
presentation changes.

### SF Symbols
`plus` / `plus.circle`, `ellipsis.circle`, `pause.fill` / `play.fill` / `stop.fill`,
`checkmark.circle` / `checkmark.circle.fill`, `exclamationmark.circle` /
`exclamationmark.triangle`, `arrow.down.circle`, `folder`, `gearshape`, `checkmark.shield`,
`magnifyingglass`, `chevron.up.chevron.down` (menus).

## Interactions & behavior
- **Right-click context menus** — every download row (popover hero / Downloading / Recent)
  opens a native-style context menu at the cursor: active → Pause · Copy URL · Copy
  Destination · Reveal in Finder · Remove; completed → Open · Reveal · Copy URL · Verify &
  Trust… · Remove from List; failed → Retry · Copy URL · Remove. Build as a real `NSMenu`.
- **Drag a link onto the menu-bar icon** — dragging a URL over the status item shows a drop
  target (the icon lights its active/accent state + a “Drop to download with goh” tooltip);
  dropping starts a download. Implement via `NSDraggingDestination` on the status item.
- **Notification grouping** — completion banners group under the goh app in Notification
  Center (the prototype shows the stacked-cards look); use a stable
  `UNNotificationContent.threadIdentifier` so the system groups them.
- **Sound & haptics** — completion plays a subtle system sound (respect Do Not Disturb / the
  “Notify on completion” pref); errors use a distinct alert. No haptics on macOS, but a
  gentle menu-bar-icon bounce/bloom on completion is the tactile cue (see the icon animation).
- **End-to-end Add flow** (`goh Add Flow.html`): a scrubbable, looping guided demo of the
  full path — clipboard URL → Add Download sheet (prefilled) → the download becomes the
  active **hero** and progresses → completion **notification** slides in → the file lands in
  **Recent**, verified. Shows the intended surface choreography and the menu-bar icon
  tracking (idle → active → done → idle).
- **Edge conditions** (prototype Tweak → Condition): the popover handles real-world states:
  - **No Internet** — a neutral inline notice (“No Internet Connection · Transfers will
    resume when you reconnect”); active transfers shown as Paused.
  - **On Cellular** — a notice (“Paused on Cellular · Data Saver…”) with a green **Resume**
    action; transfers paused.
  - **Low disk** — a `systemRed`-tinted notice (“Startup Disk Almost Full · 1.2 GB
    available…”) with a **Manage…** action; transfers continue.
  - **Transfer error** — the failed transfer stays in the list with a red bar, a red reason
    (“Couldn’t connect — server returned 503”), and a circular **Retry** control; hover adds
    Reveal / Remove. (Distinct from a *completed-but-failed* item, which sits in Recent.)
  These map to view-model health/per-job error states; the notices are inline modules at the
  top of the popover, not separate alerts.
- **Live demo mode** (prototype Tweak, on by default): downloads progress in real time, the
  hero’s %/bytes/ETA tick up, completed transfers move into **Recent** with a verified check,
  new downloads arrive (queued → active), and the menu-bar icon tracks activity (active →
  brief done → idle). This models the intended runtime; in SwiftUI it’s driven by the
  view-model’s progress subscription, not a timer.
- **Determinate progress** itself is a static fill (no shimmer); motion comes only from the
  values changing and the icon’s completion bloom.
- Row **hover** reveals Copy URL / Remove; the `⋯` overflow holds Trust / Terminal / Settings
  / Quit; the clipboard CTA appears only when a URL is on the pasteboard.

## State management
Use the existing `GohMenuViewModel` (`@MainActor`, `ObservableObject`) and
`GohMenuPreferences` — no new state is needed; the redesign only re-presents what these
already publish.

## Assets & fonts
- **Icon/mark:** `assets/brand/wordmark/goh-wordmark.svg` (authoritative). The **app icon**
  is the **full “goh” wordmark in the Phosphor treatment** on Apple’s continuous-curvature
  squircle (ground #0C0E14, letters #F4EDE0, arrow #6BFA9B through the *o*) — see
  `goh App Icon.html`. Liquid Glass / Paper / g+arrow are shown there as alternates. For
  production, render to the full size set (16→1024 @1×/@2×) / an `.icon` via Icon Composer.
  The menu-bar status item and popover header use the same wordmark in a small Liquid Glass
  tile (a colored, non-template status item — `goh` wordmark, arrow tinting green when live).
- **Fonts:** SF Pro + SF Pro Rounded (system). No third-party UI fonts. The serif `goh`
  lockup is brand/marketing only — not used in the running UI.

## Files in this bundle
- `goh menu bar (prototype).html` — **the spec**, interactive, Tweaks for every surface +
  appearance. Deps: `common.jsx` (glyph path data + Icon + sample data), `apple.jsx`
  (popover, tokens, notification, shared controls), `appleWin.jsx` (windows),
  `tweaks-panel.jsx`, `appleProto.jsx`.
- `goh Icon Lifecycle.html` (+ `anim.jsx`) — menu-bar icon completion animation.
- `goh Add Flow.html` (+ `flow.jsx`) — scrubbable end-to-end Add flow (clipboard → sheet →
  hero → notification → Recent).
- `goh App Icon.html` (+ `icon.jsx`) — the app icon (full goh wordmark, Phosphor) + alternates.
- `goh Editorial (archived).html` + `dirD.jsx`/`dirWin.jsx` — the earlier editorial
  exploration, kept for reference only. Do not build from these.
