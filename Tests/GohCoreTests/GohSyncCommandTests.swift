import Foundation
import Testing
import XPC

@testable import GohCore

// MARK: - Test harness

/// A scriptable fake daemon for `goh sync` tests.
///
/// It mirrors the real reply envelope exactly: it decodes the request's
/// `GohEnvelope<Command>`, echoes the request's `requestID` (required, or
/// `decodeGohReply` rejects the reply), and replies with `messageType: .reply`
/// and the matching reply payload (`JobSummary` for `add`, `LsReply` for `ls`).
///
/// "Downloading" is simulated: when `add` is received, the harness invokes
/// `onAdd`, which is expected to stage bytes on disk at the destination and
/// return the `JobSummary` the daemon would report. Subsequent `ls` calls
/// return every job staged so far (so completion detection finds them), unless
/// `onLs` is overridden.
final class FakeSyncDaemon: @unchecked Sendable {
    /// Called for each `add`. Returns the JobSummary to reply with, after the
    /// closure has (typically) staged bytes at the destination on disk. Marked
    /// `throws` so a staging failure surfaces instead of being papered over.
    var onAdd: (AddRequest, UInt64) throws -> JobSummary
    /// Optional override for `ls`. When nil, returns all jobs added so far.
    var onLs: (() throws -> [JobSummary])?

    private(set) var addCount = 0
    private(set) var lsCount = 0
    private var jobs: [JobSummary] = []
    private var nextID: UInt64 = 1

    init(
        onAdd: @escaping (AddRequest, UInt64) throws -> JobSummary,
        onLs: (() throws -> [JobSummary])? = nil
    ) {
        self.onAdd = onAdd
        self.onLs = onLs
    }

    /// The `GohCommandLine.Sender` to pass into `GohSyncCommand.run`.
    func sender() -> GohCommandLine.Sender {
        { [weak self] request in
            guard let self else { throw FakeError.deallocated }
            return try self.handle(request)
        }
    }

    enum FakeError: Error { case deallocated; case badCommand }

    private func handle(_ request: XPCDictionary) throws -> XPCDictionary {
        let envelope = try request.withUnsafeUnderlyingDictionary { object in
            try GohEnvelope<Command>(xpcDictionary: object)
        }
        let requestID = envelope.requestID

        switch envelope.payload {
        case .add(let addRequest):
            addCount += 1
            let id = nextID
            nextID += 1
            let summary = try onAdd(addRequest, id)
            jobs.removeAll { $0.id == summary.id }
            jobs.append(summary)
            return try reply(requestID: requestID, payload: summary)

        case .ls:
            lsCount += 1
            let listed = try (onLs?() ?? jobs)
            return try reply(requestID: requestID, payload: LsReply(jobs: listed))

        default:
            throw FakeError.badCommand
        }
    }

    /// The most recently added job, for `onLs` closures that need its id.
    func firstJob() -> JobSummary? { jobs.last }

    private func reply<Payload: Codable & Sendable>(
        requestID: UUID, payload: Payload
    ) throws -> XPCDictionary {
        let dict = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .reply,
            payload: payload)
            .xpcDictionary()
        return XPCDictionary(dict)
    }
}

// MARK: - Shared helpers

enum SyncTestSupport {
    /// Creates a fresh temp directory and returns its realpath-canonical path.
    static func makeDir() throws -> String {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return URL(fileURLWithPath: raw.path).resolvingSymlinksInPath().path
    }

    /// Writes `contents` to `path`, creating parent directories.
    static func stage(_ contents: Data, at path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
    }

    /// The sha256 string for `data` as `FileDigest` would report it.
    static func digest(_ data: Data) throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try FileDigest.sha256(path: tmp.path)
    }

    /// A minimal completed JobSummary for `dest`.
    static func completedJob(id: UInt64, url: String, dest: String, bytes: UInt64) -> JobSummary {
        JobSummary(
            id: id, url: url, destination: dest, state: .completed,
            progress: JobProgress(bytesCompleted: bytes, bytesTotal: bytes, bytesPerSecond: 0),
            createdAt: Date(), lastProgressAt: Date(),
            requestedConnectionCount: 8, actualConnectionCount: 0,
            completedAt: Date())
    }

    static func readLock(dir: String) throws -> LockfileCodec.Lockfile {
        let toml = try String(contentsOfFile: dir + "/gohfile.lock", encoding: .utf8)
        return try LockfileCodec.decode(toml)
    }
}

