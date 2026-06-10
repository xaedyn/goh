---
date: 2026-06-09
feature: daemon-upgrade-self-heal
plan-status: draft
branch: feat/daemon-upgrade-self-heal
spec: docs/superpowers/specs/2026-06-09-daemon-upgrade-self-heal-design.md
phases:
  - docs/superpowers/progress/2026-06-09-daemon-upgrade-self-heal-phase1.md
  - docs/superpowers/progress/2026-06-09-daemon-upgrade-self-heal-phase2.md
  - docs/superpowers/progress/2026-06-09-daemon-upgrade-self-heal-phase3.md
---

# Implementation Plan — Self-Healing Daemon Upgrade (version-skew aware)

## Goal

After a `brew`/`.pkg` upgrade the on-disk binaries are new but the running
`gohd` is the old build. The new client silently loses behavior (the
backfill-on-verify bug: old daemon drops the new baseline fields). This plan
makes the mismatch detectable and self-correcting when idle.

## Architecture (from spec §2–4)

**The Bets:**

1. **Client-driven idle-gated restart, not daemon self-exit.** The plist has
   `KeepAlive = { SuccessfulExit: false }`, so `exit(0)` is NOT relaunched and
   `exit(1)` would abuse crash semantics. The client uses
   `launchctl kickstart -k gui/<uid>/dev.goh.daemon` (bypasses KeepAlive
   entirely; immediate, not throttled). The daemon barely changes — it only
   *reports* a feature level.

2. **`nil` reported == stale, not "unknown/do-nothing".** A pre-feature daemon
   omits the field → `nil` → treated as stale. This makes the *first* upgrade
   self-heal. A newer daemon always reports its level.

3. **One `.ls` round-trip answers both questions.** `LsReply` already lists
   jobs (idle count) and now additively carries `featureLevel: Int?`. One call
   to the already-existing doctor path suffices.

4. **Auto-heal is scoped** to `verify --all`, `verify --quick`, and `doctor` —
   the commands where skew causes silent data loss. Not every verb.

5. **Honest reconcile semantics.** A download that was `.active` at restart
   resumes only if a safe checkpoint exists (≥1 MiB, strong validator); else
   it is marked `.failed` (retry-eligible and logged) — never silently dropped.
   The auto-heal idle gate + re-check make hitting an active download a rare
   sub-second race, not the steady-state path.

## Tech Stack

Swift 6.2 tools / 6.3.x toolchain. Targets:
- **GohCore** — `nonisolated` default isolation. All new types here.
- **gohd** — no isolation (`nonisolated`-default). Only `CommandDispatcher` changes.
- **goh** — `MainActor`-default. Only `GohCommandLine` changes.
- **GohMenuBar** — `@MainActor`-default. `GohMenuViewModel`, `GohMenuModels`, `GohMenuPresenter` change.
- **goh-menu** — `@MainActor`-default. `LiveGohMenuClient` changes.

Build and test gate for **every task**:
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <SuiteName>
```

---

## Phase 0 Reads — Confirmed Shapes and Signatures

### `CommandReply.swift` (`Sources/GohCore/Model/CommandReply.swift`)

```swift
// L1–9  (current shape — FROZEN fields)
public struct LsReply: Codable, Sendable, Equatable {
    public var jobs: [JobSummary]
    public init(jobs: [JobSummary]) { self.jobs = jobs }
}
```
**Action (Task 3):** Add `public var featureLevel: Int?` with explicit
`CodingKeys` (additive-optional). Encode always (`encodeIfPresent`);
decode with `decodeIfPresent`. `init(jobs:)` gains `featureLevel: Int? = nil`
default so every existing call site compiles unchanged.

### `CommandDispatcher.swift` — `.ls` handler (`Sources/GohCore/Model/CommandDispatcher.swift`)

```swift
// L175–176
case .ls:
    return .list(LsReply(jobs: store.allJobs()))
```
**Action (Task 4):** Change to:
```swift
case .ls:
    return .list(LsReply(jobs: store.allJobs(),
                         featureLevel: GohFeatureLevel.current))
```

### `gohd/main.swift` (`Sources/gohd/main.swift`)

- L109: `let reconciliation = store.reconcileActiveJobsOnStartup(checkpoints: checkpointStore)`
- L110–115: logs `requeuedJobIDs` and `failedJobIDs`.
- L221: `for job in store.allJobs() where job.state == .queued` — re-schedules queued jobs.
- L237–244: SIGTERM → `writer.flush()` → `exit(0)`.
- **No changes to `gohd/main.swift`.** The plan RELIES on reconcile behavior; does not modify it.

### `goh/main.swift` (`Sources/goh/main.swift`)

- L73–97: `readQueueForDoctor(validationMode:)` — builds `.ls` request, calls
  `sendOneShot`, decodes `LsReply`. This is the XPC path the doctor and new
  scoped auto-heal calls reuse.
- L133: `userID: { Int(getuid()) }` — this is how uid is obtained in doctor probes.
- L215–295: `GohCommandLine(arguments: ..., foreground: ..., top: ..., doctor: ..., diagnose: ...)` — trailing `send:` closure.
- **New `daemon restart` verb requires:** a new `daemon: ((_ force: Bool) throws -> GohCommandLineResult)?` closure type in `GohCommandLine.init`, injected from `goh/main.swift` which constructs a `LaunchctlDaemonRestarter` and calls `readQueueForDoctor` for the idle check.

### `GohCommandLine.swift` (`Sources/GohCore/CLI/GohCommandLine.swift`)

- L44–102: `GohCommandLine` struct with `Foreground`, `Top`, `Doctor`, `Diagnose` typealias closures. `init` has them as optional params before the trailing `send:`.
- L104–265: `run()` dispatches `ParsedCommand` via `switch`.
- L300–323: `private enum ParsedCommand` — no `daemon` case yet.
- L340–509: `static func parse(_ arguments:)` — the verb-dispatch logic.
- L509: falls through to `throw ParseError(message: "unknown or incomplete command")`.
- **New `daemon` case** added to `ParsedCommand`, parsed before the final throw.
- **Exit code 64** is the existing usage-error code (see L257 `exitCode: 64` for `ParseError`).

### `GohDoctor.swift` (`Sources/GohCore/CLI/GohDoctor.swift`)

- L1–17: `GohDoctorProbes` struct — holds `readQueue: () throws -> LsReply`.
- L195–219: `xpcFindings()` — calls `probes.readQueue()`, produces `[Finding]`.
  Currently checks XPC reachability and queue count. The reply `LsReply` is
  decoded here but `featureLevel` is not currently read.
- **Action (Task 9):** After existing findings in `xpcFindings()`, inspect
  `reply.featureLevel` vs `GohFeatureLevel.current` and append a skew/ok finding.

### `GohVerifyAllCommand.swift` (`Sources/GohCore/CLI/GohVerifyAllCommand.swift`)

- L45–50: `static func run(provenanceStorePath:json:generatedAt:send:)` —
  `send: GohCommandLine.Sender?`.
- L108–133: best-effort backfill block (uses `send`).
- **Action (Task 7):** Add `restarter: (any DaemonRestarting)? = nil` parameter.
  Before the ledger classify step, if `send` is non-nil, call
  `DaemonAutoHeal.runIfNeeded(send:restarter:)`. Best-effort; never changes exit code.

### `GohVerifyQuickCommand.swift` (`Sources/GohCore/CLI/GohVerifyQuickCommand.swift`)

- L33: `static func run(provenanceStorePath:probe:)` — no `send` param today.
- **Action (Task 7):** Add `send: GohCommandLine.Sender? = nil` and
  `restarter: (any DaemonRestarting)? = nil` parameters. Before classifying
  the ledger, call `DaemonAutoHeal.runIfNeeded(send:restarter:)` when non-nil.

### `JobStore` / `JobSummary` / `JobState`

- `JobStore.allJobs() -> [JobSummary]` (L92–94) — `Mutex`-guarded, returns snapshot.
- `JobSummary.state: JobState` — `.queued`, `.active`, `.paused`, `.completed`, `.failed`.
- Active download count: `reply.jobs.filter { $0.state == .active }.count`.

### `GohMenuViewModel.swift` (`Sources/GohMenuBar/GohMenuViewModel.swift`)

- L6–15: `GohMenuClient` protocol (MainActor) — has `progressSnapshots()`,
  `add`, `pause`, `resume`, `remove`, `recordVerifiedProvenance`.
- L17–229: `GohMenuViewModel` (ObservableObject, MainActor) — has `start()`,
  `stop()`, `applyProgressSnapshots`, `render(health:)`.
- **Action (Task 11–13):** Extend protocol with `func ls() async throws -> LsReply`
  and `func restartDaemon() async throws`. Implement in `LiveGohMenuClient`.
  `GohMenuViewModel` calls `.ls()` periodically (reuse the progress stream's
  reconnect cadence) or on demand, checks skew via `DaemonSkewCheck.evaluate`,
  sets a new published `daemonSkew: DaemonSkew?` property.

### `GohMenuModels.swift` + `GohMenuPresenter.swift`

- `GohMenuHealth` (L4): cases: `.connecting`, `.connected`, `.reconnecting`,
  `.failed(GohMenuError)`. Skew notice is NOT a health failure — it is a separate
  informational field.
- `GohMenuState` (L129): has `health`, `healthTitle`, `healthDetail`,
  `activeCount`, `aggregateSpeedText`, `primaryAction`, `recoveryAction`, `rows`.
- **Action (Task 12):** Add `daemonSkewNotice: String?` to `GohMenuState` and
  `GohMenuPresenter.state(...)`. Presenter sets it to a neutral string when
  `DaemonSkew` is `.staleIdle` or `.staleBusy`, `nil` when `.current`.
  `GohMenuView` renders it as a subdued caption below the header.

---

## Phase 0.5 — AC Extraction and Task Map

| AC  | Description (abridged from spec §5)                                         | Task(s) |
|-----|----------------------------------------------------------------------------|---------|
| AC1 | Daemon includes `featureLevel == current` in every `LsReply`; old client still decodes | 3, 4 |
| AC2 | `DaemonSkewCheck.evaluate` table (nil,0,current covered)                    | 2       |
| AC3 | `goh daemon restart` idle-refuses / force-restarts; exit-64-class refusal  | 8       |
| AC4 | Auto-heal triggers kickstart + follow-up `.ls` reports new level; unit seam | 5, 6   |
| AC5 | `.staleBusy` does NOT restart; notice only; exit code unchanged             | 6, 7    |
| AC6 | `goh doctor` shows featureLevel, flags skew, prints restart instruction     | 9       |
| AC7 | kickstart unavailable → degrade to notice-only; command still succeeds      | 6       |
| AC8 | Reconcile: both branches asserted; end-to-end requeue→reschedule           | 10      |
| AC9 | `protocolVersion` stays 4; `LsReply` additive-optional; frozen tests unchanged | 3  |

---

## Phase 2 — File Map

| Status | Path | Key symbols |
|--------|------|-------------|
| Create | `Sources/GohCore/Model/GohFeatureLevel.swift` | `GohFeatureLevel.current: Int = 1` |
| Create | `Sources/GohCore/Model/DaemonSkewCheck.swift` | `DaemonSkew`, `DaemonSkewCheck.evaluate(reported:expected:activeDownloadCount:)` |
| Create | `Sources/GohCore/Model/DaemonRestarting.swift` | `DaemonRestarting` protocol, `LaunchctlDaemonRestarter` struct |
| Create | `Sources/GohCore/CLI/DaemonAutoHeal.swift` | `DaemonAutoHeal.runIfNeeded(send:restarter:machServiceName:uid:)` |
| Modify | `Sources/GohCore/Model/CommandReply.swift` | `LsReply` + `featureLevel: Int?` additive field |
| Modify | `Sources/GohCore/Model/CommandDispatcher.swift` | `.ls` handler sets `featureLevel: GohFeatureLevel.current` |
| Modify | `Sources/GohCore/CLI/GohCommandLine.swift` | `daemon` closure type, `ParsedCommand.daemon`, `parse` + `run` dispatch |
| Modify | `Sources/GohCore/CLI/GohDoctor.swift` | `xpcFindings()` appends skew finding |
| Modify | `Sources/GohCore/CLI/GohVerifyAllCommand.swift` | `run(restarter:)` pre-check |
| Modify | `Sources/GohCore/CLI/GohVerifyQuickCommand.swift` | `run(send:restarter:)` pre-check |
| Modify | `Sources/GohMenuBar/GohMenuViewModel.swift` | `GohMenuClient.ls()`, `GohMenuViewModel.daemonSkew` |
| Modify | `Sources/GohMenuBar/GohMenuModels.swift` | `GohMenuState.daemonSkewNotice: String?` |
| Modify | `Sources/GohMenuBar/GohMenuPresenter.swift` | sets `daemonSkewNotice` |
| Modify | `Sources/GohMenuBar/GohMenuView.swift` | renders notice |
| Modify | `Sources/goh-menu/main.swift` | `LiveGohMenuClient.ls()` + `restartDaemon()` |
| Modify | `Tests/GohCoreTests/JobStoreStartupReconciliationTests.swift` | end-to-end requeue→reschedule |
| Create | `Tests/GohCoreTests/DaemonFeatureLevelTests.swift` | AC1/AC9 wire round-trip |
| Create | `Tests/GohCoreTests/DaemonSkewCheckTests.swift` | AC2 pure table |
| Create | `Tests/GohCoreTests/Support/LsReplyTestSupport.swift` | Shared reply seam: `makeLsSender`, `SequencedLsSender`, `StubRestarter` |
| Create | `Tests/GohCoreTests/DaemonRestartingTests.swift` | AC4 seam, AC7 |
| Create | `Tests/GohCoreTests/DaemonAutoHealTests.swift` | AC4 wiring, AC5, AC7 |

---

## Phase 3 — Phase Segmentation

### Phase 1 — GohCore + Wire + Daemon Report (Tasks 1–4)
Pure additions: new types, wire extension, daemon sets the field.
Fully unit-testable. No CLI, no tray. Commit gate after Task 4.

### Phase 2 — CLI Surfaces (Tasks 5–10)
`DaemonRestarting` protocol, `DaemonAutoHeal`, scoped auto-heal,
`goh daemon restart`, doctor finding, reconcile end-to-end test.
Depends on Phase 1 (`GohFeatureLevel`, `DaemonSkew`, `LsReply.featureLevel`).

### Phase 3 — Tray (Tasks 11–13)
Neutral skew notice + idle-gated restart action.
Depends on Phase 1 (wire field) and Phase 2 (`DaemonRestarting` protocol).

---

## Task Specifications

---

### Task 1 — `GohFeatureLevel`

**Files:**
- Create: `Sources/GohCore/Model/GohFeatureLevel.swift`
- Create: `Tests/GohCoreTests/DaemonFeatureLevelTests.swift` (partial — complete in Task 3)

**Pre-task reads checklist:**
- [x] `CommandReply.swift` — `LsReply` current shape (confirmed above)
- [x] `CommandService.swift` — `protocolVersion = 4` (confirmed; not touched)

**AC ownership:** AC1 (partial), AC9 (partial)

**Step 1 — Failing test**

File: `Tests/GohCoreTests/DaemonFeatureLevelTests.swift`

```swift
import Testing
import GohCore

