# goh — Roadmap

This roadmap has two layers. The **strategic arc** below is the spine — the
phased road from today's engine to the end-state "Personal Asset Manager." The
**version sections** (v0.1, v0.2) beneath it hold the granular per-feature
scope, mapped onto the phases at the end of the arc.

## Strategic arc — the road ahead

### The end-state version: a trust layer, not a transfer layer

The world has `apt` / `brew` / `cargo` / `npm` for software packages but no
equivalent for the AI era's ambient assets — model weights, datasets, samples,
archives, large binaries. Today people improvise with `wget` / `curl` /
`huggingface-cli` plus manual `mv`, with no manifest, no integrity guarantee
across re-downloads, and no source-of-truth lockfile. The end-state `goh` *is* that
missing tool:

```bash
goh add hf://meta-llama/Llama-3-70B-Instruct   # smart-URL adapters
goh add kaggle://datasets/coco/2017
goh sync ./gohfile.toml      # reproducible bulk pull, hash-verified, idempotent
goh verify ~/datasets/       # "is this still exactly what I downloaded?"
goh which ./model.bin        # provenance: source URL, hash, downloaded date
goh diagnose <url>           # engine diagnostics surfaced as a product
```

The cross-domain analog: **`restic` for inbound, with `apt`-style lockfile
semantics.** `restic` taught the world to never trust transfer (content-address
everything); `apt` taught the world to declare dependencies in a manifest. No
download manager has imported either lesson; the end-state `goh` imports both. Once
transfer is fast, the durable product is **integrity + provenance** — a registry
of what's on disk, where it came from, and whether it still matches.

### Strategy in one line

In a category whose incumbents are dead (`aria2` stale since Nov 2023, Motrix
since May 2023) or crashing (Folx), with no active product capital, *"doesn't
die" is itself a strategy.* The moat is **integrity discipline, not transfer
speed**, and the positioning is **"the macOS download daemon for the AI era,"**
not "a faster curl."

### Decision: legit before ship (2026-05-29)

The first **public** release bundles the differentiator and the speed win, not
just the engine. Parity with a dead competitor is a weak headline; "alive,
faster, and uniquely capable" is a strong one — and we are willing to wait for
it. So Phases 1–2 land *before* the public launch in Phase 3.

### The phased road

