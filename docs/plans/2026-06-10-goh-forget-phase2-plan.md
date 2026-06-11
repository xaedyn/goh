# goh forget — Phase 2 (Tray Forget Action) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.
> Steps use checkbox (`- [ ]`) syntax. TDD per task.

**Goal:** Add a "Forget" affordance to MISSING rows in the menu-bar Trust window so a user
can prune a deleted file's provenance entry from the GUI (AC5), via the `forgetProvenance`
command Phase 1 already shipped.

**Architecture:** "Preview-and-Confirm" (the approved approach). The tray gates the destructive
action on `displayStatus == .missing` and presents a `.confirmationDialog` (macOS HIG
destructive pattern) before sending. The send is best-effort from the UI's perspective —
errors are swallowed (never surfaced as a crash or error state), matching the existing
`try? await menuClient?.recordVerifiedProvenance(...)` idiom — then `loadOverview()` refreshes.
Daemon/CLI/wire are unchanged (Phase 1); this phase only adds the menu-bar client method, a
view-model action, and the SwiftUI affordance.

**Tech Stack:** Swift 6, MainActor-default GohMenuBar target, SwiftUI/AppKit menu-bar app,
Swift Testing, modern Swift XPC (protocolVersion 4, unchanged).

**Spec:** `docs/superpowers/specs/2026-06-10-goh-forget-design.md` (AC5).
**Contract:** `docs/superpowers/progress/2026-06-10-goh-forget-phase1.md`.

**Frozen (must NOT change):** protocolVersion 4; `ProvenanceRecord.currentVersion` 1;
`VerifyAllReport`; launchd plist; `Command.forgetProvenance` / `ForgetProvenanceRequest` /
`ForgetProvenanceReply` wire shapes (Phase 1, frozen — Phase 2 only consumes them).

---

## Acceptance Criteria → Task map

- **AC5** (tray Forget on MISSING rows; removes via daemon; row disappears on refresh;
  present-file rows get no one-click destructive Forget): primary in **Task 2** (view-model
  behavior, unit-tested) and **Task 3** (the SwiftUI affordance + gating). Task 1 is the
  enabling protocol method.

---

## File Map

| File | Create/Modify | Responsibility |
|------|---------------|----------------|
| `Sources/GohMenuBar/GohMenuViewModel.swift` | Modify | Add `forget(paths:)` to the `GohMenuClient` protocol |
| `Sources/goh-menu/main.swift` | Modify | `LiveGohMenuClient.forget` — real one-shot `.forgetProvenance` send |
| `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift` | Modify | No-op `forget` stub on `FakeMenuClient` |
| `Tests/GohMenuBarTests/GohMenuViewModelTests.swift` | Modify | No-op `forget` stubs on `FakeMenuClient` + `LongLivedMenuClient` |
| `Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift` | Modify | Recording `forget` on `SpyMenuClient` (`forgotPaths` + `forgetShouldThrow`) |
| `Sources/GohMenuBar/TrustWindowViewModel.swift` | Modify | `forgetRow(path:) async` — best-effort send + `loadOverview()` |
| `Sources/GohMenuBar/TrustWindowView.swift` | Modify | `.contextMenu` Forget on MISSING rows + `.confirmationDialog` confirm |
| `Tests/GohMenuBarTests/TrustWindowViewModelForgetTests.swift` | Create | Unit tests for `forgetRow` |

Tasks (4) > the 6-task phase-segmentation threshold is not exceeded; single phase.

---

## Task 1 — `GohMenuClient.forget(paths:)` protocol method + all 5 conformers

Adding the protocol method breaks all 5 conformers; they MUST be updated in the same commit so
the build is green and atomic.

**Files:**
- Modify: `Sources/GohMenuBar/GohMenuViewModel.swift`
- Modify: `Sources/goh-menu/main.swift`
- Modify: `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift`
- Modify: `Tests/GohMenuBarTests/GohMenuViewModelTests.swift`
- Modify: `Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift`

