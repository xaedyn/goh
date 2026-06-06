---
date: 2026-06-06
feature: tray-app-distribution
phase: 3
title: Packaging layer
status: not-started
depends-on: phase2
---

# Phase 3 — Packaging layer

Info.plist template, `package-app.sh`, `package-pkg.sh` extension, shared
staging helper, signing-script seam, `DESIGN.md` update. No new Swift unit tests
(packaging is shell + plists). Validated by manual verification commands.

THE BET load-bearing here: the PKG now contains `goh` + `gohd` + `goh.app` under
a single version. Re-cutting the PKG is required for any update to any component.
Intentional and documented in the script header.

## Tasks

- [ ] **P3-1** CREATE `Resources/app-Info.plist`
  - All required Info.plist keys: `CFBundleIdentifier=dev.goh.menu`, `LSUIElement=true`, `CFBundleExecutable=goh-menu`, `LSMinimumSystemVersion=26.5` (matches PKG `requirements.plist` `os` pin), `CFBundlePackageType=APPL`
  - `__VERSION__` placeholder substituted by `package-app.sh`
  - Validation: `plutil -lint Resources/app-Info.plist` → OK
  - AC1 coverage

- [ ] **P3-2** CREATE `Scripts/package-app.sh`
  - Assembles `goh.app` from `swift build --release` output + `Resources/app-Info.plist`
  - Guards: missing version (exit 64); missing `CFBundleIdentifier` in template (exit 64 + clear message)
  - Emits `app=<path>` and `bundle_id=<id>` on stdout
  - Manual validation: `defaults read <app>/Contents/Info CFBundleIdentifier` → `dev.goh.menu`; `LSUIElement` → `1`; `LSMinimumSystemVersion` → `26.5`
  - AC1 coverage

- [ ] **P3-3** CREATE `Scripts/_stage-app-payload.sh` + MODIFY `Scripts/package-pkg.sh` + MODIFY `Scripts/private-release-candidate.sh` + MODIFY `DESIGN.md`
  - `_stage-app-payload.sh`: shared sourced helper; calls `package-app.sh`; copies `goh.app` to `$payload_root/Applications/`
  - `package-pkg.sh`: sources `_stage-app-payload.sh` after existing binary staging; single comment names the helper
  - `private-release-candidate.sh`: sources `_stage-app-payload.sh`; extends codesign loop to include `goh-menu` (inner) + `goh.app` (outer) inside-out; documents post-credential note
  - `DESIGN.md`: adds §menu-bar-distribution subsection (bundle assembly, PKG inclusion, signing order, subscription lifecycle, trust model unchanged)
  - Manual PKG validation: `pkgutil --expand <pkg>` + inspect payload for `./Applications/goh.app/...`
  - AC1 + AC5 coverage (packaging)

## Phase 3 exit criteria

- [ ] `swift build -warnings-as-errors` clean
- [ ] `swift test` green (all existing 716+ tests)
- [ ] `plutil -lint Resources/app-Info.plist` → OK
- [ ] `Scripts/package-app.sh 0.0.1-test` succeeds; `defaults read ... CFBundleIdentifier` returns `dev.goh.menu`
- [ ] `Scripts/package-pkg.sh 0.0.1-test` succeeds; `goh.app` present in PKG payload
- [ ] AC5 tripwire: `grep -n '#error' Sources/GohCore/IPC/XPCService.swift | grep RELEASE` returns a hit
- [ ] No `#available` ladders in `Sources/goh-menu` or `Sources/GohMenuBar`
- [ ] `DESIGN.md` §menu-bar-distribution subsection present

## Notes

_Filled in during execution._
