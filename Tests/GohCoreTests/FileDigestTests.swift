import Foundation
import Testing
import GohCore

@Suite("FileDigest")
struct FileDigestTests {
    @Test("computes sha256 of a known byte string")
    func computesKnownHash() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("hello goh\n".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (digest, size) = try FileDigest.sha256WithSize(path: tmp.path)
        #expect(digest.hasPrefix("sha256:"))
        #expect(size == 10)
    }

    @Test("hash is stable across two reads")
    func stableHash() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("repeatable".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (d1, _) = try FileDigest.sha256WithSize(path: tmp.path)
        let (d2, _) = try FileDigest.sha256WithSize(path: tmp.path)
        #expect(d1 == d2)
    }

    @Test("throws for a nonexistent file")
    func throwsForMissing() {
        #expect(throws: Error.self) { _ = try FileDigest.sha256WithSize(path: "/nonexistent/path/xyz") }
    }

    @Test("computes correct hash for empty file")
    func emptyFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (digest, size) = try FileDigest.sha256WithSize(path: tmp.path)
        #expect(size == 0)
        #expect(digest == "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("handles files larger than 1 MiB chunk boundary")
    func multiChunkFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // 3 MiB of repeating 0xAB bytes — crosses the 1 MiB chunk boundary twice.
        let threeMiB = 3 * 1024 * 1024
        let data = Data(repeating: 0xAB, count: threeMiB)
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (digest1, size) = try FileDigest.sha256WithSize(path: tmp.path)
        let (digest2, _) = try FileDigest.sha256WithSize(path: tmp.path)
        #expect(size == threeMiB)
        #expect(digest1.hasPrefix("sha256:"))
        #expect(digest1.count == 7 + 64)
        #expect(digest1 == digest2)
    }
}