**Pre-task reads:**
- [ ] Read `Sources/GohMenuBar/GohMenuViewModel.swift` (the protocol, lines ~5-17)
- [ ] Read `Sources/goh-menu/main.swift` (`LiveGohMenuClient`, `sendOneShot`, the `remove`/`.rm` template, `Self.map`)
- [ ] Read each of the 5 conformers' current method set (AddDownloadViewModelTests, GohMenuViewModelTests ×2, TrustWindowViewModelBackfillTests)

- [ ] **Step 1.1: Write the failing test** (extend the Spy + assert it records). In `TrustWindowViewModelBackfillTests.swift`, add to `SpyMenuClient`:

```swift
// Spy state for forget (mirrors recordedBatches/shouldThrow)
var forgotPaths: [[String]] = []
var forgetShouldThrow = false

func forget(paths: [String]) async throws {
    if forgetShouldThrow { throw GohMenuError.daemonUnavailable("spy forced") }
    forgotPaths.append(paths)
}
```

Add a minimal test in that file (or the new forget test file) asserting the spy conforms and records — but the real behavioral test lands in Task 2. For Task 1, the **compile break is the red gate** (the protocol method makes the build fail until all 5 conformers implement it), per the Phase 1 precedent for compile-forced changes.

- [ ] **Step 1.2: Confirm red** — `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-tests -Xswiftc -warnings-as-errors 2>&1 | tail -20`. Expected: `type 'X' does not conform to protocol 'GohMenuClient'` / `does not implement 'forget(paths:)'` for the conformers, until all are added.

- [ ] **Step 1.3: Add the protocol method.** In `Sources/GohMenuBar/GohMenuViewModel.swift`, inside the `@MainActor public protocol GohMenuClient` body, after `ls()`:

```swift
/// Removes the given paths' provenance entries via the daemon (`forgetProvenance`).
/// Best-effort from the UI's perspective: callers swallow errors (the row simply
/// stays until a successful run), matching `recordVerifiedProvenance`.
func forget(paths: [String]) async throws
```

- [ ] **Step 1.4: Implement `LiveGohMenuClient.forget`** in `Sources/goh-menu/main.swift`, mirroring `remove(jobID:keepPartialFile:)` exactly:

```swift
func forget(paths: [String]) async throws {
    do {
        let _: ForgetProvenanceReply = try await Self.sendOneShot(
            .forgetProvenance(request: ForgetProvenanceRequest(paths: paths)),
            expecting: ForgetProvenanceReply.self,
            validationMode: validationMode)
    } catch {
        throw Self.map(error)
    }
}
```

(`ForgetProvenanceRequest`, `ForgetProvenanceReply`, `Command.forgetProvenance` are already in GohCore from Phase 1 — verify the import in main.swift already brings them in; it imports GohCore.)

- [ ] **Step 1.5: Add no-op stubs to the 3 plain fakes:**
  - `FakeMenuClient` in `AddDownloadViewModelTests.swift`: `func forget(paths: [String]) async throws {}`
  - `FakeMenuClient` in `GohMenuViewModelTests.swift`: `func forget(paths: [String]) async throws {}`
  - `LongLivedMenuClient` in `GohMenuViewModelTests.swift`: `func forget(paths: [String]) async throws {}`
  (The recording `SpyMenuClient` impl from Step 1.1 covers the 5th.)

- [ ] **Step 1.6: Confirm green** — `swift build -Xswiftc -warnings-as-errors` clean; `swift test 2>&1 | tail -3` full suite passes.

- [ ] **Step 1.7: Commit** — `feat(menubar): GohMenuClient.forget(paths:) + LiveGohMenuClient send + conformers`

---

## Task 2 — `TrustWindowViewModel.forgetRow(path:)` + unit tests

**Files:**
- Modify: `Sources/GohMenuBar/TrustWindowViewModel.swift`
- Create: `Tests/GohMenuBarTests/TrustWindowViewModelForgetTests.swift`

**Pre-task reads:**
- [ ] Read `Sources/GohMenuBar/TrustWindowViewModel.swift` (the `@MainActor` class, `menuClient`, `loadOverview()`, the best-effort `recordVerifiedProvenance` idiom)
- [ ] Read `Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift` (the `@MainActor @Suite` structure, `SpyMenuClient` from Task 1, `StubProvenanceReader`, how a VM is constructed + driven)