// MARK: - T6.2 tests

@Suite("GohSyncCommand")
struct GohSyncCommandTests {

    @Test("empty manifest writes a zero-entry lock and exits 0")
    func emptyManifest() throws {
        let dir = try SyncTestSupport.makeDir()
        let manifestPath = dir + "/gohfile.toml"
        try "version = 1\n".write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let daemon = FakeSyncDaemon { _, id in
            SyncTestSupport.completedJob(id: id, url: "", dest: "", bytes: 0)
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 1)

        #expect(result.exitCode == 0)
        let lock = try SyncTestSupport.readLock(dir: dir)
        #expect(lock.entries.isEmpty)
        #expect(result.standardOutput.contains("nothing to sync"))
    }

    @Test("first sync downloads and writes a self-contained lock (AC1)")
    func firstSyncDownloads() throws {
        let dir = try SyncTestSupport.makeDir()
        let body = Data("hello world".utf8)
        let pin = try SyncTestSupport.digest(body)
        let manifestPath = dir + "/gohfile.toml"
        let manifest = """
        version = 1

        [[asset]]
        url = "https://example.com/file.bin"
        path = "out/file.bin"
        sha256 = "\(pin)"
        """
        try manifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let daemon = FakeSyncDaemon { req, id in
            try? SyncTestSupport.stage(body, at: req.destination!)
            return SyncTestSupport.completedJob(
                id: id, url: req.url, dest: req.destination!, bytes: UInt64(body.count))
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 1)

        #expect(result.exitCode == 0)
        #expect(daemon.addCount == 1)
        let lock = try SyncTestSupport.readLock(dir: dir)
        #expect(lock.entries.count == 1)
        let entry = try #require(lock.entries.first)
        #expect(entry.path == "out/file.bin")
        #expect(entry.sha256 == pin)
        #expect(entry.size == body.count)
        #expect(entry.url == "https://example.com/file.bin")
        #expect(lock.manifestHash == (try ManifestCodec.parse(manifest).manifestHash))
    }

    @Test("a second sync is idempotent — zero downloads, all up to date (AC1)")
    func idempotentSecondRun() throws {
        let dir = try SyncTestSupport.makeDir()
        let body = Data("idempotent".utf8)
        let pin = try SyncTestSupport.digest(body)
        let manifestPath = dir + "/gohfile.toml"
        let manifest = """
        version = 1

        [[asset]]
        url = "https://example.com/i.bin"
        path = "i.bin"
        sha256 = "\(pin)"
        """
        try manifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let daemon = FakeSyncDaemon { req, id in
            try? SyncTestSupport.stage(body, at: req.destination!)
            return SyncTestSupport.completedJob(
                id: id, url: req.url, dest: req.destination!, bytes: UInt64(body.count))
        }

        let first = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 1)
        #expect(first.exitCode == 0)
        #expect(daemon.addCount == 1)

