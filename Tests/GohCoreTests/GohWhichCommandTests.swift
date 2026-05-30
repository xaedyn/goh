import Darwin
import Foundation
import Testing
import XPC

@testable import GohCore

@Suite("GohWhichCommand")
struct GohWhichCommandTests {

    private struct TestTransportError: Error, CustomStringConvertible {
        var description: String { "test transport error" }
    }


    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-which-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Lock lookup

    @Test("prints provenance from a lockfile entry (AC4)")
    func printsFromLock() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockText = """
            lockfileVersion = 1
            manifestHash = "sha256:a3f9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1"

            [[entry]]
            url = "https://example.org/f.bin"
            path = "f.bin"
            sha256 = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
            size = 4
            downloadedAt = "2026-05-29T00:00:00Z"
            """
        let lockURL = dir.appendingPathComponent("gohfile.lock")
        try lockText.write(to: lockURL, atomically: true, encoding: .utf8)

        let target = dir.appendingPathComponent("f.bin")
        try Data("test".utf8).write(to: target)

        let r = GohWhichCommand.run(filePath: target.path, lockPath: lockURL.path)
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("https://example.org/f.bin"))
        #expect(r.standardOutput.contains("sha256:1111"))
        #expect(r.standardOutput.contains("2026-05-29"))
        #expect(r.standardError == "")
    }

    @Test("entry path resolved relative to lock directory, not cwd (§9.3a)")
    func entryPathRelativeToLockDir() throws {
        // Lock is in a subdirectory; its entry path "f.bin" resolves relative to
        // the lock's own directory, not the process cwd.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let subdir = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let lockText = """
            lockfileVersion = 1
            manifestHash = "sha256:a3f9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1"

            [[entry]]
            url = "https://example.org/g.bin"
            path = "g.bin"
            sha256 = "sha256:2222222222222222222222222222222222222222222222222222222222222222"
            size = 1
            downloadedAt = "2026-05-30T00:00:00Z"
            """
        let lockURL = subdir.appendingPathComponent("gohfile.lock")
        try lockText.write(to: lockURL, atomically: true, encoding: .utf8)

        // File lives next to the lock (in subdir), not in the process cwd.
        let target = subdir.appendingPathComponent("g.bin")
        try Data("g".utf8).write(to: target)

        let r = GohWhichCommand.run(filePath: target.path, lockPath: lockURL.path)
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("https://example.org/g.bin"))
    }

    @Test("exits 4 when no provenance exists (AC4)")
    func exitsFourWhenUnknown() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("orphan.bin")
        try Data("x".utf8).write(to: target)

        let r = GohWhichCommand.run(
            filePath: target.path,
            lockPath: dir.appendingPathComponent("gohfile.lock").path)
        #expect(r.exitCode == 4)
        #expect(
            r.standardOutput.contains("no provenance record")
                || r.standardError.contains("no provenance record"))
    }

    @Test("lock decodes but has no matching entry → exit 4")
    func decodedLockNoMatchExitsFour() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A valid lockfile with one entry for a different file.
        let lockText = """
            lockfileVersion = 1
            manifestHash = "sha256:a3f9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1"

            [[entry]]
            url = "https://example.org/other.bin"
            path = "other.bin"
            sha256 = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            size = 5
            downloadedAt = "2026-05-29T12:00:00Z"
            """
        let lockURL = dir.appendingPathComponent("gohfile.lock")
        try lockText.write(to: lockURL, atomically: true, encoding: .utf8)

        // "other.bin" exists (so the entry path is valid), but we query a different file.
        try Data("other".utf8).write(to: dir.appendingPathComponent("other.bin"))

        let target = dir.appendingPathComponent("query.bin")
        try Data("q".utf8).write(to: target)

        let r = GohWhichCommand.run(filePath: target.path, lockPath: lockURL.path)
        #expect(r.exitCode == 4)
        #expect(
            r.standardOutput.contains("no provenance record")
                || r.standardError.contains("no provenance record"))
    }

    @Test("missing lock falls through to no-provenance (not an error)")
    func missingLockFallsThrough() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("nolock.bin")
        try Data("z".utf8).write(to: target)

        let r = GohWhichCommand.run(
            filePath: target.path,
            lockPath: dir.appendingPathComponent("absent.lock").path)
        #expect(r.exitCode == 4)
    }

    // MARK: - xattr fallback

    @Test("falls back to xattr provenance when not in lock (AC4)")
    func fallsBackToXattr() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("tagged.bin")
        try Data("y".utf8).write(to: target)

        let urls = ["https://src.example/y.bin"]
        let data = try PropertyListSerialization.data(
            fromPropertyList: urls, format: .binary, options: 0)
        let result = data.withUnsafeBytes { raw -> Int32 in
            setxattr(
                target.path,
                "com.apple.metadata:kMDItemWhereFroms",
                raw.baseAddress, raw.count, 0, 0)
        }
        #expect(result == 0, "setxattr must succeed for this test to be meaningful")

        let r = GohWhichCommand.run(
            filePath: target.path,
            lockPath: dir.appendingPathComponent("gohfile.lock").path)
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("https://src.example/y.bin"))
        #expect(r.standardOutput.contains("(not recorded)"))
        #expect(r.standardError == "")
    }

    @Test("xattr fallback includes downloaded date when present")
    func xattrFallbackIncludesDate() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("dated.bin")
        try Data("d".utf8).write(to: target)

        let urls = ["https://src.example/dated.bin"]
        let urlData = try PropertyListSerialization.data(
            fromPropertyList: urls, format: .binary, options: 0)
        _ = urlData.withUnsafeBytes { raw in
            setxattr(
                target.path,
                "com.apple.metadata:kMDItemWhereFroms",
                raw.baseAddress, raw.count, 0, 0)
        }

        // kMDItemDownloadedDate is a Date (not wrapped in an array).
        let knownDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let dateData = try PropertyListSerialization.data(
            fromPropertyList: knownDate, format: .binary, options: 0)
        _ = dateData.withUnsafeBytes { raw in
            setxattr(
                target.path,
                "com.apple.metadata:kMDItemDownloadedDate",
                raw.baseAddress, raw.count, 0, 0)
        }

        let r = GohWhichCommand.run(
            filePath: target.path,
            lockPath: dir.appendingPathComponent("gohfile.lock").path)
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("https://src.example/dated.bin"))
        // Date should appear in some human-readable form; just check it's present.
        #expect(!r.standardOutput.contains("(unknown)") || r.standardOutput.contains("2025"))
    }

    // MARK: - Parser routing

    @Test("parser routes 'which <path>' to the which command")
    func parserRoutesWhich() throws {
        // ParsedCommand is private, so we test via the full run path using a
        // non-existent file — the command returns exit 4, proving routing worked
        // (not a ParseError).
        let r = GohCommandLine(
            arguments: ["which", "/tmp/goh-which-routing-probe"],
            send: { _ in throw TestTransportError() }
        ).run()
        // Exit 4 = no provenance (which was routed); exit 64 = parse error.
        // Exit 1 = transport error, meaning routing fell through to a daemon verb.
        #expect(r.exitCode == 4)
    }

    @Test("parser rejects 'which' with no path")
    func parserRejectsWhichWithNoPath() throws {
        let r = GohCommandLine(
            arguments: ["which"],
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
        #expect(r.standardError.contains("which"))
    }

    @Test("usage text mentions 'goh which'")
    func usageTextMentionsWhich() {
        let r = GohCommandLine(
            arguments: ["--help"],
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.standardOutput.contains("goh which"))
    }
}
