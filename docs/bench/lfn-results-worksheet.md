# P4 Benchmark Worksheet — fill this in during the test session

**Purpose:** run the in-flight-parallelism benchmarks (Task 19), record the numbers, and leave a clean
record for the next session. The companion `docs/bench/lfn-runbook.md` has the rationale; THIS file is the
do-it-and-record sheet. When done, the filled "RESULTS SUMMARY" block below is what the next Claude session
reads to decide whether P1–P4 can ship.

> **Two gotchas the smoke test caught — don't lose time to them:**
> 1. **`GOH_ENGINE_TRACE` does NOT survive `swift run`.** Build once and run the **binary directly** (the
>    `$BIN` recipe below). `swift run` still works for the plain SM5a/SM2 JSON, but use `$BIN` for everything
>    so the trace is available too.
> 2. **The governor only engages on a `Range`-honoring server.** `python3 -m http.server` returns `200`
>    (no `Range`) → silently single-connection → governor bypassed. Use the embedded `rangeserver.py` below
>    (or nginx) for the LOCAL test, and a real LFN target (Hetzner) for SM5a.

---

## ★ RESULTS SUMMARY (fill in — the next session reads THIS first)

```
Date run:            2026-06-02
Machine / network:   home Wi-Fi, ~620/55 Mbps. Target: OVH France (proof.ovh.net/files/1Gb.dat),
                     RTT ~105 ms, single-conn ~19 MB/s vs ~77 MB/s link (one conn fills ~25% → LFN confirmed).
                     NOTE: original target sin-speed.hetzner.com RATE-LIMITS parallel ranges (6/8 → HTTP 429),
                     unusable for SM5a. OVH France allows 8/8 parallel (206), https, honors Range. New target.

--- BEFORE governor redesign (broken: per-worker 5% steady-state gate, inert) ---
SM5a (LFN win):      governed median = 26.260 s (IQR 4.057)   runs [27.8,26.3,31.2,23.8,15.8]
                     static-8 median = 21.870 s (IQR 4.083)   runs [24.3,22.1,21.9,18.0,17.4]
                     VERDICT: FAIL — governed ~20% SLOWER; governor never left probe (inert at seed N=8).

--- AFTER governor redesign (aggregate-rate hill-climb; commit 2026-06-02) ---
SM5a (LFN win), n=5: governed median = 19.418 s (IQR 1.869)   runs [16.9,18.8,20.7,30.2,19.4]
                     static-8 median = 21.324 s (IQR 5.114)   runs [23.1,18.0,21.3,29.6,16.3]
                     ~9% median win but IQR overlaps — re-ran larger + denoised to clinch (below).

--- AFTER tuning (settleSamples 8, kneeGain 0.07, 0.25s min sample window) — larger set n=9 ---
SM5a (LFN win), n=9: governed median = 20.358 s (q1 19.01 q3 21.83)  range [13.9, 22.6]
                     static-8 median = 20.714 s (q1 19.52 q3 23.82)  range [17.4, 26.0]
                     VERDICT: NO CLEAN WIN ON THIS TARGET. governed ≈ static-8 (1.7% median, IQR overlaps).
                     ENVIRONMENT LIMIT, not a governor flaw: raw curl aggregate throughput at 8 vs 16
                     parallel conns is the SAME (~57 MB/s ceiling, ±2× variance) — 8 connections already
                     saturate the path/link ceiling, so 16 has zero headroom to win. The governor DOES
                     converge to 16 correctly (trace: dwell@8 → addWorkers → dwell@16 → commit(16) →
                     cruise@16, no detour) and shows NO REGRESSION (governed marginally faster).
                     A clean SM5a win needs a path where a few connections are BDP-limited well BELOW the
                     throughput ceiling — i.e. higher RTT (Asia, ~160ms+) AND an uncapped, high-ceiling
                     server. OVH France (~105ms, ~57MB/s cap) and this Wi-Fi link cannot exercise that
                     regime. Realistic proving ground: a self-hosted far VPS (the plan's ~$5/mo option)
                     or a faster local link.

SM2 (no regression): NOT RUN YET (run after SM5a tuning settles).
                     VERDICT: —

SM1 (convergence):   governed converged N on LFN = 16  (probe: dwell@8 → addWorkers(8) → dwell@16 →
                     commit(16) → cruise@16). Correct adaptive behavior confirmed via trace. VERDICT: PASS.

Config tuning applied? Governor REDESIGNED (not just tuned): replaced the per-worker steady-state
                     detector with an aggregate-delivery-rate hill-climb (settleSamples=12, kneeGain=0.10,
                     reprobeCadence=40, rateAlpha=0.3 — first-cut). settleSamples may drop for faster
                     convergence (less probe overhead = wider win margin).

OVERALL: P1–P4 ready to PR?  NEEDS-TUNING (regression fixed → median win; clinch the clean win first)
Notes / anomalies / quarantined runs:
  - ROOT CAUSE (confirmed via instrumentation): old governor's allWorkersInSteadyState never returned
    true on a real network — 0/120 evaluations steady. Three compounding causes: 5% deviation threshold
    (real jitter 10–206%), slot-0 sample starvation, and an off-by-one (decided on liveWorkers = N−1).
    Governor sat inert at seed N=8 the entire download. FIXED by redesign + true aggregate signal +
    passing operating targetN.
  - Hetzner target rate-limits parallel connections (429); switched SM5a target to OVH France
    (proof.ovh.net/files/1Gb.dat — 8/8 parallel 206, ~105ms RTT, single-conn ~19MB/s vs ~77MB/s link).
  - Wi-Fi added real variance; one ~30s outlier per arm (env blip). Median is robust to it (~9% win).
  - PRODUCT GAP flagged separately: engine HARD-FAILS (httpStatus) when a server 429s a parallel range,
    instead of backing off. Future design pass.
```