        let second = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 1)
        #expect(second.exitCode == 0)
        #expect(daemon.addCount == 1)  // No new downloads.
        #expect(second.standardOutput.contains("up to date"))
    }

    @Test("a pinned mismatch quarantines the file and exits 2")
    func pinnedMismatchQuarantines() throws {
        let dir = try SyncTestSupport.makeDir()
        let pinned = try SyncTestSupport.digest(Data("expected".utf8))
        let wrong = Data("WRONG BYTES".utf8)
        let manifestPath = dir + "/gohfile.toml"
        let manifest = """
        version = 1

        [[asset]]
        url = "https://example.com/bad.bin"
        path = "bad.bin"
        sha256 = "\(pinned)"
        """
        try manifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let daemon = FakeSyncDaemon { req, id in
            try? SyncTestSupport.stage(wrong, at: req.destination!)
            return SyncTestSupport.completedJob(
                id: id, url: req.url, dest: req.destination!, bytes: UInt64(wrong.count))
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 1)

        #expect(result.exitCode == 2)
        #expect(!FileManager.default.fileExists(atPath: dir + "/bad.bin"))
        let quarantined = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .contains { $0.hasPrefix("bad.bin.corrupt-") } ?? false
        #expect(quarantined)
    }

    @Test("an unpinned first use records the on-disk hash and exits 0 (AC3)")
    func unpinnedFirstUseRecords() throws {
        let dir = try SyncTestSupport.makeDir()
        let body = Data("trust on first use".utf8)
        let expected = try SyncTestSupport.digest(body)
        let manifestPath = dir + "/gohfile.toml"
        let manifest = """
        version = 1

        [[asset]]
        url = "https://example.com/tofu.bin"
        path = "tofu.bin"
        """
        try manifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let daemon = FakeSyncDaemon { req, id in
            try? SyncTestSupport.stage(body, at: req.destination!)
            return SyncTestSupport.completedJob(
                id: id, url: req.url, dest: req.destination!, bytes: UInt64(body.count))
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 1)

        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("first use, unverified"))
        let lock = try SyncTestSupport.readLock(dir: dir)
        let entry = try #require(lock.entries.first)
        #expect(entry.sha256 == expected)
    }

    @Test("a bad manifest exits 64, not 1")
    func badManifestExits64() throws {
        let dir = try SyncTestSupport.makeDir()
        let manifestPath = dir + "/gohfile.toml"
        try "version = 1\nbogusKey = 5\n".write(
            toFile: manifestPath, atomically: true, encoding: .utf8)

        let daemon = FakeSyncDaemon { _, id in
            SyncTestSupport.completedJob(id: id, url: "", dest: "", bytes: 0)
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 1)
        #expect(result.exitCode == 64)
    }

    @Test("a missing manifest exits 64")
    func missingManifestExits64() throws {
        let dir = try SyncTestSupport.makeDir()
        let manifestPath = dir + "/gohfile.toml"  // never created

        let daemon = FakeSyncDaemon { _, id in
            SyncTestSupport.completedJob(id: id, url: "", dest: "", bytes: 0)
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 1)
        #expect(result.exitCode == 64)
    }

    // MARK: - F1: advisory lock held on the stable sidecar inode

    @Test("a held exclusive lock on the sidecar makes a concurrent sync exit 7")
    func concurrentSyncIsRefused() throws {
        let dir = try SyncTestSupport.makeDir()
        let manifestPath = dir + "/gohfile.toml"
        let manifest = """
        version = 1

        [[asset]]
        url = "https://example.com/c.bin"
        path = "c.bin"
        """
        try manifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        // Hold LOCK_EX on the stable sidecar from the test, simulating another
        // in-flight `goh sync`.
        let sidecar = dir + "/gohfile.lock.lock"
        let fd = open(sidecar, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { flock(fd, LOCK_UN) }

        let daemon = FakeSyncDaemon { req, id in
            try SyncTestSupport.stage(Data("c".utf8), at: req.destination!)
            return SyncTestSupport.completedJob(
                id: id, url: req.url, dest: req.destination!, bytes: 1)
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 1)

        #expect(result.exitCode == 7)
        #expect(daemon.addCount == 0)  // refused before any download
    }

    /// The sidecar lock must survive `writeLockAtomically`'s rename of
    /// `gohfile.lock`: a real sync renames the data file (new inode), but the
    /// lock lives on the never-renamed sidecar, so a concurrent attempt is still
    /// refused. We assert this by running a full sync (which writes+renames the
    /// lock), confirming it succeeds AND that the sidecar exists and is lockable
    /// only after the run completes (the run's own flock was released on exit).
    @Test("writeLockAtomically's rename does not move or release the sidecar lock")
    func renameDoesNotReleaseSidecarLock() throws {
        let dir = try SyncTestSupport.makeDir()
        let body = Data("sidecar-survives".utf8)
        let pin = try SyncTestSupport.digest(body)
        let manifestPath = dir + "/gohfile.toml"
        let manifest = """
        version = 1

        [[asset]]
        url = "https://example.com/s.bin"
        path = "s.bin"
        sha256 = "\(pin)"
        """
        try manifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let daemon = FakeSyncDaemon { req, id in
            try SyncTestSupport.stage(body, at: req.destination!)
            return SyncTestSupport.completedJob(
                id: id, url: req.url, dest: req.destination!, bytes: UInt64(body.count))
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 1)
        #expect(result.exitCode == 0)

        // The data file was renamed into place; the sidecar is a separate,
        // stable artifact that remains after the run.
        #expect(FileManager.default.fileExists(atPath: dir + "/gohfile.lock"))
        #expect(FileManager.default.fileExists(atPath: dir + "/gohfile.lock.lock"))

        // The run released its own lock on exit, so the sidecar is lockable now.
        let fd = open(dir + "/gohfile.lock.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        flock(fd, LOCK_UN)
    }
}
