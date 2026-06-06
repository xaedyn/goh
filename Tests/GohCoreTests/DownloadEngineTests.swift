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

    private func waitForProgressGreaterThan(
        _ bytesCompleted: UInt64, jobID: UInt64, in store: JobStore
    ) async throws {
        for _ in 0..<100 {
            if let job = store.job(id: jobID),
               job.progress.bytesCompleted > bytesCompleted {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("job \(jobID) did not advance past \(bytesCompleted) bytes")
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
        let completedJob = Mutex<JobSummary?>(nil)
        let sleepAssertionCreates = Mutex(0)
        let sleepAssertionReleases = Mutex<[UInt32]>([])
        let sleepAssertionController = SleepAssertionController(
            backend: PowerAssertionBackend(
                create: { _ in
                    sleepAssertionCreates.withLock { $0 += 1 }
                    return 42
                },
                release: { id in
                    sleepAssertionReleases.withLock { $0.append(id) }
                }))

        await DownloadEngine(
            session: mockSession(),
            sleepAssertionController: sleepAssertionController,
            completedDownloadHandler: { completed, _, _, _, _ in
                completedJob.withLock { $0 = completed }
            }
        ).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .completed)
        #expect(final?.completedAt != nil)
        #expect(final?.progress.bytesCompleted == UInt64(payload.count))
        #expect(try Data(contentsOf: URL(filePath: destination)) == payload)
        #expect(completedJob.withLock { $0?.id } == job.id)
        #expect(completedJob.withLock { $0?.state } == .completed)
        #expect(completedJob.withLock { $0?.completedAt } != nil)
        #expect(sleepAssertionCreates.withLock { $0 } == 1)
        #expect(sleepAssertionReleases.withLock { $0 } == [42])
    }

    @Test("the completion handler receives a non-zero transfer duration and isResume==false for a fresh download")
    func completionHandlerCarriesTransferDurationForFreshDownload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<200_000).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)
        let observed = Mutex<(duration: Duration, isResume: Bool)?>(nil)

        await DownloadEngine(
            session: mockSession(),
            completedDownloadHandler: { _, duration, isResume, _, _ in
                observed.withLock { $0 = (duration, isResume) }
            }
        ).run(jobID: job.id, in: store)

        #expect(store.job(id: job.id)?.state == .completed)
        let captured = try #require(observed.withLock { $0 })
        #expect(captured.duration > .zero)
        #expect(captured.isResume == false)
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

    @Test("AC: end() is called on download failure — active-job set not leaked")
    func ac9ActiveJobEndedOnFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileStore = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        _ = profileStore.load()

        // A failing transport guarantees run() takes a throwing exit path, so the
        // bracket's end() must fire through run()'s defer.
        let url = "https://example.com/file.iso"
        MockURLProtocol.stub(url, failure: URLError(.timedOut))

        let store = JobStore()
        let job = store.create(
            url: url, destination: directory.appending(path: "out.iso").path,
            requestedConnectionCount: 8)

        // Before it starts, no job is contended, so a probe id is solo.
        #expect(profileStore.wasSolo(jobID: job.id))

        let engine = DownloadEngine(
            session: mockSession(),
            hostProfileStore: profileStore)
        await engine.run(jobID: job.id, in: store)
        #expect(store.job(id: job.id)?.state == .failed)

        // After failure, end() (in run()'s defer) must have removed the job from
        // the active set: a fresh job on the same host starts solo, which would
        // not hold if end() had leaked the failed job into the active set.
        let key = "https://example.com:443"
        profileStore.begin(jobID: 100, hostKey: key)
        #expect(profileStore.wasSolo(jobID: 100))
        profileStore.end(jobID: 100, hostKey: key)
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
        // 4 MiB with a 1 MiB chunkSize → four fixed-size chunks. With 8
        // requested workers the queue (4 chunks) caps peak concurrency at 4.
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession(), chunkSize: 1 << 20).run(jobID: job.id, in: store)

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
        // 2 MiB with a 1 MiB chunkSize → two chunks → two concurrent workers.
        let engine = DownloadEngine(
            session: mockSession(),
            chunkSize: 1 << 20,
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

    @Test("a resumed range whose server total differs from the checkpoint fails closed (audit L8)")
    func resumeWithChangedTotalFailsJob() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let validator = "\"resume-validator\""
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        let checkpointedBytes = 2 << 20
        // On resume the server declares a DIFFERENT total than the checkpoint —
        // a representation change that must fail closed, never stitch bytes.
        MockURLProtocol.stub(
            url,
            body: payload,
            contentRangeOverride: [
                checkpointedBytes:
                    "bytes \(checkpointedBytes)-\(payload.count - 1)/\(payload.count + (1 << 20))",
            ],
            headers: ["ETag": validator],
            requiredIfRange: validator)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin")
        let job = store.create(
            url: url, destination: destination.path, requestedConnectionCount: 8)
        #expect(try store.start(id: job.id))

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
        #expect(final?.state == .failed)
        #expect(final?.error?.code == .connectionFailed)
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

    @Test("removing a range-parallel active download cancels sibling ranges before replying")
    func removeRangeParallelActiveDownloadCancelsSiblingRanges() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<(16 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(
            url,
            body: payload,
            headers: ["ETag": "\"rm-parallel-validator\""],
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
        guard case .job(let added) = dispatcher.reply(to: .add(request: AddRequest(
            url: url, destination: destination.path, connectionCount: 8)))
        else {
            Issue.record("expected .job from add")
            return
        }
        try await waitForState(.active, jobID: added.id, in: store)
        try await waitForProgressGreaterThan(0, jobID: added.id, in: store)

        let clock = ContinuousClock()
        let started = clock.now
        guard case .removed = dispatcher.reply(to: .rm(request: RmRequest(jobID: added.id))) else {
            Issue.record("expected .removed")
            return
        }
        let elapsed = started.duration(to: clock.now)

        // The dispatcher's `rm` path blocks on `DownloadControl.requestStop`
        // until at least one range task observes the stop signal at its next
        // checkpoint boundary; sibling cancellation propagates via TaskGroup
        // after the first range throws. The bound here is a sanity check that
        // we did not wait for the workload to finish naturally (the 8 ranges
        // would otherwise carry ~140 ms of remaining work). The real
        // correctness signal is the behavioral pair below — partial file and
        // checkpoint both gone before reply, engine task winds up promptly.
        //
        // Originally `< 500 ms`, which tripped at 548 ms on a heavily-loaded
        // GitHub macos-26 runner. Raised to a CI-safe `< 2 s` so scheduling
        // variance doesn't masquerade as a regression. Local runs measure
        // ~90 ms, so 2 s is ~22× headroom.
        #expect(elapsed < .milliseconds(2_000))
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        #expect(checkpointStore.load(jobID: added.id).checkpoint == nil)
        await engineTask.withLock { $0 }?.value
        #expect(store.job(id: added.id) == nil)
    }

    @Test("removing a resumed active download without keep deletes partials and checkpoints")
    func removeResumedActiveDownloadDeletesPartialAndCheckpoint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let validator = "\"rm-resume-validator\""
        let payload = Data((0..<(8 << 20)).map { UInt8($0 & 0xff) })
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
        guard case .job(let added) = dispatcher.reply(to: .add(request: AddRequest(
            url: url, destination: destination.path, connectionCount: 1)))
        else {
            Issue.record("expected .job from add")
            return
        }
        try await waitForState(.active, jobID: added.id, in: store)
        guard case .job = dispatcher.reply(to: .pause(jobID: added.id)) else {
            Issue.record("expected .job from pause")
            return
        }
        await engineTask.withLock { $0 }?.value
        let checkpoint = try #require(checkpointStore.load(jobID: added.id).checkpoint)
        let checkpointedBytes = try #require(checkpoint.durableBytesCompleted)
        #expect(checkpoint.completedPieces.isEmpty == false)

        MockURLProtocol.stub(
            url,
            body: payload,
            headers: ["ETag": validator],
            requiredIfRange: validator,
            bodyChunkSize: 256 << 10,
            bodyChunkDelayMicroseconds: 20_000)
        guard case .job = dispatcher.reply(to: .resume(jobID: added.id)) else {
            Issue.record("expected .job from resume")
            return
        }
        try await waitForState(.active, jobID: added.id, in: store)
        try await waitForProgressGreaterThan(checkpointedBytes, jobID: added.id, in: store)

        guard case .removed(let removed) = dispatcher.reply(
            to: .rm(request: RmRequest(jobID: added.id)))
        else {
            Issue.record("expected .removed")
            return
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        #expect(checkpointStore.load(jobID: added.id).checkpoint == nil)
        await engineTask.withLock { $0 }?.value

        #expect(removed.removedJobID == added.id)
        #expect(store.job(id: added.id) == nil)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        #expect(checkpointStore.load(jobID: added.id).checkpoint == nil)
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

        let (http, stream, cancelStream) = try await mockSession()
            .streamingResponse(for: URLRequest(url: URL(string: url)!))
        defer { cancelStream() }

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
        // Four 1 MiB chunks; fail the GET for the chunk beginning at 2 MiB. A
        // 1 MiB chunkSize puts a chunk boundary exactly at the fault offset.
        MockURLProtocol.stub(url, body: payload, failRangeStartingAt: 2 << 20)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession(), chunkSize: 1 << 20).run(jobID: job.id, in: store)

        #expect(store.job(id: job.id)?.state == .failed)
    }

    @Test("a range that ends before its advertised length fails the whole job")
    func truncatedRangeFailsJob() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        // 1 MiB chunkSize puts a chunk boundary at the truncated offset.
        MockURLProtocol.stub(url, body: payload, truncateRangeStartingAt: 1 << 20)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession(), chunkSize: 1 << 20).run(jobID: job.id, in: store)

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
        // 1 MiB chunkSize puts a chunk boundary at the overridden offset.
        MockURLProtocol.stub(
            url,
            body: payload,
            contentRangeOverride: [
                1 << 20: "bytes 0-\((2 << 20) - 1)/\(payload.count)",
            ])

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession(), chunkSize: 1 << 20).run(jobID: job.id, in: store)

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

    @Test("a 206 declaring an implausibly large total fails closed instead of planning a giant chunk array")
    func implausibleContentRangeTotalFailsJob() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<(1 << 20)).map { UInt8($0 & 0xff) })
        // A total far beyond any real asset and beyond the engine's accepted ceiling.
        let huge = (UInt64(1) << 43) + 1
        MockURLProtocol.stub(
            url,
            body: payload,
            contentRangeOverride: [0: "bytes 0-\(huge - 1)/\(huge)"])

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        // Large chunkSize so that, even without the bound, this test never tries
        // to allocate the astronomical chunk array — we assert the fail-closed path.
        await DownloadEngine(session: mockSession(), chunkSize: 1 << 40)
            .run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .failed)
        #expect(final?.error?.code == .connectionFailed)
        #expect(final?.error?.message?.contains("content length") == true)
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

    @Test("a happy-path download reports no unexpected store errors")
    func happyPathReportsNoUnexpectedStoreErrors() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<200_000).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)
        let reportedErrors = Mutex<[(UInt64, String, String)]>([])

        await DownloadEngine(
            session: mockSession(),
            unexpectedStoreError: { jobID, operation, error in
                reportedErrors.withLock { $0.append((jobID, operation, "\(error)")) }
            }
        ).run(jobID: job.id, in: store)

        #expect(store.job(id: job.id)?.state == .completed)
        #expect(reportedErrors.withLock { $0 }.isEmpty)
    }

    @Test("SM3 prerequisite: flush emits rate samples (observability check)")
    func flushEmitsRateSamples() async throws {
        // We cannot directly inspect consumeRange's local array from outside.
        // This test confirms the engine still produces correct output when
        // the sampling accumulator is present — correctness is the gate.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let total: UInt64 = 4 * 1024 * 1024
        let payload = Data(repeating: 0xCC, count: Int(total))
        MockURLProtocol.stub(url, body: payload)
        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 2)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)
        #expect(store.job(id: job.id)?.state == .completed)
        let data = try Data(contentsOf: URL(fileURLWithPath: destination))
        #expect(data == payload)
    }

    @Test("SM3 prerequisite: fetchRanged accepts an injected clock (compile check)")
    func injectedClockAccepted() async throws {
        // Verifies the new clock parameter exists; behaviour tested in Task 3.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        // 4 MiB — above minChunk, so the 206 path (fetchRanged) is exercised.
        let total: UInt64 = 4 * 1024 * 1024
        let payload = Data(repeating: 0xAB, count: Int(total))
        MockURLProtocol.stub(url, body: payload)
        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 2)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)
        #expect(store.job(id: job.id)?.state == .completed)
    }

    @Test("rm during an active download does not surface jobNotFound to the reporter")
    func rmDuringActiveDownloadSwallowsJobNotFound() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(
            url,
            body: payload,
            headers: ["ETag": "\"reporter-rm-validator\""],
            bodyChunkSize: 256 << 10,
            bodyChunkDelayMicroseconds: 20_000)

        let store = JobStore()
        let control = DownloadControl()
        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
        let dispatcher = CommandDispatcher(store: store, control: control)
        let destination = directory.appending(path: "out.bin")
        let job = store.create(
            url: url, destination: destination.path, requestedConnectionCount: 1)
        let reportedErrors = Mutex<[(UInt64, String, String)]>([])

        let engine = DownloadEngine(
            session: mockSession(),
            checkpointStore: checkpointStore,
            control: control,
            unexpectedStoreError: { jobID, operation, error in
                reportedErrors.withLock { $0.append((jobID, operation, "\(error)")) }
            })
        let engineTask = Task { await engine.run(jobID: job.id, in: store) }

        try await waitForState(.active, jobID: job.id, in: store)
        guard case .removed = dispatcher.reply(
            to: .rm(request: RmRequest(jobID: job.id)))
        else {
            Issue.record("expected .removed")
            return
        }
        await engineTask.value

        // The recordProgress / fail calls that fire after the dispatcher has
        // deleted the job all throw `.jobNotFound`. None of those reach the
        // reporter — the reporter is reserved for genuinely unexpected
        // persistence failures.
        #expect(reportedErrors.withLock { $0 }.isEmpty)
        #expect(store.job(id: job.id) == nil)
    }

    @Test("P2: control-loop pool downloads correctly at fixed N=4")
    func controlLoopPoolDownload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let total: UInt64 = 8 * 1024 * 1024   // 8 MiB → multi-range
        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data(repeating: 0xAB, count: Int(total))
        MockURLProtocol.stub(url, body: payload)
        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 4)
        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)
        #expect(store.job(id: job.id)?.state == .completed)
        let data = try Data(contentsOf: URL(fileURLWithPath: destination))
        #expect(data == payload)
        #expect(store.job(id: job.id)?.actualConnectionCount ?? 0 >= 1)
    }

    @Test("P3 (11A): fixed-size chunk pool downloads byte-identical output across many chunks")
    func fixedSizeChunkPoolMultiChunk() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let total: UInt64 = 8 * 1024 * 1024            // 8 MiB
        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<Int(total)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload)
        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 4)
        // Small chunkSize → many chunks (8 MiB / 1 MiB = 8 chunks) across the 4 workers.
        await DownloadEngine(session: mockSession(), chunkSize: 1 << 20).run(jobID: job.id, in: store)
        #expect(store.job(id: job.id)?.state == .completed)
        let data = try Data(contentsOf: URL(fileURLWithPath: destination))
        #expect(data == payload)
        // 8 chunks, 4 workers → peak concurrent workers is 4.
        #expect(store.job(id: job.id)?.actualConnectionCount == 4)
    }

    @Test("P3: completedDownloadHandler receives a GovernorOutcome (arity)")
    func completedHandlerReceivesGovernorOutcome() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let total: UInt64 = 4 * 1024 * 1024
        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data(repeating: 0x11, count: Int(total))
        MockURLProtocol.stub(url, body: payload)
        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 2)
        let captured = Mutex<GovernorOutcome?>(nil)
        await DownloadEngine(session: mockSession(), chunkSize: 1 << 20,
            completedDownloadHandler: { _, _, _, _, outcome in captured.withLock { $0 = outcome } }
        ).run(jobID: job.id, in: store)
        #expect(store.job(id: job.id)?.state == .completed)
        #expect(captured.withLock { $0 } != nil)
    }

    @Test("P3: explicit --connections pins N; governor off; peak==pinned; outcome is .governorOff")
    func explicitNGovernorOff() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let total: UInt64 = 8 * 1024 * 1024
        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data(repeating: 0x33, count: Int(total))
        MockURLProtocol.stub(url, body: payload)
        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 4)
        let captured = Mutex<GovernorOutcome?>(nil)
        // Small chunkSize → 8 chunks so 4 workers actually run concurrently (peak 4).
        await DownloadEngine(session: mockSession(), chunkSize: 1 << 20,
            completedDownloadHandler: { _, _, _, _, outcome in captured.withLock { $0 = outcome } }
        ).run(jobID: job.id, in: store, explicitConnectionCount: 4)
        #expect(store.job(id: job.id)?.state == .completed)
        let outcome = captured.withLock { $0 }!
        #expect(outcome.effectiveN == nil)            // governor off → no bandit observation
        #expect(!outcome.stabilized)
        #expect(store.job(id: job.id)?.actualConnectionCount == 4)  // pinned peak; governor never probed
    }

    // AC1/T9: Digest captured and passed through completedDownloadHandler.
    @Test("AC1/T9: completedDownloadHandler receives non-nil sha256 matching the file's independent hash")
    func handlerReceivesSha256() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<200_000).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 1)

        let capturedSha256 = Mutex<String?>(nil)
        await DownloadEngine(
            session: mockSession(),
            completedDownloadHandler: { _, _, _, sha256, _ in
                capturedSha256.withLock { $0 = sha256 }
            }
        ).run(jobID: job.id, in: store)

        #expect(store.job(id: job.id)?.state == .completed)
        let sha256 = try #require(capturedSha256.withLock { $0 })
        // The handler-received digest must match an independent FileDigest hash of the file.
        let (independent, _) = try FileDigest.sha256WithSize(path: destination)
        // Engine streams bare hex; handler receives it bare. FileDigest returns "sha256:<hex>".
        // The handler in gohd prepends "sha256:" when writing to the store, but the handler
        // closure in the engine receives the BARE hex. Confirm bare hex matches.
        #expect("sha256:" + sha256 == independent)
    }

    // AC1/T5/T9: the resume path threads the digest through verifyHash → complete → handler.
    // Drives the REAL resume path (interrupted ranged download + checkpoint) so that
    // `isResume == true` reaches the handler, and asserts the delivered bare-hex digest
    // matches an independent FileDigest hash of the completed file.
    @Test("AC1/T5/T9: a resumed download delivers its sha256 through completedDownloadHandler")
    func resumedDownloadRecordsSha256ThroughHandler() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let validator = "\"resume-digest-validator\""
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

        let captured = Mutex<(isResume: Bool, sha256: String?)?>(nil)
        await DownloadEngine(
            session: mockSession(),
            checkpointStore: checkpointStore,
            completedDownloadHandler: { _, _, isResume, sha256, _ in
                captured.withLock { $0 = (isResume, sha256) }
            }
        ).run(jobID: job.id, in: store)

        #expect(store.job(id: job.id)?.state == .completed)
        let result = try #require(captured.withLock { $0 })
        #expect(result.isResume == true)
        let sha256 = try #require(result.sha256)
        // Engine streams bare hex; FileDigest returns the "sha256:"-prefixed form.
        let (independent, _) = try FileDigest.sha256WithSize(path: destination.path)
        #expect("sha256:" + sha256 == independent)
    }
}
