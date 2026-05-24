import Foundation
import Synchronization
import Testing

import GohCore

@Suite("Sleep assertion controller")
struct SleepAssertionControllerTests {

    @Test("overlapping downloads share one assertion until the last finishes")
    func overlappingDownloadsShareOneAssertion() {
        let createdNames = Mutex<[String]>([])
        let releasedIDs = Mutex<[UInt32]>([])
        let controller = SleepAssertionController(
            backend: PowerAssertionBackend(
                create: { name in
                    createdNames.withLock { $0.append(name) }
                    return 99
                },
                release: { id in
                    releasedIDs.withLock { $0.append(id) }
                }))

        controller.downloadStarted()
        controller.downloadStarted()
        controller.downloadFinished()
        #expect(createdNames.withLock(\.count) == 1)
        #expect(releasedIDs.withLock { $0 } == [])

        controller.downloadFinished()
        controller.downloadFinished()

        #expect(createdNames.withLock { $0 } == ["goh active download"])
        #expect(releasedIDs.withLock { $0 } == [99])
    }

    @Test("a failed assertion creation is retried by the next active download")
    func failedCreateIsRetried() {
        let attempts = Mutex(0)
        let releasedIDs = Mutex<[UInt32]>([])
        let controller = SleepAssertionController(
            backend: PowerAssertionBackend(
                create: { _ in
                    attempts.withLock {
                        $0 += 1
                        return $0 == 1 ? nil : 7
                    }
                },
                release: { id in
                    releasedIDs.withLock { $0.append(id) }
                }))

        controller.downloadStarted()
        controller.downloadStarted()
        controller.downloadFinished()
        #expect(releasedIDs.withLock { $0 } == [])

        controller.downloadFinished()

        #expect(attempts.withLock { $0 } == 2)
        #expect(releasedIDs.withLock { $0 } == [7])
    }
}