@Suite("GohFeatureLevel")
struct DaemonFeatureLevelTests {

    @Test("current is a positive integer and equals 1")
    func currentIsOne() {
        #expect(GohFeatureLevel.current == 1)
    }
}
```

**Step 2 — Run expecting failure**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DaemonFeatureLevelTests
```
Expected: compile error (`GohFeatureLevel` not found).

**Step 3 — Minimal implementation**

File: `Sources/GohCore/Model/GohFeatureLevel.swift`

```swift
/// Monotonic integer bumped per release that adds daemon behavior a client
/// depends on. Distinct from the frozen wire `protocolVersion`; featureLevel 1
/// = "daemon writes stat baselines on recordVerified" (DESIGN.md §3).
///
/// Bumping this is a deliberate release step — document the bump in DESIGN.md
/// like protocolVersion. Never auto-bumped.
public enum GohFeatureLevel {
    /// The feature level compiled into this build.
    public static let current: Int = 1
}
```

**Step 4 — Run expecting pass**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DaemonFeatureLevelTests
```

**Step 5 — Commit**
```
git add Sources/GohCore/Model/GohFeatureLevel.swift Tests/GohCoreTests/DaemonFeatureLevelTests.swift
git commit -m "feat(core): add GohFeatureLevel.current = 1"
```

---

### Task 2 — `DaemonSkew` + `DaemonSkewCheck.evaluate`

**Files:**
- Create: `Sources/GohCore/Model/DaemonSkewCheck.swift`
- Create: `Tests/GohCoreTests/DaemonSkewCheckTests.swift`

**Pre-task reads checklist:**
- [x] `JobState.swift` — confirmed `.active`, `.queued`, `.paused`, `.completed`, `.failed`
- [x] Spec §4.3 — evaluate logic confirmed

**AC ownership:** AC2 (full)

**CORRECTNESS NOTE:** `nil` reported featureLevel means STALE, NOT "unknown/do nothing".
`evaluate(nil, expected: 1, activeDownloadCount: 0)` → `.staleIdle`.
`evaluate(nil, expected: 1, activeDownloadCount: 2)` → `.staleBusy`.
The full AC2 table must be tested exhaustively.

**Step 1 — Failing test**

File: `Tests/GohCoreTests/DaemonSkewCheckTests.swift`

```swift
import Testing
import GohCore

@Suite("DaemonSkewCheck.evaluate — AC2 table")
struct DaemonSkewCheckTests {

    // Nil reported == stale (pre-feature daemon). NOT "unknown" — the first
    // upgrade must self-heal. (spec §3 "nil reported == stale")
    @Test("nil reported with 0 active → staleIdle", arguments: [0, nil] as [Int?])
    func nilReportedIdleIsStaleIdle(reported: Int?) {
        #expect(DaemonSkewCheck.evaluate(reported: reported, expected: 1, activeDownloadCount: 0) == .staleIdle)
    }

    @Test("nil reported with active downloads → staleBusy")
    func nilReportedBusyIsStaleBusy() {
        #expect(DaemonSkewCheck.evaluate(reported: nil, expected: 1, activeDownloadCount: 2) == .staleBusy)
    }

    @Test("0 reported (older level) with 0 active → staleIdle")
    func zeroReportedIdleIsStaleIdle() {
        #expect(DaemonSkewCheck.evaluate(reported: 0, expected: 1, activeDownloadCount: 0) == .staleIdle)
    }

    @Test("0 reported (older level) with active downloads → staleBusy")
    func zeroReportedBusyIsStaleBusy() {
        #expect(DaemonSkewCheck.evaluate(reported: 0, expected: 1, activeDownloadCount: 3) == .staleBusy)
    }

    @Test("reported == expected → current")
    func reportedEqualsExpectedIsCurrent() {
        #expect(DaemonSkewCheck.evaluate(reported: 1, expected: 1, activeDownloadCount: 0) == .current)
    }

    @Test("reported > expected (old client + new daemon) → current")
    func reportedGreaterThanExpectedIsCurrent() {
        #expect(DaemonSkewCheck.evaluate(reported: 2, expected: 1, activeDownloadCount: 0) == .current)
    }

    @Test("reported == expected and active downloads → still current (no idle gate in evaluate)")
    func reportedEqualsExpectedWithActiveIsCurrent() {
        #expect(DaemonSkewCheck.evaluate(reported: 1, expected: 1, activeDownloadCount: 5) == .current)
    }
}
```

**Step 2 — Run expecting failure**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DaemonSkewCheckTests
```
Expected: compile error (`DaemonSkew` / `DaemonSkewCheck` not found).

**Step 3 — Minimal implementation**

File: `Sources/GohCore/Model/DaemonSkewCheck.swift`

```swift
/// The daemon's feature-level skew classification relative to the client's.
///
/// `staleIdle` / `staleBusy` mean the running daemon is older than the client;
/// `current` means the daemon is at or ahead of the client's expected level.
public enum DaemonSkew: Sendable, Equatable {
    /// Daemon is current (reported >= expected). No action needed.
    case current
    /// Daemon is stale and no downloads are active — safe to auto-restart.
    case staleIdle
    /// Daemon is stale but downloads are active — emit notice, do not restart.
    case staleBusy
}

/// Pure skew classifier. No I/O. Injectable in tests via `evaluate(...)`.
public enum DaemonSkewCheck {

    /// Classifies the daemon's reported featureLevel against the client's expectation.
    ///
    /// - Parameters:
    ///   - reported: The `LsReply.featureLevel` from the running daemon.
    ///     `nil` means the daemon pre-dates featureLevel (= stale).
    ///   - expected: The client's `GohFeatureLevel.current`.
    ///   - activeDownloadCount: Number of `.active` jobs from the same `LsReply`.
    /// - Returns: `.current`, `.staleIdle`, or `.staleBusy`.
    public static func evaluate(
        reported: Int?,
        expected: Int,
        activeDownloadCount: Int
    ) -> DaemonSkew {
        guard let reported, reported >= expected else {
            return activeDownloadCount == 0 ? .staleIdle : .staleBusy
        }
        return .current
    }
}
```

**Step 4 — Run expecting pass**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DaemonSkewCheckTests
```

**Step 5 — Commit**
```
git add Sources/GohCore/Model/DaemonSkewCheck.swift Tests/GohCoreTests/DaemonSkewCheckTests.swift
git commit -m "feat(core): add DaemonSkew + DaemonSkewCheck.evaluate (AC2)"
```

---

### Task 3 — `LsReply.featureLevel: Int?` additive-optional

**Files:**
- Modify: `Sources/GohCore/Model/CommandReply.swift`
- Create/Extend: `Tests/GohCoreTests/DaemonFeatureLevelTests.swift`

**Pre-task reads checklist:**
- [x] `CommandReply.swift` L1–9 — current `LsReply` shape (confirmed above)
- [x] `XPCReplyDecoderTests.swift` / `CommandServiceTests.swift` — existing decoder tests must pass unchanged (AC9)
- [x] `JobSummary.swift` L80–97 — pattern for explicit `CodingKeys` + `decodeIfPresent`

**AC ownership:** AC1 (partial), AC9 (full)

**CORRECTNESS NOTE — FROZEN constraint (AC9):** `protocolVersion` stays 4. Old
clients that already decoded `LsReply` must still decode the new form — the new
field uses `decodeIfPresent` so it simply comes back `nil` on an old daemon. The
`init(jobs:)` convenience initializer gains `featureLevel: Int? = nil` so zero
call sites change.

**Step 1 — Failing test** (extend `DaemonFeatureLevelTests.swift`)

```swift
// Append to DaemonFeatureLevelTests.swift inside the @Suite block:

