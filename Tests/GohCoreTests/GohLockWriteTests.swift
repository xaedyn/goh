import Foundation
import Testing

@testable import GohCore

/// T6.5 — atomic `gohfile.lock` write (tmp + fsync + rename(2) + dir fsync).
@Suite("GohLockWrite")
struct GohLockWriteTests {

    @Test("an atomically written lock round-trips through the decoder")
    func atomicWriteRoundTrips() throws {
        let dir = try SyncTestSupport.makeDir()
        let lockPath = dir + "/gohfile.lock"

        let lock = LockfileCodec.Lockfile(
            manifestHash: "sha256:" + String(repeating: "a", count: 64),
            entries: [
                LockfileCodec.LockEntry(
                    url: "https://example.com/one.bin",
                    path: "one.bin",
                    sha256: "sha256:" + String(repeating: "b", count: 64),
                    size: 1234,
                    downloadedAt: "2026-05-30T12:00:00Z"),
                LockfileCodec.LockEntry(
                    url: "https://example.com/two.bin",
                    path: "sub/two.bin",
                    sha256: "sha256:" + String(repeating: "c", count: 64),
                    size: 5678,
                    downloadedAt: "2026-05-30T12:01:00Z"),
            ])

        try GohSyncCommand.writeLockAtomically(lock, to: lockPath)

        // The destination exists and the temp file is gone.
        #expect(FileManager.default.fileExists(atPath: lockPath))
        #expect(!FileManager.default.fileExists(atPath: lockPath + ".tmp"))

        // Re-read and confirm the decoder round-trips every field.
        let decoded = try SyncTestSupport.readLock(dir: dir)
        #expect(decoded.lockfileVersion == 1)
        #expect(decoded.manifestHash == lock.manifestHash)
        #expect(decoded.entries.count == 2)
        #expect(decoded.entries[0].url == "https://example.com/one.bin")
        #expect(decoded.entries[0].path == "one.bin")
        #expect(decoded.entries[0].size == 1234)
        #expect(decoded.entries[1].path == "sub/two.bin")
        #expect(decoded.entries[1].sha256 == lock.entries[1].sha256)
    }

    @Test("a second atomic write replaces the prior lock in place")
    func atomicWriteReplaces() throws {
        let dir = try SyncTestSupport.makeDir()
        let lockPath = dir + "/gohfile.lock"

        let first = LockfileCodec.Lockfile(
            manifestHash: "sha256:" + String(repeating: "1", count: 64), entries: [])
        try GohSyncCommand.writeLockAtomically(first, to: lockPath)

        let second = LockfileCodec.Lockfile(
            manifestHash: "sha256:" + String(repeating: "2", count: 64),
            entries: [
                LockfileCodec.LockEntry(
                    url: "u", path: "p",
                    sha256: "sha256:" + String(repeating: "d", count: 64),
                    size: 9, downloadedAt: "2026-05-30T00:00:00Z"),
            ])
        try GohSyncCommand.writeLockAtomically(second, to: lockPath)

        let decoded = try SyncTestSupport.readLock(dir: dir)
        #expect(decoded.manifestHash == second.manifestHash)
        #expect(decoded.entries.count == 1)
        #expect(!FileManager.default.fileExists(atPath: lockPath + ".tmp"))
    }
}
