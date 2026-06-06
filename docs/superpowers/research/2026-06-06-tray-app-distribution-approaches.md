---
date: 2026-06-06
feature: tray-app-distribution
type: approach-decision-memos
---

# Approach Decision Memos — Tray App Distribution

The feature set is fixed (app-bundle, notifications, launch-at-login [app only],
preferences) and most implementation is determined by the research brief:
notifications post from the tray app's existing progress stream; login-item via
`SMAppService.mainApp`; `UserDefaults`/`@AppStorage` for toggles; a hand-assembled
`.app` via a new `Scripts/` script; inside-out Developer-ID signing as the final
wrapping step.

**The one real fork is how a tester receives goh** — because goh is two pieces
(the brew-installed CLI+daemon, and the new tray `.app`). Both approaches below
keep the daemon on `brew services` (per the confirmed scope) and produce a
signed/notarized artifact once the Developer ID lands.

---

## APPROACH A — "Companion DMG"

CORE IDEA
Ship the tray app as its own signed/notarized `.app` in a DMG; the CLI+daemon keep
installing through the existing brew/PKG path, untouched.

MECHANISM
A new `Scripts/package-app.sh` assembles `goh.app` (Info.plist template +
`swift build --release` output for `goh-menu`), then a DMG is built, signed,
notarized, and stapled. The `.app` contains only the tray binary. Testers install
the engine the way they do today (the existing `package-pkg.sh` PKG, or brew once
the tap opens), then drag `goh.app` to /Applications. The app talks to the
already-running daemon over XPC exactly as now.

FIT ASSESSMENT
Scale fit: matches — one user, one machine; nothing added at scale.
Team fit: fits — solo, no new expertise; reuses the SwiftPM-first build.
Operational: two install steps for the tester; two artifacts to sign/notarize
(the engine PKG and the app DMG).
Stack alignment: fits existing — smallest delta; clean separation of UI from engine.

TRADEOFFS
Strong at: minimal change, clean architecture, each artifact independently
versioned/shippable, lowest risk of touching the daemon install path.
Sacrifices: tester UX — "install the engine, THEN get the app" is two steps and a
sequencing footgun (app launched before engine installed shows a daemon-unreachable
state until they install the engine).

WHAT WE'D BUILD
`Scripts/package-app.sh`, an `Info.plist` template, a DMG build step, signing-script
additions for `goh-menu` + the `.app` + the DMG.

THE BET
Testers will tolerate a two-step install (engine, then app) — or we hand-hold them
through it.

REVERSAL COST
Easy — it's two independent artifacts; folding them together later (→ Approach B)
is additive.

WHAT WE'RE NOT BUILDING
No single-double-click installer; no bundling of CLI/daemon inside the .app.

INDUSTRY PRECEDENT
Many menu-bar companions ship as a standalone .app while a CLI installs separately
(e.g. tools that pair a brew CLI with a GUI). [UNVERIFIED — general pattern]

---

## APPROACH B — "All-in-One PKG"

CORE IDEA
One signed/notarized `.pkg`: double-click installs the CLI + daemon (LaunchAgent,
the existing mechanism) AND drops `goh.app` into /Applications — everything in a
single step.

MECHANISM
Extend the existing `Scripts/package-pkg.sh` (which already stages `goh`/`gohd`)
to also assemble and include `goh.app`. The PKG payload places the CLI/daemon as
today and installs the tray app; a postinstall step can optionally offer to launch
it. All three binaries + the `.app` are signed inside-out with the same Developer
ID (satisfying same-team XPC validation), and the PKG is notarized + stapled.
Daemon startup is unchanged (brew services for brew users; the PKG path mirrors the
current LaunchAgent install for direct-PKG testers).

FIT ASSESSMENT
Scale fit: matches — same single-user runtime; only packaging differs.
Team fit: fits — extends a script that already exists; no new tech.
Operational: one artifact to sign/notarize; one tester install step.
Stack alignment: fits existing — builds directly on `package-pkg.sh`; no daemon
*mechanism* change (still a LaunchAgent), only the installer carries the app too.

TRADEOFFS
Strong at: best tester UX — one download, one double-click, everything works;
single artifact to version and notarize; no "app-before-engine" sequencing trap.
Sacrifices: a bit more packaging machinery (PKG component + payload layout for the
.app); the engine and app are versioned together (can't ship the app alone without
re-cutting the PKG).

WHAT WE'D BUILD
Extensions to `Scripts/package-pkg.sh` (stage `goh.app`), the `Info.plist`
template + `package-app.sh` assembly (reused by the PKG), signing-script additions,
PKG notarize/staple.

THE BET
Versioning the engine and tray app together is acceptable for the tester phase
(they move in lockstep anyway right now).

REVERSAL COST
Easy — can also emit a standalone DMG later (Approach A) from the same assembled
.app without undoing anything.

WHAT WE'RE NOT BUILDING
No separate app-only DMG channel (yet); no independent app/engine version cadence.

INDUSTRY PRECEDENT
A single PKG that installs a daemon + LaunchAgent + a companion app is a standard
macOS pattern for daemon-backed tools. [UNVERIFIED — general pattern]

---

## Comparison matrix

| Criterion | A — Companion DMG | B — All-in-One PKG |
|---|---|---|
| AC1 app bundle | STRONG — builds goh.app | STRONG — same goh.app, carried by the PKG |
| AC2 notifications | STRONG — identical (tray app posts) | STRONG — identical |
| AC3 login-item | STRONG — identical (`SMAppService.mainApp`) | STRONG — identical |
| AC4 preferences | STRONG — identical (`UserDefaults`) | STRONG — identical |
| AC5 no regression | STRONG — engine untouched | STRONG — engine mechanism untouched; installer extended |
| Tester install UX | WEAK — two steps, sequencing footgun | STRONG — one double-click |
| Scale fit | STRONG | STRONG |
| Team fit | STRONG | STRONG |
| Operational burden | PARTIAL — two artifacts to sign/notarize | STRONG — one artifact |
| Stack alignment | STRONG — smallest delta | STRONG — extends existing PKG script |

## Recommendation
**Approach B — All-in-One PKG.** The entire reason for this arc is getting goh into
testers' hands with low friction; a single double-click that installs the engine
and the tray app is the difference between "testers actually try it" and "testers
get stuck on step two." It reuses the PKG machinery that already exists, changes no
daemon *mechanism*, and stays fully reversible — we can still cut a standalone app
DMG later. The feature work (bundle, notifications, login-item, preferences) is
byte-identical between A and B; only the packaging wrapper differs, and B's wrapper
is the one that serves the goal.
