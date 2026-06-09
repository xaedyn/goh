# STATE.md — goh current state

Where the project is right now. Read after `CLAUDE.md` at the start of every
session; update at the start of every PR and at the end of every session.

## Current state

### 2026-06-09 (tiered-trust session) — **Tiered rapid-trust BUILT on `design/tiered-rapid-trust` (full pipeline: spec 2 rounds + plan 2 rounds + 12 tasks + final review APPROVED FOR MERGE)**

Full enterprise-pipeline from the "is full re-hashing the best way to determine trust rapidly?" question. Design → spec (2 adversarial rounds; round 1 caught the mtime-precision blocker) → plan (custom-writing-plans, 2 rounds; round 1 caught the `S_ISREG`-not-importable blocker) → subagent-driven-development (3 phases / 12 tasks, per-task review gates) → final cross-cutting review APPROVED.

- **What it adds:** an instant `lstat`-based fast-check ("does this file still look like what I recorded?") alongside the existing O(size) deep verify. Tiered trust: origin (sha256/attestation at download) + integrity (deep re-hash, on demand) + **rapid liveness (new: stat size+mtime+inode/device)**.
- **Phase 1 (GohCore):** `FileStat`/`FileProbeResult`/`FileStatProbing`/`LiveFileStatProbe` (lstat); `FastChangeReason`/`FastCheckStatus`/`FastCheckRunner` (pure, probe-injected, precedence identity>size>mtime); 5 additive-optional baseline fields on `ProvenanceEntry` (`recordedStatSize`/`recordedMtimeSeconds`/`recordedMtimeNanoseconds`/`recordedInode`/`recordedDevice`, raw integers — `Date` would lose nanoseconds). `ProvenanceRecord.currentVersion` stays 1; golden fixture round-trips unchanged (no version bump, no four-round — the `verifiedAt` precedent).
- **Phase 2 (capture):** `DownloadFile.fileStat()` (fstat the open fd); widened `complete()`/`completedDownloadHandler` with a trailing `FileStat?`; captured at all 3 finalization sites BEFORE `finish()` (fstat-at-finalize closes TOCTOU — baseline describes the hashed bytes); daemon routes it all-or-nothing into `ProvenanceEntry`. **BBR governor block byte-for-byte untouched** (proven). No path-stat anywhere.
- **Phase 3 (surfaces):** `goh verify --quick` (lstat-only, mutually exclusive with `--all`, deep `--all` unchanged); `TrustDisplayStatus` with `looksUnchanged` rendered DISTINCTLY from `verified` (teal "checkmark.circle" vs green "checkmark.shield.fill" — model-level + AC8 test, anti-misrepresentation); Trust window runs the fast-check on open (off-main `Task.detached` → `@Published fastStatuses` on MainActor); `LiveFileStatProbe` wired in goh-menu.
- **Key invariant LOCKED by test:** the fstat-baseline mapping ≡ the lstat-compare mapping on a real file (`fileStatMatchesLstatProbe`) — if these ever drift, every fresh download silently reads `.changed`; final review flagged the gap, test added.
- **Gate:** `swift build -Xswiftc -warnings-as-errors` clean; `swift test` **844/844** (43 new tests). Frozen contracts intact (governor, protocolVersion=4, VerifyAllReport v1, ProvenanceRecord v1 + golden, JobProgress). NO `#available`, no `S_ISREG` in code (bit-test `(st_mode & S_IFMT) == S_IFREG`).
- **Spec/plan/artifacts:** `docs/superpowers/specs/2026-06-08-tiered-rapid-trust-design.md`, `docs/plans/2026-06-08-tiered-rapid-trust-plan.md`. Still private testing — no public deploy ([[tester-phase-no-official-deploy]]).
- **Pending:** push + PR + merge; then a fresh signed tester build to exercise `--quick` and the Trust-window fast status. Deferred (D3/D4 in the spec): backfill baselines into pre-feature entries; sync-skip-path baselines.

### 2026-06-08 (verify-responsive session) — **Dashboard MERGED (#102); responsive deep verify + two fixes MERGED (#103); tiered "rapid trust" design pass → implemented (see entry above)**

Continuation of the tray work. Two PRs landed on `main`:
- **#102** (squash `e8865f3`) — the professional download dashboard (the 7-task slice below). Confirmed working by the user on a real signed build.
- **#103** (squash `2a0eadf`) — responsive deep verify + two fixes found during testing:
  1. **Popover overlap fix** — job-rows VStack used `.frame(minHeight: 32)` (flexible + centered); in the content-hugging popover it squeezed to 32pt and rows overflowed onto the Trust/Downloads buttons. Fixed with `.fixedSize(vertical:)` + moved the Downloads button to its own slot.
  2. **Large-file verify OOM** — `FileDigest.sha256WithSize` streamed in 1 MiB chunks but never drained the autorelease pool; inside the long `DispatchQueue.global` verify block the autoreleased `FileHandle.read` buffers accumulated to tens of GB on a multi-GB file → silent jetsam SIGKILL (no crash report), app vanished. Fixed by wrapping each chunk in `autoreleasepool`. Affects tray verify AND CLI `goh verify`/`goh sync`.
  3. **Responsive deep verify** — `FileDigest` gains `onBytesHashed`+`isCancelled` (per-chunk, throws `DigestError.cancelled`); `VerifyProgress` gains cumulative `bytesHashed`+`totalBytes`; `VerifyAllRunner` streams progress (throttled ~16 MiB) + honors mid-file cancel (returns partial report, never throws); frozen `VerifyAllReport` v1 shape + entry order preserved, CLI golden tests unchanged. Trust window shows a live byte bar + "X GB / Y GB" + cumulative-rate ETA + working Cancel.
- **Gate:** `swift build -Xswiftc -warnings-as-errors` clean; `swift test` 800/800. User confirmed end-to-end on a real **68GB** file: live bar + ETA, app stays memory-flat, cancel instant.
- **Tester build:** user cut `goh-0.1.0-test5-macos-arm64.pkg` (signed+notarized+stapled) and validated the whole flow. Still private testing — no public deploy ([[tester-phase-no-official-deploy]]).

**NEXT SLICE — tiered "rapid trust" (design pass).** Key insight: full re-hashing answers *integrity* ("unchanged since recorded?"), inherently O(file size) — no fast cryptographic shortcut for a 68GB file. *Trust* is mostly established at download (ledger already records sha256; `goh attest` adds SE attestation). So the model is tiered: (a) **instant routine check** = `stat` size+mtime+inode vs recorded → "looks intact / changed" (heuristic, not proof; misses bit-rot); (b) **deep verify** = the now-responsive full re-hash, on demand/scheduled; (c) optional bigger win = chunked/BLAKE3 for parallel + localizable deep verify. **Format research done (2026-06-08):** `ProvenanceEntry` is `url, sha256, size:Int, downloadedAt:Date, destinationPath:String, verifiedAt:Date?`; `ProvenanceRecord{version=1, entries}`, binary plist, reader tolerates unknown keys + missing optionals. So adding `mtime`+`inode` as **additive-optional** fields keeps `version=1`, golden fixture intact, and per the project's own rule needs NO four-round pass (the `verifiedAt` precedent). Daemon write path (`gohd/main.swift` ~172) needs ONE new `stat(2)` on the destination (no open fd; `size` currently comes from the byte counter, not `fstat`). Attestation is fully decoupled (separate `dev.goh.attest/`). New trust *semantics* (a heuristic fast-check) still merit a spec + adversarial-spec-review before code. User approved direction; NO code until design approved at the gate.

### 2026-06-07 (tray-dashboard session) — **Professional download dashboard BUILT on `feat/tray-download-dashboard` (7 tasks, all reviewed green + final cross-cutting review APPROVED; MERGED via #102)**

Addressed the three things the user flagged from the tray screenshot: the climbing speed number,
downloads not appearing, and "make it look highly professional / show enough info." Full
enterprise-pipeline (spec + plan, 2 adversarial review rounds each, USER GATE 2 approved) →
subagent-driven-development (per-task implementer + review gates) → final cross-cutting Opus review.