---

## Step 0 — build once, get the binary path

```bash
cd ~/claude/goh   # adjust to your repo path
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
BIN="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --show-bin-path)/goh-bench"
echo "$BIN"   # sanity: should print .../debug/goh-bench
```

The `lfn` subcommand writes per-run timings to **stderr** and one JSON line to **stdout** (and to
`--output <file>` if given). JSON shape:
`{"url","mode","runs","medianSeconds","iqrSeconds","allSeconds":[…]}`.

---

## Step 1 — SM5a: the headline win (real long-fat network)

Target honors `Range`, real ≥150 ms RTT, no per-stream throttle. ~1 GB × 5 × 2 = ~10 GB of transfer — give it
time and a stable connection.

```bash
# Governed (the in-flight governor runs):
"$BIN" lfn --url https://sin-speed.hetzner.com/1GB.bin --runs 5 --output ~/goh-bench-governed.json
# Static control arm (governor OFF, pinned at N=8):
"$BIN" lfn --url https://sin-speed.hetzner.com/1GB.bin --runs 5 --static-n 8 --output ~/goh-bench-static8.json

cat ~/goh-bench-governed.json; echo; cat ~/goh-bench-static8.json
```

**Paste the two JSON lines here:**
```
governed: ____________________________________________________________
static8:  ____________________________________________________________
```
**Accept:** governed `medianSeconds` < static8 `medianSeconds`, AND non-overlapping IQR
(governed.median + governed.iqr/2  <  static8.median − static8.iqr/2). Record the verdict in the summary.

**Quarantine:** if ONE run is a clear outlier (a network blip), re-run that arm and discard the outlier if the
re-run sits within IQR. Note any quarantined run in the summary. Never call a single blip a regression.

---

## Step 2 — SM1: confirm the governor actually converges (trace)

Run ONE governed LFN download with the trace on (must use `$BIN`, not `swift run`):

```bash
GOH_ENGINE_TRACE=1 "$BIN" lfn --url https://sin-speed.hetzner.com/1GB.bin --runs 1 2>&1 | grep 'governor '
```

You'll see lines like `[goh-trace t=…] governor phase=probe decision=addWorkers(2) N=4 host=…` then a
`commit(n)` and `cruise`. **Record the converged N** (the last `commit`/`cruise` N) in the summary — on a real
LFN path it should climb **> 8**. (On a fast/saturated link it converges **low** — that's correct; the smoke
test on loopback gave `commit(1)`.)

---

## Step 3 — SM2: no regression on a saturated link (local, deterministic)

The saturated case = a fast last-mile where one flow already fills the pipe, so extra connections can't help
(and naive static-8 can even hurt via bufferbloat). We make it deterministic with a local `Range`-honoring
server + dummynet shaping. **Needs sudo** (run the `sudo` lines via the `!` prefix in a Claude session, or in
your own terminal).

