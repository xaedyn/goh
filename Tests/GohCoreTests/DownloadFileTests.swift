import Foundation
import Testing

import GohCore

@Suite("Download file")
struct DownloadFileTests {

    /// A path inside a fresh temporary directory; the caller removes the
    /// directory.
    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goh-file-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "download.bin")
    }

    @Test("a positioned write is read back byte-for-byte")
    func writeReadRoundTrip() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let payload = Data("the quick brown fox".utf8)
        let file = try DownloadFile(path: url.path, expectedSize: UInt64(payload.count))
        try file.write(payload, at: 0)
        let readBack = try file.read(at: 0, count: payload.count)
        try file.finish()

        #expect(readBack == payload)
        #expect(try Data(contentsOf: url) == payload)
    }

    // fileStat() returns a FileStat with correct size for a written file.
    @Test("fileStat() returns accurate size and isRegularFile for a written file")
    func fileStatReturnsAccurateSize() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let path = tmpDir.appendingPathComponent("goh-fileStat-test-\(UUID().uuidString).bin").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let file = try DownloadFile(path: path, expectedSize: nil)
        let payload = Data(repeating: 0xAB, count: 1024)
        try file.write(payload, at: 0)

        let stat = try file.fileStat()
        #expect(stat.size == 1024)
        #expect(stat.isRegularFile == true)
        #expect(stat.inode > 0)
        #expect(stat.device != 0)

        try file.finish()
    }

    // Capture≡compare parity: the fstat baseline captured at finalization (the
    // write path) MUST equal a later lstat probe of the same file (the read/
    // fast-check path). If these two `struct stat → FileStat` mappings ever drift,
    // every freshly-downloaded file would silently read back as `.changed`. This
    // locks the load-bearing invariant of the whole rapid-trust feature.
    @Test("fileStat() baseline equals a later LiveFileStatProbe lstat of the same file")
    func fileStatMatchesLstatProbe() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let path = tmpDir.appendingPathComponent("goh-parity-\(UUID().uuidString).bin").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let file = try DownloadFile(path: path, expectedSize: nil)
        try file.write(Data(repeating: 0xCD, count: 4096), at: 0)
        let captured = try file.fileStat()   // fstat on the open fd (baseline/write path)
        try file.finish()                    // fsync + close (does not alter mtime/size/inode)

        let probed = LiveFileStatProbe().probe(path: path)  // lstat on the path (compare path)
        guard case .stat(let viaLstat) = probed else {
            Issue.record("expected .stat from LiveFileStatProbe, got \(probed)")
            return
        }
        #expect(captured == viaLstat,
            "fstat baseline must equal lstat compare — divergence would mark every fresh download .changed")
    }

    @Test("opening a destination creates missing parent directories")
    func createsMissingParentDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goh-file-test-\(UUID().uuidString)")
        let url = root
            .appending(path: "nested", directoryHint: .isDirectory)
            .appending(path: "deeper", directoryHint: .isDirectory)
            .appending(path: "download.bin")
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data("parent directories are made".utf8)
        let file = try DownloadFile(path: url.path, expectedSize: UInt64(payload.count))
        try file.write(payload, at: 0)
        try file.finish()

        #expect(try Data(contentsOf: url) == payload)
    }

    @Test("writes at out-of-order offsets assemble the whole file")
    func outOfOrderPositionedWrites() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let whole = Data((0..<300).map { UInt8($0 & 0xff) })
        let file = try DownloadFile(path: url.path, expectedSize: 300)
        // Write the three 100-byte thirds in the order 2, 0, 1.
        for third in [2, 0, 1] {
            let start = third * 100
            try file.write(Data(whole[start..<(start + 100)]), at: UInt64(start))
        }
        try file.finish()

        #expect(try Data(contentsOf: url) == whole)
    }

    @Test("a payload larger than the checkpoint interval round-trips intact")
    func largePayloadCrossesCheckpoint() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // 40 × 64 KiB = 2.5 MiB — crosses the 1 MiB checkpoint boundary twice.
        let chunk = Data((0..<65_536).map { UInt8($0 & 0xff) })
        var whole = Data()
        let file = try DownloadFile(path: url.path, expectedSize: UInt64(65_536 * 40))
        for index in 0..<40 {
            try file.write(chunk, at: UInt64(index * 65_536))
            whole.append(chunk)
        }
        let readBack = try file.read(at: 0, count: whole.count)
        try file.finish()

        #expect(readBack == whole)
        #expect(try Data(contentsOf: url) == whole)
    }

    @Test("redactedDescription of openFailed carries no filesystem path")
    func redactedDescriptionOmitsPath() {
        let error = DownloadFileError.openFailed(path: "/Users/secret/private.iso", errno: 13)
        let redacted = error.redactedDescription
        #expect(!redacted.contains("/Users/secret"))
        #expect(!redacted.contains("/"))
    }
}