- **The speed fix (Approach A — engine-side, the user's chosen bet).** The displayed speed was a
  cumulative average (`completed / elapsed`) that only ever climbs. Replaced with a **5-second rolling
  window** (curl's convention) computed in a new `RollingRateSampler` (GohCore, Mutex-guarded,
  `@unchecked Sendable`, monotonic guard + saturating subtraction → crash-safe for concurrent ranged
  workers; always-evict so a stall decays the rate; span measured oldest→`now`). Created **once per
  `run(job:)`** and threaded to **all 6 `Self.progress(...)` display sites** (resume final/flush,
  single in-flight/final, ranged final, consumeRange worker). Fixes the metric **everywhere** — tray
  AND `goh ls`/`goh top` inherit it (same `bytesPerSecond` field). **The BBR governor's separate
  `ByteCounter`/`governor.record`/`governor.decide` sampler block is byte-for-byte UNTOUCHED**
  (final review confirmed against the diff). `JobProgress` wire shape unchanged — only the runtime value.
- **The dashboard.** Popover collapse fixed (maxHeight-only `ScrollView` → top-5 `VStack(minHeight:32)`
  + overflow hint + "Downloads…" button). New **resizable `Window(id:"downloads")`** with rich two-line
  rows: file-type icon + middle-truncated filename + hover controls, determinate `ProgressView`
  (spinner when size unknown), secondary line = `downloaded/total · ETA · elapsed · N connections ·
  verify status`. Completed/failed rows retained; completed rows join the provenance ledger
  (`trustReader`) for a **verified <date> / recorded** badge. Six new `GohMenuJobRow` fields populated
  by the presenter; `ledgerOutcome` wired through the viewmodel (off-main read preserved, re-render on
  MainActor). `orderedControls` promoted to a module-internal extension in `GohMenuModels.swift`.
- **Post-review fix folded in:** ledger lookup now canonicalizes the destination path
  (`URL(fileURLWithPath:).standardizedFileURL.path`) on BOTH map-build and lookup, matching the daemon
  write side + `ProvenanceStore.lookup` — a non-canonical `job.destination` no longer silently misses
  the verify badge.
- **Commits (branch `feat/tray-download-dashboard`, off `main` @ `581a7bb`):** `a26ccc0` docs →
  `b7c5a19` T1 sampler → `80b95e4` T2 engine threading → `c81fa0d` T3 model → `4074eca` T4 presenter →
  `bc49f0c` T5 popover → `a8ee44b` T6 window view → `7e6a147` T7 scene → `7db7d54` canonicalize fix.
- **Gate:** `swift build -Xswiftc -warnings-as-errors` clean; `swift test` **791/791** (11 new: 5
  sampler + 6 presenter). 11 new tests non-vacuous, no existing test weakened. NO `#available`, no
  wire/protocolVersion/golden change. Final cross-cutting review: **APPROVED FOR MERGE**.
- **NOT pushed / no PR yet** — awaiting user go-ahead (push-only-when-asked). **The installed
  0.1.0-test PKG still has the OLD code + the buggy Preferences sheet** → to actually SEE the dashboard
  the user must cut a fresh signed build (`Scripts/sign-tester-build.sh`) after this merges. Still in
  the private testing phase — no public deploy ([[tester-phase-no-official-deploy]]).

### 2026-06-07 (tester-signing session) — **Local tester-build signer added: `Scripts/sign-tester-build.sh` (signed+notarized all-in-one PKG from the login keychain)**

User enrolled in the Apple Developer Program (Individual) but is **still in private testing — NO
official/public deploy** (no brew tap, no launch post; see [[tester-phase-no-official-deploy]]).
Added a local signing helper so the user can hand testers a clean double-click install.

- **`Scripts/sign-tester-build.sh`** (new, reviewed ✅): the solo-dev counterpart to the CI-shaped
  `private-release-candidate.sh`. Uses the **login-keychain** Developer ID identities directly (no
  base64 cert import / no ephemeral keychain), reuses `_stage-app-payload.sh` + mirrors the CLI/daemon
  payload staging, signs inside-out (`--options runtime --timestamp`), `pkgbuild`→`productbuild --sign`
  (Developer ID **Installer**), `notarytool submit --wait` (keychain profile `goh-notary` by default, or
  `APPLE_ID`/`APPLE_APP_SPECIFIC_PASSWORD`/`APPLE_TEAM_ID`), `stapler staple`, then `stapler validate` +
  `pkgutil --check-signature` (hard) + `spctl` (advisory). Auto-detects the two identities (env override
  `GOH_APP_SIGN_IDENTITY`/`GOH_INSTALLER_SIGN_IDENTITY`); refuses to guess on 0/>1.
- **Approach verified against current (2026) Apple sources** before building: notarytool + 3 auth methods
  still current; altool dead; Developer ID Application + Installer both required; inside-out + hardened
  runtime + timestamp + staple is the flow; local signing uses login-keychain (no CI ceremony). Two
  findings baked in: (1) **macOS 26 "Tahoe" `.pkg` `spctl` quirk** — a validly-stapled pkg can report
  `spctl --type install: rejected` when the signing cert chain is incomplete (`unable to build chain to
  self-signed root`); the script flags this advisory + points to the cert-chain fix, treating
  stapler-validate + pkgutil-check-signature as authoritative. (2) Sequoia/Tahoe **removed right-click→Open**
  — un-notarized is now high-friction; notarized+stapled clears silently (which is why we notarize).
- **The user RUNS it** (their certs + Apple creds + network live on their Mac). One-time setup is in the
  script header: create the two Developer ID certs, then `xcrun notarytool store-credentials goh-notary …`.
- **PROVEN 2026-06-07:** the user produced a real signed+notarized+stapled tester PKG
  (`goh-0.1.0-test-macos-arm64.pkg`) with it. Apple's notary queue took >30 min that day; the original
  30-min wait timed out and left an un-stapled pkg + cryptic "status unknown." **Hardened in response:**
  `GOH_NOTARY_TIMEOUT` (default 60m); a wait-timeout is now non-fatal (exit 75) and prints the exact
  `notarytool wait <id>` + `stapler staple` recovery (app-specific password MASKED in the hint); `Invalid`
  → exit 65 with the log. Learning: Apple notarization can exceed 30 min with a green status page — wait it
  out; the submission completes server-side and only needs stapling. Gotcha: the dogfood daemon (earlier
  sessions) shares the Mach service name — run `Scripts/dogfood-reset.sh` before installing the signed pkg.

### 2026-06-07 (tray-app session, cont.) — **Trust layer in the tray MERGED (#99); final review APPROVED**

Third tray slice. Surfaces goh's differentiator read-only in the tray: a popover **provenance
summary** (files tracked + last-recorded status) + a **Trust window** with per-file detail and an
on-demand **background verify** (re-hash → OK/FAILED/MISSING, with progress + cancel). Reads the
ledger **directly** (unsandboxed, like the CLI — no daemon/XPC, works daemon-down); **read-only**
(daemon stays sole writer). **780 tests pass; `swift build -warnings-as-errors` clean. Final
stack-aware review APPROVED.** Built via `enterprise-pipeline` → `subagent-driven-development`.

- **The extraction:** a shared `VerifyAllRunner` (GohCore) now does the re-hash; `GohVerifyAllCommand.run`
  delegates to it — so the tray and `goh verify --all` verify **identically** (AC5 automatic) and the
  CLI output is **byte-identical** (verified: the existing verify-all/JSON/attest tests + the
  `verify-all-report-v1.json` golden fixture are UNCHANGED — `git diff` empty). A shared
  `ProvenanceLedgerReader.read → ProvenanceReadOutcome{absent|entries|unreadable(reason)}` unifies the
  corrupt/empty classification so a corrupt ledger shows "unavailable", never silently empty; the
  structured `LedgerUnreadableReason` preserves the three frozen `--json` error codes.
- **Concurrency (load-bearing):** the blocking re-hash runs on a **real OS thread**
  (`DispatchQueue.global().async`) — NOT `Task.detached` (which stays on the cooperative pool and would
  reproduce the #81 6-hour starvation). Cancel = a `Mutex<Bool>` boxed in `CancellationBox` (a
  `final class`, since `Mutex`/`Atomic` are `~Copyable`); a `WeakRef` box for the `@Sendable` `[weak
  self]` capture; progress hops to `@MainActor`. Closing the Trust window cancels an in-flight verify.
- **Review catches (adversarial):** spec round 1 (4 blocks: `Task.detached` doesn't escape the pool;
  unified reader; pinned cancel/progress contract), spec round 2 (2 blocks: structured error-code
  preservation; non-optional path) — escalated, user accepted. Plan round 1 (1 block: test `@Sendable`
  closures captured mutable `var`s → boxed via `RunnerTestBox`), plan round 2 APPROVED.
- **New files:** GohCore `Provenance/ProvenanceLedgerReader.swift`, `CLI/VerifyAllRunner.swift`
  (+ refactored `CLI/GohVerifyAllCommand.swift`); GohMenuBar `GohTrustModels.swift`,
  `GohTrustPresenter.swift`, `TrustWindowViewModel.swift`, `TrustWindowView.swift` (+ `GohMenuView`/
  `GohMenuViewModel` popover section + `goh-menu/main.swift` `LiveProvenanceReader`/`TrustWindowRoot`/
  `Window(id:"trust")`); tests in `Tests/GohCoreTests/` + `Tests/GohMenuBarTests/`. Branch off `main`
  (after #97+#98 merged). Live window behavior (progress/cancel UX) only confirmable in a running app;
  value layer fully unit-tested.

### 2026-06-06 (tray-app session, cont.) — **Richer-add "Add Download window" MERGED (#98); final review APPROVED**

Second tray slice this session. Adds an **Add Download window** (opened from the popover):
editable URL (prefilled from clipboard), a **folder picker**, and an **Automatic/connections
(1–16)** control — so downloads can be added with a chosen destination + connection count
instead of defaults-only. The existing one-tap clipboard add is untouched. **Pure GUI change**
(`AddRequest` already carries `destination`/`connectionCount`; reuses the existing `.add` XPC
command — NO new IPC, no wire/protocolVersion change; `git diff -- Sources/GohCore` empty).
**757 tests pass; `swift build -warnings-as-errors` clean. Final stack-aware review APPROVED.**

- Built via `enterprise-pipeline` → `subagent-driven-development` (Approach A "Add Download
  window"; THE BET = a dedicated window is fine for the choose-where/how case, fast one-tap stays).
- **Folder picking from an `.accessory` app** must use a real window, not the transient popover
  (which dismisses on focus loss): `NSOpenPanelFolderPicker` (live, in `goh-menu`) uses
  `NSApp.activate(ignoringOtherApps:true)` + `NSOpenPanel.begin`; the form lives in a SwiftUI
  `Window(id:"add-download")` scene whose `AddDownloadViewModel` is owned by a `@StateObject`
  root (`AddDownloadWindowRoot`) so typed input survives scene re-eval.
- **Review catches (adversarial):** spec round 1 (4 blocks) — reuse the shipped
  `GohClipboardURLDetector` for validation + normalized submit URL; reusable
  `GohMenuError.userFacingMessage` so errors are never raw; clamp `UInt8(min(16,max(1,n)))`.
  Plan round 1 (2) — a tautological AC4 test (removed; the existing
  `startsClipboardURLThroughDaemon` is the anchor) + the `@StateObject` ownership fix. Plan
  round 2 (1) — missing `import AppKit` in `GohMenuView.swift` for `NSApp`.
- **New files:** `Sources/GohMenuBar/{FolderPicker,AddDownloadViewModel,AddDownloadView}.swift`,
  `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift` (22 tests). Modified:
  `GohMenuModels.swift` (+userFacingMessage), `GohMenuViewModel.swift` (+factory),
  `GohMenuView.swift` (+button +import AppKit), `goh-menu/main.swift` (+live picker +Window
  scene +@StateObject root), `DESIGN.md`. Commits: `5a607df` docs, `b03a6c7` Phase 1,
  `581aca7`+`b231f49` Phase 2.

**HANDOFF for this slice:** branch `feat/tray-richer-add` is **stacked on #97** (shares
`main.swift`/`GohMenuView`/`GohMenuModels`). Not pushed/PR'd yet. Cleanest order: **merge #97
first**, then this rebases onto main for its own PR (or open it now with base = the tray-app
branch). Login-item/notification live testing still gated on the Apple Developer ID; the new
folder-picker window's live behavior (NSOpenPanel focus, dismiss-on-submit) is only confirmable
in a running app, not CI — the value layer (AC1–AC5) is unit-tested + green.

### 2026-06-06 (tray-app session) — **Tray-app distribution feature BUILT on `feat/tray-app-distribution` (11 tasks, all reviewed green, NOT yet merged/PR'd)**

Turned the `goh-menu` companion into a distributable `.app`: app-bundle packaging,
completion/failure notifications, launch-at-login (tray app only — daemon stays on
`brew services`), and a preferences UI, delivered via an all-in-one signed PKG
(Approach B). Built through the full `enterprise-pipeline` → `subagent-driven-development`.
**735 tests pass; `swift build -warnings-as-errors` clean. Final cross-cutting
stack-aware review APPROVED FOR MERGE. Branch NOT pushed / NO PR yet — awaiting user.**

- **Scope decisions (user-gated):** launch-at-login is **tray-app-only** (`SMAppService.mainApp`);
  the daemon's `brew services` registration is untouched (the ROADMAP §SMAppService daemon
  migration / DESIGN §3.2 remains deferred). Distribution = **Approach B, all-in-one PKG**
  (one double-click installs CLI+daemon+`goh.app`). THE BET: versioning engine+app together
  is fine for the tester phase.
- **Load-bearing design catches (from adversarial review):** (1) the progress subscription
  was popover-scoped → notifications would be dead while the menu is closed; moved ownership
  to `GohMenuAppDelegate` (always-on, started at `applicationDidFinishLaunching`). (2) a pure
  `GohNotificationTransitionDetector` with nil-seed suppression + `job.id` dedup so pre-launch
  terminal jobs are NOT re-notified on every launch, and a synchronous `onProgressSnapshots`
  hook (NOT `@Published`/Combine, which would replay `[]` and defeat the seed). (3)
  `LiveNotificationService` is `@MainActor` (a `nonisolated` method touching the non-Sendable
  `UNUserNotificationCenter` fails to compile). Notifications post **locally** from the existing
  stream — **NO new IPC surface**; the file-name only (no URL/host) is shown.
- **Frozen contracts untouched** (verified: `git diff main..HEAD -- Sources/GohCore` is EMPTY).
  No `protocolVersion`/XPC-envelope/`ProvenanceRecord`/`JobCatalog`/`gohfile.lock` change; the
  `#if RELEASE #error` peer-relaxation tripwire is intact. The feature lives entirely in
  `GohMenuBar`/`goh-menu` + packaging scripts + `DESIGN.md`.
- **New files:** `Sources/GohMenuBar/{GohMenuPreferences,GohMenuNotifications,GohMenuNotificationsLive,GohNotificationCoordinator,GohMenuLoginItem,GohMenuLoginItemLive,GohMenuPreferencesView}.swift`;
  tests in `Tests/GohMenuBarTests/`; `Resources/app-Info.plist` (id `dev.goh.menu`,
  `LSUIElement`, `LSMinimumSystemVersion=26.5` == PKG `os` pin); `Scripts/package-app.sh`,
  `Scripts/_stage-app-payload.sh` (shared staging helper used by BOTH `package-pkg.sh` and
  `private-release-candidate.sh` — lockstep, no drift). `package-pkg.sh` now bundles `goh.app`
  at `/Applications` (verified via `pkgutil --expand-full`); `private-release-candidate.sh` now
  signs `goh-menu` + the `.app` inside-out (documented **post-credential seam** — only runs when
  a Developer ID cert env is present). Design artifacts under `docs/superpowers/**` + plan at
  `docs/plans/2026-06-06-tray-app-distribution-plan.md`.

**NEXT-SESSION HANDOFF — tray app is built + reviewed; two external dependencies remain:**
1. **Finish the branch:** decide PR vs keep-local (user was being asked at session end). When
   PR'd: CodeRabbit + Socket will run per the usual flow.
2. **Apple Developer ID (the real unlock, user is enrolling):** the signed+notarized PKG/DMG
   for easy *tester* install needs the cert. Until it lands, the `.app` is testable only via the
   local debug/dogfood path — and note the **login-item is `.unsupported` on the debug bare
   binary** (SMAppService needs a real bundle id), so AC3 is only exercisable from the signed
   `.app`. The signing seam in `private-release-candidate.sh` is ready to wire `goh-menu` + `.app`
   + notarization the day the cert exists.
3. **Advisories carried (non-blocking):** notification posting is best-effort/silent (matches
   `SpotlightMetadataTagger`); preferences test suites don't `removeSuite` (tiny plist litter);
   `GohMenuPreferencesView` reads `loginItem.status()` a few times in init (cosmetic).

### 2026-06-06 (audit + launch-doc session) — **Whole-codebase security/code-quality audit MERGED across 3 PRs (#93 / #94 / #95); SECURITY/CONTRIBUTING/CODE_OF_CONDUCT drafted (local-only, gitignored)**

A multi-agent security + code-quality audit of the entire codebase ran this
session (threat-model-first, with adversarial verification of every finding).
Report committed at `docs/security-audit-2026-06.md`. **19 findings survived
verification — ALL implementation-consistency gaps, not design flaws.** The
architecture held: URLSession transport, XPC mutual peer validation,
content-addressed SHA-256 integrity, `openat(2)`/`O_NOFOLLOW` confinement, and
every frozen wire/disk contract. Fixed or assessed across three merged PRs:

- **#93 (squash `4355a97`) — 5 high.** `CatalogStore` + `CheckpointStore` now
  write `0600` (were world-readable to same-user processes); `verify-attestation
  --json` fails closed (exit 6) on encode failure via a shared
  `GohCommandLineResult.jsonOrFailClosed`; `HostProfileStore.load` validates the
  decoded plist (host/arm caps + finite-EWMA) and `ConnObservation.foldingIn`
  saturates `sampleCount` (no overflow trap on a poisoned record).
- **#94 (squash `8a41de7`) — 5 medium (+ L1/L3).** Filesystem paths stripped from
  `GohError` messages crossing XPC (`DownloadFileError.redactedDescription`;
  sidecar path dropped from the unsafe-resume message); `goh which` URLs
  sanitized via shared `URLDisplay.sanitized` (control-char strip +
  query-credential redaction); `DownloadEngine` bounds the server-declared
  `Content-Range` total (`maxDeclaredTotal` = 8 TiB) before chunk planning;
  foreground download + `goh top` skip stale-`requestID` notifications instead of
  crashing; daemon `openConfined` rejects `..` components.
- **#95 (squash `8e72d77`) — lows + I1.** Release-script `chmod 0600` on decoded
  certs; `ci.yml` least-privilege `permissions: contents: read`; regression tests
  pinning protocolVersion-out-of-range and resume-representation-change
  fail-closed; per-command authz documented as by-design (a `CommandAuthorizer`
  seam noted in `CommandDispatcher`).

**Honest deltas (recorded so they aren't re-litigated):** L2 (binarycookies
`offset + Int(recordSize)` overflow) assessed **NO-FIX** — unreachable on the
64-bit floor, and the existing `recordEnd <= page.count` guard already rejects
oversized records. The M2 `Int(remaining)` cast was a **false alarm**
(ternary-guarded; the real fix was bounding `total`). The menu-bar progress
stream shares M3's stale-requestID pattern but ends a *recoverable* stream rather
than crashing a process, and has a test pinning its contract — left as a
documented follow-up, not flipped. One verifier agent got Swift's `UInt32`
overflow-trap semantics wrong and was overridden.

**715 tests pass; `swift build -warnings-as-errors` clean.** All three PRs
CI-green at merge; CodeRabbit clean on #93/#94 (rate-limited / org out-of-credits
on #95, so #95 didn't get a deep pass — it's config + tests + a comment).
Memory written: [[security-audit-2026-06]].

**Launch docs drafted LOCAL-ONLY** (gitignored alongside the vision/launch-post
memos): `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`. These are
**launch-sequence step 4** — ready to un-ignore and publish right before the brew
tap opens. `SECURITY.md` routes reports through GitHub Private Vulnerability
Reporting (no email address exposed) and states the single-user threat model +
90-day coordinated disclosure; the CoC adopts Contributor Covenant 2.1 by
reference.

**NEXT-SESSION HANDOFF — the strategic read is unchanged: the build is done; the lever is launch.**
1. The trust-layer arc + positioning are complete, and the security audit added
   **no design surface** (consistency fixes only). Per the standing "stop
   overbuilding a zero-user tool" call, do NOT add more hardening/features.
2. **Phase 3 public launch is the next step, gated on Apple Developer ID
   credentials** (sign+notarize PKG → open the brew tap → publish
   SECURITY/CONTRIBUTING/CODE_OF_CONDUCT → launch post → HN/Reddit). The launch
   docs are now drafted and waiting local.
3. If BUILDING anyway, the one strategically-justified feature remains the
   **`hf://` smart-URL adapter** (cross-source moat-widener), NOT more hardening.

### 2026-06-06 (build session) — **Hardware-attested provenance (`goh attest` / `goh verify-attestation`, Secure Enclave signing) MERGED to `main` via PR #89 (squash `bd4aca4`)**

**MERGED. Local `main` synced; `feat/hardware-attested-provenance` deleted (local + remote). 695 tests pass, `swift build -warnings-as-errors` clean. CI green at merge. CodeRabbit posted 2 code findings (both Major), BOTH FIXED in `41bdb25` and explicitly endorsed ("both fixes look exactly right"): (1) `payloadBytes(for:)` was `try?`→silent-blank-output — now `throws`, fail-closed (`--json` exit 6 / `attest` exit 5, never signs empty bytes); (2) the 32-bit `kid` was too weak for the trust decision — `verify-attestation --expect-key` now requires a FULL public key (or its 64-hex SHA-256 fingerprint); an 8-hex kid → usage error (exit 64); kid is display-only. 5 docs-markdownlint threads declined (no docs-lint CI gate). Real-binary spot-check passed end-to-end with the actual Secure Enclave.** Built via the full `enterprise-pipeline` → `subagent-driven-development`. The "tie Apple Silicon into goh" exploration (Concept 1 of a brainstorm).

- **What it is.** `goh attest` runs `verify --all`, then signs the report with a **Secure Enclave P-256 key** (private key never leaves the chip) into a portable, self-contained `SignedVerifyReport`; `goh verify-attestation <file>` verifies it **offline, on any machine**, using only the embedded public key. Turns a verify result into a hardware-rooted, shareable, tamper-evident proof — and makes goh's Apple-Silicon requirement *earned*. Approach **A "The Signed Receipt"** (chosen over B per-entry ledger signing = Phase 2, and C detached-sidecar).
- **KEY DE-RISKING (spike):** `SecureEnclave.P256.Signing` create/sign/verify works on **ad-hoc/dogfood builds — no Developer ID/Team ID/entitlement**. The feature does NOT depend on the Phase-3 credential gate. (Refuted the CCB's pessimistic assumption empirically.)
- **Crypto design (4 review rounds):** sign the raw stored bytes via DSSE-PAE (never re-serialize → canonicalization footgun gone); `payload_bytes = CommandCoding.encoder.encode(report)` NO trailing newline (== verify-all-report-v1.json bytes; the `--json` `+"\n"` is a separate frozen path, untouched); SSH-sig-style self-contained envelope (embedded pubkey + namespace, frozen `attestationVersion=1`); **ECDSA P-256 is non-deterministic** → tests/fixtures verify, NEVER byte-compare sigs (golden artifact signed by a software key so CI verifies without an enclave; real-SE sign tests guard `SecureEnclave.isAvailable`).
- **Honest threat model → fail-closed.** Self-signed + embedded pubkey proves tamper-evidence, NOT identity-to-strangers (the "new key, new ledger" forge by an attacker-as-you is the residual). So `verify-attestation` exits **1 (fail-closed)** on a valid-but-unpinned sig; **0** only when trusted (`--expect-key <kid|pubkey>` match or explicit `--allow-untrusted-key`); 2 invalid; 3 expect-key mismatch; 6 malformed. attest: 0/2/9 (artifact produced, verify verdict) / 5 (attest failed, no artifact) / 6 (ledger error) / 64.
- **Additive; CLI-owned key store** at `~/Library/Application Support/dev.goh.attest/` (separate from the daemon dir; `O_CREAT|O_EXCL` handle, EEXIST→open, never clobber; `keys.json` is signer-side history, NEVER read on verify). NO existing format/command/exit-code changed; `ProvenanceRecord`/`VerifyAllReport`/`gohfile.lock` untouched. DESIGN.md §Provenance-everywhere reconciled (new "Hardware-attested provenance" subsection).
- **Process:** CCB (+ empirical SE spike) → research (DSSE-PAE / sshsig / minisign / ECDSA-non-determinism) → approach gate (A, user-selected) → design validation (5 gaps) → spec **2 adversarial rounds, 5 BLOCKs** → plan **2 adversarial rounds, 5 BLOCKs total** (round-2 caught 2 mechanical second-order blocks from the round-1 fixes: init-param-order vs trailing-closure `send`, + bare `Darwin.fsync` under -warnings-as-errors — both fixed, user-accepted at the gate) → `subagent-driven-development` (3 phases, per-task TDD with real SE) → **final cross-cutting Opus review APPROVED** (re-verified all 10 crypto/security invariants).
- **Commits (10):** `411a1dc` design+plan docs; `62786c6`/`049f076`/`a0799cb` P1 (AttestKeyLocation, AttestTypes+PAE, SecureEnclaveSigner); `489631a`/`2c43361`/`9b9dcf9` P2 (encode seam, golden fixtures, GohAttestCommand); `1a71fc5`/`a87692d` P3 (GohVerifyAttestationCommand + CLI wiring + integration); (pending) docs(attest) DESIGN.md + STATE.
- **Accepted non-blocking advisories (final review):** attest runs verify-all twice (exit-6 check + signed run) — 2× hashing on huge ledgers, deferred; no unit test for the SE-unavailable exit-5 path (CI can't hit it); unused `Data.nonEmpty` helper; `--expect-key` kid is 32-bit (documented, full-pubkey pinning is the strong form).
- **Recurring gotcha re-confirmed:** SourceKit "cannot find X in scope" lagged after every subagent edit; `swift build`/`swift test` disproved them ([[sourcekit-stale-after-subagent-edits]]).

**NEXT-SESSION HANDOFF — the trust-layer arc + the positioning pass are DONE; what's left is non-build:**
1. **DONE this session — the positioning pass.** README repositioned onto the offline-lockfile wedge + the hardware-attestation hook, MERGED to `main` via **PR #91** (squash `65a30ca`) — it's the live public face now ("An offline lockfile for the files you download…"). GitHub repo **description + topics updated live** (no names). **Launch-post draft refreshed** (`docs/vision/LAUNCH-POST-DRAFT.md`, gitignored/local) — repositioned, attestation hook, no third-party names, claim-only-today, with a note it's gated on the Developer-ID launch. All per the user's directives (no names; claim only what ships today). The `feat/readme-repositioning` branch is merged + deleted.
2. **The product is in a coherent place; the honest next moves are NON-BUILD.** Per an explicit mid-session conversation: the trust-layer capability is feature-complete (provenance-everywhere + sync-verified + `verify --all --json` + Secure-Enclave attestation, all on `main`); the bottleneck is awareness/launch, not code. Do NOT add more crypto/OS hardening to an unreleased, zero-user tool (post-quantum ML-DSA + FSEvents drift were researched and deliberately PARKED as premature; a web-research pass confirmed macOS 26.5 adds nothing relevant).
3. **Public launch (Phase 3)** is the real next step and is gated on **Apple Developer ID** (sign+notarize PKG, brew tap, SECURITY/CONTRIBUTING). Everything else for launch is ready (README, repo description, launch-post draft, talking points: provenance, `verify --all`/`--json`, sync-verified provenance, hardware attestation, `goh diagnose`).
4. **If BUILDING is wanted anyway**, the one feature with a real strategic reason is the vision's **`hf://` smart-URL adapter** (cross-source = the actual moat-widener, inherits an audience) — NOT more hardening. Other deferred: Touch-ID-gated attest key; per-entry ledger signing (Approach B); SM5a governor speed headline (needs a far/high-ceiling VPS).
2. **Deliberate "stop overbuilding" call (recorded mid-session):** do NOT keep adding crypto/OS features to an unreleased, zero-user tool. Two researched-and-PARKED tie-ins (post-quantum ML-DSA hybrid signing; FSEvents-driven background drift watch) were judged premature — they harden a tool nobody runs yet. The honest next lever is positioning (#1) and, if BUILDING, the vision's **`hf://` smart-URL adapter** (cross-source = the real moat-widener, inherits an audience) — NOT more hardening. A focused web-research pass (this session) confirmed macOS 26.5 adds nothing relevant; the only genuinely-new-ish API is ML-DSA (26.0), deliberately deferred.
3. **Public launch (Phase 3)** still gated on Apple Developer ID — the one external blocker; `goh diagnose` + provenance + `verify --all`/`--json` + sync-verified provenance + hardware attestation are all real launch talking points now.
4. **Other deferred candidates (only if a real reason emerges):** Touch-ID-gated attest key; per-entry ledger signing (Approach B); the deferred SM5a governor speed headline (needs a far/high-ceiling VPS).



**MERGED. Local `main` synced; `feat/verify-json` deleted (local + remote). 641 tests pass, `swift build -warnings-as-errors` clean. CI green at merge (Build & test + Package; signed-PKG skipped — needs Dev ID). CodeRabbit clean (4 findings, ALL docs-only — zero on code: 1 Major stale-exit-code-text in a planning artifact fixed in `6ebe163`, 2 markdown table nits fixed, 1 markdownlint-fences declined-with-reasoning + accepted by CodeRabbit; all 4 threads resolved). Real-binary spot-check passed (`goh verify --all --json` emits valid JSON; human/json exit codes match; usage shows the flag).** Built via the full `enterprise-pipeline` → `subagent-driven-development`.

- **What it is — wedge slice 3.** Adds a `--json` presentation mode to `goh verify --all` so the trust ledger drops into CI/cron ("re-verify `~/datasets` nightly, fail the build / alert on drift"). Emits a versioned JSON report (`reportVersion: 1`): `summary{total,ok,failed,missing}` + `entries[]{path,url,status(ok|failed|missing),expectedSha256,actualSha256?}`. Human `verify --all` output is **byte-identical** (unchanged); the exit-code contract (`0` all-ok · `2` mismatch · `9` missing, precedence 9>2>0 · `6` ledger error · `64` usage) is unchanged and now documented; `--json` returns the identical code as the human path.
- **Approach "Compute Once, Render Twice"** (chosen over a bolt-on parallel JSON path that would duplicate the verify loop). One re-hash pass builds `[VerifyEntryResult]` + one exit code; renders either today's human strings or the JSON report from the same model. `summary` is **folded from the final `entries[]`** (single source of truth, no parallel tally). Always-JSON on the 3 exit-6 conditions (a `VerifyErrorReport` envelope, never mixed text); empty/absent → valid empty report exit 0.
- **Frozen contract:** new CLI-layer types in `VerifyReportTypes.swift` (`VerifyAllReport`/`VerifyEntryResult`/`VerifyStatus`/`VerifyErrorReport`/`VerifyErrorCode`) with "do NOT rename" + a golden fixture (`verify-all-report-v1.json`, compact single line, `CommandCoding.encoder`). `ProvenanceRecord.currentVersion` stays 1; no protocol bump; `GohVerifyCommand` (lockfile verify) untouched. DESIGN.md §Provenance-everywhere reconciled (new "Machine-readable verify" subsection). Encoder = `CommandCoding.encoder` (`.iso8601`, `[.sortedKeys]`), deliberately over diagnose's bare `JSONEncoder()`; tests decode with `CommandCoding.decoder`.
- **Process (full rigor):** CCB → clarity check (user scoped to `--all --json` only, human output unchanged) → research (validated versioned-object schema + the `2`/`9` exit codes vs trivy/SARIF/`sha256sum`) → design validation (2 gaps fixed: injected `generatedAt` for fixture determinism; minimal frozen entry surface) → spec → **adversarial spec review 2 rounds, 2 BLOCKs fixed** (summary single-source-of-truth; the `--json` flag-parse grammar) → `custom-writing-plans` (5 tasks/3 phases) → **adversarial plan review APPROVED round 1, 0 BLOCKs** (reviewer byte-verified the golden fixture against live encoder output) → **spec+plan user gate (approved)** → `subagent-driven-development` (T1+2 / T3 / T4, each TDD with real `swift test`) → **final cross-cutting Opus `stack-aware-code-review` APPROVED** (re-encoded the fixture independently to confirm byte-equality; M3 human-byte-identity gate held — existing `GohVerifyAllCommandTests` pass unmodified). Final review's 2 doc advisories CLOSED: `--help` exit-code summary line added; DESIGN.md paragraph written.
- **Implementer-caught plan defect (don't re-introduce):** the plan's JSON-decode tests used a bare `JSONDecoder()`, but `CommandCoding.encoder` emits `.iso8601` dates → must decode with `CommandCoding.decoder` (the bare decoder `typeMismatch`es on `generatedAt`). Error-envelope tests can use a bare decoder (no Date field). The plan + 2 review rounds missed this; the TDD run caught it.
- **Commits on the branch (6):** `c0e799d` design+plan docs; `16257ab` T1 (frozen types); `41a3353` T2 (golden fixture); `3a3a6dd` T3 (run() compute-once-render-twice + JSON tests); `a93cc21` T4 (parse/dispatch/usage + parse tests); (pending) docs(verify-json) DESIGN.md + `--help` exit-code line + STATE.
- **Recurring gotcha re-confirmed:** SourceKit "Cannot find X in scope" diagnostics lagged after every subagent edit; `swift build`/`swift test` disproved them each time ([[sourcekit-stale-after-subagent-edits]]).

**NEXT-SESSION HANDOFF — slice 3 is MERGED; pick the next move:**
1. **Three trust-layer wedge slices are now on `main`** (provenance-everywhere #83, sync-verified provenance #85, `verify --all --json` #87). The "offline lockfile you can wire into CI" capability is feature-complete: every downloaded + sync-verified file is in the ledger, and `goh verify --all --json | jq` is a drift-watch with a documented exit-code contract (0/2/9/6/64). The strategic read (recorded earlier this session): the *capability* is done; the bottleneck is now *positioning/awareness*, not features.
2. **Strongest next move — Bet 1: the repositioning README + demo** (near-zero code). Now fully backed by shipped capability — show `goh verify --all --json | jq` as a nightly drift-watch / CI gate; sharpen the "vendor-neutral offline lockfile for the AI era's assets" positioning. See `docs/vision/VISION-2026-06-03.md`. Other self-contained code candidates if you'd rather keep building: `goh which` over a whole Downloads tree; a one-line exit-code summary already added to `--help` (done); folding `goh sync`'d files' provenance further.
3. **Public launch (Phase 3)** still gated on **Apple Developer ID** (sign+notarize PKG, brew tap, SECURITY/CONTRIBUTING). `goh diagnose` + governor + provenance/`verify --all`/sync-verified-provenance/`verify --json` are all real launch talking points now.
4. **Deferred:** SM5a governor speed headline (needs a far/high-ceiling VPS the user declined); P5 NWConnection multi-edge (feasibility spike + dedicated security review).



**MERGED. Local `main` synced; `feat/provenance-sync-skip-fold` deleted (local + remote). 620 tests pass, `swift build -warnings-as-errors` clean. CI green at merge (Build & test + Package; signed-PKG skipped — needs Dev ID). CodeRabbit re-reviewed clean (6 actionable findings addressed in `a7ecc71`, all 6 threads resolved; 2 declined with reasoning). REAL-DAEMON SMOKE PASSED** (dogfood v4 daemon over real XPC: `goh sync` of an all-present manifest → `up to date`/exit 0/no download; `goh which <skipped file>` → "verified present <date>" (was "(not recorded)" pre-slice); `verify --all` → OK; byte mutation → FAILED/exit 2; smoke artifacts + test ledger entry cleaned up). Built via the full `enterprise-pipeline` → `subagent-driven-development`.

- **CodeRabbit-caught fix worth recording:** a *pre-existing* on-disk lost-update window — `ProvenanceStore.record(entry:)` AND the new `recordVerified(entries:)` both released the `Mutex` before `writeAtomically`, so two concurrent writers (a download completion racing a sync batch) could reorder atomic renames and regress the ledger on disk. Fixed by moving the write INSIDE `withLock` in both methods (lock now held across the durable write). Also added daemon-side dispatch validation (nil-store guard + drop entries with a malformed `sha256:` prefix / empty path) and a `goh which` renderer fix (only show "last verified" when `downloadedAt < verifiedAt`).

- **What it is — trust-layer wedge slice 2.** The merged provenance-everywhere slice recorded only files goh *downloaded*. `goh sync` skips files already present + hash-matching (the `upToDate`/`firstUse`/accepted-`tofuChange` paths), so they landed only in `gohfile.lock`, never the ledger — `goh which`/`verify --all` were blind to them. This slice records sync-verified files into the daemon-owned `provenance.plist` too. (Discovery correction: downloaded-during-sync files were ALREADY recorded — sync routes them through the daemon `.add` path; the original handoff note "they only land in gohfile.lock" was wrong. Only the *skipped* files were the gap.)
- **Approach "The Courier"** (chosen over CLI-direct-write + flock, which has a fatal landmine: the daemon caches the ledger in memory, so a CLI write is silently clobbered by the daemon's next completion write — flock can't fix it; and over a read-time lockfile-reconciler, which never unifies the ledger). The CLI collects a `VerifiedProvenanceEntry` at each skip-return and sends ONE **best-effort** `recordVerifiedProvenance` batch XPC command; the daemon (sole writer) merges it in one `Mutex.withLock` + one atomic write (O(n), not O(n²)).
- **Two load-bearing design decisions (user-gated):** (1) **`verifiedAt`** added as an *additive-optional* field on `ProvenanceEntry` — `currentVersion` stays 1, golden fixture still round-trips; `downloadedAt` is never fabricated (hash-keyed merge: same-sha preserves real `downloadedAt`, else `downloadedAt = verifiedAt`); `verifiedAt != nil && downloadedAt == verifiedAt` = "confirmed, not downloaded." (2) **`goh which` is now ledger-first** (lock-fallback) + a three-way renderer (downloaded / verified present / both) — a deliberate precedence change (rewrote `GohWhichLedgerTests.lockPrecedence`), since the ledger is the unified more-current source.
- **Wire:** `protocolVersion` bumped **3 → 4** (new `envelope-v4-*` golden fixtures; `v3-*` retained); adds `Command.recordVerifiedProvenance` + `RecordVerifiedProvenanceRequest` + `VerifiedProvenanceEntry` + `AckReply`/`CommandOutcome.ack`. Frozen contracts otherwise unchanged (`ProvenanceRecord.currentVersion` 1, `JobCatalog` 1, `JobSummary`, `gohfile.lock` 1). DESIGN.md §Provenance-everywhere reconciled (new "Sync-verified provenance (skip-path fold)" subsection).
- **Process (full rigor):** CCB → ACs → 2 research agents → Opus approach memos → **approach gate (Courier + verifiedAt, user-selected)** → adversarial design validation (3 gaps fixed: hash-keyed `downloadedAt` merge, batch to avoid O(n²), best-effort non-fatal) → spec → **adversarial spec review 2 rounds, 5 BLOCKs fixed** (round-2 caught the `goh which` lock-first short-circuit hiding `verifiedAt` + the renderer-not-rewritten gap; fixed past the 2-round cap, user-accepted at gate) → `custom-writing-plans` (7 tasks / 3 phases) → **adversarial plan review 2 rounds, 1 BLOCK fixed** (v4 golden fixture had a numeric date decoded with the wrong codec → ISO-8601 + `CommandCoding.decoder`) → **spec+plan user gate (approved)** → `subagent-driven-development`: T1→T3→T2→T4→T5→T6→T7, each TDD with real `swift test`; **Opus `stack-aware-code-review` on Tasks 1–5 (APPROVED)** + **final cross-cutting Opus review of all 7 (APPROVED)**. Final review's one spec-divergence advisory (daemon dispatch arm swallowed store errors with no `warn`) was CLOSED (`595a0a1`).
- **Commits on the branch (9):** `f1ae6cc` design+plan docs; `22116e3` T1 (verifiedAt field); `b9f0c6b` T3 (wire types — also added the encodeReply `.ack` arm + a stub dispatcher arm to keep the build compiling); `a27a755` T2 (recordVerified merge); `5e18c03` T4 (protocolVersion 4 + v4 fixtures); `581b61b` T5 (dispatcher injection — replaced the T3 stub with real recording + gohd wiring); `5799102` T6 (sync batch emit + integration tests); `fb41d7a` T7 (which ledger-first + three-way renderer); `595a0a1` daemon warn on store-write failure.
- **Accepted non-blocking advisories (from final review):** which's three-way labels are substring-distinguished (tests use `.contains`); `writeAtomically` runs outside the store `Mutex` (pre-existing pattern in `record` too — snapshots are supersets, on-disk converges to the fullest write, no in-memory lost update).
- **Recurring gotcha re-confirmed:** SourceKit "Cannot find X in scope" diagnostics lagged after every subagent edit — `swift build`/`swift test` disproved them each time. Trust the compiler ([[sourcekit-stale-after-subagent-edits]]).

**NEXT-SESSION HANDOFF — slice 2 is MERGED + real-daemon-validated; pick the next move:**
1. **Dogfood lane note:** a v4 dogfood daemon is currently installed + running (`.build/dogfood/install/debug`, marked LaunchAgent, peer-relaxation env) with an empty ledger — left from this session's smoke test (it replaced a stale May-25 pre-provenance build). `Scripts/dogfood-reset.sh` tears it down; `Scripts/dogfood-build.sh && Scripts/dogfood-install.sh` rebuilds from `main` if you want a current one.
2. **Next trust-layer slice candidates (continue the wedge, all self-contained):** `verify --all` ergonomics (summary counts, `--json`); `goh which` over a whole Downloads tree; or **Bet 1 — the repositioning README + demo** (near-zero code; "offline lockfile for everything you pulled" is now fully true — downloaded AND sync-verified files are in the ledger). See `docs/vision/VISION-2026-06-03.md`.
3. **Public launch (Phase 3)** still gated on **Apple Developer ID** (sign+notarize PKG, brew tap, SECURITY/CONTRIBUTING). `goh diagnose` + the governor + provenance/`verify --all`/sync-verified-provenance are all real launch talking points now.
4. **Deferred:** SM5a governor speed headline (needs a far/high-ceiling VPS the user declined); P5 NWConnection multi-edge (feasibility spike + dedicated security review).



**MERGED. No open PRs (besides this docs-state followup). Local `main` synced; `feat/provenance-everywhere` deleted. 602 tests pass, `-warnings-as-errors` clean. CI green at merge (Build & test + Package; signed-PKG skipped — needs Dev ID). CodeRabbit re-reviewed clean (3 findings, all addressed in `383638a`: a real latent `ProvenanceStore` stale-in-memory-state-on-reload fix + 2 regression tests, plus 2 doc nits). The full `enterprise-pipeline` design pass + `subagent-driven-development` implementation shipped.**

- **What it is — the chosen trust-layer wedge slice (user-selected over public launch / speed proof / P5).** "Provenance-everywhere, verify-only": every successful download — manifest `goh sync` OR ad-hoc `goh add`/foreground `goh <url>`, **including resume** — auto-records `{url, sha256, size, downloadedAt, destinationPath}` into a new **daemon-owned `provenance.plist`** (`~/Library/Application Support/dev.goh.daemon/`). `goh which` answers from it offline; a new **`goh verify --all`** re-hashes everything recorded against the user's own frozen record (OK/FAILED/MISSING). **Verify-only** — no content-addressed byte storage (goh *tells* you it drifted/vanished, doesn't restore). Two user gates decided the shape: (1) **Tell-you / verify-only** over keep-the-bytes; (2) **auto-record on every download** over opt-in. Self-contained (no hub API/login) per [[goh-prefers-self-contained]].
- **Approach A — "The Native Ledger"** (chosen over B global-auto-lock / C append-log / D SQLite at the approach gate). A 4th daemon plist store mirroring `HostProfileStore` (Mutex<Inner>, atomic temp→0600→fsync→rename→dir-fsync, corrupt→sidecar **copy**, **no TTL** by design), own `currentVersion=1` + golden fixture. The SHA-256 the engine **already computed and discarded** is now captured: digest threaded through all 3 completion paths via a widened **daemon-internal** `completedDownloadHandler` (`sha256: String?`); daemon records it **best-effort** (do/catch+warn, can never fail a download — mirrors `SpotlightMetadataTagger`). CLI reads the store **directly** (read-only, `create:false`, no XPC) so `which`/`verify --all` work with the daemon down.
- **THE BET:** personal-scale download counts never make the O(n) full-plist rewrite per completion user-perceptible. Escape hatch (append-log/SQLite behind the same `record`/`lookup`/`allEntries` surface) documented if it ever fails.
- **Frozen contracts ALL unchanged** (verified in the final diff): `protocolVersion` 3, `JobCatalog.currentVersion` 1, `JobSummary` wire shape, `gohfile.lock` `lockfileVersion` 1, `DownloadCheckpoint`/`HostScheduling` v1, `GohVerifyCommand` + its exit codes. `provenance.plist` is purely additive with its own version.
- **Process (full rigor):** `enterprise-pipeline` → CCB / ACs / 2 research agents / Opus approach memos → **approach gate (A)** → adversarial design validation (3 fixes folded in: best-effort recording, resume records too, direct-CLI-read-no-XPC) → spec → **adversarial spec review 2 rounds, 6 BLOCKs fixed** (2-round cap; round-2 fixes mechanical, user accepted at gate) → `custom-writing-plans` (10 tasks / 3 phases) → **adversarial plan review 2 rounds, 4 BLOCKs fixed** (round-2 caught a chdir/parallelism flaky-test the round-1 fix introduced) → **spec+plan user gate (approved)** → `subagent-driven-development`: P1 (value layer) / P2 (engine+daemon capture) / P3 (CLI surfaces), each with an Opus `stack-aware-code-review` (all APPROVED) → **final cross-cutting Opus review APPROVED** (traced the full download→record→which→verify-all value flow: prefix applied once, canonicalization byte-identical both sides). Artifacts under `docs/superpowers/{research,specs,progress,retrospectives}/2026-06-04-provenance-everywhere-*` and `docs/plans/2026-06-04-provenance-everywhere-plan.md`. DESIGN.md reconciled (§Persistence).
- **Commits on the branch (10):** `8ab1d39` design docs; `a48b92d`/`2ce0da1`/`984495b` P1; `dd63c01`/`2ab4b82` P2; `8f3a2b1`/`779c39d`/`d40fbc1`/`f7d119c`/`f6a2e15` P3; `3cad70d` resume-test strengthening.
- **Recurring gotcha re-confirmed this session:** the IDE's **SourceKit index lags badly** after a subagent adds/edits files — it repeatedly reported phantom "Cannot find X in scope" / old-arity-closure errors that the authoritative `swift build -warnings-as-errors` + `swift test` disproved every time. Trust the compiler, not the IDE diagnostics, after subagent edits.

**NEXT-SESSION HANDOFF — provenance-everywhere is MERGED; pick the next move:**
1. **Optional real-network smoke (never ran; not in CI):** build the binary, `goh add` a real URL, then confirm `goh which <file>` shows the recorded sha256/url/date (not "(not recorded)"), `goh verify --all` reports OK; mutate a byte → FAILED; delete a file → MISSING. The cross-SDK golden-fixture risk is now CLOSED (CI green on the macos-26 runner with the value-equality round-trip).
2. **Carried advisory (non-blocking):** `verifyAll` nil-resolver passes `""` → treated as "no store" (benign; near-impossible path — `defaultURL(create:false)` would have to throw). Not worth a fix unless touched again.
3. **Next trust-layer slice candidates (all self-contained, continue the wedge):** `goh which` over a whole Downloads tree / `verify --all` ergonomics (summary counts, `--json`); recording `goh sync`'d files into the SAME global ledger (today they only land in `gohfile.lock`); or **Bet 1 — the repositioning/README + TRELLIS demo** (near-zero code, sharpens the "offline lockfile for everything you pulled" positioning now that `verify --all` ships). See `docs/vision/VISION-2026-06-03.md`.
4. **Public launch (Phase 3)** remains gated on **Apple Developer ID** (sign+notarize PKG, brew tap, SECURITY/CONTRIBUTING). `goh diagnose` + the governor + now `provenance`/`verify --all` are real launch talking points.
5. **Deferred:** SM5a governor speed headline (needs a far/high-ceiling VPS the user declined); P5 NWConnection multi-edge (feasibility spike + dedicated security review).

### 2026-06-04 (merge session) — **#80 (governor) + #81 (`goh diagnose`) BOTH MERGED to `main`**

**Both feature PRs are squash-merged to `main`; no open PRs. Local `main` synced; feature branches deleted.**

- **PR #80 — in-flight adaptive parallelism (P1–P4) governor** → squash `147156f`. Ships the BBR-style
  aggregate-delivery-rate governor + dynamic chunk pool + interval-set assembler + per-host connection budget.
  Framed as **correct + adaptive + no-regression**; the SM5a headline benchmark stays **deferred**
  (environment-limited — the user's last-mile saturates at 8 conns; needs a far/high-ceiling VPS to prove).
  P5 (NWConnection multi-edge) remains a separate future PR behind a feasibility spike + dedicated security review.
- **PR #81 — `goh diagnose <url>`** → squash `3e923ac`. Self-contained CLI-local diagnostics verb (no daemon,
  no XPC, purely additive). Built via the full `enterprise-pipeline` → `subagent-driven-development`. Design +
  decisions captured in the 2026-06-04 build entry below and DESIGN.md (§Transport cancellation-race fix, §CLI
  `goh diagnose`).
- **CI + review:** both green at merge (Build & test + Package; signed-PKG skipped — needs Dev ID). All
  CodeRabbit findings on both PRs addressed. One #81 suggestion (`conn0Ended` on every conn-0 terminal path)
  was **declined with reasoning and CodeRabbit conceded** ("My suggestion was wrong… withdrawn") — it would have
  reintroduced the `accepted<N` flake; the no-first-byte gating is intentional.
- **Two CI bugs found + fixed on #81 during review (both CI-only, passed locally):** (1) a 6-hour **deadlock** —
  the synchronous `DispatchSemaphore` async→sync bridge in `GohDiagnoseCommand` was called from Swift Testing
  `@Test` bodies (which run *on* the cooperative pool); under CI's narrow pool it starved all pool threads.
  Fixed by invoking the bridge off-pool (detached thread) in tests; production (main-thread) is safe. See
  [[swift-sync-async-bridge-cooperative-pool-deadlock]]. (2) Phase-2 sampling **flakes** (`accepted=1`,
  `multiConnMBps=nil`, `--full` hang) from synchronous `usleep` stub delivery blocking URLSession threads →
  migrated those stubs to `asyncChunkDelivery` + generous test deadlines.
- **Merge mechanics for the record:** #80 and #81 had **zero code-file overlap but both edited STATE.md +
  DESIGN.md**, so #81 conflicted once #80 landed. Resolved by merging `main` into `feat/diagnose` (STATE.md
  kept both session entries; DESIGN.md auto-merged), verifying the union (567 tests pass, clean build), then
  squash-merging. Squash chosen for both (clean single commit per feature; the TDD/CI-fix/CodeRabbit iteration
  commits stay in the PRs — matches the #77 precedent).

**NEXT-SESSION HANDOFF — both v0.2 slices are on `main`; pick the next move:**
1. **Trust-layer wedge (the strategic moat).** Per the ROADMAP + `docs/vision/VISION-2026-06-03.md`: the
   vendor-neutral **offline lockfile** ("is this still exactly what I downloaded?") is the defensible,
   self-contained direction the user favors ([[goh-prefers-self-contained]]). Best candidate for the next slice.
2. **Public launch (Phase 3)** — gated on **Apple Developer ID credentials** (the one blocker outside the code):
   sign+notarize the PKG (PR #36 workflow), open the `xaedyn/homebrew-goh` tap, add SECURITY/CONTRIBUTING/
   CODE_OF_CONDUCT, launch post. `goh diagnose` + the governor are now real launch talking points.
3. **Deferred speed proof** — the SM5a governor headline still needs a high-ceiling proving ground (far VPS,
   ~1¢/hr Vultr Tokyo researched) or a faster link; the user declined the VPS for now.
4. **P5 (NWConnection multi-edge)** — separate future PR behind a feasibility spike + dedicated security review.

### 2026-06-04 (session) — `goh diagnose` **BUILT + PR #81 open**; governor PR #80 also open (headline dropped)

**Two PRs now open against `main`, independent (zero file overlap):**

**1. PR #81 — `goh diagnose <url>` — COMPLETE, on branch `feat/diagnose` (off `main`).** A self-contained
CLI-local diagnostics verb (mirrors `goh verify`/`which`; no daemon, no XPC, no new wire/on-disk format —
purely additive, `protocolVersion` 3 / `JobCatalog.version` 1 / `JobSummary` / lockfile/manifest all unchanged).
Probes a URL → plain-English report: reachability, Range support, negotiated protocol (h2/h3/1.1), parallel
connections attempted vs accepted (catches 429), throughput at 1-vs-N connections, and a hedged bottleneck
verdict. `--full` / `--json` / `--connections N|-c N` (1–16). **528 tests pass, `-warnings-as-errors` clean.**
  - **Built via the full `enterprise-pipeline`** (CCB → ACs → research → approaches → spec → 2-round adversarial
    spec review → `custom-writing-plans` → 2-round adversarial plan review → user gate) then
    `subagent-driven-development` (9 tasks, per-task two-stage review, a dedicated **Opus concurrency review** on
    the sampler, and a **final cross-cutting review**). Artifacts under `docs/superpowers/{research,specs,
    progress,retrospectives}/2026-06-03-goh-diagnose-*` and `docs/plans/2026-06-03-goh-diagnose-plan.md`.
  - **Chosen approach: Comparative Probe** — measures T₁ (1 conn) vs Tₙ (ramp to N) and reports whether
    parallelism helped. **THE BET:** a single hedged 1-vs-N comparison is enough for a useful verdict, and
    "can't tell" is an acceptable honest answer for the ambiguous case.
  - **Load-bearing design decisions (frozen in the code + DESIGN.md):** (a) **probe-without-abort** — diagnose
    does NOT reuse the engine's abort-on-non-206 path; it records each connection's outcome and continues, so
    "accepted 6 of 8" is observable. (b) **Protocol-gated verdict honesty** — 7 `Verdict` cases (a **frozen v1
    `--json` contract**); over h2/h3/unknown, parallel range requests multiplex onto one connection, so the
    verdict takes the conservative `didNotScaleMultiplexed` branch and does NOT claim a link-vs-server cause —
    only exact `http/1.1` (separate TCP conns) yields the `didNotScaleHTTP1` dichotomy, hedged. (c) **sync CLI +
    async probe** bridged via `DispatchSemaphore` *inside* `GohDiagnoseCommand` (the CLI/`main.swift` stay
    synchronous, doctor-pattern). (d) exit codes derive from a typed `ProbeTermination` (0/2/3/4), never from
    `verdictText`; 64 at the arg-parse layer.
  - **Engine change that rode along (benefits ALL callers incl. real downloads):** closed an
    already-cancelled-on-entry race in `StreamingDataTask.streamingResponse` (`if Task.isCancelled {
    taskBox.cancel() }`) that could leak a `URLSession` task when `withTaskCancellationHandler` fires `onCancel`
    before `taskBox` is set. Documented in DESIGN.md §Transport.
  - **Review-caught defects fixed during build (don't re-introduce):** spec round-2 — the verdict was
    confidently-wrong over h2/h3 multiplexing (→ the protocol-gated split); plan round-2 — the deadline bounded
    only Phase 1 (→ a single task-group whose deadline child bounds the whole probe), `--full` stopped at the
    window, Tₙ used a constant divisor + excluded conn-0 (→ boundary snapshots across all conns); Task-5
    concurrency review — a UInt64 underflow **crash** on tiny ranged files and a `--full` **hang** on a
    206-no-body server (both fixed + regression-tested); final review — a DESIGN.md paragraph described a
    non-existent `.bottleneck`/`isHedged` design (corrected to the shipped 7-case verdict).
  - **NEXT for #81:** CodeRabbit + CI auto-running (do NOT poll — wait for the user). When green + reviewed,
    merge to `main`. Optional real-network smoke (not in CI): `goh diagnose` against an h2 host, an http/1.1
    host, a 429-rate-limiting host, and a no-Range host.

**2. PR #80 — in-flight adaptive parallelism (P1–P4), branch `design/in-flight-parallelism`.** Reframed as
"correct + adaptive + no-regression governor; SM5a headline benchmark deferred (environment-limited — the user's
last-mile saturates at 8 conns, not a code limit)." Still open; CodeRabbit/CI running. P5 (NWConnection
multi-edge) is a separate future PR. NOTE: that branch's STATE.md has the detailed 2026-06-03 governor entry;
it is NOT on `main` (or on `feat/diagnose`) until #80 merges.

**Session-end housekeeping for next time:** both PRs (#80 governor, #81 diagnose) are open and independent —
merge order doesn't matter (no file overlap; diagnose branched off `main` and only *inlines* engine privates,
doesn't modify the engine except the additive StreamingDataTask cancel guard). The trust-layer wedge
(vendor-neutral offline lockfile, `docs/vision/VISION-2026-06-03.md`) remains the strategic moat — next
self-contained slice candidates live there.

### 2026-06-03 (session) — Governor **REDESIGNED + fixed** (was inert/regressing); LFN headline unprovable on this link; strategic **pivot to the trust layer**; `goh diagnose` scoped next

**Branch `design/in-flight-parallelism`. Commit `38be1b0` (`fix(governor): redesign convergence around aggregate delivery rate`). 507 tests pass, `-warnings-as-errors` clean. NOT pushed yet.**

**1. The governor was broken — now fixed (committed).** Running Task 19's benchmark caught it: the in-flight
governor was **inert** and *regressed* ~20% vs static-8 on a real LFN. Root cause (confirmed via field
instrumentation, 0/120 evaluations ever "steady"): the per-worker steady-state detector (`allWorkersInSteadyState`,
"all connections within 5%") could never pass on a real network — real per-flush rates jitter 10–206%, slot 0 was
sample-starved, and `decide()` was called on `liveWorkers` (N−1, an off-by-one). Governor sat at the seed N the
whole download.
  - **Fix (commit `38be1b0`):** replaced the per-worker gate with a **BBR-style hill-climb on the AGGREGATE
    delivery rate**. Governor now takes one aggregate sample per control window via
    `record(aggregateBytesPerSecond:)`; the engine measures aggregate over **≥0.25 s windows** (per-reap intervals
    were too short → jitter) from the shared `ByteCounter` (added a `.value` getter) and passes the **operating
    `targetN`** to `decide()` (off-by-one fixed). Dwell `settleSamples` windows at each N, keep a step up the
    `{2,4,8,16}` ladder only when aggregate gain ≥ `kneeGainThreshold`, else settle lower; periodic cruise
    re-probe. `Config.default` tuned: `settleSamples 8, kneeGainThreshold 0.07, reprobeCadence 40, rateAlpha 0.3`.
    Removed `RateSampleSink`/`WorkerRateSample`/per-worker machinery. Files: `ParallelismGovernor.swift` (rewrite),
    `DownloadEngine.swift` (aggregate sampling + operating-N), `ParallelismGovernorTests.swift` (rewritten, 7 tests).
  - **Validated:** trace now shows correct convergence (dwell@8 → addWorkers → dwell@16 → commit(16) → cruise@16,
    no detour) and **no regression** (governed ≈ static-8).

**2. The SM5a "headline win" is UNPROVABLE on this connection — and that's an environment limit, not a bug.**
  - Original target `sin-speed.hetzner.com` **rate-limits parallel connections** (6/8 → HTTP 429). Unusable. Note:
    the engine currently **hard-fails (httpStatus)** when a server 429s a parallel range — a real product-robustness
    gap worth a future design pass (governor should back off, not abort).
  - Switched to **OVH France** (`https://proof.ovh.net/files/1Gb.dat` — 8/8 parallel 206, ~105 ms RTT, https,
    honors Range). Good LFN target. Results in `docs/bench/lfn-results-worksheet.md` (full before/after recorded).
  - **n=9: governed 20.36 s vs static-8 20.71 s — ~1.7 %, IQR overlaps.** Raw curl proved why: aggregate throughput
    is the SAME at 8 and 16 conns (~57 MB/s ceiling) AND two far sources combined ≤ one source. **The bottleneck is
    the user's last-mile (~50–57 MB/s to distant hosts over Wi-Fi), not the source.** 8 conns already saturate it;
    16 has no headroom; multi-source can't help either. A clean SM5a win needs higher RTT + uncapped + higher-ceiling
    (a self-hosted far VPS, e.g. Vultr Tokyo — researched, ~1¢/hr) or a faster link. User declined the VPS for now.
  - **Disposition:** the governor ships as **correct + adaptive + no-regression**; the *benchmarked* headline is
    deferred (needs a proper proving ground). Worksheet `OVERALL: NEEDS-TUNING/defer headline`.

**3. STRATEGIC PIVOT — speed is at the physics ceiling for this user; the moat is the trust layer.** Ran the
`product-vision` skill (parallel codebase + market analysis, both Opus). New memo: **`docs/vision/VISION-2026-06-03.md`**
(supersedes the trust-layer sections of `VISION-2026-05-26.md`). Sharpened thesis: don't pitch "trust layer" (too
close to OpenSSF signing) or "integrity for downloads" (HF/Ollama do per-source already). The **unowned, defensible
wedge goh already built**: a **vendor-neutral, offline lockfile** — *"is this still exactly what I downloaded?"*
verified against YOUR frozen record, across any source, even if upstream is deleted (HF's `hf cache verify` checks
the LIVE hub; the TRELLIS-deletion case proves upstream isn't a reliable oracle). Evidence: aria2 #173 (open since
2013), HF #3298/#3643, Ollama #14554. Platform risk: ~12 mo before HF could close the HF-only slice.

**4. `hf://` adapter — proposed then DECLINED by the user.** The vision's top "bet" was smart-URL adapters
(`hf://`, `kaggle://`). User **declined**: doesn't want to couple goh to an external service's API (breakage +
maintenance) or build any login/token path. New memory saved: **[[goh-prefers-self-contained]]** — favor
self-contained trust-layer work, don't pitch external-service integrations.

**5. NEXT ACTION — build `goh diagnose <url>` (self-contained; scoped, not started).** Surface the engine's existing
diagnostics (`EngineDiagnostics`/`GOH_ENGINE_TRACE`, `Sources/GohCore/Engine/EngineDiagnostics.swift`) as a clean
plain-English CLI verb. **Confirmed behavior:** quick ~10 s sample by default, `--full` flag for the whole file;
discards the bytes; CLI-local (no daemon, no new XPC/wire surface — mirror `goh verify`/`which`). Report shape (user
approved): server + range support, negotiated protocol (h2/h3/1.1), #connections opened & how many the server
accepted (catch 429 rate-limiting), throughput estimate, bottleneck (last-mile vs source), one-line verdict.
  - **THE DESIGN WRINKLE to solve first:** to report *"server rejected 6 of 8 connections"*, diagnose **cannot**
    reuse the normal download path (it aborts on the first non-206 — the Hetzner httpStatus failure). Needs a
    **probe mode that opens connections and records each outcome WITHOUT aborting**. Everything else is
    straightforward reuse (DownloadEngine + EngineDiagnostics, run in-process, temp/throwaway sink, ~10 s
    cancel, structured summary instead of stderr-scraping → extend EngineDiagnostics to retain structured data).
  - Files likely touched: new `GohDiagnoseCommand.swift`, `EngineDiagnostics.swift` (structured capture),
    `GohCommandLine.swift` (verb + usage), tests. ~3–5 files. Start with `enterprise-pipeline` (it has the
    probe-without-abort design decision) — or `quick-plan` if the wrinkle resolves trivially on inspection.

**Session-end housekeeping for next time:** `38be1b0` is unpushed on `design/in-flight-parallelism`. The
in-flight-parallelism P1–P4 work is functionally done + correct but the SM5a headline benchmark is deferred — decide
whether to (a) PR P1–P4 as "correct adaptive governor, no regression" (drop the headline claim), or (b) hold for a
VPS/faster-link proof. The `goh diagnose` work is a fresh, self-contained slice — could be its own branch off this
one or off `main` after deciding the P1–P4 PR question.

---

### 2026-05-31 (impl session) — In-flight adaptive parallelism **P4 code done (Tasks 17–18)**; only Task 19 (the manual benchmark run) remains before the headline ships

- **P4 Tasks 17 + 18 shipped on `design/in-flight-parallelism`** (the autonomous code parts). **508 tests
  pass**, warning-clean. Task 19 (running the benchmarks) is the **you-in-the-loop** step — see below.
  - `24d4cb6` + `d45934d` — **Task 17:** global per-host `ConnectionBudget` (spec §8) gated into the control
    loop (budget request before each spawn, worker-`defer` release, leak-proof). **Opus-reviewed ✅.** It's a
    **soft cap with a liveness floor**: a download that would seed zero workers (siblings hold the budget)
    force-admits exactly one un-budgeted connection so it always progresses — peak per-host bounded at
    `16 + (D−1)`. Default-nil in the engine (no behavior change for existing tests); gohd creates one shared
    16-budget. DESIGN.md §Adaptive host scheduling documents the soft-cap.
  - `fe08c5a` — **Task 18:** `goh-bench lfn` subcommand (governed vs `--static-n`, median + IQR seconds,
    JSON out) + `docs/bench/lfn-runbook.md` (SM5a/SM2 commands + quarantine policy). The static control arm
    uses the explicit-connection-count channel to disable the governor. Builds; not run (real network).
- **NEXT ACTION — Task 19 (manual, you-in-the-loop): run the benchmarks + tune + write the P4 artifact.**
  This is the only thing between here and shipping the single-edge headline. **The fill-in worksheet is
  `docs/bench/lfn-results-worksheet.md`** (copy-paste commands + result slots + a RESULTS SUMMARY block the
  next session reads first; embeds a `Range`-honoring server for the local SM2 test). Rationale is in
  `docs/bench/lfn-runbook.md`. When the user says "results are in the worksheet," read its summary block and
  either write the P4 artifact + prep the P1–P4 PR, or iterate on tuning if a gate failed. Two gotchas the
  smoke test caught: `GOH_ENGINE_TRACE` needs the built binary (not `swift run`), and the governor only
  engages on a `Range`-honoring server (`python3 -m http.server` returns 200 → single-connection). Steps:
  (1) **SM5a** — `swift run goh-bench lfn --url https://sin-speed.hetzner.com/1GB.bin --runs 5 --output
  governed.json` vs `--static-n 8 --output static8.json`; accept = governed median < static8 median,
  non-overlapping IQR. (2) **SM2** — saturated target via dummynet ([[dummynet-macos26-confirmed]], needs
  sudo via `!`) or a throttling CDN; accept = governed median ≤ 1.05× static8 (≤5% regression = rollback
  trigger). (3) Confirm **SM1** probe→cruise via `GOH_ENGINE_TRACE=1 ... | grep '^governor '`. (4) If the
  win is marginal or SM2 regresses, **tune `Config.default` + `chunkSize`** against the medians and re-run.
  (5) Write `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase4.md` with the numbers.
  **Then P1–P4 is the proven single-edge headline → one PR.** P5 (NWConnection multi-edge) is a separate
  later PR behind its feasibility spike + dedicated security review.
- **Do NOT PR yet:** the governor is default-on but UNPROVEN on real networks until Task 19 passes SM5a/SM2;
  the PR's CI can't run the LFN benchmarks. Merge a *proven* feature.

### 2026-05-31 (impl session) — In-flight adaptive parallelism **P3 COMPLETE** (governor functional + fed back to bandit); next = P4 (benchmarks + per-host budget)

- **P3 of 5 shipped on `design/in-flight-parallelism`.** **503 tests pass**, warning-clean,
  strict-concurrency-clean. **The in-flight governor is now functional** — it adjusts the live connection
  count during a download and feeds its converged candidate-aligned N back into the per-host bandit. Full
  breakdown in the P3 artifact (`docs/superpowers/progress/...-phase3.md`) and the detailed in-progress entry
  below. Commits: Task 10 `af6e728`, Task 11 `bcb0ece`, **Task 11A `a0160df`** (fixed-size chunk pool,
  Opus-reviewed), **Task 12 `df35c8d`** (governor wired + explicit-N off channel + GovernorOutcome,
  Opus-reviewed), Task 13 `090af0a` (warm-start trace), Task 15 `d82ad98` (governor trace), Task 14 `5b28652`
  (DESIGN.md), P3 artifact (next commit).
- **The architectural gap (build-it-right):** the plan would have wired an inert governor onto P2's "N big
  pieces"; **Task 11A** (the spec §6.1 fixed-size-chunk pool + byte progress + connection slots) was added as
  the prerequisite that makes the governor actually converge. Both 11A and 12 (the data-path + concurrency
  cores) passed dedicated **Opus concurrency/data-integrity reviews** (no blocks; the governor never overrides
  an explicit `--connections` pin; the bandit can't be polluted; no data race; cooperative drop loses no bytes).
- **Two review-caught issues (don't re-introduce):** (1) `Mutex` is noncopyable → used the project's
  reference-type idiom (`ExplicitConnectionCounts`, `RateSampleSink`, like `ByteCounter`); (2) the 11A slot
  force-unwrap was a latent crash → closed in Task 12 (clamp `targetN`∈[1,16] + guard slot allocation).
- **Invariants held:** `protocolVersion` 3, `JobCatalog.version` 1, `JobSummary` wire shape,
  `host-scheduling.plist` v1, `DownloadCheckpoint` v1 — all unchanged. `GovernorOutcome`/`ExplicitConnection
  Counts`/`RateSampleSink` are daemon-internal.
- **NEXT ACTION — P4 (Tasks 17–19): the headline benchmarks + per-host budget.** (1) **Task 17** — global
  per-host `ConnectionBudget` (deliberately deferred from P2/P3; insert the budget gate into the control
  loop's `fillToTarget` + a worker-`defer` release — the structure is ready). (2) **Task 18** — `goh-bench`
  LFN subcommand + runbook (path is `Benchmarks/goh-bench/`, NOT `Sources/`). (3) **Task 19** — prove **SM5a**
  (governed > static N=8 on a sourced LFN target, non-overlapping IQR) and **SM2** (≤5% saturated regression)
  using the **confirmed dummynet harness** ([[dummynet-macos26-confirmed]]) + `sin-speed.hetzner.com/1GB.bin`;
  **tune `Config.default` + `chunkSize`** against measured convergence (first-cut values). P4 **ships the
  single-edge headline.** Then P5 (NWConnection multi-edge, behind a feasibility spike + security review).
  Continue with `subagent-driven-development`, real `swift test`
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). Do **not** re-run design/spec/plan review.

### 2026-05-31 (impl session) — In-flight adaptive parallelism **P3 detail** (Tasks 10–11 + architectural gap → Task 11A)

- **P3 started on `design/in-flight-parallelism`.** Tasks 10 + 11 shipped (497 tests pass, warning-clean):
  - `af6e728` — **Task 10:** `SelectionReason.warmStart` + `ObservationRequest` parameter struct; the
    observation gate now keys off the governor outcome (`effectiveN != nil && stabilized`) instead of the
    old `actualConnectionCount == requestedConnectionCount`. `recordObservationIfEligible` added. All 7
    gate tests + the `gohd` call site migrated. **`d5GateConnectionMismatchRejected` → `d5GateOffCandidate
    Rejected`** (the actual==requested condition no longer exists).
  - `bcb0ece` — **Task 11:** `JobStore.setActualConnectionCount` is now peak-max
    (`max(existing, min(count,16))`, cap 16 not requestedN). DESIGN.md note added.
- **⚠️ WIP CAVEAT (don't merge mid-P3):** after Task 10, `gohd/main.swift` builds the `ObservationRequest`
  with `governorOutcome: .governorOff` (a `// TODO(P3 Task 12)` placeholder), so the daemon currently
  records **NO** bandit observations until Task 12 passes the real `GovernorOutcome` through a 4-arg
  `completedDownloadHandler`. This is an intentional intermediate state on the WIP branch; the end state
  (Task 12) restores observation recording with the governor's converged N.
- **ARCHITECTURAL GAP FOUND + RESOLVED (user gate "build it right", 2026-05-31):** the plan's P3 wired the
  governor onto P2's "N big pieces" queue — but the governor can only *add* a worker if there is spare
  unclaimed work, and N pieces are all claimed up front, so the governor would be **inert**. The spec §6.1
  mandates **fixed-size chunks** (a daemon constant, independent of N) that workers pull one at a time —
  that is what enables live add/drop. P2 used N-pieces for behaviour-equivalence; P3 must switch. Added
  **Task 11A** to the plan (`docs/plans/...-plan.md`, before Task 12): fixed-size chunk pool + byte-based
  progress (replacing the per-piece-index `RangeProgress`) + connection-slot indexing (`0..<targetN`,
  reused; the governor's `WorkerRateSample.workerIndex` must be a stable slot, not the chunk index).
  Behaviour-equivalent at fixed N (identical bytes/SHA-256). This is the prerequisite that unblocks the
  governor. **The user chose "build it right" over "wire structurally only" or "re-plan with full review."**
- **NEXT ACTION — Task 11A (the heavy, sensitive rework; do with an Opus implementer + Opus concurrency +
  data-integrity review).** Design is written in the plan's Task 11A section. Key points: `chunkSize`
  daemon constant (≈8 MiB) made **injectable** on `DownloadEngine` (default 8 MiB) so tests can pass a
  small value (e.g. 1 MiB) to exercise multi-chunk parallelism; the `withThrowingTaskGroup` element type
  becomes the **slot id** (`Int`) so reaps free the slot; `consumeRange`/`downloadRange` swap
  `progress: RangeProgress` → a `Mutex<UInt64>` byte counter and take the slot as their trace index; the
  first chunk `[0, chunkSize)` reuses `firstRangeStream`; expect to fix tests that asserted a specific
  piece/connection count (pass a small chunkSize or adjust). THEN Task 12 (wire the governor — now
  functional), 13 (warm-start trace), 14 (DESIGN.md), 15 (governor trace), 16 (kill-switch + artifact).
  Continue with `subagent-driven-development`, real `swift test`
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). Do **not** re-run design/spec/plan review.

### 2026-05-31 (impl session) — In-flight adaptive parallelism **P2 COMPLETE** (dynamic chunk pool + interval-set assembler); next = P3

- **P2 of 5 shipped on `design/in-flight-parallelism`** via `subagent-driven-development` (TDD, two-stage
  review incl. Opus quality/concurrency). **493 tests pass** (was 483 at P1 end; +10), warning-clean,
  strict-concurrency-clean. **Behaviour-equivalent at fixed N — no functional change**; this is the
  structural rework enabling P3's live-N governor. Four atomic commits + artifact:
  - `efe69cf` — `ChunkQueue` + `ByteInterval` (`Sources/GohCore/Engine/ChunkQueue.swift`).
  - `b99fdd1` — interval-set `ChunkAssembler` rework: `complete(interval:)` additive-merge, coalesce,
    byte-0 frontier, `[0,total)` end-condition; SHA-256 in-order invariant preserved; `advance`/`fixedLength`
    deleted; all callers migrated (incl. `goh-bench/main.swift`).
  - `9a02981` — fix: empty (`Content-Length: 0`) downloads digest the canonical empty SHA-256 instead of
    failing (regression caught by Opus quality review).
  - `b41136a` — control-loop worker pool in `fetchRanged`: single-control-loop-inside-`TaskGroup`
    (sole `addTask` caller), `ChunkQueue`-seeded, range-0 `firstRangeStream` reuse preserved. Opus
    concurrency review APPROVED (single-adder safe, behaviour-equivalent, no race/hang/lost-cancellation).
  - P2 artifact: `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase2.md`.
- **Two defects caught by review & fixed (don't re-introduce):** (1) the plan's `init(totalBytes: UInt64)`
  + `fetchSingle` `?? UInt64.max` was a bug for unknown-length downloads → corrected to
  **`init(file:totalBytes: UInt64?)`** (nil = unknown, skips end-condition); (2) the empty-file regression
  above. Both have regression tests.
- **`ConnectionBudget` is a P4 deliverable** — deliberately NOT referenced in P2's control loop (the plan's
  Task 8 text mentioned it prematurely). P4 inserts the budget gate + worker-`defer`-release into the
  structure P2 built. **`setActualConnectionCount` peak-max is Task 11/P3** — P2 calls it with peakWorkers
  (== ranges.count at fixed N); the JobStore method body is unchanged.
- **Invariants held:** `protocolVersion` 3, `JobCatalog.version` 1, `JobSummary` wire shape,
  `host-scheduling.plist` v1, `DownloadCheckpoint` v1 — all unchanged (checkpoint `recordCompletedPiece`
  called identically per-flush).
- **NEXT ACTION — P3 (Tasks 11–18):** wire the governor to the pool. `setActualConnectionCount` peak-max
  semantics (Task 11); `ObservationRequest`/`SelectionReason.warmStart` (Task 10/11); the explicit-N
  governor-off channel (ephemeral `Mutex<[UInt64:UInt8]>` jobID→N table in gohd — NOT a JobSummary field);
  compute per-flush rate **deltas + per-worker EWMA** from `consumeRange`'s accumulator (currently
  cumulative `(bytes,elapsed)`, unconsumed) and feed `WorkerRateSample`s to the governor; apply
  `GovernorDecision` via `targetN` + `fillToTarget`; emit candidate-only `GovernorOutcome` to the bandit;
  warm-start (SM4); `GOH_ENGINE_TRACE` governor lines; DESIGN.md §Persistence/§Observability reconciliation.
  Continue with `subagent-driven-development`, real `swift test`
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). Do **not** re-run design/spec/plan review.

### 2026-05-31 (impl session) — In-flight adaptive parallelism **P1 COMPLETE** (governor + clock + dummynet confirmed); next = P2

- **P1 of 5 shipped on `design/in-flight-parallelism`** via `subagent-driven-development` (TDD per task,
  two-stage review). **483 tests pass** (was ~481), warning-clean under `-warnings-as-errors`,
  strict-concurrency-clean. **No behaviour change** — the governor is a pure value type, unit-tested
  only; nothing is wired to the engine yet. Six atomic commits + artifact:
  - `bf0aca6` — inject `ContinuousClock` into `fetchRanged` (deterministic testability; defaulted param,
    callers unchanged).
  - `b451823` — per-chunk rate accumulator at the `consumeRange` `flush()` chokepoint (**P1 placeholder**,
    `_ = rateSamples`; not yet consumed).
  - `6875bd9` + `6c75420` — pure `ParallelismGovernor` (three-phase: probe / knee / cruise+re-probe,
    gain-only RTT fallback) + **strengthened SM3 tests**. Review caught that the first-cut SM3 tests
    passed via a degenerate `allWorkersInSteadyState`-false early-return; they were rewritten to genuinely
    drive the probe-up, RTT-bufferbloat, and gain-only-knee branches.
  - `3f57db2` — `GovernorOutcome` daemon-internal struct (`{effectiveN: UInt8?, stabilized: Bool}` +
    `.governorOff`); **never on the wire**.
  - `e3cfe9d` — P1 progress artifact.
- **dummynet spike CONFIRMED (spec §12.1 top `[UNVERIFIED]` risk — now closed):** `dnctl`+`pfctl` work on
  **macOS 26.5 / arm64** (live `dnctl pipe 1 config bw 50Mbit/s delay 150 plr 0.005` → `DUMMYNET_OK`).
  **P4's hermetic benchmark gate uses `dnctl`+`pfctl` directly; the Linux-VM `tc netem` fallback is not
  needed.** See [[dummynet-macos26-confirmed]].
- **Open items carried to P2/P3** (full list in the P1 artifact): the rate-sample tuple is a placeholder
  (P3 must compute per-flush deltas + per-worker EWMA, not cumulative bytes/total-elapsed);
  `.dropWorkers`/`Phase.pinned` are forward-API reserved for P3 wiring; `Config.default` values are
  first-cut, tuned against the dummynet harness in P4; the RNG is stored-for-later (revisit in P3).
- **Invariants held:** `protocolVersion` 3, `JobCatalog.version` 1, `JobSummary` wire shape,
  `host-scheduling.plist` v1, `DownloadCheckpoint` v1 — all unchanged.
- **NEXT ACTION — P2 (Tasks 6–10):** the highest-risk phase. Replace the static `ByteRange.split` +
  `TaskGroup` with a dynamic `ChunkQueue` + **interval-set frontier `ChunkAssembler`** (the SHA-256
  in-order invariant + `[0,total)` end-condition + additive-merge `complete(interval:)` — round-2 plan
  review's compile-break fix migrated `verifyHash`/`fetchSingle`/`consumeRange` callers off the deleted
  `advance`) + the **single control-loop-inside-the-`TaskGroup`** live worker pool with worker-owned
  `defer` budget release (Block-2 fix). Behaviour-equivalent at fixed N until P3 drives it. Continue with
  `subagent-driven-development`, one task at a time, real `swift test`
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). Do **not** re-run design/spec/plan review.

### 2026-05-31 (planning session) — In-flight adaptive parallelism: implementation plan **WRITTEN + 2-round adversarial review PASSED + USER-APPROVED at the gate**; P1 implementation starting

- **Plan written** via `custom-writing-plans` (Sonnet): `docs/plans/2026-05-31-in-flight-adaptive-parallelism-plan.md`
  — **25 TDD tasks segmented at the spec's P1–P5 boundaries** (P1: 5 / P2: 4 / P3: 7 / P4: 3 / P5: 6),
  every task with failing-test-first Swift Testing stubs, exact `DEVELOPER_DIR`-prefixed `swift test`
  commands, complete copy-pasteable Swift, and SM1–SM6/AC1–AC5 mapped to owning tasks. Five phase
  artifacts seeded under `docs/superpowers/progress/2026-05-31-in-flight-adaptive-parallelism-phase{1..5}.md`.
- **Reviewed** via `adversarial-plan-review` (Opus), the **2-round cap reached**:
  - **Round 1 — 6 BLOCKs, all fixed:** (1) explicit `--connections` never disabled the governor (silent
    override of a user pin); (2) `actualConnectionCount` wasn't actually peak-max; (3) dual-writer clobber
    between the legacy `advance` shim and the new interval-set `complete(interval:)`; (4) under-specified
    per-host budget / `TaskGroup` single-adder ownership; (5) vacuous SM4 tests (`#expect(true)` / wrong
    assertion); (6) wrong `goh-bench` path (`Sources/` vs `Benchmarks/`).
  - **Round 2 — 3 BLOCKs, all fixed:** all were *second-order defects the round-1 fixes introduced* —
    (1) three legacy `ChunkAssembler` callers (`verifyHash`/`fetchSingle`/`consumeRange`) left unmigrated
    → compile break; (2) per-host budget **slot leak** on a worker-throw path; (3) the governor-off test
    under-asserted. Fixed with caller migration to `complete(interval:)` + `init(file:totalBytes:)`,
    worker-owned `defer` slot-release via a `fillToTarget` helper, and a strengthened test asserting peak
    N stays pinned. **No unresolved BLOCKs.** Remaining advisories: side-table not cleared on `rm`
    (harmless/bounded), kill-switch is a compile-time constant (spec permits env *or* constant).
  - **3rd review NOT authorized** (2-round cap); user accepted the mechanical round-2 fixes as the gate
    decision (the per-task `swift test` + review gates in subagent-driven-development are the real check).
- **USER GATE PASSED:** plan approved; proceed to implementation, **P1 first**.
- **Key design invariants the plan preserves** (verify they hold at every task): `protocolVersion` 3,
  `JobCatalog.version` 1, `JobSummary` wire shape, `host-scheduling.plist` v1 — **all unchanged**. The
  explicit-N governor-off channel is an *ephemeral daemon-internal* `Mutex<[UInt64:UInt8]>` jobID→N
  table in `gohd` (NOT a `JobSummary` wire field). `GovernorOutcome` is daemon-internal; off-candidate
  convergence records nothing (no EWMA bias). The pure `ParallelismGovernor` takes injected clock + RNG.
- **NEXT ACTION — implement P1** via `superpowers:subagent-driven-development`, one task at a time, TDD,
  real `swift test` (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`), two-stage review gate
  after each task. P1 = injected `ContinuousClock` into `fetchRanged`/`consumeRange` + per-chunk rate
  sampling at the `flush()` chokepoint + the pure `ParallelismGovernor` (geometric probe / knee / cruise,
  SM3 deterministic) + the `GovernorOutcome` struct + the **dummynet-on-macOS-26 verification spike**
  (fallback: Linux-VM `tc netem`) — one of the two MUST be confirmed in P1 so SM1/SM3 get a hermetic
  deterministic gate. No behaviour change ships in P1. Do **not** re-run design, spec review, or plan
  review — all closed.

### 2026-05-31 (design session) — In-flight adaptive parallelism: four-round design **APPROVED** + benchmark plan; **no code yet**

- **Slice started:** in-flight adaptive parallelism (the v0.2 performance headline), driven through
  `enterprise-pipeline`. This is a *design-only* session per the directive: four-round design + a
  benchmark-sourcing plan, **no code**.
- **Approach chosen (USER GATE):** **A3 — continuous in-flight governor + multi-edge fan-out** (the
  end-state path). A BBR-style governor lifted to *connection count*, driven by URLSession
  delivery-rate + coarse chunk-timing, with history-seeded warm-start unifying with the PR #77
  bandit.
- **Load-bearing finding (verified):** multi-edge fan-out is **infeasible on URLSession** — Apple
  documents no SNI override when connecting to a raw IP, and a trust-delegate can't fix the SNI byte
  on the wire. **Decision:** build multi-edge **correctly on NWConnection**
  (`sec_protocol_options_set_tls_server_name` for SNI + `sec_protocol_options_set_verify_block` for
  hostname-pinned trust) — a hand-rolled **HTTP/1.1 range client over `NWConnection<TLS>`** for the
  IP-pinned edge connections. This **revises the URLSession-only transport brief** (DESIGN.md
  §Transport — an *addition* for the one case URLSession can't serve, not a reversal). Bonus:
  NWConnection gives **separate real TCP connections** — the structural lever that beats HTTP/2
  multiplexing (the amenable gap).
- **Spec APPROVED** through **2 adversarial Opus rounds**. Round 1 found 4 real BLOCKs — the
  URLSession-SNI infeasibility, a hand-waved interval-frontier rework, `actualConnectionCount` wire
  semantics under a varying N, and live-`TaskGroup` add/drop concurrency — all resolved; round 2 =
  all 10 categories PASS. 5 advisories (the "10★" scrub actioned).
- **Phasing (deployment-independent; P1–P4 independent of P5):**
  1. **P1** — injected `ContinuousClock` + per-chunk rate instrumentation + the pure
     `ParallelismGovernor` (deterministic SM3 test). No behaviour change. Includes the **dummynet-on-
     macOS-26 verification spike** (fallback: Linux-VM `tc netem`).
  2. **P2** — dynamic chunk pool + **interval-set frontier** `ChunkAssembler` + the single-control-
     loop-inside-the-group worker pool (single edge, URLSession).
  3. **P3** — wire the governor; **observation-gate redesign** + **candidate-only** bandit feedback
     (off-candidate convergence records nothing — no EWMA bias) + warm-start; governor trace lines.
  4. **P4** — global per-host connection budget; LFN `goh-bench` harness + runbook → **ships the
     headline (SM5a)**.
  5. **P5** — NWConnection HTTP/1.1 multi-edge transport + the verify block + the **transport-brief
     revision**, behind a **feasibility spike** and a **dedicated security review** (trust-core
     Phase 3 precedent). Dormant behind a constant until then.
- **Invariants held:** `protocolVersion` 3, `JobCatalog.version` 1, `JobSummary` wire shape, and
  `host-scheduling.plist` v1 all **unchanged**; all governor feedback is daemon-internal (a
  `GovernorOutcome` struct on the completion sink, no wire field). `actualConnectionCount` keeps its
  wire shape; its meaning is re-documented as "peak concurrent connections used."
- **Benchmark-sourcing plan (2nd deliverable):** spec §12 + the research brief's options table.
  Local `dnctl`/`pfctl` dummynet (P1 verifies on macOS 26; `tc netem` VM fallback) as the **hermetic
  deterministic gate**; `sin-speed.hetzner.com/1GB.bin` for the real no-throttle LFN proof (SM5a);
  optional ~$5/mo Singapore VPS; Cloudflare `__down` for multi-edge (SM5b, best-effort, P5).
- **Artifacts** (all under `docs/superpowers/`): `research/2026-05-31-in-flight-adaptive-parallelism-{ccb,acceptance-criteria,brief,approaches,design-validation}.md`
  and `specs/2026-05-31-in-flight-adaptive-parallelism-design.md`. **Not yet committed** — no branch
  cut this session (design artifacts only).
- **Branch state:** `design/in-flight-parallelism` is **pushed** to origin (commit `ed48486`, all 6
  artifacts + this STATE.md). Work from this branch — do **not** branch off `main` again.
- **CLOSED — do NOT re-run:** the design pass is finished. Do not re-run `enterprise-pipeline`,
  approach generation, the approach gate, or `adversarial-spec-review` — the spec is **approved**
  (2 rounds, all 10 block categories pass) and the approach (A3, multi-edge via NWConnection) is a
  settled user decision. Do not re-litigate the URLSession-SNI finding (see the
  [[urlsession-no-sni-override-for-ip]] memory).
- **NEXT ACTION — kick off the implementation plan.** Go **straight to `custom-writing-plans`**
  (the CLAUDE.md override that replaces `writing-plans`), dispatched as a Sonnet subagent with:
  - `SPEC_FILE_PATH` = `docs/superpowers/specs/2026-05-31-in-flight-adaptive-parallelism-design.md`
  - `RESEARCH_BRIEF_PATH` = `docs/superpowers/research/2026-05-31-in-flight-adaptive-parallelism-brief.md`
  - `TECH_STACK` = from `CLAUDE.md` §Stack; `PROJECT_CONVENTIONS` = from `CLAUDE.md` (Test/Branch
    discipline, four-round, the recurring gotchas).
  - **Segment the plan at the spec's P1–P5 phase boundaries** (they are deployment-independent;
    P1–P4 ship the single-edge headline, P5 is the NWConnection multi-edge + security-review gate).
  Then **`adversarial-plan-review`** (the CLAUDE.md override; max 2 rounds; fix block issues between
  rounds). Then **USER GATE: spec+plan approval**, then `superpowers:subagent-driven-development`
  implementing **P1 first** (pure governor + injected clock + per-chunk instrumentation + the
  dummynet-on-macOS-26 verification spike), TDD, real `swift test`
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, see [[dev-toolchain-developer-dir]]).
  **Still no implementation code until the plan is approved at the gate.**

### 2026-05-31 (merge session) — Phase 2 adaptive scheduling **MERGED to `main`**; next = Phase 3 launch

- **Both PRs merged to `main` via squash** (branch protection: PRs required, self-merge OK; branches deleted on origin + local):
  - **PR #77** — adaptive per-host range scheduling — squash commit **`32efda1`**.
    The whole Phase 2 feature is now on `main`: a per-host ε-greedy bandit over
    `{2,4,8,16}` persisted in the daemon-owned `host-scheduling.plist`, D5/D8-gated
    observation recording, and a `GOH_ENGINE_TRACE` scheduling-decision line.
    **473 tests pass**, `-warnings-as-errors` clean. CI green at merge (Build &
    test, Package artifacts; signed-PKG skipped — needs Dev ID). CodeRabbit clean.
    `protocolVersion` 3 / `JobCatalog.version` 1 / `JobSummary` unchanged. DESIGN.md
    §Adaptive host scheduling documents the frozen v1 format.
  - **PR #78** — in-flight adaptive parallelism **design seed** + ROADMAP v0.2 entry
    — squash commit **`e048ec8`**. Docs-only; freezes nothing. The seed
    (`docs/design-notes/2026-05-31-in-flight-adaptive-parallelism.md`) designs a
    BBR-style governor on *connection count* for single-download optimization
    (multi-edge IP fan-out, protocol-aware connection-vs-stream, history-seeded
    start that unifies with the per-host bandit), plus the `URLSession`-signal
    constraint and a benchmark-sourcing gate. The v0.2 performance headline.
- **Squash was chosen deliberately for #77:** a personal email had leaked into an
  intermediate branch commit (`00c79ba`); squashing kept the redacted final
  `STATE.md` on `main` and the leaking commit out of `main`'s history. Residual:
  GitHub may retain that commit reachable by direct SHA / in the merged-PR commits
  view for a while (and it was transiently public). See the `cross-repo-email-audit`
  memory; GitHub Support purge or address rotation are the only full remediations.
- **NEXT ACTION — strategic arc Phase 3: public launch.** The one gate outside the
  code is **Apple Developer ID credentials**. Sequence (from the gitignored
  `docs/vision/VISION-2026-05-26.md` and the handoff at the bottom of this file):
  1. **Sign + notarize the PKG** via PR #36's `private-release-candidate` workflow
     (shape already verified by `Scripts/verify-private-release-workflow.sh`; what's
     missing is the secrets).
  2. **Open the `xaedyn/homebrew-goh` tap** and publish the PR #29/#30 formula.
  3. **Add `SECURITY.md` / `CONTRIBUTING.md` / `CODE_OF_CONDUCT.md`** (SECURITY.md
     first — disclosure address for a tool handling cookies + sensitive URLs).
  4. **Polish the launch post** (`docs/vision/LAUNCH-POST-DRAFT.md`, gitignored).
  5. **Post to HN + r/macapps + r/commandline + r/datahoarder.**
  - **Alternative track (no credential gate):** the in-flight-parallelism slice
    (PR #78 seed) as the v0.2 performance headline — needs its own four-round design
    pass + *sourced* long-fat-network / multi-edge-CDN benchmarks before it can claim
    a win (current benchmark hosts throttle and would mask it).

### 2026-05-31 (impl session) — Phase 2 (adaptive scheduling): IMPLEMENTED, PR #77 open

- **Branch:** `design/adaptive-scheduling`; PR **#77** open against `main`
  (https://github.com/xaedyn/goh/pull/77). All 9 plan tasks + 1 hardening
  follow-up shipped; **473 tests pass** (was 424 on `main`; +49), `swift build`
  warning-clean under `-warnings-as-errors`. Built with
  `superpowers:subagent-driven-development` — one task at a time, TDD, two-stage
  review (spec compliance + Opus stack-aware code quality) after each task, plus a
  final cross-cutting Opus review (✅ approved, zero block issues).
- **What shipped (10 atomic commits):**
  - **Phase 1 (pure value layer):** `hostKey(for:)` D1 normalizer
    (`Sources/GohCore/Scheduling/HostKey.swift`); the frozen v1 Codable on-disk
    types `HostScheduling`/`HostProfile`/`ConnObservation` + `foldingIn` EWMA fold
    + golden round-trip fixture (`HostScheduling.swift`,
    `Tests/.../Fixtures/host-scheduling-v1.plist`).
  - **Phase 2 (persistence + selection):** `HostProfileStore` (atomic versioned
    plist, 0600, 90-day TTL eviction, corrupt→sidecar, the begin/wasSolo/end
    contended-set active-job index, `recordObservation`, the pure D5/D8
    `shouldRecordObservation` gate, `selectN`); the pure ε-greedy `BanditSelector`.
  - **Phase 3 (engine + wiring):** widened `completedDownloadHandler` to carry the
    transfer-phase `Duration` + `isResume`; admission-time N resolution in
    `CommandDispatcher` (explicit honored, else bandit); the D5/D8-gated
    observation recording wired in `gohd/main.swift`; the engine begin/end
    active-job bracket; `GOH_ENGINE_TRACE` scheduling-decision line; CI-enforced
    pure selector regression tests + an optional env-gated `goh-bench
    regression-guard`.
- **Invariants held:** `protocolVersion` stays 3; `JobCatalog.version` stays 1;
  `JobSummary` struct unchanged. The new plist is daemon-internal — not in the XPC
  wire or the catalog. **DESIGN.md reconciled** this session (§Adaptive host
  scheduling documents the frozen v1 format, per the four-round discipline).
- **Review-caught & fixed during implementation (don't re-litigate):** the plan's
  punycode test paired two different domains (corrected to assert the real
  ASCII/deterministic/credential-free invariants); a `SeededRNG` xorshift64
  zero-trap (seed 0 → infinite loop) guarded; a hardcoded test date that would age
  past the TTL (made relative); a `Dictionary(uniqueKeysWithValues:)` that could
  trap the daemon at admission on a corrupt duplicate-arm plist (→
  `uniquingKeysWith:`); and the load-bearing D5 gate extracted from an inline gohd
  closure into the unit-tested pure `shouldRecordObservation` (7 cases).
- **NEXT ACTION:** PR #77 review. CodeRabbit triggered at feature-complete. When
  green + approved, merge to `main`. Then the strategic arc's **Phase 3 — public
  launch** (sign+notarize PKG via PR #36 workflow, open the brew tap, SECURITY/
  CONTRIBUTING/CODE_OF_CONDUCT, launch post) — see the launch sequence preserved in
  the older handoff below and the gitignored `docs/vision/VISION-2026-05-26.md`.
- **Order-correction note for the record:** the plan listed Task 3 (HostProfileStore)
  before Task 4 (BanditSelector), but Task 3's `selectN` references `BanditSelector`,
  so Task 4 was implemented first (the only deviation from plan order; plan content
  unchanged).

### 2026-05-31 (later session) — Phase 2 (adaptive scheduling): design + plan COMPLETE, ready to implement

- **Branch:** `design/adaptive-scheduling`, off `main` at `48ec675`. Not yet pushed.
- **What this is:** Phase 2 of the strategic arc — **adaptive per-host range
  scheduling**. The daemon learns the best parallel-connection count per host
  empirically (epsilon-greedy bandit over `{2,4,8,16}`) and persists it in a new
  daemon-owned `host-scheduling.plist` (versioned, atomic, 0600, mirrors
  `CheckpointStore`). Scope pinned this session: **adaptive scheduling only**
  (HTTP/3 deferred), **internal-only** (no new user command), bar = **measurable
  adaptation** (beating aria2c is a goal, not a ship gate — the amenable gap is
  structural). `protocolVersion` stays 3; `JobCatalog.version` stays 1 (no schema
  change — N is resolved at admission in `CommandDispatcher`, the engine's only
  touch is widening `completedDownloadHandler` to carry the transfer-phase
  `Duration`).
- **Connection ceiling decision:** keep **16**. Per-host count is governed by
  server tolerance + protocol dynamics (per-IP abuse limits, HTTP/2 multiplexing
  conflict, slow-start/TLS overhead, bufferbloat), NOT client bandwidth. Filling a
  fat pipe is mirror-racing's job (v0.2), not more sockets to one origin.
- **Where the work lives:**
  - Design spec (FROZEN on-disk format): `docs/superpowers/specs/2026-05-31-adaptive-scheduling-design.md`
    — 10 decisions (D1–D10); survived **2 adversarial spec-review rounds** (Opus).
  - Plan: `docs/plans/2026-05-31-adaptive-scheduling-plan.md` — **9 tasks, 3 phases**,
    TDD throughout; survived **2 adversarial plan-review rounds** (Opus).
  - Phase artifacts: `docs/superpowers/progress/2026-05-31-adaptive-scheduling-phase{1,2,3}.md`
- **The 3 phases (deployment-independent, implement in order):**
  1. **Pure value layer** — `HostKey` normalizer (strip credentials, nil→skip,
     IPv6 bracketed, punycode) + `HostScheduling`/`HostProfile`/`ConnObservation`
     Codable on-disk types + golden round-trip corpus & CI guard.
  2. **Persistence + selection** — `HostProfileStore` (atomic versioned plist,
     0600, TTL-on-load eviction, corrupt→sidecar, in-memory `begin/wasSolo/end`
     contended-set index) + epsilon-greedy `BanditSelector` (pure, seeded).
  3. **Engine + wiring** — widen `completedDownloadHandler` to carry transfer-phase
     `Duration`; admission-time N resolution in `CommandDispatcher`; D5-gated
     observation recording (success + ≥10s + ≥8MiB + actual==requested + solo +
     stable path; resume excluded per D8); regression guard (CI selector tests +
     optional env-gated `goh-bench regression-guard`); `GOH_ENGINE_TRACE` decision line.
- **Review caught (don't re-litigate):** the spec review fixed a nil-host bucket
  collapse, credential-at-rest, the missing regression detector, the D6 resolution
  timing, and the throughput clock provenance (the engine's `started` clock is
  phase-local and must be threaded to the sink — the "no engine change" claim was
  wrong). The plan review caught a **silent total-failure bug**: an inverted
  `activeCount` gate (the `run()` defer decrement fires AFTER the completion
  handler) — replaced with a per-job `contended`-flag faithful to D5's
  "solo for the whole duration"; plus a non-buildable AC11 benchmark, now split
  into CI-enforced selector tests + an optional manual harness.
- **NEXT ACTION (fresh session):** implement the plan with
  `superpowers:subagent-driven-development`, **Phase 1 first**, one phase at a time
  with real `swift test` runs. Do NOT re-run design or plan review — both are
  closed at the 2-round cap with all block issues resolved. Local `swift test`
  needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Push the branch
  + open the PR when a phase is green (the branch is unpushed at session close).
- **Side task done this session:** cross-repo identity audit — **DLXV (macvid)
  made private** (it was public with a personal email + real name in all 12
  commits). chronoscope has 40 public `Co-Authored-By: Claude` trailers (deferred,
  lower urgency); mirelo/crown-of-the-touched/lowest_listed are private landmines
  (personal email in history) to scrub before ever flipping public. See the
  `cross-repo-email-audit` memory.

### 2026-05-31 — Trust core: **MERGED to `main`** (PR #75), all 6 phases shipped

- **Status:** PR #75 **merged** to `main` 2026-05-31 as merge commit `fdb55e8`
  (https://github.com/xaedyn/goh/pull/75) — `--merge` (not squash), so all 25
  atomic phase-by-phase commits are preserved in `main` history. CI was green at
  merge (Build & test, Package artifacts); signed-PKG gate skipped (needs Developer
  ID). CodeRabbit findings all addressed (triage comment on the PR).
  The `design/trust-core` branch is merged; safe to delete (still present on origin
  at session close).
  Built with `superpowers:subagent-driven-development` — one phase at a time, TDD,
  a two-stage (spec + quality) review gate after each phase, plus a final
  cross-cutting review. **Test count 314 → 424, all green, `-warnings-as-errors`
  clean. `protocolVersion` stayed 3; catalog schema unchanged — purely additive,
  no migration.**
- **What shipped:** `gohfile.toml` (manifest) + `gohfile.lock` (lockfile) frozen
  on-disk formats, and `goh sync` / `goh verify` / `goh which`.
- **The 6 phases as built:**
  1. **TOML reader+writer** — `Sources/GohCore/TrustCore/MinimalTOMLReader.swift`
     (+`MinimalTOMLWriter.swift`): hand-rolled subset parser (§9.5), 14 golden
     fixtures, named errors for every out-of-subset construct. Review hardened the
     underscore-int + bare-string diagnostics and added message-content assertions.
  2. **Codecs + digest** — `ManifestCodec` (§7), `LockfileCodec` (§8, encode/decode),
     `FileDigest` (at-rest streaming SHA-256), shared `Sha256Format` validator.
  3. **Daemon write-path hardening** — `DownloadFile` now materializes paths via a
     base-free `openat` descent (`mkdirat` for missing dirs; `O_NOFOLLOW` on the
     final + immediate-parent + every created component; `O_CLOEXEC` throughout);
     new `ErrorCode.symlinkComponentRefused`. **Running-code gate passed:** 8
     symlink-swap/TOCTOU tests written first, seen fail, then pass. macOS forces
     following pre-existing prefix symlinks (`/var`→`/private/var`); an independent
     security review ruled the residual base-free-undecidable and the CLI realpath
     layer's + accepted-v0.1-residual's job — NO-OP on further daemon tightening.
     DESIGN.md §Persistence + §2.4 reconciled.
  4. **`goh which`** — `CLI/GohWhichCommand.swift`: lock lookup (entries resolved
     under the lock dir, symlink-resolved compare for `/var`, confined to the lock
     tree) then `getxattr` Spotlight provenance; exit 4 when neither. Default lock
     = cwd `./gohfile.lock`.
  5. **`goh verify`** — `CLI/GohVerifyCommand.swift`: read-only re-hash vs lock;
     `OK`/`FAILED`(2)/`MISSING`(9); `flock(LOCK_SH)` busy→7; stale manifestHash→6;
     unknown lockfileVersion→6 (NOT 1); `--strict-untracked`→10; precedence 9>2>10.
  6. **`goh sync`** — `CLI/GohSyncCommand.swift` + `TrustCore/SyncPathConfinement.swift`:
     lexical+realpath CLI confinement (rules 1–2, exit 5); loop `add` + poll `ls`
     by job id with an injectable no-progress watchdog; CLI-side re-hash only
     (never trusts a daemon hash); pinned acceptance with `.corrupt-<unix>`
     quarantine (exit 2); TOFU first-use + AC5 change event (exit 3 /
     `--accept-changed`; `verify=false` suppresses the drift event); atomic lock
     write (`.tmp`→fsync→`rename`→fsync dir); precedence 5>2>3>8. Also wired
     `which`/`verify`/`sync` into the real CLI parse/run/usage.
- **Final cross-cutting review** caught a frozen-format round-trip bug: the TOML
  codecs didn't escape `"`/`\` in url/path strings. Fixed — `LockfileCodec.encode`
  escapes, `MinimalTOMLReader` un-escapes `\"`/`\\` and preserves `#` inside quotes
  while still stripping a real trailing comment. A `TrustCoreRoundTripTests` corpus
  (`"`, `\`, `#`, `=`, `?`, spaces, unicode) is now a CI guard for both formats.
- **Exit-code contract (frozen §9.4):** 0; 2 integrity; 3 TOFU-change; 4
  no-provenance; 5 path-escape; 6 lock missing/corrupt/stale/unknown-version; 7
  lock-busy; 8 download-failed; 9 verify-missing; 10 strict-untracked; 64
  usage/bad-manifest (incl. `auth` reserved); 1 only generic daemon/transport.
- **NEXT ACTION:** **Phase 2 of the strategic arc — adaptive per-host range
  scheduling.** It freezes a per-host on-disk record, so per the ROADMAP design
  gate it starts with a **four-round design pass, not code**. Before starting:
  `git checkout main && git pull` (local was on a feature branch at session
  close), and delete the merged `design/trust-core` branch (local + origin).
- **Process notes:** Phase 3's running-code gate worked as designed — the spec's
  literal "O_NOFOLLOW every component" was caught as unshippable on macOS by the
  full suite (broke ~85 tests), corrected to the base-free boundary, confirmed by
  an independent security review. The hand-rolled TOML parser's missing string
  escaping was caught only by the final cross-cutting round-trip review, not the
  per-phase reviews — a reminder that frozen wire/disk formats need an explicit
  adversarial round-trip corpus, which now exists.

### 2026-05-30 — Trust core (Phase 1 of strategic arc): design + plan COMPLETE, ready to implement

- **Branch:** `design/trust-core`, off `main`, **pushed to origin**. Two commits:
  - `4976483` — approved design spec + research artifacts.
  - `fcf47ac` — the 6-phase implementation plan + spec exit-code reconciliation.
- **What this is:** the `gohfile.toml` + `gohfile.lock` manifest/lockfile and the
  `goh sync` / `goh verify` / `goh which` commands — the "trust core," Phase 1 of
  the ROADMAP strategic arc (reproducible, integrity-verified asset management).
  Approach 1: **lockfile-as-product, CLI-local, no XPC protocolVersion change**
  (stays 3), re-hash on demand. Trust-on-first-use by default, strict when pinned.
- **Where the work lives:**
  - Spec (FROZEN formats): `docs/superpowers/specs/2026-05-29-trust-core-design.md`
    — status `approved`; survived 4 adversarial spec-review rounds.
  - Plan: `docs/plans/2026-05-29-trust-core-plan.md` — 6 phases, TDD throughout;
    survived 2 adversarial plan-review rounds + targeted fixes.
  - Phase artifacts: `docs/superpowers/progress/2026-05-29-trust-core-phase{1..6}.md`
  - Research: `docs/superpowers/research/2026-05-29-trust-core-*.md`
- **The 6 phases (deployment-independent, implement in order):**
  1. Hand-rolled TOML reader+writer (+ golden fixtures) — depends on nothing.
  2. Manifest + Lockfile codecs + `FileDigest` (at-rest SHA-256 wrapper).
  3. **Daemon `DownloadFile` path-confinement hardening** (`O_NOFOLLOW` + base-free
     `openat` descent). ⚠️ Carries a **running-code verification gate**: its
     symlink-swap TOCTOU correctness is established by PASSING TESTS under TDD, not
     prose — write the symlink-swap tests first, see them fail, implement, see them
     pass, then a mandatory review of the COMPILED+TESTED code before merge. The
     residual same-machine symlink-race is an ACCEPTED v0.1 limitation (consistent
     with the SMAppService threat-model deferral); lexical confinement (Phase 6
     `SyncPathConfinement`) is the load-bearing defense against the real
     hostile-manifest attack.
  4. `goh which` (CLI-local; lock reader + new `getxattr` provenance reader).
  5. `goh verify` (CLI-local; re-hash vs lock; missing=9, strict-untracked=10).
  6. `goh sync` (CLI-local loop over `add`; ls-poll completion detection +
     watchdog; CLI lexical+realpath pre-flight; pinned/TOFU/AC5; atomic lock write).
- **Exit-code contract (reconciled with DESIGN.md):** 0 success; **64** usage/
  bad-input (incl. bad manifest input + `auth` reserved-field); **1** generic
  daemon/transport; 2 integrity; 3 TOFU-change; 4 no-provenance; 5 path-escape;
  6 lock missing/corrupt/stale + unknown lockfileVersion; 7 lock-acquire; 8
  download-failed; 9 verify missing-file; 10 verify strict-untracked.
- **NEXT ACTION (fresh session):** implement the plan with
  `superpowers:subagent-driven-development`, **Phase 1 first** (the TOML reader),
  one phase at a time with real `swift test` runs (NOT a big parallel fan-out).
  Do NOT re-run plan review — planning is closed; Phase 3's openat precision is
  deliberately deferred to TDD per its running-code gate. Local `swift test` needs
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (see memory).
- **Process note for next time:** the path-confinement mechanism ate ~6 review
  rounds because adversarial reviewers escalated an out-of-scope (per goh's own
  threat model) TOCTOU concern to a blocker; low-level POSIX syscall choreography
  is verified far better by running tests than by prose review. Lesson banked.

---

### 2026-05-29 — platform floor corrected; wordmark redesign parked

- **Branch:** `docs/macos-floor-26.0`, off `main`. Corrects the supported-OS
  claim from macOS 26.5+ to **26.0+** — the real floor, a hard requirement of
  the daemon's macOS 26.0 XPC peer-validation API (`XPCPeerRequirement`,
  `XPCRequirement.isFromSameTeam`, the requirement-carrying `XPCListener` /
  `XPCSession` initializers). Proven by building at a 15.0 floor and watching the
  compiler reject exactly those symbols. Docs-only plus a `Package.swift` comment;
  the `.macOS("26.0")` value is unchanged. Also fixed the `CLAUDE.md` IPC note
  that had mislabeled `XPCPeerRequirement` as macOS 14+. See `DESIGN.md`
  §Platform support.
- **Logo redesign parked:** a wordmark reconstruction effort (cormorant-italic /
  custom-cormorant / free-font drafts) is committed as WIP on branch
  `fix/smooth-wordmark-vector` (commit `5cf22a5`). Current logo kept as-is;
  direction to be revisited later. Leave that branch alone until then.
- **Prior context (code-review sweep):** branch
  `docs/state-after-code-review-sweep`, based on `main` at `06564af`.
- **Current state:** A full code-review sweep ran across `main` after the menu
  bar smoke pass landed. An LLM-driven Phase-1 codebase audit produced 17
  prioritized findings (S1–S7 significant, M1–M10 minor); the sweep merged
  fixes for the five load-bearing ones plus three minors, caught two
  reviewer-mistake findings via direct code spot-checks (S6 and M9 — both
  rejected), and deferred the remaining seven with documented rationales (a
  vision memo at `docs/vision/VISION-2026-05-26.md`, gitignored, captures the
  product-strategy synthesis). One flaky CI timing assertion surfaced by the
  sweep itself was also fixed, and the menu bar Terminal handoff was extended
  beyond Apple Terminal to auto-detect Ghostty / iTerm / WezTerm / Alacritty /
  kitty (running terminal preferred over merely-installed). Test count rose
  274 → 314.
- **Code-review sweep result (PRs #58–#66):**
  - **#58** — gitignored `docs/vision/` for private strategy memos.
  - **#59** — S1: extracted `XPCReplyDecoder` to collapse seven copies of the
    `withUnsafeUnderlyingDictionary { try? GohEnvelope<X>(...) ... }` decode
    dance into one tested helper. Net –109 / +216.
  - **#60** — M1+M2: centralized `formatBytes` / `progressText` into
    `JobDisplayFormatter` in `GohCore`; standardized percent clamping to
    `[0, 100]` across all four surfaces (CLI table, `goh top`, foreground,
    menu bar). Pre-existing inconsistency: menu bar clamped overruns to 100%
    while the other three rendered values like 200%.
  - **#61** — S3: replaced `_ = try? store.recordProgress(...)` and `_ = try?
    store.fail(...)` masking in `DownloadEngine` with an
    `unexpectedStoreError` reporter. `.jobNotFound` (the expected race when
    `rm` runs concurrently) is still dropped silently; every other store
    failure now lands in `goh.log` with job ID, operation name, and error.
  - **#62** — M5: `goh top` now uses the alternate screen buffer
    (`ESC[?1049h` / `ESC[?1049l`) and redraws in place (`ESC[H` + frame +
    `ESC[J`) instead of clearing + homing every notification. Kills the
    per-update flicker; preserves shell scrollback on exit.
  - **#63** — S2: closed the XPC peer-validation accept-path CI gap by
    testing `peerRequirement(for:)` directly (the factory function the
    production listener consults) plus a fresh `senderSatisfies` assertion
    against the production value. The OS-enforced session-accept path still
    requires a signed-build smoke run; that residual gap is now documented
    in code.
  - **#64** — M4 + M6: `expectedContentLength > 0` → `>= 0` so
    `Content-Length: 0` is a known empty body, not "unknown total." Added
    the missing `@unchecked Sendable` invariant comment on
    `GohXPCNotificationInbox` so it matches the rest of the codebase. M9
    skipped — `XPCReconnect.attempt` is only called from synchronous CLI
    contexts, not the `goh-menu` `Task.detached` path the reviewer cited.
  - **#65** — flaky-test fix: the 500 ms wall-clock bound in
    `removeRangeParallelActiveDownloadCancelsSiblingRanges` (
    `DownloadEngineTests.swift:559`) tripped at 548 ms on PR #59's CI attempt
    1 — three back-to-back local runs measured 88 / 89 / 91 ms, so 548 ms is
    ~6× local scheduling overhead. Raised to `< 2 s` (~22× local headroom,
    still meaningful as a "did not wait for siblings to finish naturally"
    sanity check). The behavioral assertions (partial file + checkpoint
    gone before reply) are the load-bearing checks.
  - **#66** — M10: `goh-menu` Terminal handoff now auto-detects across
    Ghostty (the user's terminal), iTerm2, WezTerm, Alacritty, kitty, and
    Apple Terminal. Two-phase pick: highest-priority **running** terminal
    first (strongest signal for "this is what the user actually uses"),
    then highest-priority **installed** terminal as fallback. Apple Terminal
    is the universal fallback. Each launcher emits a `Process`-ready
    invocation: `osascript` AppleScript for Apple Terminal and iTerm,
    `open -na <App>.app --args -e /bin/sh -c <command>` (xterm-convention)
    for the CLI-based terminals. 22 launcher tests cover priority, the
    running-vs-installed precedence, and AppleScript escaping. Verified
    live: Ghostty's bare `-e <command>` form makes it try to exec a binary
    literally named after the whole command string and fail; the
    `-e /bin/sh -c <command>` wrapping works.
- **Reviewer-mistake findings rejected via spot-check:**
  - **S6** — claim: `ProgressBrokerHub.deliver` holds the lock during
    synchronous `session.send`. Verified false: `deliver(state.withLock {
    ... })` evaluates the closure (acquires + releases the lock) before
    calling `deliver`, so sends already run outside the lock.
  - **M9** — claim: `XPCReconnect.attempt`'s `Thread.sleep` blocks a
    cooperative thread because `goh-menu` calls it from `Task.detached`.
    Grep showed `XPCReconnect.attempt` is only called from synchronous CLI
    contexts (`GohForegroundDownload`, `GohTop`). `Thread.sleep` is correct
    there.
- **Deferred findings (rationales captured in conversation):** S4 (improbable
  fsync-during-verifyHash edge), S5 (unused `NetworkPauseCoordinator` hook —
  dead extension point, harmless), S7 (`PendingDownloadStop` semaphore is
  stylistic), M3 (`JobSummary` encoder `encode` vs `encodeIfPresent` split
  is correct), M7 (`MockURLProtocol.stubs` static-but-guarded-by-UUID-URLs),
  M8 (`SafariCookieJar` intermediate arrays — perf non-issue for ~20
  cookies).
- **Menu bar state:** PR #54 merged the first private menu bar companion slice.
  `goh-menu` is now a SwiftPM-built, dogfood-installed MenuBarExtra backed by
  the same daemon XPC command and progress-subscription surfaces as the CLI. It
  shows daemon health, queue snapshots, active counts, aggregate speed,
  doctor-style recovery copy, clipboard quick-add,
  job controls, Finder reveal, and Terminal handoffs for `goh top` and
  `goh doctor`. PR #56 fixed the root-URL default-destination bug surfaced
  by the first logged-in smoke pass (`https://example.com/` produced
  `~/Downloads/`; now falls back to `~/Downloads/download`). PR #66 then
  taught the Terminal handoff to respect the user's actual terminal.
- **Post-sweep cleanups (PRs #68, #69):** PR #68 rewrote the README's "Why"
  section to lead with what `goh` *is* (architecture + capability list)
  instead of competitor name-drops, removed "10x" buzzwords from
  `ROADMAP.md` / `STATE.md` / the menu bar spec, and clarified that v0.1
  does not actively opt into HTTP/3. PR #69 redacted a home-directory
  path that had appeared in the post-sweep state refresh, reconciled
  DESIGN.md §6 (Observability) with the shipped implementation (`stderr`
  writes today, `os.Logger` migration framed as a v0.2 candidate), and
  tightened `.gitignore` for two local-only files (the Codex-style
  operating manual `AGENTS.md` and `Benchmarks/diagnose-*.log` engine
  traces). A separate `git config user.email` correction was applied
  outside the PR after a prior commit was authored under a personal
  email instead of the GitHub noreply.
- **GitHub account + repo settings hardened (browser-driven):** Enabled
  command-line push protection that rejects future commits authored from
  a personal email. Enabled repository-level Private vulnerability
  reporting, Dependency graph, Dependabot alerts / malware / security
  updates / grouped security updates, and Secret Protection (scanning +
  push protection). Created branch ruleset "Protect main" with basic
  protection: require PRs to merge, block force pushes, block deletions,
  0 required approvals (self-merge OK). 2FA verified enabled (read-only
  check; not modified).
- **Last roadmap merge:** PR #22 — Spotlight tagging and sleep assertions —
  `main` at `5b3884d`; PR #23 — one-shot CLI commands — `main` at `db9b82a`;
  PR #24 — CLI add options and JSON list — `main` at `58c2e73`; PR #25 — progress
  subscription contract — `main` at `c31283d`; PR #26 — backend progress
  subscription plumbing — `main` at `976775f`; PR #27 — foreground progress
  CLI — `main` at `076bfaf`; PR #28 — top progress dashboard — `main` at
  `0adf0a7`; PR #29 — release-packaging surface refresh — `main` at
  `2e1c3c7`; PR #30 — Homebrew formula validation in CI — `main` at
  `5ad60b6`; PR #31 — release artifact workflow — `main` at `e79c0bd`;
  PR #32 — release artifact verification — `main` at `b668aa0`; PR #33 —
  release signing prerequisites — `main` at `580b7c2`; PR #34 — unsigned PKG
  release artifact — `main` at `865d6aa`; PR #35 — private release posture —
  `main` at `33b1ea9`; PR #36 — private signed release gate — `main` at
  `b7e22e6`; PR #39 — menu bar companion roadmap/spec — `main` at `c2f4911`;
  PR #40 — local dogfood lane — `main` at `fd93b8d`; PR #47 — active `rm`
  cleanup hardening — `main` at `54317a9`; PR #49 — local health doctor —
  `main` at `ff45e99`; PR #50 — private dogfood acceptance gate — `main` at
  `cbe2c61`; PR #51 — state refresh after acceptance gate merge — `main` at
  `0aa3887`; PR #52 — dogfood performance evidence output — `main` at
  `befa10c`; PR #54 — menu bar companion MB1 — `main` at `56f9ad9`;
  PR #55 — state refresh after menu bar merge — `main` at `4e83522`; PR #56 —
  root-URL default destination fix — `main` at `7121e35`; PR #57 — state
  refresh after menu bar smoke — `main` at `b7bf03d`; PR #58 — gitignore
  `docs/vision/` — `main` at `f239591`; PR #59 — XPCReplyDecoder DRY —
  `main` at `d4a1857`; PR #60 — centralize byte/progress formatting —
  `main` at `5c16ec1`; PR #61 — surface daemon store errors — `main` at
  `4e24106`; PR #62 — `goh top` alternate-screen buffer — `main` at
  `e91b1cb`; PR #63 — XPC peer-requirement coverage — `main` at `a4a4236`;
  PR #64 — robustness sweep (content-length 0, inbox invariant) — `main`
  at `244e9a4`; PR #65 — relax flaky range-cancel timing bound — `main`
  at `dd7c021`; PR #66 — multi-terminal handoff w/ Ghostty — `main` at
  `06564af`; PR #68 — positioning language cleanup — `main` at `fa97d8d`;
  PR #69 — PII redaction + DESIGN §6 reconciliation — `main` at `b09616a`.
  Bookkeeping-only `STATE.md` refresh PRs may be newer than this entry; they do
  not advance the roadmap state.
- **Current slice:** Slice 9, Homebrew formula, signing, notarization, and the
  release pipeline. The first branch shipped the formula/README truth refresh in
  PR #29. PR #30 added CI validation for the in-repo Homebrew formula. The
  PR #31 added an unsigned release-artifact workflow and a reusable local
  packaging script. PR #32 added reusable artifact verification before upload.
  PR #33 documented signing/notarization prerequisites and the credential
  boundary for the remaining release work. PR #34 added an unsigned PKG
  release-candidate artifact and verifier so the direct-download path is
  exercised in CI before credential-backed signing/notarization lands. PR #35
  codified the private release posture: build every release gate, but do not
  publish an official install channel until the explicit public launch decision.
  PR #36 added the manual private signed/notarized/stapled PKG gate and a CI
  verifier for that workflow shape, while keeping official publication out of
  scope. PR #39 recorded the menu bar companion product direction in
  the roadmap and a design spec. PR #40 added the local dogfood lane so the
  product can be used and tested privately from source before any official
  install channel opens.
  PR #42 fixed dogfood-discovered destination parent-directory creation at
  `6506089`, PR #43 refreshed state at `5247964`, PR #44 fixed dogfood usability
  gaps in `goh top` at `34d8646`, PR #45 added the product catchphrase to
  restrained visible surfaces at `4c6a784`, and PR #47 fixed the dogfood-
  discovered active `rm` path where a resumed or range-parallel download could
  leave a visible partial file behind after the catalog row was removed. PR #47
  also tightened the file-ownership boundary so `rm` of a queued never-started
  job does not delete a pre-existing destination file. PR #49 added `goh
  doctor` as a read-only local health gate for private dogfood: it checks the
  dogfood binaries, LaunchAgent, launchd load state, XPC queue reachability,
  peer-relaxation setup, writable local paths, and daemon log posture, then
  prints exact recovery commands without adding daemon IPC surface. PR #50 added
  the private readiness acceptance gate above smoke: build/install, doctor,
  smoke, foreground download, JSON list, active pause/resume/remove cleanup,
  daemon restart, and opt-in competitive performance comparison. PR #52 made
  that `--performance` path evidence-grade by streaming the benchmark table and
  saving it under `.build/dogfood/logs`. PR #54 then brought the first native
  menu bar companion slice into private dogfood so non-terminal workflows can be
  exercised before any official install channel opens. PRs #58–#66 ran the
  post-merge code-review sweep and added Ghostty / iTerm / WezTerm /
  Alacritty / kitty support to the menu bar Terminal handoff (see the
  Current state section above for the per-PR breakdown). Test count 274 →
  314; CI green throughout. The remaining slice-9 work is the credential-
  backed signed/notarized PKG release-candidate (PR #36's workflow is
  ready to run with Developer ID secrets) and the Homebrew tap.
- **Slice 7 progress:** the first CLI implementation pass adds a testable
  `GohCore` command-line runner for the one-shot control verbs: `goh add`,
  `goh ls`, `goh pause`, `goh resume`, and `goh rm [--keep]`. `Sources/goh`
  is now thin process I/O plus the real XPC sender, and the existing
  `goh auth import safari` flow is routed through the same runner. The CLI
  returns `64` for local usage errors, `1` for daemon/transport failures, and
  prints `brew services start goh` guidance when the daemon is unreachable.
  Foreground `goh <url>` shipped in PR #27 as a live subscriber over the progress
  subscription path rather than a background-add alias.
  The follow-up CLI polish branch exposes already-frozen `add` options
  (`--output`, `--connections`, `--priority`, `--no-cookies`) and adds
  `goh ls --json` over the existing `LsReply` payload. PR #25 froze the
  load-bearing progress subscription contract: `Command.subscribe`,
  `SubscribeReply`, `ProgressEvent`, full in-scope progress snapshots,
  progress-model revisions, explicit `fullSnapshot` update events, 100 ms
  coalescing, foreground reconnect, and `goh top` subscription behavior. The
  PR #26 shipped the v3 wire schema, golden fixtures, protocol-version bump,
  session-aware XPC transport wrappers, broker-backed `subscribe` replies and
  notifications, `JobStore` progress publishing, and daemon composition through
  `ProgressBrokerHub`. PR #27 implemented foreground `goh <url>` as `add` plus
  `subscribe(scope: job, jobID:)` on one session. PR #28 shipped the first
  `goh top` dashboard over `subscribe(scope: all)`.
- **Slice 5 progress:** the first implementation step adds a pure in-memory
  `GohCore` Safari `Cookies.binarycookies` parser with Swift Testing coverage
  for page tables, offset-based strings, flags, Cocoa dates, and malformed
  inputs. The second step adds in-memory RFC 6265-style URL matching and
  `Cookie` header serialization with conservative host-only handling for bare
  Safari domains. The third step adds a download-engine cookie-header provider
  hook so initial, range-parallel, and resume requests can carry daemon-supplied
  cookies. The fourth step wires the frozen `add.useImportedCookies` field to a
  volatile per-job header snapshot and clears it on `rm`. No persistent
  cookie-store format or new IPC command has been added. The fifth step adds the
  Safari cookie-file locator for the modern container path plus legacy fallback.
  The sixth step composes one daemon-local `ImportedCookieStore` into both the
  dispatcher and `DownloadEngine`, so the already-built hooks are live in
  `gohd` without adding a new command. PR #19 shipped these non-wire
  foundations. PR #20 froze the load-bearing command/FDA contract for the
  remaining `goh auth import safari` surface. PR #21 implemented the
  `protocolVersion = 2` command, including XPC fd passing, daemon parse/import,
  and CLI Full Disk Access handling. PR #22 shipped Spotlight completion
  metadata and active-download sleep assertions. Slices 5 and 6 are shipped.
- **Last merged before #16:** PR #15 — core correctness gates — `dcdf709`.
- **Repository is public** (github.com/xaedyn/goh) — flipped 2026-05-22, which
  also made GitHub Actions free on the `macos-26` runner.

## Slice 3a — shipped (the milestone: `goh` moves bytes to disk)

- Engine job-store transitions — `start` (an atomic claim) / `recordProgress` /
  `complete` / `fail`, driving `queued → active → completed/failed`.
- `DownloadFile` — `pwrite` at offset, streaming SHA-256, the 1 MiB fsync
  checkpoint, best-effort `F_PREALLOCATE`.
- `DownloadEngine` — single-connection HTTP fetch over `URLSession`.
- Daemon wiring — `gohd` runs the engine on `add`, on `resume`, and for jobs
  still queued at startup.
- 84 tests; the engine path is tested over a `URLProtocol` mock.

## Slice 3b — range-parallel orchestration (shipped)

Built, tested (101 tests), pushed:

- `DownloadFile` reworked to pure positioned I/O (`pwrite`/`pread`, `Sendable`).
- `ChunkAssembler` — in-order hashing of out-of-order bytes via the
  contiguous-frontier read-back; single-connection runs through it as `N = 1`.
- `ByteRange.split` — file splitting capped by a minimum chunk size.
- The `HEAD` capability probe, `fetchRanged` with N writers in a `TaskGroup`,
  per-range failure cancelling siblings, the single-connection fallback,
  `actualConnectionCount` recorded and kept on completion.
- A default `User-Agent` — `goh/0.1 (+repo)` — on every download request, set
  via `GohCore.downloadSessionConfiguration()`.
- The `Benchmarks/` suite — `goh-bench` driver, `competitive.sh`, the hashing
  benchmark wired into CI. Default workloads rotated to Range-honoring URLs
  (amenable → an archive.org item; saturated → a `dl.google.com` asset, the
  synthetic Cloudflare endpoint having 403'd on `Range`). Each workload
  self-checks its structural assumption at run time — the amenability WARN
  joined by a saturation WARN.
- Engine diagnostics — `Benchmarks/diagnose.sh` plus `GOH_ENGINE_TRACE=1` emit
  per-range start / first-byte / completion timestamps, peak concurrent range
  count, and per-range critical-section time split between the `pwrite`+fsync
  phase and the assembler/progress/store mutex phase. Off in normal runs;
  release builds flip it on without recompiling.

Merged as PR #14. The final validated run accepted parity-for-v0.1 and moved the
remaining adaptive host scheduling work to v0.2.

## Roadmap from here

- **3c** — shipped in PR #17: checkpoint/resume implementation, error / retry /
  cancellation, live `pause` / `resume`, and `rm --keep` partial adoption.
- **4** — shipped in PR #18: `NWPathMonitor` cellular auto-pause (§12).
- **5** — shipped across PR #19, PR #20, and PR #21: Safari cookie import
  foundation, auth import command contract, and implementation.
- **6** — shipped in PR #22: Spotlight tagging and sleep assertions.
- **7** — shipped across PR #23, PR #24, and PR #27: the `goh` CLI client.
- **8** — shipped in PR #28: the TUI for `goh top`.
- **9** — in progress: Homebrew formula, signing, notarization, the release pipeline.
  PR #29 refreshed the pre-release formula/docs surfaces. PR #30 added formula
  validation to CI. PR #31 added unsigned release artifacts and checksums. PR #32
  added packaged-artifact verification. PR #33 documented signing and
  notarization prerequisites. PR #34 added an unsigned PKG artifact and verifier
  for the future direct-download channel. PR #35 removed premature public install
  guidance and recorded the private launch gate. PR #36 added a manual private
  signed/notarized PKG release-candidate workflow that can be run only with
  credentials and an explicit workflow-dispatch input. PR #49 added the local
  health doctor. PR #50 added the private dogfood acceptance gate. PRs #58–#66
  ran a post-merge code-review sweep and shipped multi-terminal handoff support
  in the menu bar.

## Recent 3b validation notes

- **3b validated — parity-for-v0.1 accepted.** See the validated-measurement
  comment on PR #14 for the full numbers and reasoning. Saturated criterion
  met with margin (`goh` 7.020s vs `aria2c` 7.293s vs `curl` 6.802s at the
  default 8 conn — slight win over `aria2c`, 3.2 % behind `curl`'s
  single-stream ceiling). Amenable parity confirmed (`goh` 10.915s vs
  `aria2c` 10.958s at 8 conn; 16-conn data point widens `aria2c`'s lead
  marginally — the gap is the structural HTTP/2-vs-N-TCP one we've been
  circling, not a `goh` code defect).

  The investigation that got here surfaced and resolved three URLSession
  behaviours, of which the first two are quirks documented in DESIGN.md
  §Transport (*URLSession quirks*):

  **#1 — HEAD's `expectedContentLength = -1`.** `URLSession` does not
  populate `expectedContentLength` from `Content-Length` for `HEAD`
  responses on the wire, even when the server sent the header. The probe's
  `expectedContentLength > 0` check therefore always failed and the engine
  always fell back to single-connection. **The range-parallel orchestration
  shipped in 3a/3b had never actually run on the wire** — `MockURLProtocol`
  builds its response from `headerFields:` and populates
  `expectedContentLength`, hiding the quirk in CI. Fixed by parsing
  `Content-Length` from the response header directly.

  **#2 — auto-decompression breaks ranged downloads.** `URLSession`'s
  default `Accept-Encoding: gzip, deflate, br` triggers transparent
  content-decoding. A `Range` over an encoded body returns a partial slice
  of the *encoded* stream, which the decoder can't start mid-stream for
  ranges past 0 (-1015) and over-decodes range 0 (proportional overshoot).
  Verified by isolating in a 4-variant Swift test program against the
  saturated host: the original HTTP/2-multiplexing hypothesis was falsified.
  Fixed by sending `Accept-Encoding: identity`.

  **#3 (engine hygiene) — byte-by-byte AsyncBytes replaced with chunked
  Data delivery.** `URLSession.bytes(for:)` was iterating one async
  suspension per byte (~70M per range on the amenable file). Replaced with
  a `URLSession.dataTask` + `URLSessionDataDelegate` bridge that yields
  `Data` chunks via an `AsyncThrowingStream`. Tested as the amenable-gap
  hypothesis; **falsified** — the asymmetric throughput pattern reproduces
  locally with the new chunked code at the same magnitude. The change
  ships anyway as engine hygiene (~70M async iterations per range becomes
  ~700-760).

  **Competitive re-run (post #1 + #2):**
  - **Saturated PARITY achieved.** `goh` 7.056s vs `aria2c` 7.300s vs `curl`
    6.223s. Saturation check PASS (`aria2c 0.85× curl`, converged). `goh`
    slightly faster than `aria2c`; both pay ~13-17% overhead vs single-conn
    `curl` — the intrinsic cost of parallelism. The slice's hardest target
    is met.
  - **Amenable check WARN'd as expected** (curl 0.3s cached at edge), and
    inside the WARN `goh` is ~5× slower than `aria2c` on the same ranged
    URL (164s vs 33s). The diagnostic trace shows asymmetric throughput
    (1-2 ranges fast, 6-7 throttled to ~430 KB/s) that reproduces locally
    against archive.org. Not a goh code issue — the leading hypothesis is
    archive.org's per-stream rate-limiting under sustained HTTP/2 multiplexed
    load, against which `aria2c`'s HTTP/1.1 + separate-TCP-connection model
    fares better. `URLSession` doesn't expose a clean way to force HTTP/1.1.

  Three of the four original diagnostic hypotheses are now ruled out:
  cap-throttling (cap is 16, observed peak=8); mutex contention
  (`writeMs`+`reportMs` per range stay single-digit milliseconds); and
  AsyncBytes byte-iteration (chunked Data fix didn't change the gap).

  **HTTP/3 trial reverted.** A first round of three optimizations
  (speculative ranged GET, per-request `URLRequest.assumesHTTP3Capable`,
  1 MiB flush buffer) regressed the saturated workload by ~45 %
  (`goh` 6.607s → 10.754s median, with run-to-run variance suggesting
  server-side rate-limiting against h3 traffic on this network path).
  `aria2c` and `curl` stayed flat. HTTP/3 reverted; skip-HEAD and 1 MiB
  buffer kept (they don't show the variance signature). The slice landed
  a per-range `protocol=` trace line so the next h3 attempt isn't blind.

  **Final state at merge:** speculative ranged GET (one RTT saved per
  download), 1 MiB flush buffer (~16× fewer pwrites), per-range protocol
  diagnostic, all URLSession quirks (HEAD `expectedContentLength = -1`
  and Range-incompatible auto-decompression) worked around, two committed
  default benchmark workloads with run-time amenability/saturation checks,
  the engine diagnostics that drove this slice's debugging cycles. 101
  tests; CI green.

## Next-session handoff

**MOST RECENT: see the top "Current state" entry (dated 2026-06-03).** The in-flight adaptive
parallelism governor has since been **redesigned + fixed and P1–P4 are functionally complete** on
`design/in-flight-parallelism` (now **PR #80**, CI green, headline-benchmark deferred). This
2026-05-31 design-session note is **historical**: the four-round design (spec
`docs/superpowers/specs/2026-05-31-in-flight-adaptive-parallelism-design.md`, approach **A3 —
continuous governor + NWConnection multi-edge** because URLSession can't override SNI for IP
connections) was approved over 2 adversarial Opus rounds and has been implemented through P4; the
branch is cut, committed, and pushed (no longer "uncommitted on `main`"). **Pick-up options:**
(a) review/merge PR #80, then **P5** (NWConnection multi-edge) behind its feasibility spike +
dedicated security review; or (b) the Phase-3 public-launch track below (credential-gated). The
detailed breakdown is the top "Current state" entry dated *2026-06-03*.

---

`main` now includes **Phase 2 — adaptive per-host range scheduling** (PR #77,
squash `32efda1`) and the **in-flight-parallelism design seed** (PR #78, squash
`e048ec8`). Both feature/docs branches are deleted. **473 tests pass**,
`swift build` warning-clean. See the top "Current state" entry, dated
*2026-05-31 (merge session)*, for the full breakdown (incl. the email-redaction
residual note).

**THE NEXT ACTION — strategic arc Phase 3: public launch.** The one gate outside the
code is **Apple Developer ID credentials**. The launch sequence is preserved just
below (sign+notarize PKG via PR #36 workflow → open the `xaedyn/homebrew-goh` tap →
add SECURITY/CONTRIBUTING/CODE_OF_CONDUCT → launch post → HN/r/macapps/r/commandline/
r/datahoarder). **Credential-free alternative:** start the **in-flight adaptive
parallelism** slice (its own four-round design pass off the PR #78 seed; needs
sourced long-fat-network / multi-edge-CDN benchmarks) as the v0.2 performance
headline.

**Doc-currency note (verified 2026-05-31, impl session):** The top "Current state"
entry and this handoff are current. `DESIGN.md` §Adaptive host scheduling now
documents the frozen v1 `host-scheduling.plist` format (reconciled this session per
the four-round discipline). The planning artifacts under `docs/plans/` and
`docs/superpowers/{specs,progress}/` are **frozen point-in-time records** of the
closed design/plan — they intentionally describe the plan *as planned*, so minor
divergences from the shipped code (e.g. the handler-arity revision, trace-emission
site, "byte-for-byte" vs decoded-value-equality wording) are expected; DESIGN.md +
this STATE.md + the code are authoritative. `ROADMAP.md` still frames Phase 2 as
"design pass first" (it tracks scope, not status — status lives here in STATE.md).

**Earlier session's launch sequence — still valid as Phase 3, AFTER Phase 2
implementation ships.** From the gitignored strategy memo at
`docs/vision/VISION-2026-05-26.md`:

1. **Sign and notarize the PKG** by running PR #36's
   `private-release-candidate` workflow with Developer ID credentials.
   The workflow shape is already verified by
   `Scripts/verify-private-release-workflow.sh` — what's missing is the
   secrets (`GOH_APP_SIGN_IDENTITY`, `GOH_INSTALLER_SIGN_IDENTITY`,
   notarization credentials).
2. **Open the brew tap** (`xaedyn/homebrew-goh`) and publish the formula
   that PR #29/#30 prepared.
3. **Polish the launch post draft** at
   `docs/vision/LAUNCH-POST-DRAFT.md` (gitignored). Needs a menu bar
   screenshot and a final tone pass. The narrative the vision memo
   lands on: "the macOS download daemon for the AI era — Personal
   Asset Manager, not a faster curl." Reference the buried capabilities
   — `goh diagnose` via `GOH_ENGINE_TRACE=1`, `goh doctor` health gate,
   Spotlight `kMDItemWhereFroms` provenance, sleep assertions, cellular
   auto-pause, the Safari cookie import via fd-passing.
4. **Add `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`** —
   ~30 minutes of writing right before the brew tap opens. `SECURITY.md`
   is the most important (responsible disclosure address for a tool
   that handles cookies and sensitive URLs).
5. **Submit to Hacker News + r/macapps + r/commandline + r/datahoarder.**

**Alternative pickup if v0.1 launch prep is blocked on credentials:**
Bet 2 from the memo — `gohfile.toml` + `goh sync` + `goh verify`.
This is the path to the "Personal Asset Manager" shape and is ~2–4
weeks of work; the persistence and integrity primitives the v0.1
engine already exposes are the foundation. Doesn't depend on signing.

**Note on the local-only files** `AGENTS.md` and
`Benchmarks/diagnose-saturated.log`: both are now properly gitignored
(PR #69). They will no longer appear as untracked in `git status`, but
they remain on disk and should still be left alone.
