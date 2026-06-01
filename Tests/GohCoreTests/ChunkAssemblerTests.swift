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
        let file = try DownloadFile(path: url.path, expectedSize: 300)
        let assembler = ChunkAssembler(file: file, totalBytes: 300)
        async let result = assembler.hashToCompletion()

        // Write and report the ranges out of order — last, first, middle.
        for index in [2, 0, 1] {
            let start = UInt64(index) * 100
            try file.write(Data(whole[Int(start)..<Int(start + 100)]), at: start)
            assembler.complete(interval: ByteInterval(start: start, length: 100))
        }
        assembler.finish()

        #expect(await result == .digest(sha256Hex(whole)))
    }

    @Test("an open-ended single range hashes once finish is signalled")
    func openEndedSingleRange() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let payload = Data("the quick brown fox".utf8)
        let file = try DownloadFile(path: url.path, expectedSize: nil)
        let assembler = ChunkAssembler(file: file, totalBytes: nil)
        async let result = assembler.hashToCompletion()

        try file.write(payload, at: 0)
        assembler.complete(interval: ByteInterval(start: 0, length: UInt64(payload.count)))
        assembler.finish()

        #expect(await result == .digest(sha256Hex(payload)))
    }

    @Test("a fixed-length range that finishes short fails instead of digesting partial bytes")
    func incompleteFixedLengthRangeFails() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let payload = Data("short".utf8)
        let file = try DownloadFile(path: url.path, expectedSize: 100)
        let assembler = ChunkAssembler(file: file, totalBytes: 100)
        async let result = assembler.hashToCompletion()

        try file.write(payload, at: 0)
        assembler.complete(interval: ByteInterval(start: 0, length: UInt64(payload.count)))
        assembler.finish()

        guard case .failed(let error) = await result else {
            Issue.record("expected .failed for an incomplete fixed-length range")
            return
        }
        #expect(error.code == .connectionFailed)
    }

    @Test("a recorded failure aborts the assembler")
    func recordedFailureAborts() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let file = try DownloadFile(path: url.path, expectedSize: 100)
        let assembler = ChunkAssembler(file: file, totalBytes: 100)
        async let result = assembler.hashToCompletion()

        assembler.recordFailure(GohError(code: .timedOut, message: "the range timed out"))

        guard case .failed(let error) = await result else {
            Issue.record("expected .failed")
            return
        }
        #expect(error.code == .timedOut)
    }

    @Test("interval-set frontier: byte-0 interval end is the frontier")
    func intervalSetFrontier() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let data = Data((0..<300).map { UInt8($0 & 0xff) })
        let file = try DownloadFile(path: url.path, expectedSize: 300)
        let assembler = ChunkAssembler(file: file, totalBytes: 300)
        async let result = assembler.hashToCompletion()
        try file.write(data, at: 0)
        assembler.complete(interval: ByteInterval(start: 0, length: 300))
        assembler.finish()
        #expect(await result == .digest(sha256Hex(data)))
    }

    @Test("interval-set: out-of-order completion hashes in order")
    func intervalSetOutOfOrder() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let chunk = UInt64(100)
        let total = chunk * 3
        let whole = Data((0..<Int(total)).map { UInt8($0 & 0xff) })
        let file = try DownloadFile(path: url.path, expectedSize: total)
        let assembler = ChunkAssembler(file: file, totalBytes: total)
        async let result = assembler.hashToCompletion()
        for idx in [2, 0, 1] {
            let start = UInt64(idx) * chunk
            try file.write(Data(whole[Int(start)..<Int(start + chunk)]), at: start)
            assembler.complete(interval: ByteInterval(start: start, length: chunk))
        }
        assembler.finish()
        #expect(await result == .digest(sha256Hex(whole)))
    }

    @Test("interval-set: end condition needs the gap filled")
    func intervalSetEndCondition() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let total: UInt64 = 200
        let data = Data(repeating: 0x42, count: Int(total))
        let file = try DownloadFile(path: url.path, expectedSize: total)
        let assembler = ChunkAssembler(file: file, totalBytes: total)
        async let result = assembler.hashToCompletion()
        try file.write(data.prefix(50), at: 0)
        assembler.complete(interval: ByteInterval(start: 0, length: 50))
        try file.write(Data(data[100..<200]), at: 100)
        assembler.complete(interval: ByteInterval(start: 100, length: 100))
        // Gap [50,100) still missing. Now fill it.
        try file.write(Data(data[50..<100]), at: 50)
        assembler.complete(interval: ByteInterval(start: 50, length: 50))
        assembler.finish()
        #expect(await result == .digest(sha256Hex(data)))
    }
}
