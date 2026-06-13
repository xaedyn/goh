# Handing goh's menu-bar redesign to Claude Code

This package is a **design reference** (HTML/React prototypes + a precise spec in
`README.md`). The goal is to recreate it **in the real `goh` SwiftUI + AppKit app** — binding
to the existing view-models, not shipping any HTML. This file is the practical playbook.

---

## 1. Put the package in the repo
Unzip this folder into the goh repo so Claude Code can read it alongside the source:

```
goh/
├── Sources/GohMenuBar/…        ← the views you'll rebuild
└── design/menubar-redesign/    ← drop this whole folder here
    ├── README.md               ← the binding spec (read first)
    ├── CLAUDE_CODE.md          ← this file
    ├── goh menu bar (prototype).html   ← the reference build (open in a browser)
    └── *.jsx, other *.html     ← supporting references
```

Commit it on a feature branch (e.g. `redesign/menubar-liquid-glass`).

## 2. Open the reference so you can SEE it
**Pixel references** for every surface (light + dark) live in `screenshots/`:
`popover`, `add-download`, `downloads`, `trust`, `settings`, `notification` — each with a
`-dark.png` and `-light.png`. Hand these to Claude Code directly so it can diff its build
against the target without running the HTML.

For live, stateful exploration, open **`goh menu bar (prototype).html`** in a browser and use
the **Tweaks** panel (top-right) to drive every surface and state:
- **Surface:** Popover · Add Download · Downloads · Trust · Settings · Notification
- **State:** Live demo, Condition (offline / cellular / low-disk / transfer-error), Activity
  (busy / light / first-run), Daemon (connected / reconnecting / unreachable), Menu-bar icon
- **Appearance:** Dark / Light

Other references: `goh App Icon.html` (app icon), `goh Icon Lifecycle.html` (completion
animation), `goh Add Flow.html` (end-to-end add flow). The earlier `goh Editorial
(archived).html` is **not** to be built — it's the rejected direction.

## 3. The golden rules (carry these into every prompt)
- **SF Pro only** in running UI; numbers use **monospaced digits** (`.monospacedDigit()`).
  No serif, no mono *typeface*. The single exception is the **`goh` wordmark**, used only
  inside the Liquid Glass tile (status item + popover header) and the app icon.
- **Semantic colors**: `Color.green`/`systemGreen` (tuned to the brand) as `accentColor`,
  `systemRed` for failure/changed, the `.primary/.secondary/.tertiary` label hierarchy.
  Light mode is **neutral & bright** — never paper/sepia.
- **Liquid Glass** everywhere: popover + windows use translucent vibrant materials
  (`.regularMaterial` / `NSVisualEffectView`, rounded ~14–18, soft top highlight) so the
  desktop tints through. Grouped content sits in floating rounded cards.
- **Bind to the existing view-models** — don't invent state. The data is already published.
- **Don't ship HTML / no web views.** Native SwiftUI only.

## 4. Build surface-by-surface (recommended order)
Each surface maps to an existing file (see README → "Mapping to the codebase"). Do them one
at a time, verifying each against the prototype before moving on:

1. **Shared foundation** — a `Theme`/tokens file (colors, materials, the `GohWordmarkTile`
   view, the status-icon states) + the `goh` wordmark asset. This unblocks everything else.
2. **Popover** → `GohMenuView.swift` (bind `GohMenuViewModel.state`). The biggest surface:
   header tile + status, clipboard CTA, hero active download, Downloading group, Recent,
   `⋯` overflow menu, right-click row menus, daemon/edge banners.
3. **Menu-bar status item** — the wordmark Liquid Glass tile + its states + completion
   animation; drag-a-URL-onto-the-icon drop target.
4. **Add Download** → `AddDownloadView.swift`.
5. **Downloads window** → new window (All / Downloading / Completed / Failed list).
6. **Trust window** → `TrustWindowView.swift` (master-detail inspector + the changed-hash
   diff).
7. **Settings** → `GohMenuPreferencesView.swift`.
8. **Notification** → `GohMenuNotifications*` (+ `threadIdentifier` grouping).

## 5. Kickoff prompt (paste into Claude Code at the repo root)

> I'm redesigning goh's menu-bar UI. The full spec and HTML/React reference prototypes are in
> `design/menubar-redesign/` — read `README.md` first (it's the binding spec) and
> `CLAUDE_CODE.md` for the plan. Open `goh menu bar (prototype).html` mentally as the visual
> reference; it's driven by the Tweaks panel through every surface and state.
>
> We're recreating this **natively in SwiftUI + AppKit**, binding to the existing
> view-models in `Sources/GohMenuBar/` — no web views, no new state. Follow the README's
> "Mapping to the codebase" table and "design language" rules exactly: SF Pro + monospaced
> digits (the only non-SF thing is the `goh` wordmark in the glass tile + app icon), semantic
> system colors with a brand-green accent, translucent Liquid Glass materials, neutral-bright
> light mode.
>
> Start with **Step 1 (shared foundation)**: create a tokens/theme file (colors, materials,
> the label hierarchy) and a reusable `GohWordmarkTile` SwiftUI view for the menu-bar status
> item + popover header (full `goh` wordmark on a translucent rounded glass tile; arrow
> tints green when downloads are active, dim when paused, oxblood on error). Import the
> wordmark from `assets/brand/wordmark/goh-wordmark.svg`. Show me the theme file and the tile
> rendered in both light and dark before we move on to the popover.

## 6. Per-surface prompt template
For each subsequent surface:

> Now rebuild the **<surface>** to match `design/menubar-redesign/` (README §"<surface>") and
> the prototype. Replace the body of `<file>.swift`, binding to `<view-model>`. Match the
> spec's layout, materials, typography (SF + mono digits), semantic colors, and the
> light+dark Liquid Glass look. Keep all existing functionality wired. Build and show me a
> screenshot in both appearances; we'll diff against the prototype before continuing.

## 7. Verify each surface
- Toggle the prototype's Tweaks to the matching state and **compare side by side** (spacing,
  type sizes, materials, the green/red semantics, the wordmark tile).
- Check **both Dark and Light** — light must read as bright neutral glass, not sepia.
- Confirm the **edge/daemon states** (offline, cellular, low-disk, transfer-error,
  reconnecting, unreachable) and the **empty/first-run** state.
- Confirm wallpaper **tints through** the glass (translucency), and right-click menus +
  hover affordances work.

## 8. Assets & fonts
- Wordmark / app icon: `assets/brand/wordmark/goh-wordmark.svg` is authoritative. Export the
  app icon (full wordmark, Phosphor treatment per `goh App Icon.html`) to an `.icon` /
  the 16→1024 size set via Icon Composer.
- Fonts: **SF Pro** (system) only in UI. The serif is *only* the wordmark glyph, shipped as
  the vector asset — not a UI font.