- [ ] **Step 2.1: Write the failing tests** in `Tests/GohMenuBarTests/TrustWindowViewModelForgetTests.swift` (Swift Testing, `@MainActor @Suite`). Use the Task-1 `SpyMenuClient` (with `forgotPaths`/`forgetShouldThrow`) and the existing `StubProvenanceReader`:

```swift
import Foundation
import Testing
@testable import GohMenuBar
import GohCore

@Suite("TrustWindowViewModel.forgetRow") @MainActor
struct TrustWindowViewModelForgetTests {

    @Test("AC5: forgetRow sends exactly the row's path to the client, verbatim")
    func forgetRowSendsPathVerbatim() async throws {
        // AC5: invoking Forget removes that entry via the daemon.
        let spy = SpyMenuClient()
        let reader = /* StubProvenanceReader producing one entry at "/tmp/gone.bin" */
        let vm = TrustWindowViewModel(reader: reader, provenanceStorePath: "/tmp/x.plist", client: spy)
        await vm.loadOverview()
        await vm.forgetRow(path: "/tmp/gone.bin")
        #expect(spy.forgotPaths == [["/tmp/gone.bin"]])   // verbatim, single path
    }

    @Test("AC5: a client error is swallowed — no crash, no error surfaced")
    func forgetRowSwallowsClientError() async throws {
        let spy = SpyMenuClient()
        spy.forgetShouldThrow = true
        let reader = /* same stub */
        let vm = TrustWindowViewModel(reader: reader, provenanceStorePath: "/tmp/x.plist", client: spy)
        await vm.loadOverview()
        await vm.forgetRow(path: "/tmp/gone.bin")   // must not throw
        #expect(spy.forgotPaths.isEmpty)            // threw before recording
        // runState must not have flipped to a failure/error state
    }

    @Test("forgetRow with a nil client is a no-op that still refreshes")
    func forgetRowNilClientNoOp() async throws {
        let reader = /* stub */
        let vm = TrustWindowViewModel(reader: reader, provenanceStorePath: "/tmp/x.plist", client: nil)
        await vm.loadOverview()
        await vm.forgetRow(path: "/tmp/gone.bin")   // no client → no send, no crash
    }
}
```

(Use the EXACT `StubProvenanceReader` / `ProvenanceReadOutcome` construction the existing tests use — read them first. If `SpyMenuClient` lives in `TrustWindowViewModelBackfillTests.swift` as `private`, either make it non-private/shared in a small test-support file or duplicate the minimal spy here; match the existing test-support convention.)

- [ ] **Step 2.2: Confirm red** — `swift test --filter TrustWindowViewModel.forgetRow` → fails (`forgetRow` undefined).

- [ ] **Step 2.3: Implement `forgetRow` + the `isForgettable` gate predicate** in `TrustWindowViewModel.swift` (the whole type is `@MainActor`, so no actor hop / no `WeakRef`/`Task.detached` needed — this is a user-initiated action, unlike the off-main verify run):

```swift
/// Whether a row's file is currently MISSING on disk (ENOENT), making its
/// provenance entry eligible for a one-click Forget. Keys off the fast-check
/// truth (`fastStatuses`), NOT the composite display status: a file that was
/// verified and later deleted carries `verifiedAt != nil`, so its `displayStatus`
/// is `.verified(at:)` even though its file is gone — gating on display status
/// would hide Forget on exactly that common case. `FastCheckStatus.missing` is
/// strictly ENOENT, so a present-but-unreadable file is NOT forgettable.
public func isForgettable(path: String) -> Bool {
    fastStatuses[path] == .missing
}

/// Removes the given path's provenance entry via the daemon, then refreshes the
/// overview so the row disappears. Best-effort: a send error is swallowed (never
/// surfaced as an error state), matching the `recordVerifiedProvenance` idiom.
public func forgetRow(path: String) async {
    try? await menuClient?.forget(paths: [path])
    await loadOverview()
}
```

The `isForgettable` test (add to Step 2.1) MUST include the regression case the plan review caught — a verified-then-deleted entry (its `verifiedAt` is non-nil) is still forgettable because `fastStatuses[path] == .missing`:

