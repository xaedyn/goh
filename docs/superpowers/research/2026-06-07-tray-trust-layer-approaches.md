---
date: 2026-06-07
feature: tray-trust-layer
type: approach-decision-memos
---

# Approach Decision Memos — Trust Layer in the Tray

Research determined most mechanics (shared, no real fork): the tray **reads the ledger directly**
(unsandboxed, like the CLI — no new XPC/wire change); a pure **`VerifyAllRunner`** is extracted into
GohCore (returning `VerifyAllReport`, taking a progress + cancel hook) and the existing CLI `run()`
reuses it (so AC5 parity is automatic and AC3 progress/cancel is possible); the re-hash runs on a
**real OS thread via `DispatchQueue.global().async`** (NOT `Task.detached`, which stays on the cooperative pool — [[swift-sync-async-bridge-cooperative-pool-deadlock]]);
the per-file list + "Verify now" + progress + cancel live in a **dedicated Trust window** (reusing the
shipped Add-Download `Window` + `@StateObject` root pattern), since the transient popover can't host them.

**The genuine fork: does the popover show a glanceable at-rest trust summary, or is all trust UI in the
window?**

---

## APPROACH A — "Status badge + Trust window"

CORE IDEA
The popover shows a compact, glanceable trust summary (tracked count + last-recorded status); a "Verify…"
entry opens a dedicated Trust window with the per-file detail and the background "Verify now".

MECHANISM
On popover open, a small trust load (off-main `allEntries()` read, published to the `@MainActor` model)
renders a one-line summary in the popover (e.g. "47 files tracked · last recorded: 45 verified · 2
download-only"), explicitly "last recorded," not live. A "Verify…" button opens the Trust window
(`Window(id:"trust")` + `@StateObject` root) showing the per-file list (path, sanitized URL, sha256,
dates, at-rest status) and a "Verify now" button that runs the extracted `VerifyAllRunner` via
`DispatchQueue.global().async` (a real OS thread, off the cooperative pool), streaming progress (n/total) into the window and supporting cancel; on completion it shows the
fresh OK/FAILED/MISSING summary (distinct from the at-rest labels). Empty ledger → "No downloads recorded
yet" in both places.

FIT ASSESSMENT
Scale fit: matches — single user; the cheap summary read is fast, the heavy re-hash is windowed + backgrounded.
Team fit: fits — reuses the Add-Download window pattern + GohMenuBar presenter convention.
Operational: none new; direct read, no daemon dependency.
Stack alignment: fits — SwiftUI/MainActor; the runner extraction is additive in GohCore.

TRADEOFFS
Strong at: glanceability (the tray's whole point) — you see trust status without opening anything; heavy
verify is correctly windowed/backgrounded.
Sacrifices: one more popover section (a new model field + presenter + view) and a cheap ledger read on
popover open.

WHAT WE'D BUILD
`VerifyAllRunner` (GohCore, + CLI reuse); a GohMenuBar trust model + pure presenter; a popover summary
section; a Trust `Window` (root + view) with per-file list + background "Verify now" (progress/cancel).

THE BET
A glanceable at-rest summary in the popover is worth the extra section — users want trust status at a
glance, not only after opening a window.

REVERSAL COST
Easy — the popover summary is additive; it can be removed leaving the Trust window intact.

WHAT WE'RE NOT BUILDING
No per-file "verify just this one" in v1 (cheap future add via the untouched `goh verify` path); no
inline per-file list in the popover (clone risk); no writes to the ledger.

INDUSTRY PRECEDENT
Backup/sync menu-bar apps show a glanceable "last check" status + a detail window for the full report
[UNVERIFIED, common pattern].

---

## APPROACH B — "Trust window only"

CORE IDEA
No inline popover summary; a "Trust…" footer button opens the dedicated window, which shows the overview
list and the background "Verify now".

MECHANISM
Identical window to A (direct read, extracted runner, per-file list, background verify with progress +
cancel), but the popover only gains a single "Trust…" button — no at-rest summary line, no ledger read on
popover open.

FIT ASSESSMENT
Scale fit: matches. Team fit: fits. Operational: none new. Stack alignment: fits.

TRADEOFFS
Strong at: smallest popover change; no ledger read on every popover open; one place for all trust UI.
Sacrifices: no glanceability — you must open a window to learn anything about trust status.

WHAT WE'D BUILD
Same as A minus the popover summary section + its model/presenter additions.

THE BET
Users don't need at-a-glance trust status; opening a window when they care is enough.

REVERSAL COST
Easy — can add the popover summary later (= Approach A).

WHAT WE'RE NOT BUILDING
Same exclusions as A, plus no inline summary.

INDUSTRY PRECEDENT
Tools that bury status one click deep [UNVERIFIED].

---

## Comparison matrix

| Criterion | A — Badge + window | B — Window only |
|---|---|---|
| AC1 overview (read-only, labelled) | STRONG — glanceable in popover + window | PARTIAL — only in the window |
| AC2 per-file provenance | STRONG — in the window | STRONG — in the window |
| AC3 background verify (progress/cancel) | STRONG — in the window | STRONG — in the window |
| AC4 read-only / no contract change | STRONG | STRONG |
| AC5 parity via shared runner | STRONG | STRONG |
| Glanceability (the tray's strength) | STRONG | WEAK — one click to see anything |
| Popover surface added | PARTIAL — one summary section | STRONG — one button only |
| Stack alignment | STRONG | STRONG |

## Recommendation
**Approach A.** A menu-bar app's reason to exist is glanceable status; showing "what's tracked / last
recorded" right in the popover (a cheap ledger read) is exactly that, while the heavy re-hash stays
correctly windowed and backgrounded. B is strictly a subset of A — if the summary ever feels like noise
we can drop it, but starting without it gives up the tray's main advantage. Both share the load-bearing
parts (direct read, extracted runner, dedicated window, `DispatchQueue.global().async` verify).