@Test("LsReply encodes featureLevel and old decoder round-trips without it")
func lsReplyFeatureLevelRoundTrip() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    // New daemon → new client: featureLevel encoded and decoded.
    let withLevel = LsReply(jobs: [], featureLevel: 1)
    let data = try encoder.encode(withLevel)
    let decoded = try decoder.decode(LsReply.self, from: data)
    #expect(decoded.featureLevel == 1)

    // Old daemon (no featureLevel key) → new client: decodes as nil.
    let oldJson = #"{"jobs":[]}"#.data(using: .utf8)!
    let fromOld = try decoder.decode(LsReply.self, from: oldJson)
    #expect(fromOld.featureLevel == nil)

    // New daemon → old client: adding the key must not break decoding
    // of a shape that already ignores unknown keys (JSON decoder default).
    let newJson = #"{"jobs":[],"featureLevel":1}"#.data(using: .utf8)!
    let fromNew = try decoder.decode(LsReply.self, from: newJson)
    #expect(fromNew.featureLevel == 1)
}
```

**Step 2 — Run expecting failure**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DaemonFeatureLevelTests
```
Expected: failure (`LsReply.init(jobs:featureLevel:)` not found).

**Step 3 — Minimal implementation**

Replace `Sources/GohCore/Model/CommandReply.swift` content:

```swift
/// The `ls` command's success reply (`DESIGN.md` §3.2) — every job in creation
/// order. `add`, `pause`, and `resume` reply with a bare ``JobSummary``.
public struct LsReply: Codable, Sendable, Equatable {
    public var jobs: [JobSummary]
    /// The daemon's compiled-in ``GohFeatureLevel/current``.
    /// `nil` from a pre-feature daemon (older than featureLevel 1).
    /// Additive-optional: old clients ignore it; new clients treat nil as stale.
    /// `protocolVersion` stays 4.
    public var featureLevel: Int?

    public init(jobs: [JobSummary], featureLevel: Int? = nil) {
        self.jobs = jobs
        self.featureLevel = featureLevel
    }

    private enum CodingKeys: String, CodingKey {
        case jobs, featureLevel
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobs = try c.decode([JobSummary].self, forKey: .jobs)
        featureLevel = try c.decodeIfPresent(Int.self, forKey: .featureLevel)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobs, forKey: .jobs)
        try c.encodeIfPresent(featureLevel, forKey: .featureLevel)
    }
}

/// The `rm` command's success reply (`DESIGN.md` §3.5).
public struct RmReply: Codable, Sendable, Equatable {
    public var removedJobID: UInt64

    public init(removedJobID: UInt64) {
        self.removedJobID = removedJobID
    }
}

/// The `recordVerifiedProvenance` command's success reply — zero-payload acknowledgement.
public struct AckReply: Codable, Sendable, Equatable {
    public init() {}
}
```

**Step 4 — Run expecting pass**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DaemonFeatureLevelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter XPCReplyDecoderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CommandServiceTests
```
All must pass. `XPCReplyDecoderTests` and `CommandServiceTests` are frozen-contract guards (AC9).

**Step 5 — Commit**
```
git add Sources/GohCore/Model/CommandReply.swift Tests/GohCoreTests/DaemonFeatureLevelTests.swift
git commit -m "feat(wire): add LsReply.featureLevel additive-optional (AC1/AC9)"
```

---

### Task 4 — Daemon sets `featureLevel` in `.ls` reply

**Files:**
- Modify: `Sources/GohCore/Model/CommandDispatcher.swift` (L175–176)

**Pre-task reads checklist:**
- [x] `CommandDispatcher.swift` L175–176 — `.ls` case confirmed above

**AC ownership:** AC1 (full)

**Step 1 — Failing test** (extend `DaemonFeatureLevelTests.swift`)

```swift
// Append to DaemonFeatureLevelTests.swift:

@Test("CommandDispatcher.ls reply includes GohFeatureLevel.current")
func dispatcherLsSetsFeatureLevel() {
    let store = JobStore()
    let dispatcher = CommandDispatcher(store: store)
    let outcome = dispatcher.reply(to: .ls)
    guard case .list(let reply) = outcome else {
        Issue.record("expected .list outcome, got \(outcome)")
        return
    }
    #expect(reply.featureLevel == GohFeatureLevel.current)
}
```

**Step 2 — Run expecting failure**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DaemonFeatureLevelTests
```
Expected: `dispatcherLsSetsFeatureLevel` fails (`featureLevel` is `nil`).

**Step 3 — Minimal implementation**

In `Sources/GohCore/Model/CommandDispatcher.swift`, change the `.ls` case at line 175:

```swift
// Before:
case .ls:
    return .list(LsReply(jobs: store.allJobs()))

// After:
case .ls:
    return .list(LsReply(jobs: store.allJobs(), featureLevel: GohFeatureLevel.current))
```

**Step 4 — Run expecting pass**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DaemonFeatureLevelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CommandDispatcherTests
```

**Step 5 — Commit**
```
git add Sources/GohCore/Model/CommandDispatcher.swift Tests/GohCoreTests/DaemonFeatureLevelTests.swift
git commit -m "feat(daemon): set LsReply.featureLevel = GohFeatureLevel.current (AC1)"
```

---

### Task 5 — `DaemonRestarting` protocol + `LaunchctlDaemonRestarter`

**Files:**
- Create: `Sources/GohCore/Model/DaemonRestarting.swift`
- Create: `Tests/GohCoreTests/DaemonRestartingTests.swift`

**Pre-task reads checklist:**
- [x] `GohDoctor.swift` L105: `"gui/\(probes.userID())/\(GohXPCService.machServiceName)"` — label format confirmed
- [x] `goh/main.swift` L133: `userID: { Int(getuid()) }` — uid pattern
- [x] `XPCService.swift`: `GohXPCService.machServiceName = "dev.goh.daemon"`

**AC ownership:** AC4 (seam), AC7

**CORRECTNESS NOTE:** `DaemonRestarting` is an INJECTABLE protocol so tests can
stub it. The live `LaunchctlDaemonRestarter` shells out to
`launchctl kickstart -k gui/<uid>/dev.goh.daemon` via `Process`. Tests inject
a stub that records calls and returns success or failure.

**Step 1 — Failing test**

File: `Tests/GohCoreTests/DaemonRestartingTests.swift`

```swift
import Testing
import Foundation
import GohCore

/// A stub DaemonRestarting for unit tests — records calls, returns a configured result.
final class StubDaemonRestarter: DaemonRestarting {
    var callCount = 0
    var shouldSucceed: Bool

    init(shouldSucceed: Bool = true) {
        self.shouldSucceed = shouldSucceed
    }

    func kickstart() throws {
        callCount += 1
        if !shouldSucceed {
            throw DaemonRestartError.launchctlFailed(exitCode: 1, stderr: "stub failure")
        }
    }
}

@Suite("DaemonRestarting")
struct DaemonRestartingTests {

    @Test("StubDaemonRestarter records calls on success")
    func stubSuccessRecordsCalls() throws {
        let stub = StubDaemonRestarter(shouldSucceed: true)
        try stub.kickstart()
        #expect(stub.callCount == 1)
    }

    @Test("StubDaemonRestarter throws on failure")
    func stubFailureThrows() {
        let stub = StubDaemonRestarter(shouldSucceed: false)
        #expect(throws: DaemonRestartError.self) {
            try stub.kickstart()
        }
    }

    @Test("LaunchctlDaemonRestarter builds the correct launchctl arguments")
    func launchctlRestartBuildsCorrectArguments() {
        let restarter = LaunchctlDaemonRestarter(uid: 501, machServiceName: "dev.goh.daemon")
        #expect(restarter.kickstartTarget == "gui/501/dev.goh.daemon")
    }
}
```

**Step 2 — Run expecting failure**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DaemonRestartingTests
```
Expected: compile error (`DaemonRestarting`, `DaemonRestartError`, `LaunchctlDaemonRestarter` not found).

**Step 3 — Minimal implementation**

File: `Sources/GohCore/Model/DaemonRestarting.swift`

```swift
import Foundation

/// Errors from a daemon restart attempt.
public enum DaemonRestartError: Error, Sendable, Equatable {
    /// `launchctl kickstart` exited with a non-zero code.
    case launchctlFailed(exitCode: Int32, stderr: String)
    /// `launchctl` binary was not found or could not be launched.
    case launchctlUnavailable(String)
}

/// Injectable seam for restarting the daemon.
///
/// Production implementation shells `launchctl kickstart -k gui/<uid>/<label>`.
/// Tests inject a stub to verify the decision→action wiring without forking a process.
public protocol DaemonRestarting: Sendable {
    /// Restarts the daemon. Throws `DaemonRestartError` on failure.
    func kickstart() throws
}

/// Live implementation: runs `launchctl kickstart -k gui/<uid>/<machServiceName>`.
///
/// `kickstart -k` is force-restart: it bypasses the KeepAlive semantics and
/// relaunches immediately without throttle. The daemon's plist
/// `KeepAlive = { SuccessfulExit: false }` is irrelevant — `-k` overrides it.
public struct LaunchctlDaemonRestarter: DaemonRestarting {
    let kickstartTarget: String

    public init(uid: Int, machServiceName: String) {
        self.kickstartTarget = "gui/\(uid)/\(machServiceName)"
    }

    public func kickstart() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", kickstartTarget]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw DaemonRestartError.launchctlUnavailable("\(error)")
        }
        process.waitUntilExit()
        let status = process.terminationStatus
        guard status == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DaemonRestartError.launchctlFailed(exitCode: status, stderr: stderr)
        }
    }
}
```

