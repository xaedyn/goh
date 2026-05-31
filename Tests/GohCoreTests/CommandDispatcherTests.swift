import Foundation
import Synchronization
import Testing

import GohCore

@Suite("Command dispatcher")
struct CommandDispatcherTests {

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goh-dispatcher-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("add creates a queued job and replies with its summary")
    func addCreatesJob() {
        let dispatcher = CommandDispatcher(store: JobStore())
        let outcome = dispatcher.reply(
            to: .add(request: AddRequest(url: "https://example.com/f.iso")))
        guard case .job(let summary) = outcome else {
            Issue.record("expected .job, got \(outcome)")
            return
        }
        #expect(summary.id == 1)
        #expect(summary.state == .queued)
        #expect(summary.url == "https://example.com/f.iso")
    }

    @Test("add without a destination derives one from the URL")
    func addDerivesDestination() {
        let dispatcher = CommandDispatcher(store: JobStore())
        let outcome = dispatcher.reply(
            to: .add(request: AddRequest(url: "https://example.com/big.iso")))
        guard case .job(let summary) = outcome else {
            Issue.record("expected .job, got \(outcome)")
            return
        }
        #expect(summary.destination.hasSuffix("big.iso"))
    }

    @Test("add without a destination gives root URLs a file destination")
    func addDerivesFileDestinationForRootURL() {
        let dispatcher = CommandDispatcher(store: JobStore())
        let outcome = dispatcher.reply(
            to: .add(request: AddRequest(url: "https://example.com/")))
        guard case .job(let summary) = outcome else {
            Issue.record("expected .job, got \(outcome)")
            return
        }
        #expect(summary.destination.hasSuffix("/Downloads/download"))
    }

    @Test("add honours an explicit destination and connection count")
    func addHonoursExplicitFields() {
        let dispatcher = CommandDispatcher(store: JobStore())
        let request = AddRequest(url: "u", destination: "/tmp/x", connectionCount: 4)
        guard case .job(let summary) = dispatcher.reply(to: .add(request: request)) else {
            Issue.record("expected .job")
            return
        }
        #expect(summary.destination == "/tmp/x")
        #expect(summary.requestedConnectionCount == 4)
    }

    @Test("add rejects a zero connection count")
    func addRejectsZeroConnectionCount() {
        let dispatcher = CommandDispatcher(store: JobStore())
        let request = AddRequest(url: "u", destination: "/tmp/x", connectionCount: 0)
        guard case .failure(let error) = dispatcher.reply(to: .add(request: request)) else {
            Issue.record("expected .failure")
            return
        }
        #expect(error.code == .invalidArgument)
        #expect(error.message?.contains("connectionCount") == true)
    }

    @Test("add caps a connection count above sixteen")
    func addCapsConnectionCountAboveSixteen() {
        let dispatcher = CommandDispatcher(store: JobStore())
        let request = AddRequest(url: "u", destination: "/tmp/x", connectionCount: 17)
        guard case .job(let summary) = dispatcher.reply(to: .add(request: request)) else {
            Issue.record("expected .job")
            return
        }
        #expect(summary.requestedConnectionCount == 16)
    }

    @Test("add snapshots a matching imported cookie header unless opted out")
    func addSnapshotsImportedCookieHeader() {
        let importedCookies = ImportedCookieStore(cookies: [
            SafariCookie(
                domain: ".example.com",
                name: "session",
                path: "/files",
                value: "abc",
                flags: [.secure],
                expiresAt: .distantFuture,
                createdAt: Date(timeIntervalSinceReferenceDate: 0)),
        ])
        let dispatcher = CommandDispatcher(
            store: JobStore(),
            importedCookies: importedCookies)

        guard case .job(let defaulted) = dispatcher.reply(to: .add(request: AddRequest(
            url: "https://downloads.example.com/files/archive.zip")))
        else {
            Issue.record("expected .job")
            return
        }
        guard case .job(let optedOut) = dispatcher.reply(to: .add(request: AddRequest(
            url: "https://downloads.example.com/files/other.zip",
            useImportedCookies: false)))
        else {
            Issue.record("expected .job")
            return
        }

        #expect(importedCookies.header(forJobID: defaulted.id) == "session=abc")
        #expect(importedCookies.header(forJobID: optedOut.id) == nil)
    }

