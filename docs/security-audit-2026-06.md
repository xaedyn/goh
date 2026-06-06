# goh — Security & Code-Quality Audit (2026-06)

**Method:** multi-agent automated code review. A threat brief was derived from
`DESIGN.md`/`CLAUDE.md`, then 26 narrow-scope auditor agents swept the codebase
one surface at a time (Swift source + shell + CI + tests). Every raw finding was
attacked by **3 adversarial verifiers** (reachability lens, threat-model-scope
lens, exploitability lens); a finding survived only if a majority failed to
refute it. **161 agents, ~6.1M tokens, ~22 min.**

**Calibration note:** severities below are the **verifier-panel consensus**
(`adjustedSeverity`), *not* the auditors' first-pass labels. The single
auditor-tagged "critical" was downgraded to **medium** by its own panel; the
honest high-severity count is **5**, all of them cheap, localized fixes.

**Confidence:** findings are reasoned and peer-refuted, **not PoC-executed**.
Each carries a confidence label.

**Status:** the review itself changed no code. The introducing PR implemented
the **five high-severity fixes (H1–H5)**. A follow-up PR then fixed the **five
medium findings (M1–M5)** and the closely-related lows **L1** (ANSI stripping,
folded into M5) and **L3** (sidecar path, folded into M1). **L2** was assessed as
**no-fix-needed** — the cookie record-size overflow is unreachable on the 64-bit
platform floor (`offset + Int(recordSize) ≤ ~8.6e9 ≪ Int.max`, and the existing
`recordEnd <= page.count` guard already rejects oversized records). A third
follow-up PR then closed the remainder: **L4** (release-script cert `chmod 0600`),
**L5** (`ci.yml` least-privilege `permissions`), **L7** (codec out-of-range
`protocolVersion` test — exact-equality was already pinned), **L8** (resume
representation-change fail-closed test), and **I1** (per-command authorization
documented as by-design with a `CommandAuthorizer` seam noted in code). **L6** was
already covered by existing peer-validation tests, so no new test was added. The
audit backlog is now fully resolved or explicitly assessed.

---

## Executive summary

The architecture is **sound**; the execution is **inconsistent**. All four
foundational bets — `URLSession` transport, XPC mutual peer validation
(`XPCPeerRequirement` / `isFromSameTeam`), streamed CryptoKit SHA-256 for
content-addressed integrity, and `openat(2)`/`O_NOFOLLOW` path confinement —
survived scrutiny and were judged correct. The crypto/attestation design (DSSE-PAE,
sign `payload_bytes` only, rebuild PAE on verify, fail-closed on valid-but-unpinned)
is the **strongest** part of the codebase.

Every confirmed issue is an **implementation-consistency gap**, not a design
flaw: a correctly-specified contract applied unevenly. **None of the 12 planned
fixes touch a frozen wire/disk format or need a four-round design pass** — the
moat held clean.

### Reconciled severity tally

| Severity | Count | Findings |
|---|---|---|
| **High** | 5 | 0600 on CatalogStore; 0600 on CheckpointStore; verify-attestation `--json` fail-open; unbounded plist growth; `sampleCount` overflow trap |
| **Medium** | 5 | Path disclosure in XPC error messages; Content-Range integer truncation; stale-session reconnect crash; daemon `..` not rejected; query-string credential leak in `goh which` |
| **Low** | 8 | ANSI injection in `goh which`; cookie record-size overflow (latent); sidecar path disclosure; cert exposure window in release script; `ci.yml` permissions; missing peer-val test; missing protocolVersion test; missing 206/200 test |
| **Info / by-design** | 1 | Per-command authorization (documented single-user assumption) |

### Five systemic root causes

