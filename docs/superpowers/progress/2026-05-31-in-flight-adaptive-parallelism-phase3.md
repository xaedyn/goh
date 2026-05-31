# Phase 3 Progress Artifact — In-Flight Adaptive Parallelism

**Status:** NOT STARTED  
**Prerequisite:** Phase 2 artifact complete and all P2 tests passing.  
**To be completed by:** the implementing agent at the end of Phase 3.

---

## Template (fill in after P3 tasks are complete)

### WHAT WAS BUILT

- Task 10: `SelectionReason.warmStart` + `ObservationRequest` struct + gate migration
- Task 11: `setActualConnectionCount` peak-max semantics (cap=16, not requestedN)
- Task 12: Governor wired to control loop; `completedDownloadHandler` gains `GovernorOutcome`
- Task 13: Warm-start trace annotation in `CommandDispatcher`
- Task 14: DESIGN.md §Persistence + §Observability reconciliation
- Task 15: `recordGovernorDecision` in `EngineDiagnostics`
- Task 16: Kill-switch verification + full suite run

### CURRENT STATE OF MODIFIED FILES

| File | Status |
|------|--------|
| `Sources/GohCore/Scheduling/BanditSelector.swift` | `SelectionReason.warmStart` added |
| `Sources/GohCore/Scheduling/HostProfileStore.swift` | `ObservationRequest` + `shouldRecordObservation(_:)` + `recordObservationIfEligible` |
| `Sources/GohCore/Engine/DownloadEngine.swift` | Governor wired; handler arity widened |
| `Sources/GohCore/Model/JobStore.swift` | `setActualConnectionCount` cap = 16 |
| `Sources/gohd/main.swift` | Handler closure updated; gate uses `ObservationRequest` |
| `Sources/GohCore/Engine/EngineDiagnostics.swift` | `recordGovernorDecision` added |
| `DESIGN.md` | §Persistence/§Adaptive host scheduling + §Observability updated |

### SM4 VERIFICATION

SM4 (AC4) — governor-converged N feeds back into bandit; warm-start on next download:  
- [ ] `ObservationRequest` with `effectiveN=8, stabilized=true` is recorded  
- [ ] Cold download on same host exploits N=8 arm  
- [ ] `GOH_ENGINE_TRACE=1` shows `reason=warmStart` at admission  

### INVARIANT VERIFICATION

- [ ] `protocolVersion` is still 3
- [ ] `host-scheduling.plist` stays v1 (golden fixture test passes)
- [ ] `JobSummary` wire shape unchanged (`actualConnectionCount` meaning changed in docs only)
- [ ] `completedDownloadHandler` arity changed from 3 to 4 params — NOT a wire change (internal)

### CONTRACTS ESTABLISHED

- `ObservationRequest` struct replaces 6-parameter `shouldRecordObservation` call
- `GovernorOutcome.effectiveN` is the candidate-aligned N fed to `recordObservation`
- `SelectionReason.warmStart` is a trace annotation only (not a new `selectN` return value)

### OPEN ITEMS FOR P4

_(fill in at end of P3)_

### FULL TEST SUITE STATUS

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
# Result: _(fill in)_
```
