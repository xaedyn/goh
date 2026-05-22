# Benchmarks

The Slice 3b benchmark harness. Two measurements, with different reproducibility
profiles, so they run differently.

## 1. Competitive benchmark — `goh` vs `aria2c` vs `curl`

`competitive.sh` times each tool downloading the same file, `RUNS` times per
workload, and reports the median wall-clock. It needs a real network, so it is
**not** a CI job — it is run by hand and the numbers recorded in the 3b PR.

```sh
swift build -c release
brew install aria2          # if not already present
./Benchmarks/competitive.sh           # uses the committed default workloads
```

The default workload URLs are baked into `competitive.sh`; override either with
`AMENABLE_URL=<url>` / `SATURATED_URL=<url>` if a default has gone stale.

### Two workloads, deliberately

Range-parallelism only helps when one connection does not already saturate the
client's bandwidth — so the benchmark needs both cases.

**Saturated** — a fast CDN that fills the pipe on one connection. `goh`,
`aria2c`, and `curl` converge here, and that convergence is the *correct*
result, not a regression.

> Default: `https://speed.cloudflare.com/__down?bytes=536870912` (512 MiB).
> **Why:** Cloudflare's anycast CDN serves the `__down` speed-test endpoint at
> full link speed on a single connection — probed 2026-05-22, 318 Mbps
> single-stream. A synthetic always-fast endpoint is *ideal* here: it removes
> server-side variability, isolating the one question the saturated case asks —
> does `goh`'s range-parallel overhead cost anything once one connection already
> fills the pipe? (Very large `bytes` values are rejected — keep it ≤ ~1 GiB.)

**Amenable** — a host that **rate-limits per connection** (or is latency-bound),
so N connections move toward N times the bytes. This is the load-bearing
workload: the ≥ 10 % target is measured here.

> Default: `https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2`
> (~350 MiB; the `latest` path is stable across point releases).
> **Why:** the `cloud.debian.org` redirector hands the request to a community /
> academic mirror, and community mirrors commonly cap per-connection bandwidth
> — probed 2026-05-22, it resolved to a `umu.se` mirror at ~23 MB/s
> single-stream, below the test link's ceiling. **This is a researched
> candidate, not a guaranteed-amenable URL** — per-connection limiting is a
> server property that is undocumented, changes over time, and varies by route,
> so it cannot be frozen into a URL. The harness verifies it at run time (next).

### Amenability is verified at run time — not assumed

`competitive.sh` self-checks the amenable workload: after the runs it compares
single-stream `curl` against 8-connection `aria2c`. If `aria2c` is **not** at
least 1.5× faster, the workload was not genuinely per-connection-limited — the
"amenable" run silently became a second saturated run — and the harness prints a
**WARN**: the ≥ 10 % comparison is not valid against that URL.

If the default `AMENABLE_URL` WARNs, pick another and re-run. Candidate sources,
ranked by structural fit:

1. **`archive.org` items** — served from the Internet Archive's own
   infrastructure, not a hyperscale CDN; single-connection throughput is
   genuinely modest and the catalog is permanent (files do not rotate). Any
   public-domain item ≥ 500 MB (`archive.org/download/<id>/<file>`).
2. **A community / academic Linux-distro mirror** — not the CDN-fronted primary.
   A current ISO (~1–2 GB) from a mirror the WARN check confirms is limited.
3. **A large GitHub release asset** (≥ 500 MB) — GitHub serves release downloads
   via a CDN where per-connection / per-IP throttling is commonly observed.

Record the actual URLs, the machine (`uname -mrs`, CPU, link speed), and the
network conditions alongside the numbers — the harness prints the first two.

### Targets — 3b's definition of done

- **Amenable:** `goh` beats `curl` (single-stream) decisively, and beats
  `aria2c` by **≥ 10 %** median wall-clock at equal connection count. If the
  bar is missed, the result is surfaced as a finding — what bottlenecked, and
  whether to tune in 3b or accept parity for v0.1 — not a quietly relaxed target.
- **Saturated:** `goh` within measurement noise of both — parity. The honest
  check is that parallel overhead does not make `goh` *lose* to `curl`.

## 2. Hashing benchmark — unified read-back vs inline

`goh-bench hash-overhead <sizeMiB>` measures the chunk assembler's read-back
hashing path against an inline hash — the unified-path-vs-3a-inline comparison.
It is deterministic (fixed file size, hardware SHA-256, no network), so it runs
in CI on the `macos-26` runner.

```sh
swift run -c release goh-bench hash-overhead 256
```

Reading the file back to hash it (rather than hashing inline during the write,
which range-parallel arrival order makes impossible) was expected to be
negligible — the re-read is page-cache-hot and SHA-256 is hardware-accelerated.
Measured on the `macos-26` runner, 256 MiB: −9.6 % — the unified path is, within
noise, slightly *faster* than inline. See the 3b PR description.
