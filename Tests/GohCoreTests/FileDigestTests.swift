import Foundation
import Testing
import GohCore

/// Mutable box for capturing test state inside non-escaping streaming closures.
/// A plain `var` cannot be mutated by-reference cleanly under -warnings-as-errors
/// from within the closures; the box holds the running state instead.
private final class DigestTestBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

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

    @Test("onBytesHashed sums to file size; digest unchanged vs no-callback call")
    func onBytesHashedSumsToSize() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // 5 MiB so the 1 MiB chunk loop runs several iterations.
        let fiveMiB = 5 * 1024 * 1024
        try Data(repeating: 0x5C, count: fiveMiB).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let baseline = try FileDigest.sha256WithSize(path: tmp.path)

        let reported = DigestTestBox(0)
        let (digest, size) = try FileDigest.sha256WithSize(
            path: tmp.path,
            onBytesHashed: { reported.value += $0 })

        #expect(size == fiveMiB)
        #expect(reported.value == fiveMiB)       // sum of chunk counts equals file size
        #expect(digest == baseline.0)            // digest identical to no-callback call
    }

    @Test("isCancelled true throws DigestError.cancelled")
    func cancelThrows() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Multi-MiB so cancellation fires partway, not on an empty read.
        let fourMiB = 4 * 1024 * 1024
        try Data(repeating: 0x11, count: fourMiB).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Flip to cancelled on the very first check (top of first chunk).
        let cancelled = DigestTestBox(true)
        #expect(throws: FileDigest.DigestError.cancelled) {
            _ = try FileDigest.sha256WithSize(
                path: tmp.path,
                isCancelled: { cancelled.value })
        }
    }
}