**Step 4 — Run expecting pass**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DaemonRestartingTests
```

**Step 5 — Commit**
```
git add Sources/GohCore/Model/DaemonRestarting.swift Tests/GohCoreTests/DaemonRestartingTests.swift
git commit -m "feat(core): add DaemonRestarting protocol + LaunchctlDaemonRestarter (AC4/AC7 seam)"
```

---

### Task 6 — `DaemonAutoHeal` helper

**Files:**
- Create: `Sources/GohCore/CLI/DaemonAutoHeal.swift`
- Create: `Tests/GohCoreTests/Support/LsReplyTestSupport.swift` (shared reply seam — B4 fix)
- Create: `Tests/GohCoreTests/DaemonAutoHealTests.swift`

**Pre-task reads checklist:**
- [x] `Sources/GohCore/IPC/GohCommandClient.swift` — `GohCommandClient(send:).send(_:expecting:)` confirmed (NOTE: file is in `IPC/`, not `CLI/`)
- [x] `Tests/GohCoreTests/GohSyncCommandTests.swift` — real `reply(requestID:payload:)` helper pattern confirmed: `GohEnvelope(...).xpcDictionary()` then `XPCDictionary(dict)` (B4 — seam basis)
- [x] `CommandReply.swift` — `LsReply` with `featureLevel: Int?` (Task 3)
- [x] `DaemonSkewCheck.swift` — `evaluate(reported:expected:activeDownloadCount:)` (Task 2)
- [x] `DaemonRestarting.swift` — `DaemonRestarting.kickstart()` (Task 5)
- [x] `goh/main.swift` L65–71 — `sendOneShot` pattern (via `GohCommandClient`)

**AC ownership:** AC4 (wiring), AC5, AC7

**CORRECTNESS NOTES:**

1. **Re-check idle immediately before kickstart** (tighten TOCTOU). After
   classifying `.staleIdle`, call `.ls` a second time to confirm 0 active before
   `kickstart()`. If the second check shows active, degrade to notice (AC5).

2. **Poll budget is PINNED: 5.0s total / 250ms interval.** Do not derive from
   parameters — these values are frozen by the spec. Success criterion: reply
   `featureLevel >= GohFeatureLevel.current`. `nil` is NOT success (still stale).

3. **Best-effort always.** If kickstart throws, log to stderr and return. The
   calling command's exit code is never changed.

4. **Scoped to verify --all / verify --quick / doctor only.** `DaemonAutoHeal`
   does not know which command calls it — the caller decides whether to call at all.

5. **`.staleBusy`** — emit notice to stderr, do not call kickstart.

**Step 0 (BEFORE Step 1) — Create shared reply test seam**

**B4 FIX:** The tests need a `GohCommandLine.Sender` that returns a properly-encoded
`LsReply`. The `fatalError` stub in the original draft will not compile successfully.
The real encoding pattern is confirmed from `Tests/GohCoreTests/GohSyncCommandTests.swift`
(the `private func reply<Payload>(requestID:payload:)` helper): encode via
`GohEnvelope(protocolVersion:requestID:messageType:.reply,payload:).xpcDictionary()`,
then wrap in `XPCDictionary(dict)`.

Create `Tests/GohCoreTests/Support/LsReplyTestSupport.swift` with this seam:

```swift
// Tests/GohCoreTests/Support/LsReplyTestSupport.swift
import Foundation
import XPC
@testable import GohCore

/// Encodes an LsReply into the wire format `GohCommandClient.send` expects,
/// echoing the request's requestID (required by `decodeGohReply`).
///
/// Usage: `makeLsSender(reply: LsReply(jobs: [], featureLevel: 1))`
func makeLsSender(reply: LsReply) -> GohCommandLine.Sender {
    { requestDict in
        // Decode the incoming request envelope to extract the requestID.
        let envelope = try requestDict.withUnsafeUnderlyingDictionary { dict in
            try GohEnvelope<Command>(xpcDictionary: dict)
        }
        let replyDict = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: envelope.requestID,
            messageType: .reply,
            payload: reply)
            .xpcDictionary()
        return XPCDictionary(replyDict)
    }
}

/// A sender that returns a sequence of LsReplies, one per call.
/// After the sequence is exhausted, repeats the last reply.
final class SequencedLsSender: @unchecked Sendable {
    private var replies: [LsReply]
    private var index = 0

    init(replies: [LsReply]) {
        precondition(!replies.isEmpty)
        self.replies = replies
    }

    func sender() -> GohCommandLine.Sender {
        { [weak self] requestDict in
            guard let self else { fatalError("SequencedLsSender deallocated") }
            let reply = self.replies[min(self.index, self.replies.count - 1)]
            self.index += 1
            return try makeLsSender(reply: reply)(requestDict)
        }
    }
}

/// Shared stub restarter for DaemonAutoHeal and verify-command tests.
/// Defined here (not private) so it is accessible across all GohCoreTests files.
final class StubRestarter: DaemonRestarting, @unchecked Sendable {
    private(set) var kickstartCalled = 0
    var shouldSucceed: Bool
    init(shouldSucceed: Bool = true) { self.shouldSucceed = shouldSucceed }
    func kickstart() throws {
        kickstartCalled += 1
        if !shouldSucceed {
            throw DaemonRestartError.launchctlFailed(exitCode: 1, stderr: "stub")
        }
    }
}
```

**Step 1 — Failing test**

File: `Tests/GohCoreTests/DaemonAutoHealTests.swift`

```swift
import Testing
import Foundation
import XPC
@testable import GohCore

// StubRestarter, SequencedLsSender, and makeLsSender are defined in
// Tests/GohCoreTests/Support/LsReplyTestSupport.swift (created in Step 0).
// DaemonRestartingTests.swift defines its own private StubDaemonRestarter —
// that is separate and private; no collision.

@Suite("DaemonAutoHeal")
struct DaemonAutoHealTests {

    @Test("staleIdle triggers kickstart and poll; AC4 wiring")
    func staleIdleTriggersKickstart() throws {
        // Sequence: stale (call 1 = initial ls), stale (call 2 = re-check idle),
        // then current (calls 3+ = poll after kickstart).
        let restarter = StubRestarter()
        let sequenced = SequencedLsSender(replies: [
            LsReply(jobs: [], featureLevel: nil),      // call 1: initial classify → staleIdle
            LsReply(jobs: [], featureLevel: nil),      // call 2: re-check still idle → ok to kickstart
            LsReply(jobs: [], featureLevel: GohFeatureLevel.current),  // call 3: poll → current
        ])
        let notice = DaemonAutoHeal.runIfNeeded(
            send: sequenced.sender(),
            restarter: restarter,
            uid: 501,
            pollBudget: .seconds(1),
            pollInterval: .milliseconds(50))
        #expect(restarter.kickstartCalled == 1)
        #expect(notice == nil)  // successful heal → no notice
    }

    @Test("staleBusy does NOT kickstart, emits notice; AC5")
    func staleBusyNoKickstart() throws {
        let restarter = StubRestarter()
        let activeJob = JobSummary(
            id: 0, url: "https://example.com", destination: "/tmp/f",
            state: .active,
            progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
            createdAt: Date(), lastProgressAt: nil,
            requestedConnectionCount: 8, actualConnectionCount: 1)
        let sender = makeLsSender(reply: LsReply(jobs: [activeJob], featureLevel: nil))
        let notice = DaemonAutoHeal.runIfNeeded(send: sender, restarter: restarter, uid: 501)
        #expect(restarter.kickstartCalled == 0)
        #expect(notice != nil)   // busy notice present
    }

    @Test("kickstart unavailable degrades to notice-only; AC7")
    func kickstartUnavailableDegradesGracefully() throws {
        let restarter = StubRestarter(shouldSucceed: false)
        // Always returns stale reply — kickstart will fail, poll will timeout.
        let sequenced = SequencedLsSender(replies: [
            LsReply(jobs: [], featureLevel: nil),  // classify: staleIdle
            LsReply(jobs: [], featureLevel: nil),  // re-check: still idle → attempt kickstart (fails)
        ])
        let notice = DaemonAutoHeal.runIfNeeded(
            send: sequenced.sender(),
            restarter: restarter,
            uid: 501,
            pollBudget: .milliseconds(200),
            pollInterval: .milliseconds(50))
        #expect(restarter.kickstartCalled == 1)
        #expect(notice != nil)   // degraded to notice (kickstart threw)
    }

    @Test("current daemon skips all action")
    func currentDaemonNoOp() throws {
        let restarter = StubRestarter()
        let sender = makeLsSender(reply: LsReply(jobs: [], featureLevel: GohFeatureLevel.current))
        let notice = DaemonAutoHeal.runIfNeeded(send: sender, restarter: restarter, uid: 501)
        #expect(restarter.kickstartCalled == 0)
        #expect(notice == nil)
    }
}
```

**Step 2 — Run expecting failure**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DaemonAutoHealTests
```
Expected: compile error (`DaemonAutoHeal` not found).

**Step 3 — Minimal implementation**

File: `Sources/GohCore/CLI/DaemonAutoHeal.swift`

```swift
import Darwin   // getuid() — required; not implied by Foundation on all SDK configs (B5 fix)
import Foundation
import XPC

/// Shared auto-heal logic for commands scoped to detect and correct daemon skew.
///
/// Scoped to: `goh verify --all`, `goh verify --quick`, `goh doctor`.
/// NOT invoked by every verb — that would add a needless per-command round-trip.
///
/// Protocol:
/// 1. Send `.ls` to classify skew (`DaemonSkewCheck.evaluate`).
/// 2. `.staleIdle` → re-check idle (tighten TOCTOU window). If still idle,
///    call `restarter.kickstart()`. Poll `.ls` until `featureLevel >= current`
///    or budget exhausted. On timeout or kickstart failure → notice only.
/// 3. `.staleBusy` → notice only (no restart while downloads run).
/// 4. `.current` → no-op.
/// 5. All failures (XPC, kickstart, poll timeout) → notice only. Exit code unchanged.
public enum DaemonAutoHeal {

    /// Duration type used for the poll budget and interval.
    /// Using `Duration` (Swift 5.7+; always available on macOS 26.0 target).
    public typealias Budget = Duration

    /// Run the auto-heal check and return an optional notice string.
    ///
    /// - Parameters:
    ///   - send: XPC sender (the CLI's existing send closure).
    ///   - restarter: Injectable restart seam. Nil disables the kickstart step
    ///     (test-only: pass nil to assert no kickstart was attempted).
    ///   - uid: User ID for the launchctl target (default: `getuid()`).
    ///   - pollBudget: Maximum time to wait for the new daemon. Default 5s (spec §6).
    ///   - pollInterval: Interval between `.ls` polls. Default 250ms (spec §6).
    /// - Returns: A non-nil notice string when skew was detected but NOT resolved
    ///   (busy, kickstart failed, or poll timed out). `nil` means either current
    ///   or successfully healed.
    @discardableResult
    public static func runIfNeeded(
        send: GohCommandLine.Sender,
        restarter: (any DaemonRestarting)?,
        uid: Int = Int(Darwin.getuid()),
        pollBudget: Budget = .seconds(5),
        pollInterval: Budget = .milliseconds(250)
    ) -> String? {
        // Step 1: Initial .ls to classify.
        let reply: LsReply
        do {
            reply = try sendLs(send)
        } catch {
            return nil  // XPC unreachable — not our problem here (doctor handles that)
        }
        let activeCount = reply.jobs.filter { $0.state == .active }.count
        let skew = DaemonSkewCheck.evaluate(
            reported: reply.featureLevel,
            expected: GohFeatureLevel.current,
            activeDownloadCount: activeCount)

        switch skew {
        case .current:
            return nil

        case .staleBusy:
            fputs(
                "goh: background service is an older build — "
                + "it will update automatically when downloads finish "
                + "(or run: goh daemon restart --force)\n",
                stderr)
            return "stale daemon (busy)"

        case .staleIdle:
            // Step 2: Re-check idle to tighten the TOCTOU window.
            do {
                let recheck = try sendLs(send)
                let recheckActive = recheck.jobs.filter { $0.state == .active }.count
                if recheckActive > 0 {
                    // A download started in the window — treat as busy.
                    fputs(
                        "goh: background service is an older build — "
                        + "a download started before the restart window closed. "
                        + "It will update when downloads finish.\n",
                        stderr)
                    return "stale daemon (became busy)"
                }
            } catch {
                return nil  // XPC lost — let the command proceed
            }

            // Step 3: Kickstart.
            guard let restarter else {
                return "stale daemon (no restarter configured)"
            }
            do {
                try restarter.kickstart()
            } catch {
                fputs(
                    "goh: could not restart background service (\(error)) — "
                    + "run: goh daemon restart\n",
                    stderr)
                return "stale daemon (kickstart failed: \(error))"
            }

            // Step 4: Poll until featureLevel >= current or budget exhausted.
            let deadline = ContinuousClock.now.advanced(by: pollBudget)
            while ContinuousClock.now < deadline {
                // Busy-wait with Thread.sleep (synchronous CLI context).
                // Must include both .seconds and .attoseconds to avoid 0-sleep spin
                // for any interval ≥ 1s (B1 fix).
                let intervalSecs = Double(pollInterval.components.seconds)
                    + Double(pollInterval.components.attoseconds) / 1e18
                Thread.sleep(forTimeInterval: intervalSecs)
                do {
                    let polled = try sendLs(send)
                    if let level = polled.featureLevel, level >= GohFeatureLevel.current {
                        return nil  // Successfully healed.
                    }
                    // nil or < current → keep polling (old daemon may still be dying)
                } catch {
                    // XPC temporarily unavailable during restart — keep polling
                }
            }

            // Step 5: Timeout → notice only (best-effort).
            fputs(
                "goh: background service did not respond with the new version within 5s — "
                + "it may need a moment. Run: goh doctor\n",
                stderr)
            return "stale daemon (poll timeout)"
        }
    }

    private static func sendLs(_ send: GohCommandLine.Sender) throws -> LsReply {
        try GohCommandClient(send: send).send(.ls, expecting: LsReply.self)
    }
}
```

