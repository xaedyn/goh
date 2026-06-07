---
date: 2026-06-06
feature: tray-richer-add
type: acceptance-criteria
---

# Acceptance Criteria — Richer Add in the Tray

Scope: let the tray app's add-a-download flow optionally choose a **destination folder**
and a **connection count (1–16)**, surfacing existing `AddRequest` fields the daemon already
honors. Pure GUI change — no wire/protocol change.

**AC1 (destination).** When the user picks a destination folder in the tray's add flow, the
resulting `AddRequest.destination` carries that folder; when they do NOT pick one,
`AddRequest.destination` is `nil` (so the daemon's `~/Downloads` default is preserved).
Signal: the captured `AddRequest` has the chosen path when picked, and `nil` otherwise.

**AC2 (connection count).** When the user pins a connection count, `AddRequest.connectionCount`
carries that `UInt8`; when left at "default", `AddRequest.connectionCount` is `nil` (so the
bandit/governor runs — it is NOT forced to 8). Signal: captured `AddRequest.connectionCount`
equals the pinned value, or is `nil` for default.

**AC3 (range safety).** The connection-count control cannot emit a value outside 1–16 (CLI
parity). Signal: the UI clamps/limits to 1...16; no path produces 0 or >16.

**AC4 (no regression to the default path).** The existing default add (no folder, no pinned
count) still produces `AddRequest(url:)` with `nil` destination and `nil` connectionCount —
existing add-path tests pass unchanged. Signal: `GohMenuViewModelTests` default-add assertions
unchanged and green.

**AC5 (no contract change).** `protocolVersion` and the `AddRequest` wire shape are unchanged
(the GUI only uses existing fields); `swift build -warnings-as-errors` clean and the full test
suite green. Signal: no diff to `Sources/GohCore` wire/contract; build + tests pass.
