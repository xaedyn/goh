import Foundation
import Testing
import XPC

@testable import GohCore

/// T6.3 — completion detection: poll `ls` by job id + no-progress watchdog.
///
/// Each test drives `GohSyncCommand.run` with a single pinned asset and scripts
/// the `ls` replies via `FakeSyncDaemon.onLs` to exercise one completion outcome.
@Suite("GohSyncCompletion")
struct GohSyncCompletionTests {

    /// A one-asset manifest pinned to `pin`, written into a fresh temp dir.
    private func makeManifest(pin: String?) throws -> (dir: String, manifestPath: String) {
        let dir = try SyncTestSupport.makeDir()
        let manifestPath = dir + "/gohfile.toml"
        var manifest = """
        version = 1

        [[asset]]
        url = "https://example.com/c.bin"
        path = "c.bin"
        """
        if let pin { manifest += "\nsha256 = \"\(pin)\"" }
        try manifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)
        return (dir, manifestPath)
    }

    /// An active JobSummary placeholder the `add` closure returns.
    private func activeJob(_ req: AddRequest, _ id: UInt64) -> JobSummary {
        JobSummary(
            id: id, url: req.url, destination: req.destination!, state: .active,
            progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 1),
            createdAt: Date(), lastProgressAt: Date(),
            requestedConnectionCount: 8, actualConnectionCount: 1)
    }

    @Test("completed → re-hash and a lock entry, exit 0")
    func completedRehashes() throws {
        let body = Data("polled-complete".utf8)
        let pin = try SyncTestSupport.digest(body)
        let (dir, manifestPath) = try makeManifest(pin: pin)

        let daemon = FakeSyncDaemon { req, id in
            // add reports active; stage the file so the later re-hash works.
            try? SyncTestSupport.stage(body, at: req.destination!)
            return self.activeJob(req, id)
        }
        // ls flips the job to completed.
        daemon.onLs = { [weak daemon] in
            guard let daemon, let job = daemon.firstJob() else { return [] }
            return [SyncTestSupport.completedJob(
                id: job.id, url: job.url, dest: job.destination, bytes: UInt64(body.count))]
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 5)

        #expect(result.exitCode == 0)
        let lock = try SyncTestSupport.readLock(dir: dir)
        #expect(lock.entries.first?.sha256 == pin)
    }

    @Test("failed job → exit 8")
    func failedExits8() throws {
        let (_, manifestPath) = try makeManifest(pin: try SyncTestSupport.digest(Data("x".utf8)))

        let daemon = FakeSyncDaemon { req, id in self.activeJob(req, id) }
        daemon.onLs = { [weak daemon] in
            guard let daemon, let job = daemon.firstJob() else { return [] }
            return [Self.failedJob(job, error: GohError(code: .connectionFailed, message: "boom"))]
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 5)
        #expect(result.exitCode == 8)
    }

    @Test("failed with symlinkComponentRefused → exit 5")
    func symlinkRefusedExits5() throws {
        let (_, manifestPath) = try makeManifest(pin: try SyncTestSupport.digest(Data("x".utf8)))

        let daemon = FakeSyncDaemon { req, id in self.activeJob(req, id) }
        daemon.onLs = { [weak daemon] in
            guard let daemon, let job = daemon.firstJob() else { return [] }
            return [Self.failedJob(job, error: GohError(code: .symlinkComponentRefused, message: "symlink"))]
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 5)
        #expect(result.exitCode == 5)
    }

    @Test("job id absent from a successful ls → disappeared → exit 8")
    func disappearedExits8() throws {
        let (_, manifestPath) = try makeManifest(pin: try SyncTestSupport.digest(Data("x".utf8)))

        let daemon = FakeSyncDaemon { req, id in self.activeJob(req, id) }
        // ls succeeds but never lists the job.
        daemon.onLs = { [] }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 5)
        #expect(result.exitCode == 8)
    }

    @Test("watchdog: ls always active + tiny watchdogSeconds → exit 8 timed out")
    func watchdogExits8() throws {
        let (_, manifestPath) = try makeManifest(pin: try SyncTestSupport.digest(Data("x".utf8)))

        let daemon = FakeSyncDaemon { req, id in self.activeJob(req, id) }
        // Always active, never any byte advance → watchdog fires.
        daemon.onLs = { [weak daemon] in
            guard let daemon, let job = daemon.firstJob() else { return [] }
            return [JobSummary(
                id: job.id, url: job.url, destination: job.destination, state: .active,
                progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
                createdAt: Date(), lastProgressAt: nil,
                requestedConnectionCount: 8, actualConnectionCount: 1)]
        }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 0.05)
        #expect(result.exitCode == 8)
        #expect(result.standardOutput.contains("timed out"))
    }

    @Test("ls always throws → transport failure → exit 1, not 8")
    func lsThrowsExits1() throws {
        let (_, manifestPath) = try makeManifest(pin: try SyncTestSupport.digest(Data("x".utf8)))

        let daemon = FakeSyncDaemon { req, id in self.activeJob(req, id) }
        daemon.onLs = { throw NSError(domain: "transport", code: -1) }

        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 5)
        #expect(result.exitCode == 1)
    }

    // MARK: - Helpers

    private static func failedJob(_ base: JobSummary, error: GohError) -> JobSummary {
        JobSummary(
            id: base.id, url: base.url, destination: base.destination, state: .failed,
            progress: base.progress,
            createdAt: base.createdAt, lastProgressAt: base.lastProgressAt,
            requestedConnectionCount: base.requestedConnectionCount,
            actualConnectionCount: 0,
            error: error, retryEligible: false, failedAt: Date(), retryCount: 0)
    }
}