**Step 4 — Run expecting pass**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DaemonAutoHealTests
```

**Step 5 — Commit**
```
git add Sources/GohCore/CLI/DaemonAutoHeal.swift \
        Tests/GohCoreTests/Support/LsReplyTestSupport.swift \
        Tests/GohCoreTests/DaemonAutoHealTests.swift
git commit -m "feat(cli): add DaemonAutoHeal — scoped idle-gated kickstart + poll (AC4/AC5/AC7)"
```

---

### Task 7 — Wire auto-heal into `GohVerifyAllCommand` and `GohVerifyQuickCommand`

**Files:**
- Modify: `Sources/GohCore/CLI/GohVerifyAllCommand.swift`
- Modify: `Sources/GohCore/CLI/GohVerifyQuickCommand.swift`
- Extend: `Tests/GohCoreTests/GohVerifyAllCommandTests.swift`
- Extend: `Tests/GohCoreTests/GohVerifyQuickCommandTests.swift`
- Reads (pre-existing from Task 6): `Tests/GohCoreTests/Support/LsReplyTestSupport.swift`

**Pre-task reads checklist:**
- [x] `GohVerifyAllCommand.swift` L45–50 — `run(provenanceStorePath:json:generatedAt:send:)` confirmed
- [x] `GohVerifyQuickCommand.swift` L33 — `run(provenanceStorePath:probe:)` confirmed (no `send` param today — Task 7 adds it)
- [x] `Tests/GohCoreTests/Support/LsReplyTestSupport.swift` — `StubRestarter`, `SequencedLsSender`, `makeLsSender` confirmed (created in Task 6)

**AC ownership:** AC5 (verify paths)

**CORRECTNESS NOTE:** Auto-heal is **best-effort** — it must never change the
command's exit code. Add the `DaemonAutoHeal.runIfNeeded(send:restarter:)` call
**before** the ledger classify step. If `send` is nil (attest path), skip.
New parameters `restarter: (any DaemonRestarting)? = nil` added with default
nil so all existing call sites compile unchanged.

**Step 1 — Failing test** (extend both test files)

**B4 NOTE:** `StubRestarter` and `makeLsSender`/`SequencedLsSender` come from
`Tests/GohCoreTests/Support/LsReplyTestSupport.swift` (created in Task 6 Step 0).
Add `StubRestarter` to that shared support file (move it out of `DaemonAutoHealTests.swift`
where it was defined private) so it is accessible across test files in the `GohCoreTests` target.
Do NOT use `makeReplyDict` — that symbol does not exist. Use `SequencedLsSender` instead.

```swift
// GohVerifyAllCommandTests.swift — append to the existing suite:
// (requires LsReplyTestSupport.swift to define StubRestarter and SequencedLsSender)
@Test("verify --all with stale idle daemon triggers auto-heal before verification")
func verifyAllWithStaleIdleDaemonTriggersAutoHeal() throws {
    let restarter = StubRestarter(shouldSucceed: true)
    // Sequence: stale (initial classify), stale (re-check idle), current (poll)
    let sequenced = SequencedLsSender(replies: [
        LsReply(jobs: [], featureLevel: nil),
        LsReply(jobs: [], featureLevel: nil),
        LsReply(jobs: [], featureLevel: GohFeatureLevel.current),
    ])
    let result = GohVerifyAllCommand.run(
        provenanceStorePath: "",
        send: sequenced.sender(),
        restarter: restarter)
    #expect(restarter.kickstartCalled == 1)
    #expect(result.exitCode == 0)   // no entries → 0; auto-heal never changes exit code
}
```

```swift
// GohVerifyQuickCommandTests.swift — append:
// (requires LsReplyTestSupport.swift to define StubRestarter and SequencedLsSender)
@Test("verify --quick with stale daemon triggers auto-heal")
func verifyQuickWithStaleDaemonTriggersAutoHeal() throws {
    let restarter = StubRestarter(shouldSucceed: true)
    let sequenced = SequencedLsSender(replies: [
        LsReply(jobs: [], featureLevel: nil),
        LsReply(jobs: [], featureLevel: nil),
        LsReply(jobs: [], featureLevel: GohFeatureLevel.current),
    ])
    let result = GohVerifyQuickCommand.run(
        provenanceStorePath: "",
        send: sequenced.sender(),
        restarter: restarter)
    #expect(restarter.kickstartCalled == 1)
    #expect(result.exitCode == 0)
}
```

**Step 2 — Run expecting failure**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllCommandTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyQuickCommandTests
```

**Step 3 — Minimal implementation**

In `GohVerifyAllCommand.run(...)`, add `restarter: (any DaemonRestarting)? = nil`
parameter. Before `let outcome = ProvenanceLedgerReader.read(...)`:
```swift
if let send {
    DaemonAutoHeal.runIfNeeded(send: send, restarter: restarter)
}
```

In `GohVerifyQuickCommand.run(...)`, add `send: GohCommandLine.Sender? = nil`
and `restarter: (any DaemonRestarting)? = nil` parameters. Before
`let outcome = ProvenanceLedgerReader.read(...)`:
```swift
if let send {
    DaemonAutoHeal.runIfNeeded(send: send, restarter: restarter)
}
```

**A1 FIX — concrete `goh/main.swift` call-site edits for verify paths:**

`GohVerifyQuickCommand.run` today (confirmed at L33) takes only
`provenanceStorePath:probe:` — no `send` param. After Task 7's change it gains
`send: GohCommandLine.Sender? = nil` and `restarter: (any DaemonRestarting)? = nil`.

The `GohCommandLine.run()` dispatch site for `.verifyQuick` (currently at ~L182–184)
changes from:
```swift
case .verifyQuick:
    return GohVerifyQuickCommand.run(
        provenanceStorePath: provenanceStorePathResolver() ?? "")
```
to:
```swift
case .verifyQuick:
    return GohVerifyQuickCommand.run(
        provenanceStorePath: provenanceStorePathResolver() ?? "",
        send: send,
        restarter: LaunchctlDaemonRestarter(
            uid: Int(getuid()),
            machServiceName: GohXPCService.machServiceName))
```
Note: `getuid()` is already called at `goh/main.swift` L133 via `{ Int(getuid()) }`;
this call is in `GohCommandLine.run()` inside `GohCore`, which imports Darwin
through Foundation. No new import is required in `GohCommandLine.swift`.

Similarly, the `.verifyAll` dispatch site (in `GohCommandLine.run()`) gains
`restarter: LaunchctlDaemonRestarter(uid: Int(getuid()), machServiceName: GohXPCService.machServiceName)`.
The `send` parameter is already threaded to `GohVerifyAllCommand.run` — confirm
at the actual dispatch site before editing.

`goh/main.swift` itself does NOT need changes for the verify paths — the `send`
closure is already passed as the trailing closure at L293–294; `GohCommandLine.run()`
uses `self.send` internally. The `LaunchctlDaemonRestarter` is constructed inside
`GohCommandLine.run()` at the dispatch site, using `GohXPCService.machServiceName`
(available from `GohCore`) and `getuid()` (available via Foundation/Darwin).

**Step 4 — Run expecting pass**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyAllCommandTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohVerifyQuickCommandTests
```

**Step 5 — Commit**
```
git add Sources/GohCore/CLI/GohVerifyAllCommand.swift Sources/GohCore/CLI/GohVerifyQuickCommand.swift \
        Sources/goh/main.swift \
        Tests/GohCoreTests/GohVerifyAllCommandTests.swift Tests/GohCoreTests/GohVerifyQuickCommandTests.swift
git commit -m "feat(cli): wire DaemonAutoHeal into verify --all and verify --quick (AC5)"
```

---

### Task 8 — `goh daemon restart [--force]` verb

**Files:**
- Modify: `Sources/GohCore/CLI/GohCommandLine.swift`
- Modify: `Sources/goh/main.swift`
- Extend: `Tests/GohCoreTests/GohCommandLineTests.swift`

**Pre-task reads checklist:**
- [x] `GohCommandLine.swift` L300–323 — `ParsedCommand` enum cases
- [x] `GohCommandLine.swift` L340–509 — `parse(_:)` method
- [x] `GohCommandLine.swift` L257 — `exitCode: 64` for `ParseError` (usage refusal)
- [x] `GohCommandLine.swift` L44–102 — `GohCommandLine.init` parameter list (confirmed: `doctor: Doctor? = nil` before `send:` — same pattern for `daemon:`)
- [x] `Sources/goh/main.swift` L215–295 — `GohCommandLine(...)` trailing-closure region confirmed; `daemon:` goes before the `send:` trailing closure
- [x] `Tests/GohCoreTests/Support/LsReplyTestSupport.swift` — `StubRestarter` and `makeLsSender` available (created in Task 6)

**AC ownership:** AC3 (full)

**CORRECTNESS NOTES:**

1. **Exit code for idle refusal is in the 64-class (usage refusal).** Specifically
   exit 64. This is PINNED — the spec says "fixed non-zero exit code (64-class
   usage refusal)". The message must be clear: how many active downloads, and
   that `--force` overrides.

2. **`goh daemon restart` with `--force`** restarts regardless. The force path
   must log to stderr: "Restarting background service (force) — active downloads
   may be interrupted." This is honest documentation, not an error.

3. **No collision with existing parse cases.** `daemon` is a new top-level verb.
   Unknown `daemon` subcommands (not `restart`) → `ParseError` (exit 64).

4. **The daemon closure in `GohCommandLine.init`:** add
   `daemon: ((_ force: Bool) throws -> GohCommandLineResult)? = nil` before `send:`.
   This is an optional closure like `doctor`.

**B4 NOTE:** `GohCommandLineTests.swift` needs `StubRestarter` from
`Tests/GohCoreTests/Support/LsReplyTestSupport.swift`. Add an import or ensure
the support file is in the same test target (it is — all files under `Tests/GohCoreTests/`
compile into the same target). `makeReplyDict` does NOT exist; use `makeLsSender`.
The `send:` closure in the test below is never actually invoked (the `daemon:` closure
is the stub that handles everything), so a simple non-crashing placeholder is fine.

**Step 1 — Failing tests**

```swift
// GohCommandLineTests.swift — append to the existing suite:
// (StubRestarter is defined in Tests/GohCoreTests/Support/LsReplyTestSupport.swift)