### 3a — make a 1 GB file + start the Range server (NOT python's http.server)

```bash
WORK="$(mktemp -d)"; dd if=/dev/urandom of="$WORK/1GB.bin" bs=1m count=1024
cat > "$WORK/rangeserver.py" <<'PY'
import http.server, os
BASE = os.path.dirname(os.path.abspath(__file__))
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        path = os.path.join(BASE, "1GB.bin"); size = os.path.getsize(path)
        rng = self.headers.get('Range')
        if rng and rng.startswith('bytes='):
            s, e = rng[6:].split('-'); start = int(s); end = int(e) if e else size - 1
            length = end - start + 1
            self.send_response(206)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.send_header('Content-Length', str(length))
            self.send_header('Accept-Ranges', 'bytes'); self.end_headers()
            with open(path, 'rb') as f: f.seek(start); self.wfile.write(f.read(length))
        else:
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(size))
            self.send_header('Accept-Ranges', 'bytes'); self.end_headers()
            with open(path, 'rb') as f: self.wfile.write(f.read())
http.server.ThreadingHTTPServer(('127.0.0.1', 8079), H).serve_forever()
PY
( cd "$WORK" && python3 rangeserver.py & echo "server PID $!" )
# sanity — must say "206 Partial Content" and show Content-Range:
curl -s -D - -r 0-1048575 -o /dev/null http://127.0.0.1:8079/1GB.bin | grep -iE 'HTTP/|Content-Range'
```

### 3b — shape it saturated with dummynet (sudo)

`dnctl` creates the pipe; `pfctl` routes loopback :8079 into it. (Confirmed on macOS 26.5 / arm64.)

```bash
# Saturated last-mile: high bandwidth, tiny delay, no loss → one flow fills it.
sudo dnctl pipe 1 config bw 500Mbit/s delay 2 plr 0
printf 'dummynet in proto tcp from any to any port 8079 pipe 1\ndummynet out proto tcp from any to any port 8079 pipe 1\n' | sudo pfctl -f - -e
# (If pfctl complains, you can skip dummynet and run unshaped — loopback is already ~saturated; note that in the summary.)
```

### 3c — benchmark governed vs static-8 through the shaped local link

```bash
"$BIN" lfn --url http://127.0.0.1:8079/1GB.bin --runs 5 --output ~/goh-bench-governed-sat.json
"$BIN" lfn --url http://127.0.0.1:8079/1GB.bin --runs 5 --static-n 8 --output ~/goh-bench-static8-sat.json
cat ~/goh-bench-governed-sat.json; echo; cat ~/goh-bench-static8-sat.json
```

**Paste the two JSON lines here:**
```
governed-sat: ________________________________________________________
static8-sat:  ________________________________________________________
```
**Accept:** governed `medianSeconds` ≤ **1.05 ×** static8 `medianSeconds` (≤5% regression). A regression
> 5% is the **rollback trigger** — do NOT ship; see Step 4.

### 3d — tear down

```bash
sudo pfctl -d; sudo dnctl pipe 1 delete           # remove shaping
pkill -f rangeserver.py; rm -rf "$WORK"            # stop server + cleanup
```

---

## Step 4 — if SM2 regresses or SM5a's win is marginal: tune, then re-run

The governor's `Config.default` (in `Sources/GohCore/Governor/ParallelismGovernor.swift`) and the engine's
`chunkSize` (in `Sources/GohCore/Engine/DownloadEngine.swift`) are first-cut. Likely knobs:
- **SM2 regresses (governor probes too high on a saturated link):** raise `kneeGainThreshold` (knee fires
  sooner) or lower `rttBufferbloatFactor` (back off on smaller RTT inflation).
- **SM5a win is weak (governor doesn't probe high enough on LFN):** lower `kneeGainThreshold`, raise the hard
  loop cadence, or lower `chunkSize` (more chunks → more reaps → faster adaptation).
- After any change: `swift build` again, re-run the relevant SM. **Record the final values + which SM drove
  the change** in the summary block.

> **Hand this back:** once the summary block is filled, a Claude session can read it and either (a) write the
> P4 artifact `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase4.md` from your
> numbers and prepare the P1–P4 PR, or (b) iterate on tuning if a gate failed. Just say "the benchmark
> results are in docs/bench/lfn-results-worksheet.md."
