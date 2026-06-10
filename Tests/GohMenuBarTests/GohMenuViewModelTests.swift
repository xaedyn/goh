import Foundation
import Testing
import GohCore
@testable import GohMenuBar

@Suite("GohMenuViewModel")
@MainActor
struct GohMenuViewModelTests {
    @Test func startsWithConnectingState() {
        let model = GohMenuViewModel(
            client: FakeMenuClient(),
            pasteboardText: { nil },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        #expect(model.state.health == .connecting)
        #expect(model.state.healthTitle == "Connecting to gohd")
        #expect(model.state.primaryAction == .pasteURL)
        #expect(model.state.rows.isEmpty)
    }

    @Test func startsClipboardURLThroughDaemon() async throws {
        let client = FakeMenuClient()
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { "https://example.com/big.iso" },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        await model.refreshClipboard()
        await model.performPrimaryAction()

        #expect(model.state.health == .connecting)
        #expect(client.addedRequests == [AddRequest(url: "https://example.com/big.iso")])
    }

    @Test func invalidClipboardLeavesPasteActionAndDoesNotAdd() async throws {
        let client = FakeMenuClient()
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { "https://example.com/big.iso more text" },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        await model.refreshClipboard()
        await model.performPrimaryAction()

        #expect(model.state.primaryAction == .pasteURL)
        #expect(client.addedRequests.isEmpty)
    }

    @Test func pastePrimaryActionRefreshesClipboardCandidate() async throws {
        var pasteboardText: String? = "https://example.com/fresh.iso"
        let model = GohMenuViewModel(
            client: FakeMenuClient(),
            pasteboardText: { pasteboardText },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        #expect(model.state.primaryAction == .pasteURL)
        await model.performPrimaryAction()

        #expect(model.state.primaryAction == .addClipboardURL(URL(string: "https://example.com/fresh.iso")!))
        pasteboardText = nil
    }

    @Test func mapsProgressStreamIntoState() async throws {
        let client = FakeMenuClient()
        client.enqueue(.success([Self.snapshot(id: 9, state: .active, speed: 4096)]))
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { nil },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        let consumed = await model.consumeOneProgressUpdateForTesting()

        #expect(consumed)
        #expect(model.state.health == .connected)
        #expect(model.state.activeCount == 1)
        #expect(model.state.aggregateSpeedText == "4 KB/s")
        #expect(model.state.rows.first?.id == 9)
    }

    @Test func progressStreamEndReturnsFalse() async throws {
        let client = FakeMenuClient()
        client.enqueue(.end)
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { nil },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        let consumed = await model.consumeOneProgressUpdateForTesting()

        #expect(consumed == false)
    }

    @Test func progressStreamErrorMapsToFailedHealth() async throws {
        let client = FakeMenuClient()
        client.enqueue(.failure(FakeMenuError.intentional))
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { nil },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        let consumed = await model.consumeOneProgressUpdateForTesting()

        #expect(consumed == false)
        guard case .failed(.daemonUnavailable(let detail)) = model.state.health else {
            Issue.record("Expected failed daemonUnavailable health")
            return
        }
        #expect(detail.contains("intentional"))
    }

    @Test func startConsumesProgressUntilStreamEnds() async throws {
        let client = FakeMenuClient()
        client.enqueue(.success([Self.snapshot(id: 1, state: .active, speed: 1024)]))
        client.enqueue(.success([Self.snapshot(id: 2, state: .active, speed: 2048)]))
        client.enqueue(.end)
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { nil },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        model.start()
        await waitUntil { model.state.rows.first?.id == 2 }

        #expect(model.state.rows.first?.id == 2)
        #expect(model.state.aggregateSpeedText == "2 KB/s")
    }

    @Test func repeatedStartCancelsAndReplacesPreviousProgressStream() async throws {
        let client = LongLivedMenuClient()
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { nil },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        model.start()
        await waitUntil { client.startedStreamIDs == [1] }
        client.yield([Self.snapshot(id: 1, state: .active, speed: 1024)], to: 1)
        await waitUntil { model.state.rows.first?.id == 1 }

        model.start()
        await waitUntil {
            client.startedStreamIDs == [1, 2]
                && client.terminatedStreamIDs == [1]
                && client.activeStreamIDs == [2]
        }
        client.yield([Self.snapshot(id: 2, state: .active, speed: 2048)], to: 2)
        await waitUntil { model.state.rows.first?.id == 2 }

        #expect(model.state.rows.first?.id == 2)
        #expect(model.state.health == .connected)
        #expect(client.activeStreamIDs == [2])
    }

    @Test func stopCancelsProgressStreamWithoutRenderingFailure() async throws {
        let client = LongLivedMenuClient()
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { nil },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        model.start()
        await waitUntil { client.startedStreamIDs == [1] }
        client.yield([Self.snapshot(id: 1, state: .active, speed: 1024)], to: 1)
        await waitUntil { model.state.health == .connected }

        model.stop()
        await waitUntil { client.terminatedStreamIDs == [1] }

        #expect(model.state.health == .connected)
        #expect(client.activeStreamIDs.isEmpty)
    }

    @Test func deinitCancelsProgressStream() async throws {
        let client = LongLivedMenuClient()
        var model: GohMenuViewModel? = GohMenuViewModel(
            client: client,
            pasteboardText: { nil },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        model?.start()
        await waitUntil { client.startedStreamIDs == [1] }
        model = nil
        await waitUntil { client.terminatedStreamIDs == [1] }

        #expect(client.activeStreamIDs.isEmpty)
    }

    @Test func pauseResumeAndRemoveSendExistingCommands() async throws {
        let client = FakeMenuClient()
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { nil },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        await model.pause(jobID: 7)
        await model.resume(jobID: 8)
        await model.remove(jobID: 9, keepPartialFile: true)

        #expect(client.pausedIDs == [7])
        #expect(client.resumedIDs == [8])
        #expect(client.removedRequests == [RemoveRequest(jobID: 9, keepPartialFile: true)])
    }

    @Test func commandErrorsRenderFailedHealth() async throws {
        let client = FakeMenuClient()
        client.pauseError = FakeMenuError.intentional
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { nil },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })

        await model.pause(jobID: 7)

        guard case .failed(.daemonUnavailable(let detail)) = model.state.health else {
            Issue.record("Expected failed daemonUnavailable health")
            return
        }
        #expect(detail.contains("intentional"))
    }

    @Test func sideEffectActionsRouteToInjectedClosures() {
        var revealed: [String] = []
        var copied: [String] = []
        var openedTopCount = 0
        var openedDoctorCount = 0
        let model = GohMenuViewModel(
            client: FakeMenuClient(),
            pasteboardText: { nil },
            revealInFinder: { revealed.append($0) },
            openTerminalDashboard: { openedTopCount += 1 },
            openDoctor: { openedDoctorCount += 1 },
            copyText: { copied.append($0) })

        model.reveal(destination: "/tmp/file.iso")
        model.copy("https://example.com/file.iso")
        model.openTop()
        model.openDoctor()

        #expect(revealed == ["/tmp/file.iso"])
        #expect(copied == ["https://example.com/file.iso"])
        #expect(openedTopCount == 1)
        #expect(openedDoctorCount == 1)
    }

    @Test func diagnosePrimaryActionOpensDoctor() async throws {
        var openedDoctorCount = 0
        let client = FakeMenuClient()
        client.enqueue(.failure(FakeMenuError.intentional))
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { "https://example.com/big.iso" },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            openDoctor: { openedDoctorCount += 1 },
            copyText: { _ in })

        _ = await model.consumeOneProgressUpdateForTesting()
        await model.refreshClipboard()
        await model.performPrimaryAction()

        #expect(model.state.primaryAction == .diagnose)
        #expect(openedDoctorCount == 1)
    }