@Test("goh daemon restart parses successfully")
func parseDaemonRestart() throws {
    // GohCommandLine.parse is private; verify end-to-end via run().
    let restarter = StubRestarter(shouldSucceed: true)
    // The daemon: closure below never calls send, but GohCommandLine.init requires
    // a non-nil send closure. Provide one via makeLsSender with a dummy reply.
    let sender = makeLsSender(reply: LsReply(jobs: [], featureLevel: GohFeatureLevel.current))
    let line = GohCommandLine(
        arguments: ["daemon", "restart"],
        daemon: { force in
            // Minimal stub: no active downloads → kickstart
            if !force {
                // Simulate 0 active downloads → proceed
            }
            try restarter.kickstart()
            return GohCommandLineResult(exitCode: 0, standardOutput: "Background service restarted.\n")
        },
        send: sender)
    let result = line.run()
    #expect(result.exitCode == 0)
    #expect(restarter.kickstartCalled == 1)
}

@Test("goh daemon restart refuses with active downloads (exit 64)")
func daemonRestartRefusesWhenBusy() {
    let line = GohCommandLine(
        arguments: ["daemon", "restart"],
        daemon: { force in
            guard !force else {
                return GohCommandLineResult(exitCode: 0, standardOutput: "Force restarted.\n")
            }
            return GohCommandLineResult(
                exitCode: 64,
                standardError: "1 active download is running. Use --force to restart anyway.\n")
        },
        send: { _ in fatalError("send not called") })
    let result = line.run()
    #expect(result.exitCode == 64)
    #expect(result.standardError.contains("active download"))
}

@Test("goh daemon restart --force bypasses idle gate")
func daemonRestartForceBypassesIdleGate() {
    let restarter = StubRestarter()
    let line = GohCommandLine(
        arguments: ["daemon", "restart", "--force"],
        daemon: { force in
            #expect(force == true)
            try restarter.kickstart()
            return GohCommandLineResult(exitCode: 0, standardOutput: "Force restarted.\n")
        },
        send: { _ in fatalError("send not called") })
    let result = line.run()
    #expect(result.exitCode == 0)
    #expect(restarter.kickstartCalled == 1)
}

@Test("goh daemon with unknown subcommand exits 64")
func daemonUnknownSubcommandExits64() {
    let line = GohCommandLine(
        arguments: ["daemon", "frobnicate"],
        daemon: { _ in fatalError("should not reach") },
        send: { _ in fatalError("send not called") })
    let result = line.run()
    #expect(result.exitCode == 64)
}
```

**Step 2 — Run expecting failure**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohCommandLineTests
```

**Step 3 — Minimal implementation**

In `GohCommandLine.swift`:

1. Add `public typealias DaemonCommand = (_ force: Bool) throws -> GohCommandLineResult` (alongside existing typealias).
2. Add `private let daemon: DaemonCommand?` property.
3. Add `daemon: DaemonCommand? = nil` parameter to `init`, before `send:`.
4. Add `case daemon(force: Bool)` to `private enum ParsedCommand`.
5. In `parse(_:)`, before the final throw, add:
   ```swift
   if arguments.first == "daemon" {
       let rest = Array(arguments.dropFirst())
       return try parseDaemon(rest)
   }
   ```
6. Add `private static func parseDaemon(_ arguments: [String]) throws -> ParsedCommand`:
   ```swift
   private static func parseDaemon(_ arguments: [String]) throws -> ParsedCommand {
       guard arguments.first == "restart" else {
           let sub = arguments.first ?? "(none)"
           throw ParseError(message: "unknown daemon subcommand '\(sub)'; try: goh daemon restart [--force]")
       }
       let rest = Array(arguments.dropFirst())
       var force = false
       for arg in rest {
           if arg == "--force" { force = true }
           else { throw ParseError(message: "unknown daemon restart option \(arg)") }
       }
       return .daemon(force: force)
   }
   ```
7. In `run()`, add a `case .daemon(let force):` dispatch:
   ```swift
   case .daemon(let force):
       guard let daemon else {
           return GohCommandLineResult(
               exitCode: 1, standardError: "The daemon command is not configured.\n")
       }
       return try daemon(force)
   ```
8. Update `Self.usage()` to add the daemon line.

**A1 FIX — concrete `goh/main.swift` daemon-verb closure:**

The `daemon:` closure is added to `GohCommandLine.init(...)` in `goh/main.swift`
alongside the existing `foreground:`, `top:`, `doctor:`, `diagnose:` closures.
The trailing-closure `send:` stays last. Confirmed at `goh/main.swift` L215–295
— insert `daemon:` before the `send:` trailing closure, following the same pattern.

```swift
// goh/main.swift — add daemon: closure inside GohCommandLine(...)
// Insert BEFORE the ) { request in  send trailing-closure at ~L293:
daemon: { force in
    // Step 1: Read current queue to get active count and featureLevel.
    let requestID = UUID()
    let lsRequest = try GohEnvelope(
        protocolVersion: CommandService.protocolVersion,
        requestID: requestID,
        messageType: .request,
        payload: Command.ls)
        .xpcDictionary()
    let lsResponse = try sendOneShot(
        XPCDictionary(lsRequest), validationMode: validationMode)
    let lsReply: LsReply
    switch lsResponse.decodeGohReply(as: LsReply.self) {
    case .reply(_, let payload): lsReply = payload
    case .daemonError(_, let err):
        return GohCommandLineResult(exitCode: 1,
            standardError: "goh: daemon error reading queue: \(err)\n")
    case .malformed:
        return GohCommandLineResult(exitCode: 1,
            standardError: "goh: malformed daemon reply\n")
    }
    let activeCount = lsReply.jobs.filter { $0.state == .active }.count

    // Step 2: Idle-gate (unless --force).
    if !force && activeCount > 0 {
        return GohCommandLineResult(
            exitCode: 64,
            standardError: "goh: \(activeCount) active download(s) running."
                + " Use --force to restart anyway.\n")
    }
    if force && activeCount > 0 {
        fputs("goh: Restarting background service (force) —"
            + " active downloads may be interrupted.\n", stderr)
    }

    // Step 3: Kickstart.
    let restarter = LaunchctlDaemonRestarter(
        uid: Int(getuid()),
        machServiceName: GohXPCService.machServiceName)
    do {
        try restarter.kickstart()
    } catch {
        return GohCommandLineResult(
            exitCode: 1,
            standardError: "goh: could not restart background service: \(error)\n")
    }

    // Step 4: Poll up to 5s / 250ms for the new daemon.
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        Thread.sleep(forTimeInterval: 0.25)
        if let polled = try? GohCommandClient(
                send: { req in try sendOneShot(req, validationMode: validationMode) })
            .send(.ls, expecting: LsReply.self),
           let level = polled.featureLevel,
           level >= GohFeatureLevel.current {
            return GohCommandLineResult(
                exitCode: 0,
                standardOutput: "Background service restarted.\n")
        }
    }
    return GohCommandLineResult(
        exitCode: 0,
        standardOutput: "Background service restart initiated"
            + " (did not confirm new version within 5s — run: goh doctor).\n")
},
```

Note: `GohCommandClient` and `GohEnvelope` are `import`-visible inside `goh/main.swift`
via `import GohCore`. `sendOneShot` and `validationMode` are defined earlier in the file
(L65–71 and L213 respectively). `CommandService.protocolVersion` is public from `GohCore`.

**Step 4 — Run expecting pass**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohCommandLineTests
```

**Step 5 — Commit**
```
git add Sources/GohCore/CLI/GohCommandLine.swift Sources/goh/main.swift \
        Tests/GohCoreTests/GohCommandLineTests.swift
git commit -m "feat(cli): add 'goh daemon restart [--force]' verb (AC3)"
```

---

### Task 9 — Doctor skew finding

**Files:**
- Modify: `Sources/GohCore/CLI/GohDoctor.swift`
- Extend: `Tests/GohCoreTests/GohDoctorTests.swift`

**Pre-task reads checklist:**
- [x] `GohDoctor.swift` L195–219 — `xpcFindings()` confirmed; `reply.jobs` used for count
- [x] `GohDoctorProbes` L17 — `readQueue: () throws -> LsReply` returns `LsReply`

**AC ownership:** AC6 (full)

**CORRECTNESS NOTE:** The doctor finding uses `.warning` severity for skew (not
`.failure`) — skew is actionable, not a blocking error. The finding text:
- When stale: title `"daemon featureLevel: \(daemon) (client expects \(current)) — skew detected"`,
  recovery `"Run: goh daemon restart"`.
- When current: title `"daemon featureLevel: \(level) (current)"`, severity `.ok`.
- When unreachable: XPC finding already reports failure; skip the featureLevel finding.

**Step 1 — Failing tests**

```swift
// GohDoctorTests.swift — append to the @Suite:

@Test("doctor shows ok featureLevel finding when current")
func doctorShowsOkFeatureLevelWhenCurrent() {
    let paths = DoctorPaths()
    var probes = Self.probes(paths: paths)
    // Override readQueue to return current featureLevel
    probes.readQueue = {
        LsReply(jobs: [/* one existing job */], featureLevel: GohFeatureLevel.current)
    }
    let result = GohDoctor(probes: probes).run()
    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("[ok] daemon featureLevel: \(GohFeatureLevel.current) (current)"))
}

@Test("doctor flags daemon featureLevel skew as warning")
func doctorFlagsFeatureLevelSkewAsWarning() {
    let paths = DoctorPaths()
    var probes = Self.probes(paths: paths)
    probes.readQueue = {
        LsReply(jobs: [], featureLevel: nil)   // nil = stale
    }
    let result = GohDoctor(probes: probes).run()
    #expect(result.exitCode == 0)   // warning → not a failure exit
    #expect(result.standardOutput.contains("[warn]"))
    #expect(result.standardOutput.contains("skew"))
    #expect(result.standardOutput.contains("goh daemon restart"))
    // Must end with "Healthy with warnings."
    #expect(result.standardOutput.hasSuffix("Healthy with warnings.\n"))
}
```

**Step 2 — Run expecting failure**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohDoctorTests
```

