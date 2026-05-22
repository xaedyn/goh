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

**Saturated** — a real file on a fast CDN that fills the pipe on one
connection. `goh`, `aria2c`, and `curl` converge here, and that convergence is
the *correct* result, not a regression.

> Default: `https://dl.google.com/android/repository/android-ndk-r27c-linux.zip`
> (633 MiB) — the Android NDK r27c archive.
> **Why:** the saturated case asks one question — once a single connection
> already fills the link, does `goh`'s range-parallel overhead *cost* anything?
> Answering it needs a file served fast enough to saturate the pipe on one
> stream. `dl.google.com` is a hyperscale CDN that does that on a 300+ Mbps
> link; the NDK archive is large, static, permanently hosted (Google keeps every
> released NDK), and served directly — no redirect — with `Accept-Ranges:
> bytes`. Probed 2026-05-22: `200`, ranged request `206`.
>
> **Considered — a synthetic speed-test endpoint** (`speed.cloudflare.com/__down`
> and the like), the original default. A generator removes all server-side
> variability, which made it the obvious first pick — but it has no underlying
> file to range *into*, so it rejects any request carrying a `Range` header:
> `speed.cloudflare.com/__down` returns `403 Forbidden` to a ranged request
> (probed 2026-05-22, with and without a browser `User-Agent`), and a
> range-parallel downloader cannot run against it at all. The saturated workload
> must be a real file. The modest server-side variability of a CDN-hosted file
> is the price of measuring the actual question; the `RUNS`-median is the
> smoothing, so the file is sized large enough that the transfer dominates
> per-run fixed overhead.

**Amenable** — a host that **rate-limits per connection** (or is latency-bound),
so N connections move toward N times the bytes. This is the load-bearing
workload: the ≥ 10 % target is measured here.

> Default: `https://archive.org/download/his_girl_friday/his_girl_friday.mp4`
> (~549 MiB) — *His Girl Friday* (1940), public domain, in the Internet
> Archive's `feature_films` collection.
> **Why:** the Internet Archive serves items from its own infrastructure, not a
> hyperscale CDN, so single-connection throughput is genuinely modest — the
> per-connection ceiling the amenable case needs — and the catalog is permanent,
> so the item does not rotate. Probed 2026-05-22: `200`, `Accept-Ranges: bytes`,
> ranged request `206`.
>
> The `archive.org/download/<id>/<file>` form is a *catalog* URL — it issues one
> 302 to whichever data node currently holds the item. That redirect is fine,
> and the distinction matters: the data-node URL (`ia*.us.archive.org/…`) is
> *not* stable — it varied between two probes seconds apart — so the catalog URL
> is the stable form, and one redirect is the price of that stability. It is
> **not** the redirect *chain* a distro-mirror network produces: the catalog 302
> is deterministic, so every tool on every run follows the same logic to the
> same effective node; a mirror redirector can land different tools on different
> mirrors and confound the comparison. One predictable redirect is fine; a
> nondeterministic redirect chain is not.
>
> **This is a researched candidate, not a guaranteed-amenable URL** —
> per-connection limiting is an undocumented, route-dependent server property
> that cannot be frozen into a URL. A live probe confirms only that the URL is
> reachable and honours `Range`; the amenability property itself is checked at
> run time (next).

### Amenability is verified at run time — not assumed

`competitive.sh` self-checks the amenable workload: after the runs it compares
single-stream `curl` against 8-connection `aria2c`. If `aria2c` is **not** at
least 1.5× faster, the workload was not genuinely per-connection-limited — the
"amenable" run silently became a second saturated run — and the harness prints a
**WARN**: the ≥ 10 % comparison is not valid against that URL.

If the default `AMENABLE_URL` WARNs, override it with a **fallback candidate**
(below) and re-run.

Record the actual URLs, the machine (`uname -mrs`, CPU, link speed), and the
network conditions alongside the numbers — the harness prints the first two.

### Fallback candidates — if the amenable default WARNs

Per-connection limiting cannot be guaranteed (above), so the amenable default
can WARN. When it does, override `AMENABLE_URL` with another candidate and
re-run. Sources, ranked by structural fit:

1. **Another `archive.org` item** — a different public-domain item ≥ 500 MB
   (`archive.org/download/<id>/<file>`), for the same structural reason the
   default is one: Internet Archive infrastructure rather than a hyperscale CDN,
   so single-connection throughput is genuinely modest, and a permanent catalog.
   The `feature_films`, `opensource_movies`, and `audio` collections all hold
   items in range.
2. **A community / academic Linux-distro mirror** — not the CDN-fronted primary;
   a current ISO (~1–2 GB) from a mirror the WARN check confirms is limited.
   Prefer a direct mirror URL — a mirror *redirector* is the nondeterministic
   redirect chain the amenable rationale above warns against.
3. **A large GitHub release asset** (≥ 500 MB) — GitHub serves release downloads
   via a CDN where per-connection / per-IP throttling is commonly observed.

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
