import CryptoKit
import Foundation
import Testing

import GohCore

@Suite("Chunk assembler")
struct ChunkAssemblerTests {

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goh-assembler-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "download.bin")
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("ranges completing out of order still hash the whole file in order")
    func outOfOrderRangesHashInOrder() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let whole = Data((0..<300).map { UInt8($0 & 0xff) })
        let ranges = [
            ByteRange(start: 0, length: 100),
            ByteRange(start: 100, length: 100),
            ByteRange(start: 200, length: 100),
        ]
        let file = try DownloadFile(path: url.path, expectedSize: 300)
        let assembler = ChunkAssembler(file: file, ranges: ranges)
        async let result = assembler.hashToCompletion()

        // Write and report the ranges out of order — last, first, middle.
        for index in [2, 0, 1] {
            let start = index * 100
            try file.write(Data(whole[start..<(start + 100)]), at: UInt64(start))
            assembler.advance(range: index, writtenBytes: 100)
        }
        assembler.finish()

        #expect(await result == .digest(sha256Hex(whole)))
    }

    @Test("an open-ended single range hashes once finish is signalled")
    func openEndedSingleRange() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let payload = Data("get over here".utf8)
        let file = try DownloadFile(path: url.path, expectedSize: nil)
        let assembler = ChunkAssembler(
            file: file, ranges: [ByteRange(start: 0, length: .max)])
        async let result = assembler.hashToCompletion()

        try file.write(payload, at: 0)
        assembler.advance(range: 0, writtenBytes: UInt64(payload.count))
        assembler.finish()

        #expect(await result == .digest(sha256Hex(payload)))
    }

    @Test("a recorded failure aborts the assembler")
    func recordedFailureAborts() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let file = try DownloadFile(path: url.path, expectedSize: 100)
        let assembler = ChunkAssembler(
            file: file, ranges: [ByteRange(start: 0, length: 100)])
        async let result = assembler.hashToCompletion()

        assembler.recordFailure(GohError(code: .timedOut, message: "the range timed out"))

        guard case .failed(let error) = await result else {
            Issue.record("expected .failed")
            return
        }
        #expect(error.code == .timedOut)
    }
}