**Step 3 — Minimal implementation**

**B2 FIX — `xpcFindings()` restructure (REQUIRED for compilability):**
The real `xpcFindings()` at `Sources/GohCore/CLI/GohDoctor.swift` L195–219 returns a
literal `[Finding]` in the success branch — there is NO mutable `findings` local var.
`findings.append(...)` will not compile as-is. The entire method must be restructured
to use a `var findings: [Finding]` collector.

Replace `private func xpcFindings() -> [Finding]` in full:

```swift
private func xpcFindings() -> [Finding] {
    do {
        let reply = try probes.readQueue()
        // Start with the two existing findings (reachable + queue-readable).
        var findings: [Finding] = [
            Finding(
                severity: .ok,
                title: "XPC reachable",
                detail: nil,
                recovery: nil),
            Finding(
                severity: .ok,
                title: "queue readable: \(jobCount(reply.jobs.count))",
                detail: nil,
                recovery: nil),
        ]
        // Append featureLevel / skew finding.
        let daemonLevel = reply.featureLevel
        let clientLevel = GohFeatureLevel.current
        if let daemonLevel {
            let skew = DaemonSkewCheck.evaluate(
                reported: daemonLevel,
                expected: clientLevel,
                activeDownloadCount: reply.jobs.filter { $0.state == .active }.count)
            if skew == .current {
                findings.append(Finding(
                    severity: .ok,
                    title: "[ok] daemon featureLevel: \(daemonLevel) (current)",
                    detail: nil,
                    recovery: nil))
            } else {
                findings.append(Finding(
                    severity: .warning,
                    title: "[warn] daemon featureLevel: \(daemonLevel) (client expects \(clientLevel)) — skew detected",
                    detail: "The background service is an older build. New behavior is unavailable until it restarts.",
                    recovery: "Run: goh daemon restart"))
            }
        } else {
            // nil = pre-feature daemon (stale)
            findings.append(Finding(
                severity: .warning,
                title: "[warn] daemon featureLevel: unknown (client expects \(clientLevel)) — skew detected",
                detail: "The background service predates featureLevel tracking. It needs a restart.",
                recovery: "Run: goh daemon restart"))
        }
        return findings
    } catch {
        return [
            Finding(
                severity: .failure,
                title: "XPC reachable",
                detail: "Could not reach gohd: \(error)",
                recovery: xpcRecovery()),
        ]
    }
}
```

Note on the `[\(label)]` prefix format: the real `Finding` renders the severity label
inline in the title string in this project. The `severity: .ok` / `severity: .warning`
field labels are confirmed from the existing code. The `severity:`, `title:`, `detail:`,
`recovery:` parameter labels are confirmed from the existing `Finding` call sites in the
real file.

**Step 4 — Run expecting pass**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohDoctorTests
```

**Step 5 — Commit**
```
git add Sources/GohCore/CLI/GohDoctor.swift Tests/GohCoreTests/GohDoctorTests.swift
git commit -m "feat(cli): doctor reports daemon featureLevel and flags skew (AC6)"
```

---

### Task 10 — Reconcile end-to-end re-schedule assertion

**Files:**
- Extend: `Tests/GohCoreTests/JobStoreStartupReconciliationTests.swift`

**Pre-task reads checklist:**
- [x] `JobStoreStartupReconciliationTests.swift` L1–219 — existing test structure confirmed
- [x] `gohd/main.swift` L109–115, L221 — reconcile call + re-schedule loop (RELY only)

**AC ownership:** AC8 (full)

**CORRECTNESS NOTES:**

1. **Both branches must be tested:** checkpointed (resumes) AND uncheckpointed (fails-retryable).
2. **End-to-end re-schedule assertion:** after reconcile, the `requeuedJobIDs` must be
   handed to the scheduler. Simulate the gohd main loop (`for job in store.allJobs() where job.state == .queued`).
3. **The "silent loss" invariant:** a job with no checkpoint must be `.failed` with
   `retryEligible == true` after reconcile, and must appear in `failedJobIDs` (logged).
4. Do NOT change reconcile behavior — only ADD assertions.

**Step 1 — Failing tests** (append to `JobStoreStartupReconciliationTests.swift`)

```swift
@Test("end-to-end: checkpointed active job is requeued AND re-scheduled by the main loop")
func activeJobWithCheckpointIsRequeuedAndRescheduled() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = JobStore()
    let active = try makeActiveJob(store: store, directory: directory)
    let partialSize: UInt64 = 2 << 20
    try Data(count: Int(partialSize)).write(to: URL(filePath: active.destination))

    let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
    try checkpointStore.save(DownloadCheckpoint(
        jobID: active.id,
        url: active.url,
        destination: active.destination,
        partialFileSize: partialSize,
        totalBytes: 4 << 20,
        strongETag: "\"strong-validator\"",
        completedPieces: [
            CheckpointPiece(start: 0, length: 1 << 20),
            CheckpointPiece(start: 1 << 20, length: 1 << 20),
        ],
        updatedAt: Date()))

    let result = store.reconcileActiveJobsOnStartup(checkpoints: checkpointStore)

    // Phase 1 assertion: the job is in requeuedJobIDs (existing behavior).
    #expect(result.requeuedJobIDs == [active.id])
    #expect(result.failedJobIDs.isEmpty)

    // Phase 2 assertion: the gohd main-loop pattern (RELY — do not change gohd).
    // Simulate: for job in store.allJobs() where job.state == .queued { schedule(job) }
    var scheduledIDs: [UInt64] = []
    for job in store.allJobs() where job.state == .queued {
        scheduledIDs.append(job.id)
    }
    #expect(scheduledIDs == [active.id], "requeued job must be picked up by the scheduler loop")
    // The requeued job has the checkpoint's progress applied.
    let requeued = try #require(store.job(id: active.id))
    #expect(requeued.progress.bytesCompleted == partialSize)
}

@Test("end-to-end: uncheckpointed active job is failed-retryable and surfaced — never silently dropped")
func activeJobWithoutCheckpointIsFailedRetryableAndSurfaced() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = JobStore()
    let active = try makeActiveJob(store: store, directory: directory)
    let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))

    let result = store.reconcileActiveJobsOnStartup(checkpoints: checkpointStore)

    // Must appear in failedJobIDs (the daemon logs this path — "surfaced").
    #expect(result.failedJobIDs == [active.id])
    #expect(result.requeuedJobIDs.isEmpty)

    // The job is NOT silently dropped — it is failed with retryEligible = true.
    let failed = try #require(store.job(id: active.id))
    #expect(failed.state == .failed)
    #expect(failed.retryEligible == true)

    // It is NOT in the scheduler loop (state != .queued).
    let scheduledIDs = store.allJobs().filter { $0.state == .queued }.map(\.id)
    #expect(!scheduledIDs.contains(active.id), "failed job must NOT be re-scheduled")
}
```

**Step 2 — Run expecting failure** (tests should pass if reconcile is already
correct; they only ADD assertions about behavior not previously asserted):
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter JobStoreStartupReconciliationTests
```
Expected: tests compile and pass (they assert existing correct behavior in a
new way). If any fail, the reconcile behavior has drifted — investigate before
proceeding.

**Step 3 — Implementation**

No production code changes. If the tests pass as written, the commit records
the end-to-end invariant. If they fail, identify the drift and fix it first.

**Step 4 — Run confirming pass**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter JobStoreStartupReconciliationTests
```

**Step 5 — Commit**
```
git add Tests/GohCoreTests/JobStoreStartupReconciliationTests.swift
git commit -m "test(core): assert reconcile end-to-end re-schedule and fail-retryable (AC8)"
```

---

### Task 11 — `GohMenuClient.ls()` + `LiveGohMenuClient` implementation

**B3 PROTOCOL-EXTENSION FAN-OUT WARNING:** Adding `func ls() async throws -> LsReply`
(and `func restartDaemon() async throws` in Task 13) to the `GohMenuClient` protocol
forces EVERY conformer to implement it. Under `-warnings-as-errors` a missing
protocol requirement is a hard build error. The full conformer list, found via
`grep -rn "GohMenuClient" Tests/ Sources/`, is:

| Conformer | File | Action |
|---|---|---|
| `LiveGohMenuClient` | `Sources/goh-menu/main.swift` | Add real XPC `.ls` impl |
| `FakeMenuClient` | `Tests/GohMenuBarTests/GohMenuViewModelTests.swift` ~L320 | Add stub returning configurable `LsReply` |
| `LongLivedMenuClient` | `Tests/GohMenuBarTests/GohMenuViewModelTests.swift` ~L419 | Add stub returning `LsReply(jobs: [], featureLevel: nil)` |
| `FakeMenuClient` | `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift` ~L18 | Add stub returning `LsReply(jobs: [], featureLevel: nil)` |
| `SpyMenuClient` | `Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift` ~L9 | Add stub returning `LsReply(jobs: [], featureLevel: nil)` |

All five must be updated in the same task or the build breaks.

**Files:**
- Modify: `Sources/GohMenuBar/GohMenuViewModel.swift` (protocol: add `ls()`)
- Modify: `Sources/goh-menu/main.swift` (`LiveGohMenuClient` real impl)
- Modify: `Tests/GohMenuBarTests/GohMenuViewModelTests.swift` (`FakeMenuClient` + `LongLivedMenuClient` stubs)
- Modify: `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift` (`FakeMenuClient` stub)
- Modify: `Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift` (`SpyMenuClient` stub)

**Pre-task reads checklist:**
- [x] `GohMenuViewModel.swift` L6–15 — `GohMenuClient` protocol confirmed (has `progressSnapshots`, `add`, `pause`, `resume`, `remove`, `recordVerifiedProvenance`)
- [x] `goh-menu/main.swift` L11–135 — `LiveGohMenuClient` pattern confirmed (uses `sendOneShot`)
- [x] `Tests/GohMenuBarTests/GohMenuViewModelTests.swift` ~L320 — `FakeMenuClient` shape confirmed
- [x] `Tests/GohMenuBarTests/GohMenuViewModelTests.swift` ~L419 — `LongLivedMenuClient` shape confirmed
- [x] `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift` ~L18 — `FakeMenuClient` shape confirmed
- [x] `Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift` ~L9 — `SpyMenuClient` shape confirmed

**AC ownership:** Tray surface (spec §4.7)

**Step 1 — Failing test** (extend `GohMenuViewModelTests.swift`)

**B4 FIX:** Do NOT invent `StubGohMenuClient(lsReply:)` or a free `makeViewModel(client:)` —
these don't exist. Instead: add a settable `lsReply: LsReply` property to the existing
`FakeMenuClient` in `GohMenuViewModelTests.swift` (which already has the viewmodel init
pattern in every test). The test uses the existing `GohMenuViewModel.init(client:)`.

```swift
// In GohMenuViewModelTests.swift — add `lsReply` property to FakeMenuClient:
// var lsReply: LsReply = LsReply(jobs: [], featureLevel: nil)
// func ls() async throws -> LsReply { lsReply }

