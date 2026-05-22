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

## v0.2 — backlog

- **HTTP/3.** Resolved by the Slice 3a `URLSession` transport revision — HTTP/3
  works transparently wherever servers offer it; no dedicated v0.2 design pass
  is needed.
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
