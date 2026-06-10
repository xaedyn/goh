import Darwin
import Foundation
import Testing

@testable import GohCore

@Suite("GohVerifyCommand")
struct GohVerifyCommandTests {

    // MARK: - Helpers

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a valid 1-entry lockfile to `dir/gohfile.lock`.
    /// Also writes the file at `fileName` with `content`.
    /// Returns the sha256 of `content` (the correct hash for the entry).
    @discardableResult
    private func writeValidLock(
        in dir: URL,
        fileName: String = "asset.bin",
        content: Data = Data("hello".utf8),
        manifestHash: String = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ) throws -> (lockURL: URL, fileURL: URL, sha256: String) {
        let fileURL = dir.appendingPathComponent(fileName)
        try content.write(to: fileURL)

        let (sha256, size) = try FileDigest.sha256WithSize(path: fileURL.path)
        let lockText = """
            lockfileVersion = 1
            manifestHash = "\(manifestHash)"

            [[entry]]
            url = "https://example.org/\(fileName)"
            path = "\(fileName)"
            sha256 = "\(sha256)"
            size = \(size)
            downloadedAt = "2026-05-30T00:00:00Z"
            """
        let lockURL = dir.appendingPathComponent("gohfile.lock")
        try lockText.write(to: lockURL, atomically: true, encoding: .utf8)
        return (lockURL, fileURL, sha256)
    }

    // MARK: - AC2: all-match → exit 0

    @Test("all entries match → exit 0, OK lines printed")
    func allEntriesMatch() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (lockURL, _, _) = try writeValidLock(in: dir)

