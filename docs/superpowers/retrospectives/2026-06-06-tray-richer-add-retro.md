---
date: 2026-06-06
feature: tray-richer-add
type: pipeline-retrospective
---

# Pipeline Retrospective — Richer Add in the Tray

## Adversarial Review Categories That Fired

### Spec Review (round 1: 4 block; round 2: APPROVED)
- Cat 1/7 — `canAdd` URL validation was undefined; fixed to reuse the shipped
  `GohClipboardURLDetector.url(from:)` and submit the normalized `absoluteString`.
- Cat 3/7 — `errorText` had no plain-English producer; fixed by adding a reusable
  `GohMenuError.userFacingMessage` and routing thrown errors through `GohMenuErrorMapper.map`.
- Cat 8 — `UInt8(connectionCount)` could trap; fixed with `UInt8(min(16, max(1, count)))`.
- Cat 5 — test list expanded to cover garbage URLs, exact error text, clamp-no-trap, cancel-unchanged.

### Plan Review (round 1: 2 block; round 2: 1 block, fixed → APPROVED)
- Cat 1 — the AC4 "regression" test was a tautology (hand-built `AddRequest`, never called
  `performPrimaryAction`); fixed by designating the EXISTING `startsClipboardURLThroughDaemon`
  as the AC4 anchor and adding no tautological copy.
- Cat 7 — the view model was constructed inside the `Window {}` content closure (rebuilt on
  re-eval, losing input); fixed with an `AddDownloadWindowRoot` owning `@StateObject` via an
  `@autoclosure` init.
- Cat 10 (round 2) — the "Add download…" button called `NSApp.activate` in a SwiftUI-only file;
  fixed by adding `import AppKit` to `GohMenuView.swift`.

## Approach Selected
**Chosen:** A — Add Download window.
**THE BET:** a dedicated add window is acceptable UX for the choose-where/how case (the fast
one-tap clipboard add stays in the popover for everyone else).
**Rejected:** B — Set-once defaults (no per-download choice; would rework the just-shipped
Preferences sheet).

## Design Validation Changes
6 gaps fixed at design time: URL validation, automatic(nil)/pinned mapping, single-window focus,
accessory-app activation, error surfacing, default-preservation. Key property: reuses the existing
`.add` XPC command — **no new IPC surface**, no wire change (`AddRequest` already has the fields).

## Open Risks Not Resolved
- **Stacked on PR #97** (the tray-app-distribution slice, unmerged): both touch `main.swift`,
  `GohMenuView.swift`, `GohMenuModels.swift`. Built on top of that branch; #97 should merge first,
  then this rebases onto main.
- Live folder-picker behavior from an `.accessory` app (NSOpenPanel.begin + NSApp.activate; window
  front-order) is research-backed [SINGLE] but only fully confirmable by running the built app — the
  `FolderPicker` protocol seam lets the live impl be swapped without touching the tested view model.
- `.fileImporter`-vs-`NSOpenPanel` and the non-sandboxed-no-bookmark claims are [SINGLE]/[UNVERIFIED]
  but isolated behind the protocol seam.