```swift
@Test("AC5 gate: a verified-then-deleted entry IS forgettable (fast-check missing, not displayStatus)")
func verifiedThenDeletedIsForgettable() async throws {
    // entry has verifiedAt != nil; inject a probe returning .notFound so the
    // fast-check is .missing even though displayStatus would be .verified(at:).
    let reader = /* StubProvenanceReader: one entry at "/tmp/gone.bin", verifiedAt set */
    let probe = /* stub FileStatProbing returning .notFound */
    let vm = TrustWindowViewModel(reader: reader, provenanceStorePath: "/tmp/x.plist", probe: probe, client: SpyMenuClient())
    await vm.loadOverview()
    #expect(vm.isForgettable(path: "/tmp/gone.bin"))   // gate keys off fast-check, not verifiedAt
}

@Test("AC5 gate: a present file is NOT forgettable")
func presentFileNotForgettable() async throws {
    let reader = /* StubProvenanceReader: one entry at "/tmp/here.bin" */
    let probe = /* stub returning .stat(...) for a present file */
    let vm = TrustWindowViewModel(reader: reader, provenanceStorePath: "/tmp/x.plist", probe: probe, client: SpyMenuClient())
    await vm.loadOverview()
    #expect(!vm.isForgettable(path: "/tmp/here.bin"))
}
```

Read the existing tests for the exact `StubProvenanceReader` / `ProvenanceReadOutcome` construction AND the `FileStatProbing` stub pattern (a probe returning `.notFound` / `.stat(...)`); inject the probe via the `TrustWindowViewModel(probe:)` init parameter. If no menu-bar probe stub exists, define a minimal one in the test file.

> **CRITICAL test precondition (from plan review):** `FastCheckRunner.check` returns
> `.notBaselined` — NOT `.missing` — when ANY of the five baseline fields is nil, *before* it
> ever consults the probe. So the `verifiedThenDeletedIsForgettable` entry MUST set all five
> `recordedStatSize` / `recordedMtimeSeconds` / `recordedMtimeNanoseconds` / `recordedInode` /
> `recordedDevice` fields (non-nil) **and** `verifiedAt`, or the test will get `.notBaselined`
> → `isForgettable == false` and fail. Build the `ProvenanceEntry` with a full baseline (mirror
> how `TrustWindowViewModelBackfillTests` / `FastCheckRunnerTests` construct a baselined entry).

- [ ] **Step 2.4: Confirm green** — `swift test --filter TrustWindowViewModel.forgetRow` passes; full suite `swift test 2>&1 | tail -3` green; build `-warnings-as-errors` clean.

- [ ] **Step 2.5: Commit** — `feat(menubar): TrustWindowViewModel.forgetRow — best-effort forget + refresh (AC5)`

---

## Task 3 — Trust window Forget affordance (MISSING rows + confirm)

SwiftUI view changes — not unit-testable without ViewInspector (the project has none), so the
gate is a clean `-warnings-as-errors` build plus the AC5 view-model coverage from Task 2. Keep
the view logic thin (it delegates to `forgetRow`); all behavior lives in the tested view model.

**Files:**
- Modify: `Sources/GohMenuBar/TrustWindowView.swift`

> **Spec-deviation note (record in the PR):** spec §6 describes a "preview/confirm **sheet**";
> this plan ships a visible Forget button + a `.confirmationDialog` (the macOS-HIG destructive-
> confirm control). That's a deliberate, more-idiomatic equivalent — note it in the PR per the
> working-style "judgment, recorded with a note" rule.

