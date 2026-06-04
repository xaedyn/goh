---
date: 2026-06-03
feature: goh-diagnose
type: acceptance-criteria
---

# Acceptance Criteria — `goh diagnose <url>`

AC1: When a user runs `goh diagnose <url>` against a reachable server that honors Range requests,
stdout contains labeled lines reporting (a) server reachable, (b) range support = supported,
(c) the negotiated HTTP protocol (`h3`/`h2`/`http/1.1`), and (d) an estimated throughput in MB/s,
and the process exits 0.

AC2: When a user runs `goh diagnose <url>` against a server that returns 429 (or other non-206) to
some of N concurrent range probes, the output reports connections **attempted** vs connections
**accepted** with accepted < attempted and identifies rate-limiting as the cause — and the command
records ALL N probe outcomes rather than terminating on the first rejection (the abort-on-first-non-206
failure mode is observably absent: no single `httpStatus` error aborts the run).

AC3: When a user runs `goh diagnose <url>` against a server that ignores Range (responds 200, not 206),
the output reports range support = not supported, produces a single-connection throughput estimate, and
the verdict states that added parallel connections will not help for this source.

AC4: With no `--full` flag, the command samples for a bounded window and returns regardless of file size,
with default-mode wall-clock bounded near `defaultDeadlineSeconds` (the named spec constant, 12s ± slack);
with `--full`, it reads to completion (wall-clock proportional to size). Observable by running both modes
against a never-ending / large stub and comparing wall-clock.

AC5: The output always ends with exactly one plain-English verdict line, selected from the defined `Verdict`
enum based on the measured signals (throughput scaling, connection rejections, range support, and the
**negotiated protocol**). It never over-claims: it does NOT assert a link-vs-server-cap cause ("your connection
is the limit or the server caps bandwidth") unless the protocol is HTTP/1.1 (separate TCP connections) AND
throughput failed to scale with added accepted connections. Over HTTP/2/3 (or unknown protocol) with no scaling,
it emits the multiplexed-protocol verdict instead — stating the test cannot isolate link vs source over a shared
connection.
