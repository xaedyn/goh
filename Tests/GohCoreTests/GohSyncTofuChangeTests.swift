import Foundation
import Testing
import XPC

@testable import GohCore

/// T6.4 — trust-on-first-use drift (AC5) and `--accept-changed`.
///
/// An unpinned entry whose recorded lock hash exists, whose on-disk bytes now
/// differ, and whose file is complete (size >= recorded) is a TOFU change:
///   - without `--accept-changed`: exit 3, lock keeps the OLD hash, event printed.
///   - with `--accept-changed`: exit 0, lock updated to the new hash.
///   - `verify = false` on the asset suppresses the exit-3 event entirely and
///     just accepts the new bytes (exit 0).
@Suite("GohSyncTofuChange")
struct GohSyncTofuChangeTests {

    /// Writes a one-asset unpinned manifest. `verify` controls the asset flag.
    private func makeManifest(verify: Bool) throws -> (dir: String, manifestPath: String) {
        let dir = try SyncTestSupport.makeDir()
        let manifestPath = dir + "/gohfile.toml"
        var manifest = """
        version = 1

        [[asset]]
        url = "https://example.com/u.bin"
        path = "u.bin"
        """
        if !verify { manifest += "\nverify = false" }
        try manifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)
        return (dir, manifestPath)
    }

    /// Runs an initial sync that records `original` bytes for `u.bin`, then
    /// overwrites the on-disk file with `changed` bytes (complete, same length
    /// class), and returns the original hash that the lock should hold.
    @discardableResult
    private func seedThenChange(
        dir: String, manifestPath: String,
        original: Data, changed: Data
    ) throws -> String {
        let daemon = FakeSyncDaemon { req, id in
            try? SyncTestSupport.stage(original, at: req.destination!)
            return SyncTestSupport.completedJob(
                id: id, url: req.url, dest: req.destination!, bytes: UInt64(original.count))
        }
        let first = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 5)
        #expect(first.exitCode == 0)

        try changed.write(to: URL(fileURLWithPath: dir + "/u.bin"))
        return SyncTestSupport.digest(original)
    }

    /// A daemon that must never be asked to download (the file is present).
    private func noDownloadDaemon() -> FakeSyncDaemon {
        FakeSyncDaemon { req, id in
            SyncTestSupport.completedJob(id: id, url: req.url, dest: req.destination!, bytes: 0)
        }
    }

    @Test("unpinned change without --accept-changed → exit 3, lock unchanged, event printed")
    func driftWithoutAcceptExits3() throws {
        let (dir, manifestPath) = try makeManifest(verify: true)
        let original = Data("original content".utf8)
        let changed = Data("changed content!!".utf8)  // complete
        let originalHash = try seedThenChange(
            dir: dir, manifestPath: manifestPath, original: original, changed: changed)

        let daemon = noDownloadDaemon()
        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 5)

        #expect(result.exitCode == 3)
        #expect(daemon.addCount == 0)
        #expect(result.standardOutput.contains("hash changed for unpinned entry"))
        let lock = try SyncTestSupport.readLock(dir: dir)
        #expect(lock.entries.first?.sha256 == originalHash)
    }

    @Test("unpinned change with --accept-changed → exit 0, lock updated")
    func driftWithAcceptExits0() throws {
        let (dir, manifestPath) = try makeManifest(verify: true)
        let original = Data("original content".utf8)
        let changed = Data("changed content!!".utf8)
        try seedThenChange(
            dir: dir, manifestPath: manifestPath, original: original, changed: changed)
        let changedHash = SyncTestSupport.digest(changed)

        let daemon = noDownloadDaemon()
        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: true,
            send: daemon.sender(), watchdogSeconds: 5)

        #expect(result.exitCode == 0)
        #expect(daemon.addCount == 0)
        let lock = try SyncTestSupport.readLock(dir: dir)
        #expect(lock.entries.first?.sha256 == changedHash)
    }

    @Test("verify=false + changed → exit 0, lock updated, no exit-3 event")
    func verifyFalseSuppressesDrift() throws {
        let (dir, manifestPath) = try makeManifest(verify: false)
        let original = Data("original content".utf8)
        let changed = Data("changed content!!".utf8)
        try seedThenChange(
            dir: dir, manifestPath: manifestPath, original: original, changed: changed)
        let changedHash = SyncTestSupport.digest(changed)

        let daemon = noDownloadDaemon()
        let result = GohSyncCommand.run(
            manifestPath: manifestPath, base: nil, acceptChanged: false,
            send: daemon.sender(), watchdogSeconds: 5)

        #expect(result.exitCode == 0)
        #expect(!result.standardOutput.contains("hash changed for unpinned entry"))
        let lock = try SyncTestSupport.readLock(dir: dir)
        #expect(lock.entries.first?.sha256 == changedHash)
    }
}
