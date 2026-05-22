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
RUNS=3 \
  AMENABLE_URL=<url> \
  SATURATED_URL=<url> \
  ./Benchmarks/competitive.sh
```

### Two workloads, deliberately

Range-parallelism only helps when one connection does not already saturate the
client's bandwidth — so the benchmark needs both cases:

- **Amenable** — a large file (~1 GB) from a host that **rate-limits per
  connection** or is latency-bound, so eight connections move eight times the
  bytes. Many distribution mirrors and file hosts cap per-connection bandwidth;
  a good `AMENABLE_URL` is any file where a single-stream `curl` runs visibly
  slower than the link can carry.
- **Saturated** — a large file (~1 GB) from a **fast CDN** that fills the pipe
  on one connection. Here `goh`, `aria2c`, and `curl` converge — and that
  convergence is the *correct* result, not a regression. A CDN-backed Linux
  distribution ISO is a representative `SATURATED_URL`.

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
Measured on the macos-26 runner: see the 3b PR description.
