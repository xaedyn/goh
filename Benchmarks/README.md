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
> is the price of measuring the actual question; the file is sized large enough
> that the transfer dominates per-run fixed overhead, and whether it genuinely
> saturates a single connection is verified at run time (below).

**Amenable** — a host that **rate-limits per connection** (or is latency-bound),
so N connections move toward N times the bytes. This is the load-bearing
workload: the ≥ 10 % target is measured here.

> Default: `https://saimei.ftp.acc.umu.se/debian-cd/current/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso`
> (~791 MiB) — the Debian 13.5.0 net-install ISO, served directly from
> `saimei`, a machine in the Umeå University FTP-cluster mirror.
> **Why:** academic distro mirrors commonly cap per-connection bandwidth so
> volunteer-funded uplinks stay fair across users; that per-connection ceiling
> is the amenable case's load-bearing property. The URL is the direct mirror
> host — zero redirects, not a mirror redirector that would route different
> connections to different backends nondeterministically and confound the
> comparison. Probed 2026-05-22: `200`, `Accept-Ranges: bytes`, ranged request
> `206`.
>
> **Considered — an `archive.org` item.** The prior amenable default
> (`his_girl_friday.mp4` in `feature_films`) was rotated out: against
> `URLSession`'s HTTP/2 multiplexed streams the Internet Archive served 1–2
> streams at full speed and rate-limited the remaining 6 to ~430 KB/s,
> reproducible across machines. `aria2c` on HTTP/1.1 with separate TCP
> connections was unaffected on the same workload, but `URLSession` does not
> cleanly expose a knob to force the equivalent connection model — so the
> workload was unmeasurable as "amenable" against `goh` in particular. `goh`
> single-stream-vs-`aria2c`-multi-stream comparison was distorted, not by
> `goh`'s engine, but by `URLSession`-vs-archive.org's stream distribution.
> archive.org items remain a reasonable fallback for non-`URLSession`
> consumers and for cross-host diagnostic comparison.
>
> **This is a researched candidate, not a guaranteed-amenable URL** —
> per-connection limiting is an undocumented server property that cannot be
> frozen into a URL. A live probe confirms only that the URL is reachable and
> honours `Range`; the amenability property itself is checked at run time
> (next).

### Each workload's assumption is verified at run time — not assumed

`competitive.sh` self-checks **both** workloads after their runs, each time
comparing 8-connection `aria2c` against single-stream `curl`. `aria2c` — a
mature parallel downloader — is the reference, so the check measures the
*workload's* property, not `goh`'s performance.

**Amenable.** If `aria2c` is **not** at least 1.5× faster than single-stream
`curl`, the workload was not genuinely per-connection-limited — the "amenable"
run silently became a second saturated run — and the harness prints a **WARN**:
the ≥ 10 % comparison is not valid against that URL.

**Saturated.** If `aria2c` is **more than ~20 % faster** than single-stream
`curl` (`curl ÷ aria2c` median above 1.2), one connection did *not* already
fill the pipe — parallelism found headroom to exploit — so the workload was not
genuinely saturated and the parity target is meaningless against it; the
harness prints a **WARN**. The check is one-sided, the same shape as the
amenable check: it fires on the unambiguous signal (parallelism clearly
helped), not on `aria2c` merely being a little slower than `curl`, which is the
expected saturated outcome.

If a default WARNs, override that workload's URL and re-run — `AMENABLE_URL`
with a **fallback candidate** (below); `SATURATED_URL` with another real file
on a fast CDN.

Record the actual URLs, the machine (`uname -mrs`, CPU, link speed), and the
network conditions alongside the numbers — the harness prints the first two.

### Fallback candidates — if the amenable default WARNs

Per-connection limiting cannot be guaranteed (above), so the amenable default
can WARN. When it does, override `AMENABLE_URL` with another candidate and
re-run. Sources, ranked by structural fit:

1. **Another community / academic Linux-distro mirror** — a different ISO from
   a different mirror, or the same mirror's larger DVD ISO. Direct host URLs
   only (not mirror *redirectors*). Volunteer-funded academic mirrors commonly
   per-connection-limit, which is the amenable property the comparison needs.
2. **A large GitHub release asset** (≥ 500 MB) — GitHub serves release
   downloads via a CDN where per-connection / per-IP throttling is commonly
   observed.
3. **An `archive.org` item** — single-connection throughput is genuinely
   modest, served from Internet Archive infrastructure rather than a
   hyperscale CDN, and the catalog is permanent. Caveat: against
   `URLSession`-based clients the Archive's HTTP/2 stream distribution is
   uneven and inflates the apparent `goh`-vs-`aria2c` ratio compared to other
   amenable hosts (see the amenable rationale above). Useful for cross-host
   diagnostic comparison; misleading as the load-bearing amenable workload.

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
