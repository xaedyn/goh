---
date: 2026-06-03
feature: goh-diagnose
type: design-validation
---

# Design Validation — `goh diagnose <url>` (Approach 2: Comparative Probe)

## Acceptance Criteria (from Step 2.5)

- **AC1:** Against a reachable Range-honoring server, stdout reports server reachable, range support = supported,
  negotiated protocol (h3/h2/http1.1), and an estimated throughput (MB/s); exit 0.
- **AC2:** Against a server that 429s some of N concurrent range probes, output reports connections attempted vs
  accepted (accepted < attempted) and identifies rate-limiting, recording ALL N outcomes — no abort on first
  non-206.
- **AC3:** Against a server that ignores Range (200, not 206), output reports range unsupported, gives a
  single-connection throughput estimate, and the verdict states parallel connections won't help.
- **AC4:** Default mode samples a bounded window (~10–15s) and returns regardless of file size; `--full` runs to
  completion. Observable by comparing wall-clock on a large file.
- **AC5:** Output always ends with one hedged plain-English verdict naming the most likely limiting factor from
  the measured signals; never claims "last-mile-limited" unless throughput failed to scale with added accepted
  connections.

## Dependency Enumeration

**No existing interfaces modified.** Diagnose is purely additive: a new `GohDiagnoseCommand` in `GohCore/CLI/`,
a new `ParsedCommand` case + `usage()` line in `GohCommandLine.swift`, and a new async closure in
`goh/main.swift` (the `doctor` wiring pattern). It calls the module-internal `streamingResponse` and the public
`downloadSessionConfiguration()`; it *inlines* three trivial `DownloadEngine` privates (`request(for:)`,
`contentRange`, `httpFailure`) rather than widening them. `protocolVersion` 3, `JobCatalog.version` 1,
`JobSummary`, lockfile/manifest formats — all untouched. No external consumers affected.

## Questions Asked & Answers

### Zero Silent Failures
- **Existing users on ship?** Nothing changes — additive verb, no schema/wire/behavior change to other commands.
- **Existing data?** None touched. Diagnose writes NOTHING to disk (bytes discarded in-stream, no temp/sink) —
  this also removes the entire path-traversal/symlink attack surface that `download` carries.
- **Existing integrations?** None — no interface signature changes.
- **Partial-failure mid-probe** (DNS ok, connection drops mid-sample; server hangs sending no bytes): the probe
  MUST always terminate (global time-box + per-connection timeout) and MUST always print either a report or a
  clear "diagnosis incomplete" error with a distinct exit code — never hang, never crash, never print a partial
  garbage number.

### Failure at Scale
- **10x / huge file:** the global time-box bounds default-mode runtime independent of file size; `--full` is
  explicitly proportional and user-requested (document the bandwidth cost).
- **Concurrent operations:** diagnose touches no shared state (ephemeral session, no store, no daemon, no
  locks). Two concurrent diagnoses are safe.
- **External dependency unavailable:** there is none. DNS failure / connection refused / TLS failure map to the
  existing `GohError` codes (`dnsResolutionFailed`/`connectionFailed`/`tlsFailure`/`timedOut`) and are reported
  with a distinct non-zero exit. Diagnose cannot take anything else down — it's an isolated CLI process.

### Simplest Attack
- **Cheapest abuse:** diagnose opens up to N connections for ~10–15s against a user-chosen URL, discarding
  bytes — identical trust posture to `curl`/`goh add`, run as the user, no new auth path, no daemon/XPC surface.
- **Credentials:** diagnose does NOT send cookies/credentials by default (it's a throwaway probe; auto-sending
  the user's auth cookies to a diagnostic is surprising and a needless leak risk). An auth-required URL returns
  401/403, reported as "requires authentication." (A `--cookies`/auth opt-in can come later; out of scope v1.)
- **Missing authz on a new endpoint:** N/A — no endpoint, no privilege, CLI-local.
- **Resource use:** discarding bytes uses bandwidth — inherent and user-initiated; the time-box caps default
  mode.

## Gaps Found

1. The probe must be *guaranteed-terminating* and *always-reporting* (time-box + per-connection timeout + a
   "diagnosis incomplete" path). Not yet specified.
2. Tiny/zero-length files (or servers that send too few bytes to clear TCP slow-start) yield an unreliable
   throughput number — must degrade to "insufficient data to estimate throughput," not print garbage.
3. Cookie/credential behavior was undecided — needs an explicit default-off decision in the spec.
4. Exit-code semantics undecided: does exit 0 mean "diagnosis ran" or "target healthy"?

## Fixes Applied (folded into spec requirements)

1. **Spec must define:** a global default time-box (~10–15s), a per-connection idle/connect timeout, and a
   mandatory terminal report-or-clear-error guarantee (the probe never hangs/crashes; on partial failure it
   prints what it learned plus a clear incomplete note).
2. **Spec must define** a minimum-sampled-bytes threshold below which throughput is reported as "insufficient
   data," and the verdict adapts accordingly.
3. **Decision:** v1 sends NO cookies/credentials; an auth-required URL is reported as "requires authentication."
   Documented as an explicit non-goal for v1.
4. **Decision:** exit 0 = diagnosis *completed* (rate-limiting / no-range / link-limited are findings, still
   exit 0 — scriptable). Non-zero is reserved for "diagnosis could not be completed" (unreachable / DNS / TLS /
   connection / timeout / auth-required), each a distinct code. Spec finalizes the exact code table.

No unresolved gaps. Proceeding to spec writing.