        let r = GohVerifyCommand.run(lockPath: lockURL.path, strictUntracked: false)
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("OK"))
    }

    @Test("empty lockfile → exit 0, '0 entries, all verified' message")
    func emptyLock() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockText = """
            lockfileVersion = 1
            manifestHash = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            """
        let lockURL = dir.appendingPathComponent("gohfile.lock")
        try lockText.write(to: lockURL, atomically: true, encoding: .utf8)

        let r = GohVerifyCommand.run(lockPath: lockURL.path, strictUntracked: false)
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("0 entries, all verified"))
    }

    // MARK: - AC2: content mismatch → exit 2

    @Test("content corrupted → exit 2, FAILED line with expected and actual")
    func contentCorrupted() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (lockURL, fileURL, expectedHash) = try writeValidLock(in: dir)

        // Overwrite file with different content
        try Data("corrupted!".utf8).write(to: fileURL)

        let r = GohVerifyCommand.run(lockPath: lockURL.path, strictUntracked: false)
        #expect(r.exitCode == 2)
        #expect(r.standardOutput.contains("FAILED"))
        #expect(r.standardOutput.contains("expected"))
        #expect(r.standardOutput.contains(expectedHash))
        #expect(r.standardOutput.contains("actual"))
    }

    // MARK: - AC2: missing file → exit 9

    @Test("locked file deleted → exit 9, MISSING line")
    func missingFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (lockURL, fileURL, _) = try writeValidLock(in: dir)
        try FileManager.default.removeItem(at: fileURL)

        let r = GohVerifyCommand.run(lockPath: lockURL.path, strictUntracked: false)
        #expect(r.exitCode == 9)
        #expect(r.standardOutput.contains("MISSING"))
    }

    // MARK: - Precedence: MISSING > FAILED

    @Test("one MISSING + one FAILED → exit 9 (MISSING takes precedence)")
    func missingPrecedenceOverFailed() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a valid lock with two entries
        let file1URL = dir.appendingPathComponent("a.bin")
        let file2URL = dir.appendingPathComponent("b.bin")
        try Data("content-a".utf8).write(to: file1URL)
        try Data("content-b".utf8).write(to: file2URL)

        let (sha1, size1) = try FileDigest.sha256WithSize(path: file1URL.path)
        let (sha2, size2) = try FileDigest.sha256WithSize(path: file2URL.path)

        let lockText = """
            lockfileVersion = 1
            manifestHash = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

            [[entry]]
            url = "https://example.org/a.bin"
            path = "a.bin"
            sha256 = "\(sha1)"
            size = \(size1)
            downloadedAt = "2026-05-30T00:00:00Z"

            [[entry]]
            url = "https://example.org/b.bin"
            path = "b.bin"
            sha256 = "\(sha2)"
            size = \(size2)
            downloadedAt = "2026-05-30T00:00:00Z"
            """
        let lockURL = dir.appendingPathComponent("gohfile.lock")
        try lockText.write(to: lockURL, atomically: true, encoding: .utf8)

        // Delete a.bin (MISSING) and corrupt b.bin (FAILED)
        try FileManager.default.removeItem(at: file1URL)
        try Data("corrupted!".utf8).write(to: file2URL)

        let r = GohVerifyCommand.run(lockPath: lockURL.path, strictUntracked: false)
        #expect(r.exitCode == 9)
        #expect(r.standardOutput.contains("MISSING"))
        #expect(r.standardOutput.contains("FAILED"))
    }

    // MARK: - Lock load failure → exit 6

    @Test("missing lock file → exit 6")
    func missingLockFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockPath = dir.appendingPathComponent("gohfile.lock").path
        let r = GohVerifyCommand.run(lockPath: lockPath, strictUntracked: false)
        #expect(r.exitCode == 6)
        // Diagnostic errors go to stderr, never stdout, so piping verify output
        // (e.g. into a parser) is not polluted by error text.
        #expect(r.standardError.contains("no gohfile.lock"))
        #expect(!r.standardOutput.contains("no gohfile.lock"))
    }

    @Test("unknown lockfileVersion → exit 6 (NOT 1), no quarantine")
    func unknownLockfileVersion() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockText = """
            lockfileVersion = 99
            manifestHash = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            """
        let lockURL = dir.appendingPathComponent("gohfile.lock")
        try lockText.write(to: lockURL, atomically: true, encoding: .utf8)

        let r = GohVerifyCommand.run(lockPath: lockURL.path, strictUntracked: false)
        #expect(r.exitCode == 6)
        // Must NOT be exit 1
        #expect(r.exitCode != 1)
        // Should say unsupported version (on stderr) and not quarantine the file
        #expect(r.standardError.contains("unsupported"))
        #expect(!r.standardOutput.contains("unsupported"))
        // Lock file should still exist (not quarantined)
        #expect(FileManager.default.fileExists(atPath: lockURL.path))
    }

    @Test("corrupt/unparseable lock → exit 6, quarantined to gohfile.lock.corrupt-*")
    func corruptLockQuarantined() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockText = "this is not TOML at all @@@@###"
        let lockURL = dir.appendingPathComponent("gohfile.lock")
        try lockText.write(to: lockURL, atomically: true, encoding: .utf8)

        let r = GohVerifyCommand.run(lockPath: lockURL.path, strictUntracked: false)
        #expect(r.exitCode == 6)
        #expect(r.standardError.contains("corrupt"))
        #expect(!r.standardOutput.contains("corrupt"))

        // Original lock file should be gone (quarantined)
        #expect(!FileManager.default.fileExists(atPath: lockURL.path))

        // A quarantined file should exist
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let quarantined = contents.filter {
            $0.hasPrefix("gohfile.lock.corrupt-")
        }
        #expect(!quarantined.isEmpty, "Expected a quarantined file matching gohfile.lock.corrupt-*")
    }

    // MARK: - Stale manifestHash → exit 6

    @Test("gohfile.toml alongside whose manifestHash differs → exit 6 (stale)")
    func staleManifestHash() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a lock with a manifestHash that won't match any toml we write
        let lockText = """
            lockfileVersion = 1
            manifestHash = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
            """
        let lockURL = dir.appendingPathComponent("gohfile.lock")
        try lockText.write(to: lockURL, atomically: true, encoding: .utf8)

        // Write a gohfile.toml alongside it (its real hash will differ from "0000...")
        let tomlText = """
            version = 1

            [[asset]]
            url = "https://example.org/a.bin"
            path = "a.bin"
            """
        let tomlURL = dir.appendingPathComponent("gohfile.toml")
        try tomlText.write(to: tomlURL, atomically: true, encoding: .utf8)

        let r = GohVerifyCommand.run(lockPath: lockURL.path, strictUntracked: false)
        #expect(r.exitCode == 6)
        #expect(r.standardError.contains("stale"))
        #expect(!r.standardOutput.contains("stale"))
    }

    // MARK: - --strict-untracked → exit 10

    @Test("--strict-untracked with unlisted file → exit 10")
    func strictUntrackedExtraFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (lockURL, _, _) = try writeValidLock(in: dir, fileName: "asset.bin")

        // Write an extra file not in the lock
        try Data("extra".utf8).write(to: dir.appendingPathComponent("extra.bin"))

        let r = GohVerifyCommand.run(lockPath: lockURL.path, strictUntracked: true)
        #expect(r.exitCode == 10)
        #expect(r.standardOutput.contains("untracked"))
    }

    @Test("without --strict-untracked, unlisted file → exit 0 (untracked is informational)")
    func withoutStrictUntrackedExtraFileIsOk() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (lockURL, _, _) = try writeValidLock(in: dir, fileName: "asset.bin")

        // Write an extra file not in the lock
        try Data("extra".utf8).write(to: dir.appendingPathComponent("extra.bin"))

        let r = GohVerifyCommand.run(lockPath: lockURL.path, strictUntracked: false)
        #expect(r.exitCode == 0)
    }

    // MARK: - Precedence: MISSING > FAILED > untracked (exit 9 beats 10)

    @Test("MISSING + untracked → exit 9 (MISSING beats untracked)")
    func missingBeatUntracked() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (lockURL, fileURL, _) = try writeValidLock(in: dir, fileName: "asset.bin")
        try FileManager.default.removeItem(at: fileURL)

        // Add untracked file
        try Data("extra".utf8).write(to: dir.appendingPathComponent("extra.bin"))

        let r = GohVerifyCommand.run(lockPath: lockURL.path, strictUntracked: true)
        #expect(r.exitCode == 9)
    }

    @Test("FAILED + untracked → exit 2 (FAILED beats untracked)")
    func failedBeatUntracked() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (lockURL, fileURL, _) = try writeValidLock(in: dir, fileName: "asset.bin")
        try Data("corrupted!".utf8).write(to: fileURL)

        // Add untracked file
        try Data("extra".utf8).write(to: dir.appendingPathComponent("extra.bin"))

        let r = GohVerifyCommand.run(lockPath: lockURL.path, strictUntracked: true)
        #expect(r.exitCode == 2)
    }

    // MARK: - Concurrent lock acquisition → exit 7

    @Test("concurrent exclusive lock held on the sidecar → exit 7")
    func concurrentLockHeld() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (lockURL, _, _) = try writeValidLock(in: dir)

        // Hold an exclusive lock on the STABLE sidecar (gohfile.lock.lock) — the
        // same inode verify now contends on. Locking gohfile.lock directly would
        // no longer block verify, because verify locks the sidecar.
        let sidecar = dir.appendingPathComponent("gohfile.lock.lock").path
        let fd = open(sidecar, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        #expect(fd >= 0, "open must succeed for this test to be meaningful")
        defer { close(fd) }

        let flockResult = flock(fd, LOCK_EX | LOCK_NB)
        #expect(flockResult == 0, "exclusive flock must succeed for this test to be meaningful")
        defer { flock(fd, LOCK_UN) }

        let r = GohVerifyCommand.run(lockPath: lockURL.path, strictUntracked: false)
        #expect(r.exitCode == 7)
        #expect(r.standardError.contains("another goh"))
        #expect(!r.standardOutput.contains("another goh"))
    }

    // MARK: - Parser routing

    @Test("parse(['verify', '--strict-untracked']) routes to verify with strictUntracked: true")
    func parserRoutesVerifyStrictUntracked() {
        // Test via full GohCommandLine.run() with a non-existent lock file.
        // A missing lock → exit 6, proving routing worked (not 64 = parse error, not 1 = transport).
        let r = GohCommandLine(
            arguments: ["verify", "--strict-untracked"],
            send: { _ in fatalError("should not reach daemon") }
        ).run()
        // exit 6 = lock missing/corrupt (verify was routed and ran)
        // exit 64 = parse error (verify was not recognized)
        #expect(r.exitCode == 6, "expected exit 6 (missing lock), got \(r.exitCode)")
    }

    @Test("parse(['verify']) routes to verify with default lockPath and strictUntracked: false")
    func parserRoutesVerifyDefaults() {
        let r = GohCommandLine(
            arguments: ["verify"],
            send: { _ in fatalError("should not reach daemon") }
        ).run()
        // The default lock is ./gohfile.lock in cwd; if it doesn't exist → exit 6.
        // Accept both 6 (lock missing) and 0 (lock happens to exist in cwd during test).
        #expect(r.exitCode == 6 || r.exitCode == 0)
        #expect(r.exitCode != 64, "verify was not parsed (got parse error)")
    }

    @Test("parse(['verify', '/tmp/some.lock']) routes to verify with explicit lockPath")
    func parserRoutesVerifyExplicitPath() {
        let r = GohCommandLine(
            arguments: ["verify", "/tmp/goh-verify-nonexistent-\(UUID().uuidString).lock"],
            send: { _ in fatalError("should not reach daemon") }
        ).run()
        #expect(r.exitCode == 6)
        #expect(r.exitCode != 64, "verify was not parsed")
    }

    @Test("usage text mentions 'goh verify'")
    func usageTextMentionsVerify() {
        let r = GohCommandLine(
            arguments: ["--help"],
            send: { _ in fatalError("should not reach daemon") }
        ).run()
        #expect(r.standardOutput.contains("goh verify"))
    }
}
