import Foundation
import Testing

import GohCore

@Suite("Job store — startup checkpoint reconciliation")
struct JobStoreStartupReconciliationTests {

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goh-reconcile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeActiveJob(
        store: JobStore, directory: URL, url: String = "https://example.com/large.iso"
    ) throws -> JobSummary {
        let destination = directory.appending(path: "large.iso")
        let job = store.create(
            url: url, destination: destination.path, requestedConnectionCount: 8)
        #expect(try store.start(id: job.id))
        return try #require(store.job(id: job.id))
    }

    @Test("an active job with a safe checkpoint is requeued for startup scheduling")
    func activeJobWithSafeCheckpointRequeues() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JobStore()
        let active = try makeActiveJob(store: store, directory: directory)
        let partialSize: UInt64 = 2 << 20
        try Data(count: Int(partialSize)).write(to: URL(filePath: active.destination))

        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
        let checkpointDate = Date(timeIntervalSince1970: 1_800_000_000)
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
            updatedAt: checkpointDate))

        let result = store.reconcileActiveJobsOnStartup(checkpoints: checkpointStore)

        #expect(result.requeuedJobIDs == [active.id])
        #expect(result.failedJobIDs.isEmpty)
        let requeued = try #require(store.job(id: active.id))
        #expect(requeued.state == .queued)
        #expect(requeued.actualConnectionCount == 0)
        #expect(requeued.progress.bytesCompleted == partialSize)
        #expect(requeued.progress.bytesTotal == 4 << 20)
        #expect(requeued.progress.bytesPerSecond == 0)
        #expect(requeued.lastProgressAt == checkpointDate)
        #expect(requeued.error == nil)
        #expect(requeued.retryEligible == nil)
    }

    @Test("an active job without a checkpoint fails retryably on startup")
    func activeJobWithoutCheckpointFailsRetryably() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JobStore()
        let active = try makeActiveJob(store: store, directory: directory)
        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))

        let result = store.reconcileActiveJobsOnStartup(checkpoints: checkpointStore)

        #expect(result.requeuedJobIDs.isEmpty)
        #expect(result.failedJobIDs == [active.id])
        let failed = try #require(store.job(id: active.id))
        #expect(failed.state == .failed)
        #expect(failed.error?.code == .connectionFailed)
        #expect(failed.error?.message?.contains("resume metadata") == true)
        #expect(failed.retryEligible == true)
        #expect(failed.retryCount == 0)
        #expect(failed.failedAt != nil)
        #expect(failed.actualConnectionCount == 0)
    }

    @Test("startup reconciliation leaves queued and paused jobs alone")
    func queuedAndPausedJobsAreUntouched() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JobStore()
        let queued = store.create(
            url: "https://example.com/q", destination: "/tmp/q", requestedConnectionCount: 4)
        let paused = store.create(
            url: "https://example.com/p", destination: "/tmp/p", requestedConnectionCount: 4)
        _ = try store.pause(id: paused.id)
        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))

        let result = store.reconcileActiveJobsOnStartup(checkpoints: checkpointStore)

        #expect(result.requeuedJobIDs.isEmpty)
        #expect(result.failedJobIDs.isEmpty)
        #expect(store.job(id: queued.id)?.state == .queued)
        #expect(store.job(id: paused.id)?.state == .paused)
        #expect(store.job(id: paused.id)?.pauseReason == .user)
    }

    @Test("an active job with mismatched checkpoint metadata fails retryably")
    func activeJobWithMismatchedCheckpointFailsRetryably() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JobStore()
        let active = try makeActiveJob(store: store, directory: directory)
        let partialSize: UInt64 = 1 << 20
        try Data(count: Int(partialSize)).write(to: URL(filePath: active.destination))

        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
        try checkpointStore.save(DownloadCheckpoint(
            jobID: active.id,
            url: "https://example.com/other.iso",
            destination: active.destination,
            partialFileSize: partialSize,
            totalBytes: 2 << 20,
            strongETag: "\"strong-validator\"",
            completedPieces: [CheckpointPiece(start: 0, length: partialSize)]))

        let result = store.reconcileActiveJobsOnStartup(checkpoints: checkpointStore)

        #expect(result.requeuedJobIDs.isEmpty)
        #expect(result.failedJobIDs == [active.id])
        let failed = try #require(store.job(id: active.id))
        #expect(failed.state == .failed)
        #expect(failed.error?.code == .connectionFailed)
        #expect(failed.retryEligible == true)
    }

    @Test("a Last-Modified validator is enough for startup requeue")
    func lastModifiedValidatorRequeues() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JobStore()
        let active = try makeActiveJob(store: store, directory: directory)
        let partialSize: UInt64 = 1 << 20
        try Data(count: Int(partialSize)).write(to: URL(filePath: active.destination))

        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
        try checkpointStore.save(DownloadCheckpoint(
            jobID: active.id,
            url: active.url,
            destination: active.destination,
            partialFileSize: partialSize,
            totalBytes: 2 << 20,
            lastModified: "Sun, 24 May 2026 12:00:00 GMT",
            completedPieces: [CheckpointPiece(start: 0, length: partialSize)]))

        let result = store.reconcileActiveJobsOnStartup(checkpoints: checkpointStore)

        #expect(result.requeuedJobIDs == [active.id])
        #expect(store.job(id: active.id)?.state == .queued)
    }

    @Test("a weak ETag without another validator is unsafe after restart")
    func weakETagWithoutLastModifiedFailsRetryably() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JobStore()
        let active = try makeActiveJob(store: store, directory: directory)
        let partialSize: UInt64 = 1 << 20
        try Data(count: Int(partialSize)).write(to: URL(filePath: active.destination))

        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
        try checkpointStore.save(DownloadCheckpoint(
            jobID: active.id,
            url: active.url,
            destination: active.destination,
            partialFileSize: partialSize,
            totalBytes: 2 << 20,
            strongETag: "W/\"weak-validator\"",
            completedPieces: [CheckpointPiece(start: 0, length: partialSize)]))

        let result = store.reconcileActiveJobsOnStartup(checkpoints: checkpointStore)

        #expect(result.requeuedJobIDs.isEmpty)
        #expect(result.failedJobIDs == [active.id])
        #expect(store.job(id: active.id)?.state == .failed)
    }

    @Test("the unsafe-resume failure message does not disclose the checkpoint sidecar path")
    func unsafeResumeMessageOmitsSidecarPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JobStore()
        let active = try makeActiveJob(store: store, directory: directory)

        let checkpointDir = directory.appending(path: "checkpoints")
        try FileManager.default.createDirectory(at: checkpointDir, withIntermediateDirectories: true)
        let checkpointStore = CheckpointStore(directoryURL: checkpointDir)
        // A corrupt checkpoint file makes load() recover to nil and preserve a
        // sidecar; the failure message published over XPC must not leak its path.
        try Data("not a property list".utf8).write(
            to: checkpointStore.fileURL(jobID: active.id))

        let result = store.reconcileActiveJobsOnStartup(checkpoints: checkpointStore)

        #expect(result.failedJobIDs == [active.id])
        let failed = try #require(store.job(id: active.id))
        let message = try #require(failed.error?.message)
        #expect(message.contains("resume metadata"))
        #expect(!message.contains("/"))
        #expect(!message.contains(".corrupt-"))
    }
}
