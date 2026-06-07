---
date: 2026-06-07
feature: tray-download-dashboard
type: acceptance-criteria
---

# Acceptance Criteria — Professional Download Dashboard (tray)

Scope (confirmed): one slice — fix the no-row bug, fix the climbing-speed metric (rolling rate), and a
rich "full professional dashboard" per-download display; keep recently-completed visible.

**AC1 (downloads are visible).** When ≥1 download exists in any state, the dashboard renders one row per
download with non-zero height (no collapse); the "N active" header count is consistent with the visible
rows. Signal: with one active job in the snapshot, exactly one visible row renders (height > 0).

**AC2 (rolling, honest speed).** The displayed per-download speed reflects a recent rolling window of
throughput, not the cumulative average since start — it stabilizes near the true rate on a steady transfer
and drops when the transfer slows, instead of monotonically climbing. Signal: a unit test feeding a
varying-throughput byte/timestamp sequence to the rate function yields a windowed rate (e.g. ≈ recent
delta-bytes/delta-time), NOT total-bytes/total-elapsed; aggregate header speed uses the same rolling basis.

**AC3 (rich per-download info).** Each download shows: a visual progress bar, downloaded/total + percent,
the rolling speed, ETA (when total size is known) and elapsed, the connection count (actual), and state.
Signal: these fields render per row, sourced from `JobSummary` (incl. `actualConnectionCount`,
`bytesTotal`, `createdAt`); ETA shows "unknown"/omitted when `bytesTotal` is nil.

**AC4 (completed/failed stay, with status).** Completed and failed downloads remain visible (until the
user removes them) showing final state + final size, and for completed files their provenance/verify
status when available (via the ledger join). Signal: a `.completed` job shows "Completed" + size + a
recorded/verified indicator; a `.failed` job shows the failure (error/retry) state.

**AC5 (no contract/governor regression).** `protocolVersion` and the `JobProgress`/`JobSummary` wire
shapes are unchanged (`bytesPerSecond` stays a present field; only its computed value may change), the BBR
governor's separate windowed sampling is untouched, and `swift build -warnings-as-errors` + the full test
suite pass. Signal: no frozen-format diff; governor sampling code unchanged; suite green.