@Test("GohMenuViewModel.checkDaemonSkew returns staleIdle for a nil featureLevel daemon")
func checkDaemonSkewReturnsStaleDaemon() async {
    let client = FakeMenuClient()
    client.lsReply = LsReply(jobs: [], featureLevel: nil)
    let model = GohMenuViewModel(client: client)
    await model.checkDaemonSkew()
    #expect(model.daemonSkew == .staleIdle)
}
```

**Step 2 — Run expecting failure**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohMenuViewModelTests
```

**Step 3 — Minimal implementation**

1. Add `func ls() async throws -> LsReply` to the `GohMenuClient` protocol in
   `Sources/GohMenuBar/GohMenuViewModel.swift`.

2. Implement in `LiveGohMenuClient` (`Sources/goh-menu/main.swift`) via the existing
   `sendOneShot` pattern (same as `add`, `pause`, etc. already use).

3. Add stub to ALL existing test doubles (required — build error without them):
   - `FakeMenuClient` in `GohMenuViewModelTests.swift`: add
     `var lsReply: LsReply = LsReply(jobs: [], featureLevel: nil)` and
     `func ls() async throws -> LsReply { lsReply }`.
   - `LongLivedMenuClient` in `GohMenuViewModelTests.swift`: add
     `func ls() async throws -> LsReply { LsReply(jobs: [], featureLevel: nil) }`.
   - `FakeMenuClient` in `AddDownloadViewModelTests.swift`: add
     `func ls() async throws -> LsReply { LsReply(jobs: [], featureLevel: nil) }`.
   - `SpyMenuClient` in `TrustWindowViewModelBackfillTests.swift`: add
     `func ls() async throws -> LsReply { LsReply(jobs: [], featureLevel: nil) }`.

4. In `GohMenuViewModel`, add:
   ```swift
   @Published public private(set) var daemonSkew: DaemonSkew?

   public func checkDaemonSkew() async {
       guard let reply = try? await client.ls() else { return }
       let activeCount = reply.jobs.filter { $0.state == .active }.count
       daemonSkew = DaemonSkewCheck.evaluate(
           reported: reply.featureLevel,
           expected: GohFeatureLevel.current,
           activeDownloadCount: activeCount)
   }
   ```

**Step 4 — Run expecting pass**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohMenuViewModelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AddDownloadViewModelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TrustWindowViewModelBackfillTests
```
All three suites must pass — the latter two verify the stubs compile.

**Step 5 — Commit**
```
git add Sources/GohMenuBar/GohMenuViewModel.swift Sources/goh-menu/main.swift \
        Tests/GohMenuBarTests/GohMenuViewModelTests.swift \
        Tests/GohMenuBarTests/AddDownloadViewModelTests.swift \
        Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift
git commit -m "feat(tray): add GohMenuClient.ls() + LiveGohMenuClient impl; update all conformers (B3)"
```

---

### Task 12 — Skew notice in `GohMenuModels` + `GohMenuPresenter`

**Files:**
- Modify: `Sources/GohMenuBar/GohMenuModels.swift`
- Modify: `Sources/GohMenuBar/GohMenuPresenter.swift`

**Pre-task reads checklist:**
- [x] `GohMenuModels.swift` L129–158 — `GohMenuState` struct fields confirmed
- [x] `GohMenuPresenter.swift` L1–201 — `state(health:snapshots:clipboardURL:ledgerOutcome:)` confirmed

**AC ownership:** Tray surface (spec §4.7 neutral notice)

**CORRECTNESS NOTE:** Skew notice is NOT a health failure. It is a neutral
informational field `daemonSkewNotice: String?` on `GohMenuState`.
The notice text: `"A newer background service is ready — it activates when downloads finish."` (spec §4.7).
An idle-skew situation shows a different notice: `"Background service updated — restarting..."` during
the heal, or an "Update background service" action button.

**Step 1 — Failing test** (extend `GohMenuPresenterTests.swift`)

```swift
@Test("presenter includes daemonSkewNotice when daemonSkew is staleBusy")
func presenterIncludesStaleBusyNotice() {
    let presenter = GohMenuPresenter()
    let state = presenter.state(
        health: .connected,
        snapshots: [],
        clipboardURL: nil,
        daemonSkew: .staleBusy)
    #expect(state.daemonSkewNotice != nil)
    #expect(state.daemonSkewNotice?.contains("downloads finish") == true)
}

@Test("presenter daemonSkewNotice is nil when current")
func presenterNilNoticeWhenCurrent() {
    let presenter = GohMenuPresenter()
    let state = presenter.state(
        health: .connected,
        snapshots: [],
        clipboardURL: nil,
        daemonSkew: .current)
    #expect(state.daemonSkewNotice == nil)
}
```

**Step 2 — Run expecting failure**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohMenuPresenterTests
```

**Step 3 — Minimal implementation**

Add `public var daemonSkewNotice: String?` to `GohMenuState`.
Add `daemonSkew: DaemonSkew? = nil` parameter to `GohMenuPresenter.state(...)`.
Set `daemonSkewNotice` based on skew value.

**Step 4 — Run expecting pass**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohMenuPresenterTests
```

**Step 5 — Commit**
```
git add Sources/GohMenuBar/GohMenuModels.swift Sources/GohMenuBar/GohMenuPresenter.swift \
        Tests/GohMenuBarTests/GohMenuPresenterTests.swift
git commit -m "feat(tray): add daemonSkewNotice to GohMenuState + presenter (AC tray)"
```

---

### Task 13 — Idle-gated restart action in `GohMenuViewModel` + `GohMenuView`

**B3 PROTOCOL-EXTENSION FAN-OUT WARNING (continued from Task 11):** If `func restartDaemon()
async throws` is also added to `GohMenuClient`, the same five conformers must be updated.
Consider whether `restartDaemon()` needs to be on the protocol at all — it can be a method
on `GohMenuViewModel` that calls a separately-injected `DaemonRestarting` (not via the client
protocol), keeping the protocol surface minimal. If it IS added to the protocol, update the
same five files listed in Task 11's conformer table with a no-op stub:
`func restartDaemon() async throws {}`.

**Files:**
- Modify: `Sources/GohMenuBar/GohMenuViewModel.swift`
- Modify: `Sources/GohMenuBar/GohMenuView.swift`
- (Conditional) Modify: `Sources/goh-menu/main.swift` — only if `restartDaemon` is on the protocol
- (Conditional) Modify: `Tests/GohMenuBarTests/GohMenuViewModelTests.swift`, `AddDownloadViewModelTests.swift`, `TrustWindowViewModelBackfillTests.swift` — same conformer fan-out as Task 11

**Pre-task reads checklist:**
- [x] `GohMenuView.swift` L1–60 — `body` layout sections confirmed
- [x] `GohMenuViewModel.swift` L126–163 — action methods (`pause`, `resume`, etc.) confirmed
- [x] `GohMenuViewModel.swift` L42 — `GohMenuViewModel.init(client:)` signature confirmed (to add `restarter:` param)

**AC ownership:** Tray surface (spec §4.7 idle-gated restart action)

**CORRECTNESS NOTE:** The restart action is idle-gated — shown only when
`daemonSkew` is `.staleIdle`. When `.staleBusy`, show the notice but not
the button (downloads are running). When `.current`, neither notice nor button.

**Step 1 — Failing test** (extend `GohMenuViewModelTests.swift`)

**B4 FIX:** Do NOT use `StubGohMenuClient(lsReply:)` or `makeViewModel(client:)` —
those don't exist. Use the existing `FakeMenuClient` (already extended with `lsReply`
in Task 11) and `GohMenuViewModel.init(client:)` directly.

```swift
@Test("restartDaemon is available only when daemonSkew is staleIdle")
func restartDaemonAvailableOnlyWhenStaleIdle() async {
    let client = FakeMenuClient()
    client.lsReply = LsReply(jobs: [], featureLevel: nil)  // nil featureLevel → staleIdle
    let model = GohMenuViewModel(client: client)
    await model.checkDaemonSkew()
    #expect(model.daemonSkew == .staleIdle)
    // The action should be reachable (no crash or precondition failure).
    // (Full integration tested via ▶-tier)
}
```

**Step 2 — Run expecting failure**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohMenuViewModelTests
```

**Step 3 — Minimal implementation**

Preferred approach: keep `restartDaemon()` OFF the protocol — inject `DaemonRestarting`
directly into `GohMenuViewModel.init` instead. This avoids forcing all five test doubles
to grow another method for an action that only the viewmodel needs.

```swift
// GohMenuViewModel.init gains an optional restarter:
public init(client: GohMenuClient, restarter: (any DaemonRestarting)? = nil)

// GohMenuViewModel.restartDaemon():
public func restartDaemon() async {
    guard let lsReply = try? await client.ls() else { return }
    let activeCount = lsReply.jobs.filter { $0.state == .active }.count
    guard activeCount == 0, let restarter else { return }
    try? restarter.kickstart()
    daemonSkew = nil  // optimistic reset; next checkDaemonSkew() confirms
}
```

In `GohMenuView`, below the `header` section, render a `Button("Restart background service")`
if `model.daemonSkew == .staleIdle`, or a subdued `Text(model.state.daemonSkewNotice ?? "")` if
`model.daemonSkew == .staleBusy`.

In `goh-menu/main.swift` (`LiveGohMenuClient` init), pass a live `LaunchctlDaemonRestarter`
to `GohMenuViewModel.init(client:restarter:)`.

**Step 4 — Run expecting pass**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GohMenuViewModelTests
```

**Step 5 — Commit**
```
git add Sources/GohMenuBar/GohMenuViewModel.swift Sources/GohMenuBar/GohMenuView.swift \
        Sources/goh-menu/main.swift Tests/GohMenuBarTests/GohMenuViewModelTests.swift
git commit -m "feat(tray): idle-gated restart action + skew notice in menu view (AC tray)"
```

---

## Summary

Three phases, 13 tasks, 3 new source files, 10 modified source files, 7 new
test/support files (plus extensions to 6 existing test files).

**Phase 1** (Tasks 1–4) builds the pure GohCore foundation: `GohFeatureLevel`,
`DaemonSkewCheck`, the `LsReply.featureLevel` additive-optional wire field, and
the daemon's reporting in `CommandDispatcher`. All four tasks are fully
unit-testable with no daemon running and no wire involved beyond JSON codec tests.

**Phase 2** (Tasks 5–10) surfaces the feature in the CLI: the `DaemonRestarting`
injectable protocol and its live `launchctl kickstart` impl (seam for AC4/AC7),
the `DaemonAutoHeal` shared polling loop scoped to verify --all / verify --quick /
doctor, the new `goh daemon restart [--force]` verb (AC3), the doctor skew finding
(AC6), and the end-to-end reconcile re-schedule assertions (AC8). Depends on Phase 1.

**Phase 3** (Tasks 11–13) surfaces skew in the tray: a one-shot `.ls` method on
`GohMenuClient`, a `daemonSkewNotice` field in `GohMenuState`/Presenter, and an
idle-gated "Restart background service" action in `GohMenuView`. Depends on
Phase 1 (wire field) and Phase 2 (`DaemonRestarting` protocol).
