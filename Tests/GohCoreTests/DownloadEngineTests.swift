import Foundation
import Synchronization
import Testing

@testable import GohCore

@Suite("Download engine", .serialized)
struct DownloadEngineTests {

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goh-engine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForState(
        _ expected: JobState, jobID: UInt64, in store: JobStore
    ) async throws {
        for _ in 0..<100 {
            if store.job(id: jobID)?.state == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("job \(jobID) did not reach \(expected)")
    }

    @Test("a successful download lands the bytes on disk and completes the job")
    func successfulDownload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<200_000).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .completed)
        #expect(final?.completedAt != nil)
        #expect(final?.progress.bytesCompleted == UInt64(payload.count))
        #expect(try Data(contentsOf: URL(filePath: destination)) == payload)
    }

    @Test("an HTTP error status fails the job with httpStatus")
    func httpErrorFailsJob() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, status: 404, body: Data("not found".utf8))

        let store = JobStore()
        let job = store.create(
            url: url, destination: directory.appending(path: "out.bin").path,
            requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .failed)
        #expect(final?.error?.code == .httpStatus)
        #expect(final?.error?.httpStatusCode == 404)
        #expect(final?.retryEligible == false)
    }

    @Test("an authentication HTTP status fails the job as unauthorized")
    func authenticationHTTPStatusFailsAsUnauthorized() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, status: 401, body: Data("login required".utf8))

        let store = JobStore()
        let job = store.create(
            url: url, destination: directory.appending(path: "out.bin").path,
            requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .failed)
        #expect(final?.error?.code == .unauthorized)
        #expect(final?.error?.httpStatusCode == nil)
        #expect(final?.retryEligible == false)
    }

    @Test("retry policy marks transient HTTP statuses and checksum failures retryable")
    func retryPolicyMarksTransientFailures() {
        #expect(DownloadEngine.retryEligible(for: GohError(
            code: .httpStatus, httpStatusCode: 408)))
        #expect(DownloadEngine.retryEligible(for: GohError(
            code: .httpStatus, httpStatusCode: 429)))
        #expect(DownloadEngine.retryEligible(for: GohError(
            code: .httpStatus, httpStatusCode: 503)))
        #expect(DownloadEngine.retryEligible(for: GohError(
            code: .checksumMismatch)))

        #expect(DownloadEngine.retryEligible(for: GohError(
            code: .httpStatus, httpStatusCode: 404)) == false)
    }

    @Test("a transport failure fails the job with the mapped error code")
    func networkErrorFailsJob() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, failure: URLError(.timedOut))

        let store = JobStore()
        let job = store.create(
            url: url, destination: directory.appending(path: "out.bin").path,
            requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .failed)
        #expect(final?.error?.code == .timedOut)
        #expect(final?.retryEligible == true)
    }

    @Test("a dispatched add drives the engine to completion")
    func dispatchedAddDrivesEngine() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<120_000).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload)

        let store = JobStore()
        let engine = DownloadEngine(session: mockSession())
        let engineTask = Mutex<Task<Void, Never>?>(nil)
        let dispatcher = CommandDispatcher(store: store, onJobQueued: { id in
            engineTask.withLock { $0 = Task { await engine.run(jobID: id, in: store) } }
        })

        let destination = directory.appending(path: "out.bin").path
        _ = dispatcher.reply(to: .add(request: AddRequest(url: url, destination: destination)))
        await engineTask.withLock { $0 }?.value

        #expect(store.job(id: 1)?.state == .completed)
        #expect(try Data(contentsOf: URL(filePath: destination)) == payload)
    }

    @Test("a large file downloads across multiple ranges")
    func multiRangeDownload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        // 4 MiB against a 1 MiB minimum chunk → four ranges.
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .completed)
        #expect(final?.actualConnectionCount == 4)
        #expect(try Data(contentsOf: URL(filePath: destination)) == payload)
    }

    @Test("download requests attach an imported cookie header from the provider")
    func downloadRequestsAttachImportedCookies() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<(2 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(
            url,
            body: payload,
            requiredCookieHeader: "session=abc; pref=dark")

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 2)
        let engine = DownloadEngine(
            session: mockSession(),
            cookieHeaderProvider: { jobID, requestURL in
                guard jobID == job.id, requestURL.absoluteString == url else { return nil }
                return "session=abc; pref=dark"
            })

        await engine.run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .completed)
        #expect(final?.actualConnectionCount == 2)
        #expect(try Data(contentsOf: URL(filePath: destination)) == payload)
    }

    @Test("a checkpointed job resumes from the first missing byte")
    func resumesFromCheckpoint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let validator = "\"resume-validator\""
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(
            url,
            body: payload,
            failRangeStartingAt: 0,
            headers: ["ETag": validator],
            requiredIfRange: validator)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin")
        let job = store.create(
            url: url, destination: destination.path, requestedConnectionCount: 8)
        #expect(try store.start(id: job.id))

        let checkpointedBytes = 2 << 20
        try payload.prefix(checkpointedBytes).write(to: destination)
        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
        try checkpointStore.save(DownloadCheckpoint(
            jobID: job.id,
            url: url,
            destination: destination.path,
            partialFileSize: UInt64(checkpointedBytes),
            totalBytes: UInt64(payload.count),
            strongETag: validator,
            completedPieces: [CheckpointPiece(start: 0, length: UInt64(checkpointedBytes))]))
        #expect(store.reconcileActiveJobsOnStartup(checkpoints: checkpointStore).requeuedJobIDs == [job.id])

        await DownloadEngine(session: mockSession(), checkpointStore: checkpointStore)
            .run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .completed)
        #expect(final?.progress.bytesCompleted == UInt64(payload.count))
        #expect(try Data(contentsOf: destination) == payload)
        #expect(checkpointStore.load(jobID: job.id).checkpoint == nil)
    }

    @Test("a failed ranged download leaves a durable checkpoint")
    func failedRangedDownloadLeavesCheckpoint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let validator = "\"checkpoint-validator\""
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(
            url,
            body: payload,
            truncateRangeStartingAt: 0,
            headers: ["ETag": validator])

        let store = JobStore()
        let destination = directory.appending(path: "out.bin")
        let job = store.create(
            url: url, destination: destination.path, requestedConnectionCount: 1)
        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))

        await DownloadEngine(session: mockSession(), checkpointStore: checkpointStore)
            .run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .failed)
        #expect(final?.error?.code == .connectionFailed)
        let checkpoint = try #require(checkpointStore.load(jobID: job.id).checkpoint)
        #expect(checkpoint.strongETag == validator)
        #expect(checkpoint.totalBytes == UInt64(payload.count))
        #expect(checkpoint.completedPieces == [
            CheckpointPiece(start: 0, length: UInt64(2 << 20)),
        ])
        #expect(checkpoint.partialFileSize == UInt64(2 << 20))
    }

    @Test("pausing an active download waits for a checkpoint boundary")
    func pauseActiveDownloadAtCheckpoint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let validator = "\"pause-validator\""
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(
            url,
            body: payload,
            headers: ["ETag": validator],
            bodyChunkSize: 256 << 10,
            bodyChunkDelayMicroseconds: 20_000)

        let store = JobStore()
        let control = DownloadControl()
        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
        let dispatcher = CommandDispatcher(store: store, control: control)
        let destination = directory.appending(path: "out.bin")
        let job = store.create(
            url: url, destination: destination.path, requestedConnectionCount: 1)
        let engine = DownloadEngine(
            session: mockSession(), checkpointStore: checkpointStore, control: control)
        let engineTask = Task { await engine.run(jobID: job.id, in: store) }

        try await waitForState(.active, jobID: job.id, in: store)
        guard case .job(let paused) = dispatcher.reply(to: .pause(jobID: job.id)) else {
            Issue.record("expected .job from pause")
            return
        }
        await engineTask.value

        #expect(paused.state == .paused)
        #expect(paused.pauseReason == .user)
        #expect(store.job(id: job.id)?.state == .paused)
        let checkpoint = try #require(checkpointStore.load(jobID: job.id).checkpoint)
        #expect(checkpoint.completedPieces.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("a paused active download resumes through the dispatcher from its checkpoint")
    func pauseThenResumeActiveDownload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let validator = "\"pause-resume-validator\""
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(
            url,
            body: payload,
            headers: ["ETag": validator],
            bodyChunkSize: 256 << 10,
            bodyChunkDelayMicroseconds: 20_000)

        let store = JobStore()
        let control = DownloadControl()
        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
        let engine = DownloadEngine(
            session: mockSession(), checkpointStore: checkpointStore, control: control)
        let engineTask = Mutex<Task<Void, Never>?>(nil)
        let dispatcher = CommandDispatcher(
            store: store, control: control,
            onJobQueued: { id in
                engineTask.withLock { task in
                    task = Task { await engine.run(jobID: id, in: store) }
                }
            })

        let destination = directory.appending(path: "out.bin")
        guard case .job(let added) = dispatcher.reply(to: .add(request: AddRequest(
            url: url, destination: destination.path, connectionCount: 1)))
        else {
            Issue.record("expected .job from add")
            return
        }
        try await waitForState(.active, jobID: added.id, in: store)
        guard case .job(let paused) = dispatcher.reply(to: .pause(jobID: added.id)) else {
            Issue.record("expected .job from pause")
            return
        }
        await engineTask.withLock { $0 }?.value
        let checkpoint = try #require(checkpointStore.load(jobID: added.id).checkpoint)

        MockURLProtocol.stub(
            url,
            body: payload,
            failRangeStartingAt: 0,
            headers: ["ETag": validator],
            requiredIfRange: validator)
        guard case .job(let resumed) = dispatcher.reply(to: .resume(jobID: added.id)) else {
            Issue.record("expected .job from resume")
            return
        }
        await engineTask.withLock { $0 }?.value

        #expect(paused.state == .paused)
        #expect(checkpoint.completedPieces.isEmpty == false)
        #expect(resumed.state == .queued)
        #expect(store.job(id: added.id)?.state == .completed)
        #expect(try Data(contentsOf: destination) == payload)
        #expect(checkpointStore.load(jobID: added.id).checkpoint == nil)
    }

    @Test("removing an active download without keep deletes partials and checkpoints")
    func removeActiveDownloadDeletesPartialAndCheckpoint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(
            url,
            body: payload,
            headers: ["ETag": "\"rm-validator\""],
            bodyChunkSize: 256 << 10,
            bodyChunkDelayMicroseconds: 20_000)

        let store = JobStore()
        let control = DownloadControl()
        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
        let dispatcher = CommandDispatcher(store: store, control: control)
        let destination = directory.appending(path: "out.bin")
        let job = store.create(
            url: url, destination: destination.path, requestedConnectionCount: 1)
        let engine = DownloadEngine(
            session: mockSession(), checkpointStore: checkpointStore, control: control)
        let engineTask = Task { await engine.run(jobID: job.id, in: store) }

        try await waitForState(.active, jobID: job.id, in: store)
        guard case .removed(let removed) = dispatcher.reply(
            to: .rm(request: RmRequest(jobID: job.id)))
        else {
            Issue.record("expected .removed")
            return
        }
        await engineTask.value

        #expect(removed.removedJobID == job.id)
        #expect(store.job(id: job.id) == nil)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        #expect(checkpointStore.load(jobID: job.id).checkpoint == nil)
    }

    @Test("removing an active download with keep preserves the partial and checkpoint")
    func removeActiveDownloadKeepsPartialAndCheckpoint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(
            url,
            body: payload,
            headers: ["ETag": "\"keep-validator\""],
            bodyChunkSize: 256 << 10,
            bodyChunkDelayMicroseconds: 20_000)

        let store = JobStore()
        let control = DownloadControl()
        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
        let dispatcher = CommandDispatcher(store: store, control: control)
        let destination = directory.appending(path: "out.bin")
        let job = store.create(
            url: url, destination: destination.path, requestedConnectionCount: 1)
        let engine = DownloadEngine(
            session: mockSession(), checkpointStore: checkpointStore, control: control)
        let engineTask = Task { await engine.run(jobID: job.id, in: store) }

        try await waitForState(.active, jobID: job.id, in: store)
        guard case .removed(let removed) = dispatcher.reply(
            to: .rm(request: RmRequest(jobID: job.id, keepPartialFile: true)))
        else {
            Issue.record("expected .removed")
            return
        }
        await engineTask.value

        #expect(removed.removedJobID == job.id)
        #expect(store.job(id: job.id) == nil)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(checkpointStore.load(jobID: job.id).checkpoint != nil)
    }

    @Test("add after rm keep adopts the kept partial and resumes it")
    func addAfterRemoveKeepAdoptsPartial() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let validator = "\"adopt-kept-validator\""
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(
            url,
            body: payload,
            headers: ["ETag": validator],
            bodyChunkSize: 256 << 10,
            bodyChunkDelayMicroseconds: 20_000)

        let store = JobStore()
        let control = DownloadControl()
        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
        let engine = DownloadEngine(
            session: mockSession(), checkpointStore: checkpointStore, control: control)
        let engineTask = Mutex<Task<Void, Never>?>(nil)
        let dispatcher = CommandDispatcher(
            store: store,
            control: control,
            checkpointStore: checkpointStore,
            onJobQueued: { id in
                engineTask.withLock { task in
                    task = Task { await engine.run(jobID: id, in: store) }
                }
            })

        let destination = directory.appending(path: "out.bin")
        guard case .job(let first) = dispatcher.reply(to: .add(request: AddRequest(
            url: url, destination: destination.path, connectionCount: 1)))
        else {
            Issue.record("expected first add to create a job")
            return
        }
        try await waitForState(.active, jobID: first.id, in: store)
        guard case .removed = dispatcher.reply(to: .rm(request: RmRequest(
            jobID: first.id, keepPartialFile: true)))
        else {
            Issue.record("expected rm --keep to remove the active job")
            return
        }
        await engineTask.withLock { $0 }?.value
        let kept = try #require(checkpointStore.load(jobID: first.id).checkpoint)
        #expect(kept.completedPieces.isEmpty == false)

        MockURLProtocol.stub(
            url,
            body: payload,
            failRangeStartingAt: 0,
            headers: ["ETag": validator],
            requiredIfRange: validator)
        guard case .job(let second) = dispatcher.reply(to: .add(request: AddRequest(
            url: url, destination: destination.path, connectionCount: 1)))
        else {
            Issue.record("expected second add to adopt the kept job")
            return
        }
        await engineTask.withLock { $0 }?.value

        #expect(second.id == 2)
        #expect(second.progress.bytesCompleted == kept.durableBytesCompleted)
        #expect(store.job(id: second.id)?.state == .completed)
        #expect(try Data(contentsOf: destination) == payload)
        #expect(checkpointStore.load(jobID: first.id).checkpoint == nil)
        #expect(checkpointStore.load(jobID: second.id).checkpoint == nil)
    }

    @Test("a server without range support falls back to a single connection")
    func fallbackWhenNoRangeSupport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload, acceptsRanges: false)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .completed)
        #expect(final?.actualConnectionCount == 1)
        #expect(try Data(contentsOf: URL(filePath: destination)) == payload)
    }

    @Test("streamingResponse delivers the response and yields the body via async stream")
    func streamingResponseDeliversChunks() async throws {
        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<4096).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload)

        let (http, stream) = try await mockSession()
            .streamingResponse(for: URLRequest(url: URL(string: url)!))

        #expect(http.statusCode == 200)
        var received = Data()
        for try await chunk in stream {
            received.append(chunk)
        }
        #expect(received == payload)
    }

    @Test("a failing range fails the whole job")
    func failingRangeFailsJob() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        // Four 1 MiB ranges; fail the one beginning at 2 MiB.
        MockURLProtocol.stub(url, body: payload, failRangeStartingAt: 2 << 20)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        #expect(store.job(id: job.id)?.state == .failed)
    }

    @Test("a range that ends before its advertised length fails the whole job")
    func truncatedRangeFailsJob() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload, truncateRangeStartingAt: 1 << 20)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .failed)
        #expect(final?.error?.code == .connectionFailed)
    }

    @Test("a ranged response with a mismatched Content-Range fails the whole job")
    func mismatchedContentRangeFailsJob() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(
            url,
            body: payload,
            contentRangeOverride: [
                1 << 20: "bytes 0-\((2 << 20) - 1)/\(payload.count)",
            ])

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .failed)
        #expect(final?.error?.code == .connectionFailed)
    }

    @Test("an initial open-ended ranged response with a mismatched Content-Range fails the job")
    func mismatchedInitialContentRangeFailsJob() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(
            url,
            body: payload,
            contentRangeOverride: [
                0: "bytes 0-\((1 << 20) - 1)/\(payload.count)",
            ])

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .failed)
        #expect(final?.error?.code == .connectionFailed)
    }

    @Test("an initial open-ended ranged response that ends early fails the job")
    func truncatedInitialRangeFailsJob() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<900_000).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload, truncateRangeStartingAt: 0)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .failed)
        #expect(final?.error?.code == .connectionFailed)
    }
}
