---
date: 2026-06-10
feature: goh-forget
type: phase-artifact
phase: 1
status: planned
---

# Phase 1 Complete — Interface Contract for Phase 2 (Tray)

This document records what Phase 1 ships so Phase 2 implementers can build the
tray affordance without reading the full plan.

---

## What Phase 1 ships (daemon + CLI, independently deployable)

### 1. Wire command

`Command.forgetProvenance(request: ForgetProvenanceRequest)` — new case on the
existing `protocolVersion = 4` XPC channel. `ForgetProvenanceRequest` carries
`paths: [String]`. The daemon replies with `ForgetProvenanceReply(forgotCount: Int)`.

```swift
// Sources/GohCore/Model/Command.swift
case forgetProvenance(request: ForgetProvenanceRequest)

public struct ForgetProvenanceRequest: Codable, Sendable, Equatable {
    public var paths: [String]
    public init(paths: [String]) { self.paths = paths }
}

// Sources/GohCore/Model/CommandReply.swift
public struct ForgetProvenanceReply: Codable, Sendable, Equatable {
    public var forgotCount: Int
    public init(forgotCount: Int) { self.forgotCount = forgotCount }
}

// Sources/GohCore/Model/CommandOutcome.swift
case forgotProvenance(ForgetProvenanceReply)
```

`protocolVersion` stays 4 (additive enum case). `ProvenanceRecord.currentVersion`
stays 1 (runtime entry mutation only).

### 2. featureLevel

`GohFeatureLevel.current = 2` (was 1). featureLevel 2 means the daemon honors
`forgetProvenance`. Phase 2 MAY read `LsReply.featureLevel` to decide whether to
show the Forget affordance, but the MINIMUM required guard is: send the command
only when `featureLevel >= 2`.

### 3. Store method

`ProvenanceStore.forget(paths:) throws -> Int` — removes matching entries and
atomically rewrites the ledger. Returns the count removed. Throws
`ProvenanceStoreError` on write failure (the dispatcher wraps it as
`GohError(.destinationUnwritable,...)`). Never touches files at the requested paths.

---

## What Phase 2 needs to implement

### `GohMenuClient.forget(paths:)` — new protocol method

Add to `Sources/GohMenuBar/GohMenuViewModel.swift`:

```swift
@MainActor
public protocol GohMenuClient: AnyObject {
    // ... existing methods ...

    /// Removes the given paths' provenance entries via the daemon. Best-effort
    /// from the UI's perspective (errors surface as render(health:.failed)).
    func forget(paths: [String]) async throws
}
```

This breaks all 5 conformers — each must implement it before Phase 2 compiles:

1. **`LiveGohMenuClient`** — `Sources/goh-menu/main.swift` (production; sends `.forgetProvenance`):

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

2. **`FakeMenuClient`** — `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift`
   (line numbers illustrative; the compile break is the guard):

```swift
func forget(paths: [String]) async throws { /* no-op stub */ }
```

3. **`FakeMenuClient`** — `Tests/GohMenuBarTests/GohMenuViewModelTests.swift`:

```swift
func forget(paths: [String]) async throws { /* no-op stub */ }
```

4. **`LongLivedMenuClient`** — `Tests/GohMenuBarTests/GohMenuViewModelTests.swift`:

```swift
func forget(paths: [String]) async throws { /* no-op stub */ }
```

5. **`SpyMenuClient`** — `Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift`:

```swift
var forgotPaths: [[String]] = []
func forget(paths: [String]) async throws { forgotPaths.append(paths) }
```

### `TrustWindowViewModel.forget(paths:)` — new method

```swift
/// Removes the given paths' provenance entries via the daemon and refreshes
/// the trust overview. Best-effort: errors are swallowed (not surfaced to UI),
/// matching the existing `try? vm.menuClient?.recordVerifiedProvenance(...)` pattern.
@MainActor
public func forget(paths: [String]) async {
    try? await menuClient?.forget(paths: paths)
    await loadOverview()
}
```

### Trust window SwiftUI affordance

- MISSING-row rows in `TrustWindowView` gain a "Forget" button/menu item.
- Tapping it presents a preview/confirm sheet (macOS HIG destructive-action pattern):
  - Sheet lists the path and annotation.
  - Cancel / Forget buttons.
  - On "Forget": calls `viewModel.forget(paths: [entry.destinationPath])`.
- Present-file rows also go through the same sheet — no one-click destructive action.
- After confirm, `loadOverview()` is called (already done inside `TrustWindowViewModel.forget`).

### `ForgetProvenanceReply` decoding in `LiveGohMenuClient`

`ForgetProvenanceReply` conforms to `Codable`. Decode via `sendOneShot` expecting
`ForgetProvenanceReply.self` (same pattern as `RmReply`). The reply carries
`forgotCount: Int`. Phase 2 may surface a warning when `forgotCount < paths.count`
but must not propagate errors to the UI (best-effort contract, matches `recordVerifiedProvenance`).

### How `LiveGohMenuClient` sends `forgetProvenance`

```swift
// Pattern: identical to how remove(jobID:keepPartialFile:) sends .rm
// Sources/goh-menu/main.swift — add to LiveGohMenuClient:
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

`sendOneShot` creates a new `GohXPCClient`, wraps it in `GohCommandClient`, calls
`.send(_:expecting:)`, maps errors via `GohMenuErrorMapper.map`. The send runs on
a detached task (existing pattern). `ForgetProvenanceReply` must be `Codable &
Sendable` (it is, from Phase 1).

---

## Dependency constraint for Phase 2

Phase 2 must NOT be merged until Phase 1 is shipped and the daemon on users'
machines is `featureLevel >= 2`. In CI the constraint is enforced by the
`featureLevel >= 2` gate inside any Phase 2 code that calls `forget`.

---

## Phase 2 files that need changes

| File | Change |
|------|--------|
| `Sources/GohMenuBar/GohMenuViewModel.swift` | Add `func forget(paths: [String]) async throws` to `GohMenuClient` protocol |
| `Sources/goh-menu/main.swift` | Add `forget` to `LiveGohMenuClient` |
| `Tests/GohMenuBarTests/AddDownloadViewModelTests.swift` | Stub `forget` on `FakeMenuClient` |
| `Tests/GohMenuBarTests/GohMenuViewModelTests.swift` | Stub `forget` on both `FakeMenuClient` and `LongLivedMenuClient` |
| `Tests/GohMenuBarTests/TrustWindowViewModelBackfillTests.swift` | Spy `forget` on `SpyMenuClient` |
| `Sources/GohMenuBar/TrustWindowViewModel.swift` | Add `forget(paths:)` method |
| `Sources/GohMenuBar/TrustWindowView.swift` (or wherever the Trust view lives) | Forget affordance on MISSING rows + preview/confirm sheet |
