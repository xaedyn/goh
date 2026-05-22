import CryptoKit
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

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("a single append writes the bytes and reports the streaming SHA-256")
    func singleAppend() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let payload = Data("get over here".utf8)
        let file = try DownloadFile(path: url.path, expectedSize: UInt64(payload.count))
        try file.append(payload)
        let digest = try file.finalize()

        #expect(try Data(contentsOf: url) == payload)
        #expect(digest == sha256Hex(payload))
    }

    @Test("appends accumulate in order and the digest spans them all")
    func multipleAppends() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let chunks = [Data("alpha".utf8), Data("beta".utf8), Data("gamma".utf8)]
        let whole = chunks.reduce(Data(), +)
        let file = try DownloadFile(path: url.path, expectedSize: nil)
        for chunk in chunks {
            try file.append(chunk)
        }
        let digest = try file.finalize()

        #expect(try Data(contentsOf: url) == whole)
        #expect(digest == sha256Hex(whole))
        #expect(file.bytesWritten == UInt64(whole.count))
    }

    @Test("a payload larger than the checkpoint interval round-trips intact")
    func largePayloadCrossesCheckpoint() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // 40 × 64 KiB = 2.5 MiB — crosses the 1 MiB checkpoint boundary twice.
        let chunk = Data((0..<65_536).map { UInt8($0 & 0xff) })
        var whole = Data()
        let file = try DownloadFile(path: url.path, expectedSize: UInt64(65_536 * 40))
        for _ in 0..<40 {
            try file.append(chunk)
            whole.append(chunk)
        }
        let digest = try file.finalize()

        #expect(try Data(contentsOf: url) == whole)
        #expect(digest == sha256Hex(whole))
    }
}