1. **0600 frozen-contract applied unevenly.** 2 of 4 daemon stores (`HostProfileStore`, `ProvenanceStore`) chmod 0600; the other 2 (`CatalogStore`, `CheckpointStore`) don't — they inherit umask (~0644). Root cause: no shared atomic-write helper; each store re-implements the temp→fsync→rename dance, so the security-relevant chmod is per-author discretion.
2. **Untrusted/sensitive strings reach sinks unsanitized.** Server/user-controlled URLs hit the terminal raw (`goh which`), and filesystem paths are interpolated into `GohError` messages that cross the XPC progress channel. No redaction layer.
3. **On-disk plist trusted past the decode boundary.** "Recover to empty on decode failure" was mistaken for "validate decoded values." A well-formed-but-hostile `host-scheduling.plist` is trusted wholesale → memory amplification or an overflow crash.
4. **Integer-width assumptions on adversary-influenced sizes.** Network/disk lengths flow into `Int` arithmetic without `clamping`/checked variants.
5. **Strongest invariants have the weakest CI coverage.** Peer-validation rejection, protocolVersion exact-equality, and 206/200 fail-closed are documented but not pinned by tests — a future edit could silently relax them.

### Clean surfaces (audited, nothing confirmed)

XPC peer-validation core · XPC envelope codec · TrustCore crypto & confinement ·
TrustCore parsers · cookie secret store · provenance store/Spotlight ·
**cross-cutting concurrency (no data races found — notable given the #81 deadlock
history)** · **menu-bar terminal-command builder (no shell/AppleScript injection
found)** · download IO · checkpoint/budget engine.

---

## One verifier error I overrode

Finding **#7 (`sampleCount` overflow)**: one of the three verifiers refuted it,
claiming Swift `UInt32` addition *wraps* and therefore there's no crash. **That
is factually wrong** — Swift's standard `+` operator traps on unsigned overflow
in all normal build configurations (only `-Ounchecked`, which this project does
not use, disables it). The other two verifiers correctly identified a trap (one
empirically ran `swift -e 'let x: UInt32 = .max; _ = x + 1'` and observed the
crash). I am keeping this at **high** on the strength of the two correct verdicts
and my own check of Swift semantics. Recorded here as evidence the panel is not
infallible and was not trusted blindly.

---

## Findings (high → low, verifier-consensus severity)

> **Line numbers reference the pre-fix code** at the time of review. H1–H5 have
> since been fixed in the introducing PR, so their cited lines now point at the
> remediated code. A `~` prefix (e.g. `~1062`) marks an approximate line where
> the exact offset shifts with surrounding edits.

### HIGH

**H1 · `CatalogStore` does not set 0600 on `catalog.plist`** — `Sources/GohCore/Model/CatalogStore.swift:44-64` · confidence: high (3/3 agree)
`save()` writes the temp file with no `setAttributes(posixPermissions: 0o600)`, unlike `HostProfileStore:333` and `ProvenanceStore:218`. File lands ~0644 (world-readable). A same-user process can read all job URLs, destinations, timestamps, progress. Violates the explicitly-frozen 0600 contract.

**H2 · `CheckpointStore` does not set 0600 on checkpoint files** — `Sources/GohCore/Model/CheckpointStore.swift:31-53` · confidence: high (3/3)
Same defect class as H1. Checkpoint files (`checkpoints/{jobID}.checkpoint.plist`) leak ETags, validators, byte-range progress, and URLs to same-user processes; enables resume-spoofing reconnaissance.

