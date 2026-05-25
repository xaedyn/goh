# goh — Roadmap

## v0.1 — MVP (in development)

The smallest slice that already beats the category for ~80% of real use.

1. `launchd`-managed daemon, distributed via Homebrew with a `service` block.
   Opt-in via `brew services start goh`. First-time `goh <url>` invocation detects
   an unloaded agent and prints the one-line enable command.
2. `goh <url>` — foreground download with live TUI progress, attached to a
   daemon job.
3. `goh add <url>` — background download, returns immediately.
4. `goh ls`, `goh pause`, `goh resume`, `goh rm`, `goh top`.
5. HTTP fetch via `URLSession` — it negotiates HTTP/1.1, HTTP/2, and HTTP/3
   internally; goh does not select the protocol.
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

## v0.2 — backlog

- **Native menu bar companion.** A 10x Mac-native control surface for users who
  want persistent visibility without living in a terminal. The companion is an
  optional SwiftUI/AppKit menu bar app backed by the same daemon, XPC commands,
  and progress subscriptions as the CLI. It shows daemon health, active download
  count, aggregate speed, foreground/background jobs, completion/failure
  notifications, and a compact popover with pause/resume/remove/reveal controls.
  It includes a restrained quick-add path from the clipboard or pasted URL and
  an "open terminal dashboard" handoff to `goh top`. It must not become a second
  download engine, a full GUI clone, or a mandatory runtime dependency for CLI
  users. The daemon remains the source of truth.
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