**Pre-task reads:**
- [ ] Read `Sources/GohMenuBar/TrustWindowView.swift` in full (the `ForEach(viewModel.rows, id: \.displayPath)`, the `TrustEntryRowView` private struct + its params, how `displayStatus` is computed at the call site, the absence of existing sheets/menus)
- [ ] Read `Sources/GohMenuBar/GohTrustModels.swift` (`TrustDisplayStatus` cases — for the row's existing status display, not the gate)

- [ ] **Step 3.1: Add a confirm-target `@State` and the `.confirmationDialog`** at the `TrustWindowView` level. Add `@State private var confirmForgetPath: String?` to `TrustWindowView`. Attach to the `ScrollView` (or outermost container):

```swift
.confirmationDialog(
    "Forget this download's provenance?",
    isPresented: Binding(
        get: { confirmForgetPath != nil },
        set: { if !$0 { confirmForgetPath = nil } }),
    titleVisibility: .visible,
    presenting: confirmForgetPath
) { path in
    Button("Forget", role: .destructive) {
        confirmForgetPath = nil
        Task { await viewModel.forgetRow(path: path) }
    }
    Button("Cancel", role: .cancel) { confirmForgetPath = nil }
} message: { path in
    Text("Removes the saved download record for \(URL(fileURLWithPath: path).lastPathComponent). The file is already missing; this does not delete anything from disk.")
}
```

- [ ] **Step 3.2: Add a visible Forget affordance to MISSING rows.** Gate on the tested view-model
predicate `viewModel.isForgettable(path: row.displayPath)` — NOT on `displayStatus` (a verified-
then-deleted file has `displayStatus == .verified(at:)` but is still MISSING on disk; gating on
display status would hide Forget on the exact case this feature exists for). Render a visible,
discoverable button on forgettable rows (a hidden `.contextMenu` is right-click-only); it sets the
parent `@State` to drive the confirm dialog:

```swift
// In the ForEach body, alongside TrustEntryRowView (pass the predicate result in,
// or compute at the call site so the row view stays a pure display struct):
if viewModel.isForgettable(path: row.displayPath) {
    Button {
        confirmForgetPath = row.displayPath     // VERBATIM canonical destinationPath
    } label: {
        Label("Forget", systemImage: "trash")
    }
    .buttonStyle(.borderless)
    .help("Remove this missing file's saved provenance record")
}
```

Pass `row.displayPath` VERBATIM (it is already the canonical `destinationPath`; do NOT
re-canonicalize — matches the `--missing --confirm` CLI contract). Because the gate is
`fastStatuses[path] == .missing` and `FastCheckStatus.missing` is strictly ENOENT, present files
and present-but-unreadable files expose NO Forget button (satisfies AC5's "present-file rows get
no one-click destructive Forget"). The button's visibility logic is the same predicate unit-tested
in Task 2, so the gate is covered by tests, not build-only.

- [ ] **Step 3.3: Build** — `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -warnings-as-errors 2>&1 | tail` clean; `swift test 2>&1 | tail -3` full suite still green (no regressions).

- [ ] **Step 3.4: Commit** — `feat(menubar): Forget affordance on MISSING Trust rows with destructive confirm (AC5)`

---

## Task 4 — Phase 2 finalize: integration verify + final review + PR

- [ ] **Step 4.1: Integration verify** — clean build `swift build -Xswiftc -warnings-as-errors` + full `swift test` green; confirm protocolVersion 4 / ProvenanceRecord v1 untouched (`git diff main -- Sources/GohCore` should show NO changes — Phase 2 touches only GohMenuBar + goh-menu + tests).
- [ ] **Step 4.2: Final review** — dispatch `stack-aware-code-review` (Opus) over the whole Phase-2 diff (BASE = current main, HEAD = branch tip). Fix any block issues, re-verify.
- [ ] **Step 4.3: Update** `STATE.md` (Phase 2 complete) and flip the Phase-1 artifact's "What Phase 2 needs" to done (or add a short Phase-2-complete note).
- [ ] **Step 4.4: Push + PR** — `git push -u origin feat/goh-forget-tray`; open the PR describing the tray Forget affordance, AC5 coverage, the best-effort/swallow contract, and that no daemon/wire change is included.

---

## Test plan
- [ ] `swift build -Xswiftc -warnings-as-errors` green (incl. tests).
- [ ] `TrustWindowViewModelForgetTests` — `isForgettable` gate (MISSING→true incl. the **verified-then-deleted** regression case; present file→false; present-but-unreadable→false); `forgetRow` sends the path verbatim; client error swallowed (no crash/error state); nil-client no-op.
- [ ] Full suite green (no regression in the existing TrustWindowViewModel / GohMenuViewModel / AddDownloadViewModel suites after the protocol method + conformer additions).
- [ ] `git diff main -- Sources/GohCore` empty — no daemon/wire/store change in Phase 2.