- **Phase 1 — Trust core** *(the moat's first brick).* `gohfile.toml` +
  `goh sync` + `goh verify` + `goh which`. Declare assets with expected hashes;
  `sync` pulls reproducibly and idempotently (skipping what already matches);
  `verify` confirms on-disk state still matches; `which` answers provenance. The
  hard primitives (streamed SHA-256, atomic persistence, Spotlight provenance)
  already exist — this is mostly a TOML parser plus verbs. **Gate:** freezes an
  on-disk format → starts with a four-round design pass, not code. No credentials
  needed. ~2–4 weeks.

- **Phase 2 — Performance win** *(parity → beats aria2c).* Adaptive per-host
  range scheduling (probe-and-adapt for the optimal connection count per host,
  persisted in `gohd`'s catalog) plus an optional HTTP/3 retry against well-tuned
  QUIC origins. Converts today's saturated parity into a benchmarkable win.
  **Gate:** the per-host record is a frozen on-disk format → design pass first.
  *Honest caveat:* the amenable-workload gap is structural (HTTP/2-multiplex vs
  N-TCP); treat the win as a goal, not a guarantee. ~2–4 weeks, design-heavy.

- **Phase 3 — Public launch** *(now legit).* Sign + notarize the PKG (PR #36
  workflow), open the `xaedyn/homebrew-goh` tap, add SECURITY / CONTRIBUTING /
  CODE_OF_CONDUCT, write the AI-era launch post (naming the category and the
  buried capabilities — `goh diagnose`, `goh doctor`, Spotlight provenance, sleep
  assertion, cellular auto-pause), post to HN + r/macapps + r/commandline +
  r/datahoarder. **Gate:** Apple Developer ID credentials — the one blocker
  outside the code. (Phase 1 alone is a valid earlier launch point if priorities
  change.) ~2 weeks.

- **Phase 4 — Smart-URL adapters** *(realizes the end-state surface).* `hf://`,
  `kaggle://`, and a `yt-dlp -g` handoff, each plugging a major asset source into
  the trust layer and inheriting its audience. Ship as separate releases; let the
  launch audience prioritize which adapter comes first. ~3–4 weeks each.

- **Phase 5 — Platform / end-state polish.** Mirror racing, `goh diagnose` as a
  first-class surface, multi-browser auth (Chrome/Firefox), public menu-bar app,
  `SMAppService` hardening, per-host bandwidth budgets, plugin system. The trust
  layer becomes an ecosystem.

### Sequence

```
v0.1 engine (complete)
   │
   ▼
Phase 1 ─────────► Phase 2 ─────────► Phase 3 ─────────► Phase 4 ─────────► Phase 5
trust core         speed win          LAUNCH (legit)     adapters           platform
gohfile/sync/      adaptive sched.    sign+brew+post     hf:// kaggle://     mirror racing,
verify/which       +HTTP/3 retry      (needs Dev ID)     yt-dlp             plugins, auth…
[design gate]      [design gate]      [credential gate]
```

### How the version sections map to phases

- **v0.1 (below)** = the engine (complete) and the public launch (Phase 3).
- **Phase 1 (trust core)** is new scope, promoted from the private vision memo;
  it lands before launch per the decision above.
- **v0.2 backlog** distributes across phases: adaptive scheduling + HTTP/3 →
  Phase 2; yt-dlp + smart-URL adapters → Phase 4; mirror racing, plugin system,
  multi-browser auth, public menu-bar app, `SMAppService` → Phase 5.

---

## v0.1 — MVP engine (complete) + launch (Phase 3)

The engine is built and hardened; the remaining v0.1 work is the public launch.
The smallest slice that already beats the category for ~80% of real use.

1. `launchd`-managed daemon, distributed via Homebrew with a `service` block.
   Opt-in via `brew services start goh`. First-time `goh <url>` invocation detects
   an unloaded agent and prints the one-line enable command.
2. `goh <url>` — foreground download with live TUI progress, attached to a
   daemon job.
3. `goh add <url>` — background download, returns immediately.
4. `goh ls`, `goh pause`, `goh resume`, `goh rm`, `goh top`.
5. HTTP fetch via `URLSession`. The session negotiates HTTP/1.1 and HTTP/2
   internally; HTTP/3 is not actively opted into for v0.1 (see
   [DESIGN.md §Transport](DESIGN.md#http3--tried-and-reverted-for-v01)).
6. Single-source download with range-based parallelism (8 connections default,
   tunable).
7. Resume after interrupt, with checkpoint to disk every 1 MB.
8. SHA-256 verification via CryptoKit, computed during the download, not after.
9. `goh auth import safari` — parse Safari's `Cookies.binarycookies` after the
   user grants Full Disk Access. Clear, dismissible permission prompt. Graceful
   handling of revocation.
10. Spotlight tagging on completion (`kMDItemWhereFroms`, `kMDItemDownloadedDate`).
11. Sleep assertion via `IOPMAssertionCreateWithName` — prevent idle sleep, allow
    display sleep.
12. `nw_path_monitor` — auto-pause on cellular, resume on Wi-Fi.

### Out of scope for v0.1

Mirror racing; plugin system / dynamic library loading; Chrome and Firefox
cookie import; yt-dlp integration; calendar-aware bandwidth scheduling; per-host
bandwidth budgets; hashes beyond SHA-256.

### Private pre-launch gates

- **Local dogfood.** Before any public install channel opens, maintain a
  reversible local dogfood lane that builds from source, registers a marked
  per-user LaunchAgent, smokes real launchd/XPC behavior, and resets cleanly.
  This lane uses a debug build until Developer ID credentials exist because
  unsigned release binaries cannot satisfy production peer validation.
- **Local health doctor.** `goh doctor` is the read-only pre-launch triage gate:
  it checks the CLI/daemon binaries, LaunchAgent install, launchd load state,
  XPC reachability, dogfood peer-relaxation setup, writable local download/log
  paths, and queue readability, then prints exact recovery commands. The doctor
  is deliberately CLI-local and does not add daemon IPC surface.
- **Private readiness acceptance.** `Scripts/dogfood-acceptance.sh` is the
  pre-public "can we actually use this?" gate: build/install, doctor, smoke,
  foreground download, JSON list, active pause/resume/remove cleanup, daemon
  restart, and an opt-in competitive benchmark against `aria2c` and `curl`.
  It is local-only, creates uniquely named test files, publishes nothing, and
  saves opt-in performance evidence under `.build/dogfood/logs`.

## v0.2 — backlog

- **Native menu bar companion.** A Mac-native control surface for users who
  want persistent visibility without living in a terminal. The companion is an
  optional SwiftUI/AppKit menu bar app backed by the same daemon, XPC commands,
  and progress subscriptions as the CLI. It shows daemon health, active download
  count, aggregate speed, foreground/background jobs, completion/failure
  notifications, and a compact popover with pause/resume/remove/reveal controls.
  It includes a restrained quick-add path from the clipboard or pasted URL and
  an "open terminal dashboard" handoff to `goh top`. It must not become a second
  download engine, a full GUI clone, or a mandatory runtime dependency for CLI
  users. The daemon remains the source of truth.

  **MB1 shipped in v0.1** (PR #54, with Ghostty / iTerm / WezTerm / Alacritty /
  kitty handoff added in PR #66) as a private-dogfood companion. Remaining
  menu bar slices on the v0.2 backlog: notifications, launch-at-login, app
  bundle packaging for public distribution, and a preferences UI.
- **Adaptive per-host range scheduling.** Slice 3b's competitive run validated
  saturated parity but not the ≥10 % amenable target — the residual gap is
  the structural HTTP/2-multiplexed-vs-N-TCP-connections difference between
  `goh` and `aria2c`, and the 16-connection data point confirmed that no
  static `N` is right for both workload classes (16 helps amenable, hurts
  saturated). The v0.2 move is probe-and-adapt: discover the optimal `N` per
  host empirically, persist in `gohd`'s catalog for repeat downloads. This is
  the structural path past `aria2c`'s manual `--max-connection-per-server`.
  Has its own design pass; the persisted per-host record is a load-bearing
  on-disk format.
- **In-flight adaptive parallelism.** The per-host bandit above optimizes *repeat*
  traffic and needs several downloads per host to converge — it does nothing for a
  *first/only* download or for conditions that change mid-transfer. The complementary
  move is a controller that adjusts the connection count *live, during a single
  download*: a BBR-style governor operating on connection count (delivery-rate +
  min-RTT-inflation + the per-connection-scaling regime), with multi-edge IP
  fan-out, protocol-aware connection-vs-stream policy, and the converged count fed
  back to seed the per-host bandit. This is the path that closes the structural
  amenable gap for the long tail of one-and-done downloads, and the bigger v0.2
  performance headline. Constraint: `URLSession` exposes only delivery-rate and
  coarse timing (not per-packet cwnd/RTT), so v1 runs BBR-style on delivery rate;
  packet-level signal would need `NWConnection`. Has its own four-round design pass
  and must be proven on sourced long-fat-network / multi-edge-CDN benchmarks. See
  the design seed: `docs/design-notes/2026-05-31-in-flight-adaptive-parallelism.md`.
- **HTTP/3.** A 3b trial via `URLRequest.assumesHTTP3Capable = true` regressed
  saturated against `dl.google.com` (run-to-run variance signature of
  server-side h3 throttling against this network path); reverted, documented
  in DESIGN.md §Transport. The new per-range `protocol=` trace line landed
  this round will isolate "h3 negotiated but slow" from "h3 didn't even
  negotiate" when revisited. Worth retrying against Cloudflare/Akamai-served
  workloads where QUIC is typically well-tuned, and against a different
  network path.
- **Mirror racing.** The headline v0.2 feature. Needs its own design pass.
- **Plugin system** / dynamic library loading.
- **Multi-browser auth.** Chrome (keychain-encrypted SQLite) and Firefox
  (`cookies.sqlite`) — different mechanics for each.
- **yt-dlp integration.** As a plugin; `goh` does not reimplement site
  extraction.
- **`SMAppService` migration.** Move daemon registration off `brew services` —
  which writes the LaunchAgent plist into the user-writable
  `~/Library/LaunchAgents/` — to `SMAppService`, whose tamper-resistant plist
  location closes the configuration-time Mach-service squat described in
  DESIGN.md §3.2. Deferred deliberately: v0.1's threat model accepts that a
  same-user attacker already on the box has many options; this is hardening for
  when goh is distributed outside Homebrew.

## Notes

New gaps discovered during implementation are recorded here rather than expanding
the current slice's scope.
