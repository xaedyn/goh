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
