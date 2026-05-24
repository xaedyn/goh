import Foundation
import IOKit.pwr_mgt
import Synchronization

public struct PowerAssertionBackend: Sendable {
    private let createAssertion: @Sendable (String) -> IOPMAssertionID?
    private let releaseAssertion: @Sendable (IOPMAssertionID) -> Void

    public init(
        create: @escaping @Sendable (String) -> IOPMAssertionID?,
        release: @escaping @Sendable (IOPMAssertionID) -> Void
    ) {
        self.createAssertion = create
        self.releaseAssertion = release
    }

    public static let macOS = PowerAssertionBackend(
        create: { name in
            var assertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                name as CFString,
                &assertionID)
            guard result == kIOReturnSuccess else { return nil }
            return assertionID
        },
        release: { assertionID in
            _ = IOPMAssertionRelease(assertionID)
        })

    func create(name: String) -> IOPMAssertionID? {
        createAssertion(name)
    }

    func release(id: IOPMAssertionID) {
        releaseAssertion(id)
    }
}

public final class SleepAssertionController: Sendable {
    private struct State {
        var activeDownloads = 0
        var assertionID: IOPMAssertionID?
    }

    private let name: String
    private let backend: PowerAssertionBackend
    private let state = Mutex(State())

    public init(
        name: String = "goh active download",
        backend: PowerAssertionBackend = .macOS
    ) {
        self.name = name
        self.backend = backend
    }

    public func downloadStarted() {
        state.withLock { state in
            state.activeDownloads += 1
            if state.assertionID == nil {
                state.assertionID = backend.create(name: name)
            }
        }
    }

    public func downloadFinished() {
        state.withLock { state in
            guard state.activeDownloads > 0 else { return }
            state.activeDownloads -= 1
            guard state.activeDownloads == 0, let assertionID = state.assertionID else {
                return
            }
            state.assertionID = nil
            backend.release(id: assertionID)
        }
    }
}