    @Test("rm clears an imported cookie header for the removed job")
    func rmClearsImportedCookieHeader() {
        let importedCookies = ImportedCookieStore(cookies: [
            SafariCookie(
                domain: ".example.com",
                name: "session",
                path: "/",
                value: "abc",
                flags: [.secure],
                expiresAt: .distantFuture,
                createdAt: Date(timeIntervalSinceReferenceDate: 0)),
        ])
        let dispatcher = CommandDispatcher(
            store: JobStore(),
            importedCookies: importedCookies)

        _ = dispatcher.reply(to: .add(request: AddRequest(url: "https://example.com/f")))
        #expect(importedCookies.header(forJobID: 1) == "session=abc")

        _ = dispatcher.reply(to: .rm(request: RmRequest(jobID: 1)))

        #expect(importedCookies.header(forJobID: 1) == nil)
    }

    @Test("ls replies with every job in creation order")
    func lsListsJobs() {
        let dispatcher = CommandDispatcher(store: JobStore())
        _ = dispatcher.reply(to: .add(request: AddRequest(url: "u1")))
        _ = dispatcher.reply(to: .add(request: AddRequest(url: "u2")))
        guard case .list(let reply) = dispatcher.reply(to: .ls) else {
            Issue.record("expected .list")
            return
        }
        #expect(reply.jobs.map(\.id) == [1, 2])
    }

    @Test("pause then resume move a job through paused and back to queued")
    func pauseThenResume() {
        let dispatcher = CommandDispatcher(store: JobStore())
        _ = dispatcher.reply(to: .add(request: AddRequest(url: "u")))
        guard case .job(let paused) = dispatcher.reply(to: .pause(jobID: 1)) else {
            Issue.record("expected .job from pause")
            return
        }
        #expect(paused.state == .paused)
        guard case .job(let resumed) = dispatcher.reply(to: .resume(jobID: 1)) else {
            Issue.record("expected .job from resume")
            return
        }
        #expect(resumed.state == .queued)
    }

    @Test("rm removes a job and replies with the removed id")
    func rmRemovesJob() {
        let dispatcher = CommandDispatcher(store: JobStore())
        _ = dispatcher.reply(to: .add(request: AddRequest(url: "u")))
        guard case .removed(let reply) = dispatcher.reply(to: .rm(request: RmRequest(jobID: 1)))
        else {
            Issue.record("expected .removed")
            return
        }
        #expect(reply.removedJobID == 1)
        guard case .list(let after) = dispatcher.reply(to: .ls) else {
            Issue.record("expected .list")
            return
        }
        #expect(after.jobs.isEmpty)
    }

    @Test("rm without keep deletes a paused partial and checkpoint")
    func rmDeletesPausedPartialAndCheckpoint() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appending(path: "partial.bin")
        try Data("partial".utf8).write(to: destination)
        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
        let store = JobStore()
        let job = store.create(
            url: "https://example.com/partial.bin",
            destination: destination.path,
            requestedConnectionCount: 8)
        _ = try store.pause(id: job.id)
        try checkpointStore.save(DownloadCheckpoint(
            jobID: job.id,
            url: job.url,
            destination: destination.path,
            partialFileSize: 7,
            totalBytes: 100,
            strongETag: "\"paused\"",
            completedPieces: [CheckpointPiece(start: 0, length: 7)]))