**H3 · `verify-attestation --json` fails open on encode error** — `Sources/GohCore/CLI/GohVerifyAttestationCommand.swift:170-172` · confidence: high (panel split medium/high; flagged #1 top-risk by synthesis)
A `try?` swallows a JSON-encode failure and returns the *verdict* exit code (0/1/2/3) with empty stdout. `goh verify-attestation --json && deploy` can therefore deploy on a swallowed error. The sibling `GohVerifyAllCommand.jsonResult()` already fails closed with exit 6 — this command diverges. Directly undermines the product's stated differentiator (integrity discipline). **Highest-leverage fix.**

**H4 · Unbounded on-disk data growth via untrusted plist** — `Sources/GohCore/Scheduling/HostProfileStore.swift:107-126` · confidence: high (3/3)
`PropertyListDecoder` decodes `host-scheduling.plist` with no post-decode bound on hosts-count or arms-per-host. A hostile-but-well-formed plist (millions of entries) causes memory exhaustion → daemon crash, then is re-persisted, spreading the corruption. "Recover to empty on decode failure" doesn't cover "decode succeeded, values are insane."

**H5 · Integer overflow trap on poisoned `sampleCount`** — `Sources/GohCore/Scheduling/HostScheduling.swift:75-86` · confidence: high (see override note above)
A crafted `ConnObservation.sampleCount = UInt32.max` makes `sampleCount + 1` trap (SIGILL) on the next `recordObservation()` fold. Persistent DoS — the poisoned value reloads on restart. Same on-disk-tampering threat class as H4 (which the panel accepted as in scope).

### MEDIUM

**M1 · Destination path disclosure in XPC error messages** — `Sources/GohCore/Engine/DownloadEngine.swift:~1062` · confidence: medium (auditor said "critical"; panel → medium)
`GohError(message: "\(fileError)")` interpolates `DownloadFileError.openFailed(path:errno:)` — the full destination path — into an error delivered over the authenticated XPC progress channel. Bounded by the fact that XPC peer validation gates connections to same-Team-signed binaries, but paths shouldn't cross the boundary regardless.

**M2 · Content-Range integer truncation** — `Sources/GohCore/Engine/DownloadEngine.swift:437,984` · confidence: medium (panel split; one called it high DoS, one refuted)
A malicious server's `Content-Range` total `> Int.max` flows into `chunk.prefix(Int(remaining))` with no upper bound. Realistic outcome is a crash/failed-download (the `written == range.length` guard catches incompleteness), not silent corruption — but the unchecked `UInt64→Int` cast is a real defect. Server bytes are explicitly untrusted.

**M3 · Stale-session notification crashes foreground/`top`** — `Sources/GohCore/CLI/GohForegroundDownload.swift:168-170,321-333` · confidence: high (3/3, no refute)
On daemon restart, the notification inbox is reused across reconnect; an in-flight notification with the old `requestID` arrives after reconnect, fails the requestID-match, and surfaces as a fatal `ForegroundError` — `goh top`/foreground exit with a confusing error (background download unaffected). Inbox lifetime is tied to the client object, not the session.

**M4 · Daemon path descent doesn't reject `..`** — `Sources/GohCore/Engine/DownloadFile.swift:148-200` · confidence: high
`openConfined()` filters `.` and empty components but **keeps `..`**, relying entirely on the CLI to have normalized. A verifier found this is **more reachable than the auditor claimed**: `goh add --output` does *not* run `SyncPathConfinement.resolve()`, so `goh add --output /tmp/base/../../etc/foo` reaches the daemon with `..` intact. `goh sync` is safe (it normalizes). Defense-in-depth gap; add a daemon-side `..` rejection.

**M5 · Query-string credential leak in `goh which`** — `Sources/GohCore/CLI/GohWhichCommand.swift:86` · confidence: high (3/3)
`entry.url` is printed verbatim. `ProvenanceRecord`'s own comment warns the field "may contain query-string credentials." Tokens in URLs leak to stdout/shell-history/logs. Redact query params on display.

### LOW

**L1 · ANSI escape injection in `goh which`** — `GohWhichCommand.swift:86` · confidence: medium — raw `entry.url` can carry ESC sequences to the terminal. Requires the user to have added a malicious URL themselves; display-only impact.
**L2 · Cookie record-size overflow (latent)** — `Auth/SafariBinaryCookies.swift:174-192` · confidence: medium — `offset + Int(recordSize)` unchecked; unreachable on the frozen 64-bit platform, real only if platform assumptions change. Harden anyway.
**L3 · Checkpoint sidecar path disclosure** — `Model/JobStore.swift:338-344` · confidence: medium — sidecar path in the unsafe-resume message crosses XPC; only on startup after checkpoint corruption; discloses a predictable directory.
**L4 · Cert exposure window in release script** — `Scripts/private-release-candidate.sh:116-120` — decoded `.p12` files briefly at umask default before import (notary key is chmod'd, certs aren't). Release-only, same-user, microsecond window.
**L5 · `ci.yml` missing `permissions:` block** — `.github/workflows/ci.yml` — read-only workflow; defense-in-depth/consistency with `release-artifacts.yml`.
**L6 · Missing CI test: peer-validation rejection** — `Tests/.../XPCTransportTests.swift` — partially covered already (`peerRequirementForEnforcedModeIsSet`, `enforcedRequirementRejectsUnsignedPeer`); add a listener-wiring assertion.
**L7 · Missing CI test: protocolVersion bounds** — `Tests/.../XPCEnvelopeCodecTests.swift` — actual rejection is enforced in `CommandService` (exact-equality); only the regression test is missing.
**L8 · Missing CI test: 206/200 representation change** — `Tests/.../DownloadEngineTests.swift` — defense exists (`validateContentRange`); the resume-representation-change case isn't pinned.

### INFO / BY-DESIGN

**I1 · No per-command authorization** — `Model/CommandDispatcher.swift:63-245` — correct for the documented single-user threat model; `DESIGN.md` already says multi-user would re-surface auth granularity. Recommendation: record the extension seam in a comment.

---

## Architecture verdict — *was the approach correct?*

**Mostly yes — architecturally correct, executionally inconsistent.**

- **XPC peer validation** (per-connection, never cached, bidirectional, Team-ID + designated-signing-identifier) is the right daemon trust boundary and correctly sets the macOS 26.0 floor.
- **URLSession** was correctly re-adopted after `NWConnection` was shown to carry no HTTP application protocol.
- **Content-addressed integrity** (streamed SHA-256) + **DSSE-PAE attestation** is the strongest, most careful part of the design.
- **`openat(2)`/`O_NOFOLLOW` confinement** is coherent and honestly documents its accepted residual.

The fragility is uniform: the daemon **trusts** that the CLI normalized paths, **trusts** that decoded plist values are sane, and **trusts** that each store author remembered to chmod. None breaks the primary boundary, but each turns a single upstream bug or hostile on-disk file cleanly into impact, because the second line of defense is *documentation* rather than *code*. The frozen contracts (0600, exact-equality version, fail-closed verify) are the right invariants; the gap is enforcement-by-convention instead of shared helpers + CI tests.

---

## Prioritized fix plan

All fixes are localized; **none touch a frozen contract or need a design pass**.

| # | Fix | Addresses | Severity | Effort |
|---|---|---|---|---|
| 1 | Route `verify-attestation --json` through a shared **fail-closed** JSON helper (exit 6 on encode failure); audit the sibling fail-open in verify-all | H3 | high | small |
| 2 | Extract one **`AtomicDurableWrite` helper** with 0600 baked in; migrate all 4 daemon stores onto it | H1, H2 | high | small |
| 3 | **Validate decoded plist** past the decode boundary: cap hosts/arms counts, clamp numeric fields, guard `sampleCount` increment | H4, H5 | high | medium |
| 4 | **Strip paths** from `GohError` messages crossing XPC (sanitized `DownloadFileError` rendering; generic sidecar message) | M1, L3 | medium | small |
| 5 | **Sanitize provenance URLs** on display: strip C0/C1 control chars, redact query-string credentials | M5, L1 | medium | small |
| 6 | **Checked/clamping arithmetic** convention for all network/disk lengths (Content-Range total bound; cookie record-size guard) | M2, L2 | medium | medium |
| 7 | Bind **notification-inbox lifetime to the session**; drop genuinely-stale messages instead of fatal-erroring | M3 | medium | medium |
| 8 | **Pin invariants with CI tests**: listener wires non-nil requirement; protocolVersion 0/out-of-range rejection; 206/200 + changed-Content-Range fail-closed | L6, L7, L8 | (test) | medium |
| 9 | **Reject `..` components in `openConfined()`** (daemon-side defense-in-depth) | M4 | medium | small |
| 10 | Add `permissions: { contents: read }` to `ci.yml` | L5 | low | trivial |
| 11 | `umask 0077` / chmod 0600 decoded certs in the release script | L4 | low | trivial |
| 12 | Document the single-user authz assumption + reserve a `CommandAuthorizer` seam | I1 | info | trivial |

**Recommended execution order:** fixes 1–3 first (the 5 high-severity issues,
all small/medium), then 4–6 (the two unsanitized-sink + arithmetic clusters),
then 7–9, then the trivial hygiene items 10–12. Fixes 2, 4, 5, and 6 each kill a
*class* of bug via a shared helper, so they're worth more than their individual
findings suggest.
