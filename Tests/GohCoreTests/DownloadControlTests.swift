import Foundation
import Synchronization
import Testing

@testable import GohCore

@Suite("Download control")
struct DownloadControlTests {

    @Test("stop requests stay visible until the job unregisters")
    func stopRequestStaysVisibleUntilUnregister() async throws {
        let control = DownloadControl()
        control.register(jobID: 1)

        let firstWaiter = Task {
            control.requestStop(jobID: 1, reason: .remove(keepPartialFile: false))
        }
        let secondWaiter = Task {
            control.requestStop(jobID: 1, reason: .remove(keepPartialFile: false))
        }

        let firstStop = try await nextPendingStop(for: 1, in: control)
        #expect(firstStop.reason == .remove(keepPartialFile: false))
        #expect(await firstWaiter.value == .stopped)
        #expect(await secondWaiter.value == .stopped)

        let secondStop = try await nextPendingStop(for: 1, in: control)
        #expect(secondStop.reason == .remove(keepPartialFile: false))

        control.unregister(jobID: 1)
        do {
            try control.stopIfRequested(jobID: 1)
        } catch {
            Issue.record("stop should be cleared once the job unregisters")
        }
    }

    private func nextPendingStop(
        for jobID: UInt64, in control: DownloadControl
    ) async throws -> DownloadControlStop {
        for _ in 0..<100 {
            do {
                try control.stopIfRequested(jobID: jobID)
            } catch let stop as DownloadControlStop {
                return stop
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("stop request was not observed by the engine")
        throw GohError(code: .cancelled, message: "stop request was not observed")
    }
}
