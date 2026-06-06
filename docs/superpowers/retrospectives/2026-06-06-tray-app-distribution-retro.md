---
date: 2026-06-06
feature: tray-app-distribution
type: pipeline-retrospective
---

# Pipeline Retrospective — Tray App Distribution

## Adversarial Review Categories That Fired

### Spec Review
- **Round 1 (5 block issues):**
  - Cat 1 Product Validity — notification subscription was popover-scoped → feature dead
    while the menu is closed. Fixed: always-on subscription at the composition root (§4).
  - Cat 3 + 8 Completeness/Interface Contracts — transition-detection state ownership
    undefined. Fixed: pure `GohNotificationTransitionDetector` with nil-seed suppression,
    `job.id` dedup, drop-on-disappear (§7.2).
  - Cat 6 Technical Feasibility — `LSMinimumSystemVersion=26.0` vs PKG `os=26.5`
    contradiction. Fixed: single-sourced to the PKG value; Package.swift gap declared
    out of scope (§2).
  - Cat 6 — login-item infeasible on debug bare binary. Fixed: `.unsupported` case;
    AC3 bundle-only (§6/§7.3).
  - Cat 8 — interface contracts were prose, not signatures. Fixed: full Swift
    signatures (§7).
- **Round 2:** APPROVED — all 10 categories PASS. Concurrency soundness verified against
  the GohMenuBar `nonisolated`-Sendable convention.

### Plan Review
- **Round 1 (2 block issues, both Task P2-3):**
  - Cat 3/10 — `LiveNotificationService` `nonisolated async` methods touched non-Sendable
    `UNUserNotificationCenter` → compile error. Fixed: methods MainActor-isolated.
  - Cat 1/7 — `@Published.sink` synchronous replay of `[]` defeated nil-seed suppression
    → history-replay notifications every launch. Fixed: replaced Combine with a sync
    `onProgressSnapshots` hook + testable `GohNotificationCoordinator`.
  - Also collapsed P2-1's three competing wiring snippets to one (advisory C).
- **Round 2 (2 block issues, both in the new coordinator test block):** `.running`
  (non-existent JobState case) → `.active`; undefined `makeSnapshot` → self-contained
  helper added. Production design + both round-1 fixes compile-verified correct by the
  reviewer. Escalation surfaced to the user; user approved proceeding.

## Approach Selected

**Chosen:** B — All-in-One PKG.
**THE BET:** Versioning the engine and the tray app together is acceptable for the tester
phase (they move in lockstep anyway).
**Rejected:** A — Companion DMG (two-step install + app-before-engine footgun; reversible
to add later from the same assembled `.app`).

## Design Validation Changes

5 gaps fixed at design time: notification spam scoped to terminal events only;
authorization-denied no-op; first-run prompt once; `SMAppService.requiresApproval`
surfaced honestly; `.app` payload is `goh-menu` only (no bundled CLI/daemon duplicates).
Key safety property: notifications post locally from the existing stream → **no new IPC
surface**.

## Open Risks Not Resolved

- **External dependency:** Gatekeeper-clean tester install requires the pending Apple
  Developer ID (signing + notarization). The build is structured signing-ready; the
  wrapping step runs when the cert lands. Until then, local debug/dogfood testing only.
- **Unverified research claims (acceptable):** ad-hoc signing sufficing for *dev*
  notification delivery; `@AppStorage` name — both isolated from the testable contract.
- **Advisory carried into implementation:** add `nonisolated public` to the two new
  protocols for module consistency (gate-4 review will confirm).