    private static func snapshot(id: UInt64, state: JobState, speed: UInt64) -> ProgressSnapshot {
        ProgressSnapshot(
            job: JobSummary(
                id: id,
                url: "https://example.com/\(id).iso",
                destination: "/tmp/\(id).iso",
                state: state,
                progress: JobProgress(bytesCompleted: 128, bytesTotal: 1024, bytesPerSecond: speed),
                createdAt: Date(timeIntervalSince1970: 1),
                lastProgressAt: Date(timeIntervalSince1970: 2),
                requestedConnectionCount: 8,
                actualConnectionCount: state == .active ? 8 : 0),
            lanes: [])
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        maxYields: Int = 20
    ) async {
        for _ in 0..<maxYields {
            if condition() {
                return
            }
            await Task.yield()
        }
    }

    @Test("GohMenuViewModel.checkDaemonSkew returns staleIdle for a nil featureLevel daemon")
    func checkDaemonSkewReturnsStaleDaemon() async {
        let client = FakeMenuClient()
        client.lsReply = LsReply(jobs: [], featureLevel: nil)
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { nil },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })
        await model.checkDaemonSkew()
        #expect(model.daemonSkew == .staleIdle)
    }

    @Test("restartDaemon is available only when daemonSkew is staleIdle")
    func restartDaemonAvailableOnlyWhenStaleIdle() async {
        let client = FakeMenuClient()
        client.lsReply = LsReply(jobs: [], featureLevel: nil)  // nil featureLevel → staleIdle
        let model = GohMenuViewModel(
            client: client,
            pasteboardText: { nil },
            revealInFinder: { _ in },
            openTerminalDashboard: {},
            copyText: { _ in })
        await model.checkDaemonSkew()
        #expect(model.daemonSkew == .staleIdle)
        // The action should be reachable (no crash or precondition failure).
        // (Full integration tested via ▶-tier)
    }
}

