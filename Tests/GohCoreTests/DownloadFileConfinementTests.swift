import Foundation
import Testing
@testable import GohCore

/// Phase 3 (trust core): the daemon's write path must never follow a symlink in
/// any destination path component. These tests are the running-code gate — the
/// load-bearing case is the symlinked *intermediate* directory (it proves the
/// parent-fd-relative descent, not merely an O_NOFOLLOW on the final open).
@Suite("DownloadFile confinement", .serialized)
struct DownloadFileConfinementTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("normal write to a real path succeeds (regression guard)")
    func normalWriteSucceeds() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("file.bin").path
        let file = try DownloadFile(path: dest, expectedSize: 4, truncate: true)
        try file.write(Data([1, 2, 3, 4]), at: 0)
        try file.finish()
        #expect(FileManager.default.fileExists(atPath: dest))
    }

    @Test("fresh download CREATES missing intermediate dirs (regression: descent must mkdir, not bail)")
    func freshDownloadCreatesMissingDirs() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // none of a/b/c pre-exist
        let dest = dir.appendingPathComponent("a/b/c/file.bin").path
        let file = try DownloadFile(path: dest, expectedSize: 4, truncate: true)
        try file.write(Data([9, 9, 9, 9]), at: 0)
        try file.finish()
        #expect(FileManager.default.fileExists(atPath: dest))
    }

    @Test("resume reopen (truncate:false) of an existing file succeeds (regression)")
    func resumeReopenSucceeds() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("resume.bin").path
        let f1 = try DownloadFile(path: dest, expectedSize: 4, truncate: true)
        try f1.write(Data([1, 2, 3, 4]), at: 0); try f1.finish()
        // Must NOT fail (no O_EXCL): resume reopens the same destination in place.
        let f2 = try DownloadFile(path: dest, expectedSize: nil, truncate: false)
        try f2.write(Data([5, 6]), at: 4); try f2.finish()
        #expect(FileManager.default.fileExists(atPath: dest))
    }

    @Test("symlinked final component is refused")
    func symlinkFinalRefused() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let outside = try tempDir(); defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("escaped.bin").path
        let dest = dir.appendingPathComponent("link.bin").path
        try FileManager.default.createSymbolicLink(atPath: dest, withDestinationPath: target)
        #expect(throws: GohError.self) {
            _ = try DownloadFile(path: dest, expectedSize: 4, truncate: true)
        }
        #expect(!FileManager.default.fileExists(atPath: target))  // nothing written outside
    }

    @Test("symlinked intermediate (parent) directory component is refused — LOAD-BEARING")
    func symlinkIntermediateRefused() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let outside = try tempDir(); defer { try? FileManager.default.removeItem(at: outside) }
        let linkPath = dir.appendingPathComponent("evil").path
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: outside.path)
        let dest = dir.appendingPathComponent("evil/file.bin").path
        #expect(throws: GohError.self) {
            _ = try DownloadFile(path: dest, expectedSize: 4, truncate: true)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("file.bin").path))
    }

    @Test("TOCTOU: a real parent dir swapped for a symlink AFTER a lexical check is caught at open time")
    func toctouSymlinkSwap() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let outside = try tempDir(); defer { try? FileManager.default.removeItem(at: outside) }
        let realParent = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
        let dest = realParent.appendingPathComponent("file.bin").path
        try FileManager.default.removeItem(at: realParent)  // swap real dir → symlink to outside
        try FileManager.default.createSymbolicLink(atPath: realParent.path, withDestinationPath: outside.path)
        #expect(throws: GohError.self) {
            _ = try DownloadFile(path: dest, expectedSize: 4, truncate: true)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("file.bin").path))
    }

    @Test("the refusal is specifically symlinkComponentRefused, not a generic open failure")
    func refusalIsSymlinkCode() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let outside = try tempDir(); defer { try? FileManager.default.removeItem(at: outside) }
        let dest = dir.appendingPathComponent("link.bin").path
        try FileManager.default.createSymbolicLink(
            atPath: dest, withDestinationPath: outside.appendingPathComponent("x").path)
        do {
            _ = try DownloadFile(path: dest, expectedSize: 4, truncate: true)
            Issue.record("expected throw")
        } catch let e as GohError {
            #expect(e.code == .symlinkComponentRefused)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}
