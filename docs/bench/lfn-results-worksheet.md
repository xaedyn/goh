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
Date run:            __________
Machine / network:   __________ (e.g. home Wi-Fi, RTT to Singapore ~___ ms)

SM5a (LFN win):      governed median = ______ s (IQR ______)
                     static-8 median = ______ s (IQR ______)
                     VERDICT: PASS / FAIL   (PASS = governed median < static median, non-overlapping IQR)

SM2 (no regression): governed median = ______ s   static-8 median = ______ s
                     ratio governed/static = ______   (PASS = ≤ 1.05)
                     VERDICT: PASS / FAIL

SM1 (convergence):   governed converged N on LFN = ____ (expect > 8)
                     governed converged N on saturated = ____ (expect ≤ 4)
                     VERDICT: PASS / FAIL

Config/chunkSize tuning applied? ____ (if yes, record new values + which SM drove the change)

OVERALL: P1–P4 ready to PR?  YES / NO / NEEDS-TUNING
Notes / anomalies / quarantined runs:
  __________________________________________________________________
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