        let dispatcher = CommandDispatcher(store: store, checkpointStore: checkpointStore)
        guard case .removed = dispatcher.reply(to: .rm(request: RmRequest(jobID: job.id))) else {
            Issue.record("expected .removed")
            return
        }

        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        #expect(checkpointStore.load(jobID: job.id).checkpoint == nil)
    }

    @Test("rm of a never-started queued job keeps a pre-existing destination")
    func rmQueuedJobKeepsPreExistingDestination() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appending(path: "user-owned.bin")
        let existingBytes = Data("not from goh".utf8)
        try existingBytes.write(to: destination)

        let store = JobStore()
        let job = store.create(
            url: "https://example.com/user-owned.bin",
            destination: destination.path,
            requestedConnectionCount: 8)
        let dispatcher = CommandDispatcher(store: store)

        guard case .removed = dispatcher.reply(to: .rm(request: RmRequest(jobID: job.id))) else {
            Issue.record("expected .removed")
            return
        }

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect((try? Data(contentsOf: destination)) == existingBytes)
    }

    @Test("rm of a completed job keeps the finished file")
    func rmCompletedKeepsFinishedFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appending(path: "finished.bin")
        try Data("finished".utf8).write(to: destination)
        let store = JobStore()
        let job = store.create(
            url: "https://example.com/finished.bin",
            destination: destination.path,
            requestedConnectionCount: 8)
        _ = try store.start(id: job.id)
        _ = try store.complete(id: job.id)

        let dispatcher = CommandDispatcher(store: store)
        guard case .removed = dispatcher.reply(to: .rm(request: RmRequest(jobID: job.id))) else {
            Issue.record("expected .removed")
            return
        }

        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("onJobQueued fires with the new job's id when add creates a job")
    func onJobQueuedFiresOnAdd() {
        let signalled = Mutex<[UInt64]>([])
        let dispatcher = CommandDispatcher(
            store: JobStore(),
            onJobQueued: { id in signalled.withLock { $0.append(id) } })
        _ = dispatcher.reply(to: .add(request: AddRequest(url: "u")))
        #expect(signalled.withLock { $0 } == [1])
    }

    @Test("add adopts a kept checkpoint with the same URL and destination")
    func addAdoptsKeptCheckpoint() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://example.com/large.iso"
        let destination = directory.appending(path: "large.iso")
        let partialSize: UInt64 = 2 << 20
        try Data(count: Int(partialSize)).write(to: destination)
        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
        let checkpointDate = Date(timeIntervalSince1970: 1_800_000_100)
        try checkpointStore.save(DownloadCheckpoint(
            jobID: 77,
            url: url,
            destination: destination.path,
            partialFileSize: partialSize,
            totalBytes: 4 << 20,
            strongETag: "\"adopt-me\"",
            completedPieces: [CheckpointPiece(start: 0, length: partialSize)],
            updatedAt: checkpointDate))

        let signalled = Mutex<[UInt64]>([])
        let dispatcher = CommandDispatcher(
            store: JobStore(),
            checkpointStore: checkpointStore,
            onJobQueued: { id in signalled.withLock { $0.append(id) } })

        guard case .job(let summary) = dispatcher.reply(to: .add(request: AddRequest(
            url: url, destination: destination.path)))
        else {
            Issue.record("expected .job")
            return
        }

        #expect(summary.id == 1)
        #expect(summary.state == .queued)
        #expect(summary.progress.bytesCompleted == partialSize)
        #expect(summary.progress.bytesTotal == 4 << 20)
        #expect(summary.progress.bytesPerSecond == 0)
        #expect(summary.lastProgressAt == checkpointDate)
        #expect(signalled.withLock { $0 } == [1])
        let adopted = try #require(checkpointStore.load(jobID: 1).checkpoint)
        #expect(adopted.jobID == 1)
        #expect(adopted.url == url)
        #expect(adopted.destination == destination.path)
        #expect(checkpointStore.load(jobID: 77).checkpoint == nil)
    }

    @Test("add ignores a kept checkpoint for a different URL")
    func addIgnoresMismatchedKeptCheckpoint() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appending(path: "large.iso")
        let partialSize: UInt64 = 1 << 20
        try Data(count: Int(partialSize)).write(to: destination)
        let checkpointStore = CheckpointStore(directoryURL: directory.appending(path: "checkpoints"))
        try checkpointStore.save(DownloadCheckpoint(
            jobID: 77,
            url: "https://example.com/other.iso",
            destination: destination.path,
            partialFileSize: partialSize,
            totalBytes: 4 << 20,
            strongETag: "\"do-not-adopt\"",
            completedPieces: [CheckpointPiece(start: 0, length: partialSize)]))

        let dispatcher = CommandDispatcher(
            store: JobStore(), checkpointStore: checkpointStore)
        guard case .job(let summary) = dispatcher.reply(to: .add(request: AddRequest(
            url: "https://example.com/large.iso", destination: destination.path)))
        else {
            Issue.record("expected .job")
            return
        }

        #expect(summary.progress.bytesCompleted == 0)
        #expect(checkpointStore.load(jobID: 1).checkpoint == nil)
        #expect(checkpointStore.load(jobID: 77).checkpoint != nil)
    }

    @Test("onJobQueued fires again when resume returns a job to queued")
    func onJobQueuedFiresOnResume() {
        let signalled = Mutex<[UInt64]>([])
        let dispatcher = CommandDispatcher(
            store: JobStore(),
            onJobQueued: { id in signalled.withLock { $0.append(id) } })
        _ = dispatcher.reply(to: .add(request: AddRequest(url: "u")))    // fires once
        _ = dispatcher.reply(to: .pause(jobID: 1))                        // no fire
        _ = dispatcher.reply(to: .resume(jobID: 1))                       // fires again
        #expect(signalled.withLock { $0 } == [1, 1])
    }

    @Test("pause, resume, and rm of an unknown id reply with a jobNotFound failure")
    func unknownIdFails() {
        let dispatcher = CommandDispatcher(store: JobStore())
        let commands: [Command] = [
            .pause(jobID: 9), .resume(jobID: 9), .rm(request: RmRequest(jobID: 9)),
        ]
        for command in commands {
            guard case .failure(let error) = dispatcher.reply(to: command) else {
                Issue.record("expected .failure for \(command)")
                return
            }
            #expect(error.code == .jobNotFound)
        }
    }

    // AC7: nil connectionCount → profile-driven N.
    @Test("AC: nil connectionCount uses profile-driven N at admission")
    func ac7NilConnectionCountUsesProfile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        store.recordObservation(
            hostKey: "https://example.com:443", connectionCount: 16,
            totalBytes: 200 * 1024 * 1024, transferDuration: .seconds(15))
        store.recordObservation(
            hostKey: "https://example.com:443", connectionCount: 16,
            totalBytes: 200 * 1024 * 1024, transferDuration: .seconds(15))
        let dispatcher = CommandDispatcher(store: JobStore(), hostProfileStore: store)
        let request = AddRequest(url: "https://example.com/file.iso")
        guard case .job(let summary) = dispatcher.reply(to: .add(request: request)) else {
            Issue.record("expected .job"); return
        }
        #expect(BanditSelector.candidateSet.contains(summary.requestedConnectionCount))
    }

    // AC7: nil connectionCount + no profile → default 8.
    @Test("AC: nil connectionCount with no profile falls back to 8")
    func ac7NilConnectionCountNoProfile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        _ = store.load()
        let dispatcher = CommandDispatcher(store: JobStore(), hostProfileStore: store)
        let request = AddRequest(url: "https://coldhost.example.com/file.iso")
        guard case .job(let summary) = dispatcher.reply(to: .add(request: request)) else {
            Issue.record("expected .job"); return
        }
        #expect(summary.requestedConnectionCount == 8)
    }

    // AC7: explicit connectionCount is honored unchanged.
    @Test("AC: explicit connectionCount is honored unchanged, ignoring profile")
    func ac7ExplicitConnectionCountHonored() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileStore = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        // Seed a converged profile that would steer the bandit toward 16, so the
        // assertion proves the EXPLICIT count overrides the profile — not merely
        // that an empty store falls through. The explicit path never consults the
        // bandit (no RNG), so this stays deterministic.
        for _ in 0..<3 {
            profileStore.recordObservation(
                hostKey: "https://example.com:443", connectionCount: 16,
                totalBytes: 200 * 1024 * 1024, transferDuration: .seconds(15))
        }
        let dispatcher = CommandDispatcher(store: JobStore(), hostProfileStore: profileStore)
        let request = AddRequest(url: "https://example.com/file.iso", connectionCount: 4)
        guard case .job(let summary) = dispatcher.reply(to: .add(request: request)) else {
            Issue.record("expected .job"); return
        }
        #expect(summary.requestedConnectionCount == 4)
    }

    // AC13: JobSummary requestedConnectionCount field type is unchanged.
    @Test("AC: JobSummary requestedConnectionCount field type is unchanged")
    func ac13JobSummaryUnchanged() {
        let dispatcher = CommandDispatcher(store: JobStore())
        let outcome = dispatcher.reply(to: .add(request: AddRequest(url: "https://example.com/f")))
        guard case .job(let summary) = outcome else {
            Issue.record("expected .job"); return
        }
        let _: UInt8 = summary.requestedConnectionCount
        #expect(summary.requestedConnectionCount == 8)
    }
}