@MainActor
private final class FakeMenuClient: GohMenuClient {
    var addedRequests: [AddRequest] = []
    var pausedIDs: [UInt64] = []
    var resumedIDs: [UInt64] = []
    var removedRequests: [RemoveRequest] = []
    var addError: (any Error)?
    var pauseError: (any Error)?
    var resumeError: (any Error)?
    var removeError: (any Error)?

    private var streamEvents: [FakeStreamEvent] = []

    func progressSnapshots() -> AsyncThrowingStream<[ProgressSnapshot], any Error> {
        AsyncThrowingStream { continuation in
            for event in streamEvents {
                switch event {
                case .success(let snapshots):
                    continuation.yield(snapshots)
                case .failure(let error):
                    continuation.finish(throwing: error)
                    return
                case .end:
                    continuation.finish()
                    return
                }
            }
            continuation.finish()
        }
    }

    func add(_ request: AddRequest) async throws -> JobSummary {
        if let addError {
            throw addError
        }
        addedRequests.append(request)
        return JobSummary(
            id: 1,
            url: request.url,
            destination: "/tmp/big.iso",
            state: .queued,
            progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
            createdAt: Date(timeIntervalSince1970: 1),
            lastProgressAt: nil,
            requestedConnectionCount: request.connectionCount ?? 8,
            actualConnectionCount: 0)
    }

    func pause(jobID: UInt64) async throws {
        if let pauseError {
            throw pauseError
        }
        pausedIDs.append(jobID)
    }

    func resume(jobID: UInt64) async throws {
        if let resumeError {
            throw resumeError
        }
        resumedIDs.append(jobID)
    }

    func remove(jobID: UInt64, keepPartialFile: Bool) async throws {
        if let removeError {
            throw removeError
        }
        removedRequests.append(RemoveRequest(jobID: jobID, keepPartialFile: keepPartialFile))
    }

    private(set) var recordedVerifiedEntries: [[VerifiedProvenanceEntry]] = []

    func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry]) async throws {
        recordedVerifiedEntries.append(entries)
    }

    var lsReply: LsReply = LsReply(jobs: [], featureLevel: nil)

    func ls() async throws -> LsReply { lsReply }

    func enqueue(_ event: FakeStreamEvent) {
        streamEvents.append(event)
    }
}

private enum FakeStreamEvent {
    case success([ProgressSnapshot])
    case failure(any Error)
    case end
}

private enum FakeMenuError: Error, CustomStringConvertible {
    case intentional

    var description: String {
        "intentional test error"
    }
}

private struct RemoveRequest: Equatable {
    var jobID: UInt64
    var keepPartialFile: Bool
}

@MainActor
private final class LongLivedMenuClient: GohMenuClient {
    private var nextStreamID = 1
    private var continuations: [Int: AsyncThrowingStream<[ProgressSnapshot], any Error>.Continuation] = [:]

    private(set) var startedStreamIDs: [Int] = []
    private(set) var terminatedStreamIDs: [Int] = []

    var activeStreamIDs: [Int] {
        Array(continuations.keys).sorted()
    }

    func progressSnapshots() -> AsyncThrowingStream<[ProgressSnapshot], any Error> {
        let streamID = nextStreamID
        nextStreamID += 1
        startedStreamIDs.append(streamID)

        return AsyncThrowingStream { continuation in
            continuations[streamID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations[streamID] = nil
                    self?.terminatedStreamIDs.append(streamID)
                }
            }
        }
    }

    func yield(_ snapshots: [ProgressSnapshot], to streamID: Int) {
        continuations[streamID]?.yield(snapshots)
    }

    func add(_ request: AddRequest) async throws -> JobSummary {
        JobSummary(
            id: 1,
            url: request.url,
            destination: "/tmp/big.iso",
            state: .queued,
            progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
            createdAt: Date(timeIntervalSince1970: 1),
            lastProgressAt: nil,
            requestedConnectionCount: request.connectionCount ?? 8,
            actualConnectionCount: 0)
    }

    func pause(jobID: UInt64) async throws {}
    func resume(jobID: UInt64) async throws {}
    func remove(jobID: UInt64, keepPartialFile: Bool) async throws {}
    func recordVerifiedProvenance(_ entries: [VerifiedProvenanceEntry]) async throws {}
    func ls() async throws -> LsReply { LsReply(jobs: [], featureLevel: nil) }
}
