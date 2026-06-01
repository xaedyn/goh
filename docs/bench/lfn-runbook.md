# LFN Benchmark Runbook — SM5a + SM2 gate

The `goh-bench lfn` subcommand proves the in-flight governor's headline: on a long-fat network it
beats static N=8 (SM5a), and on a saturated path it does not regress (SM2). **Real network / manual —
not in CI.** All commands need the Xcode toolchain prefix:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## How the arms work

- **Governed arm** — no `--static-n`: the engine runs with the live `ParallelismGovernor` (default-on).
- **Static control arm** — `--static-n 8`: passes the explicit-connection-count channel, which **disables
  the governor** and pins N at 8 for the whole transfer. This is the apples-to-apples baseline.

Each run downloads the target to a temp file, times wall-clock, verifies completion, then prints a JSON
line: `{"url","mode","runs","medianSeconds","iqrSeconds","allSeconds":[…]}`. Per-run timings go to stderr.

## SM5a — single-edge win on a sourced LFN target (the headline)

Target: `https://sin-speed.hetzner.com/1GB.bin` (Singapore, real ≥150 ms RTT, no per-stream throttle).

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run goh-bench lfn --url https://sin-speed.hetzner.com/1GB.bin --runs 5 --output governed.json
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run goh-bench lfn --url https://sin-speed.hetzner.com/1GB.bin --runs 5 --static-n 8 --output static8.json
```

**Accept (SM5a):** `governed.json` `medianSeconds` **<** `static8.json` `medianSeconds`, with
**non-overlapping IQR** (i.e. `governed.median + governed.iqr/2 < static8.median − static8.iqr/2`,
or simply confirm the two medians differ by more than either IQR). ≥5 runs each.

## SM2 — no saturated regression (the no-ship guard)

Use a **saturated / last-mile** target where parallelism can't help — either the confirmed dummynet pipe
(below) or a known-throttling CDN asset. The governor should converge low (N≤4) and not lose to static N=8.

### Saturated target via dummynet (deterministic, confirmed on macOS 26.5 / arm64)

Serve a 1 GB file over loopback (e.g. `python3 -m http.server` or nginx on `127.0.0.1:8080`), then shape it
to a saturated last-mile (high bandwidth, low RTT, no loss — so a single flow already fills it):

```
# Requires sudo (run via the ! prefix in-session):
sudo dnctl pipe 1 config bw 200Mbit/s delay 5 plr 0
# (route loopback :8080 traffic through pipe 1 with a PF anchor, or shape the interface as needed)

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run goh-bench lfn --url http://127.0.0.1:8080/1GB.bin --runs 5 --output governed-sat.json
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run goh-bench lfn --url http://127.0.0.1:8080/1GB.bin --runs 5 --static-n 8 --output static8-sat.json

sudo dnctl pipe 1 delete
```

For an LFN-with-loss profile (to exercise the governor probing *up*), use
`sudo dnctl pipe 1 config bw 50Mbit/s delay 150 plr 0.005` (the profile confirmed in P1).

**Accept (SM2):** `governed-sat.json` `medianSeconds` **≤ 1.05 ×** `static8-sat.json` `medianSeconds`
(≤5% regression). A regression >5% is the **rollback trigger** — do not ship; diagnose the governor's
knee detection (likely `kneeGainThreshold`/`rttBufferbloatFactor`/`reproBeCadence` or `chunkSize` tuning).

## SM1 — regime-aware convergence (trace confirmation)

Run either arm with `GOH_ENGINE_TRACE=1` and confirm the governor lines show probe→cruise and the converged
N (saturated ⇒ converged N ≤ 4; LFN ⇒ converged N > 8):

```
GOH_ENGINE_TRACE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run goh-bench lfn --url <target> --runs 1 2>&1 | grep '^governor '
```

## Quarantine policy (Advisory A3)

A single anomalous run (a transient host blip or network hiccup) is **re-run and discarded** if the re-run
falls within IQR. Never treat one outlier as a regression. Document any quarantined run in the P4 artifact.

## Tuning loop

`Config.default` (`steadyStateWindow`, `kneeGainThreshold`, `rttBufferbloatFactor`, `reproBeCadence`,
`rateAlpha`) and `chunkSize` are first-cut values. If SM5a's win is marginal or SM2 regresses, adjust them
against the measured medians and re-run. Record the final values + the numbers in
`docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase4.md`.
