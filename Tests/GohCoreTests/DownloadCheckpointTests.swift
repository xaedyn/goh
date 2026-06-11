import Foundation
import Testing

import GohCore

@Suite("Download checkpoint")
struct DownloadCheckpointTests {

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goh-checkpoint-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sampleCheckpoint() -> DownloadCheckpoint {
        var checkpoint = DownloadCheckpoint(
            jobID: 7,
            url: "https://example.com/large.iso",
            destination: "/tmp/large.iso",
            partialFileSize: 4 << 20,
            totalBytes: 8 << 20,
            strongETag: "\"abc123\"",
            lastModified: "Sun, 24 May 2026 12:00:00 GMT",
            completedPieces: [
                CheckpointPiece(start: 0, length: 1 << 20),
                CheckpointPiece(start: 3 << 20, length: 1 << 20),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        checkpoint.recordCompletedPiece(start: 1 << 20, length: 2 << 20)
        return checkpoint
    }

    @Test("recording pieces keeps them sorted and coalesces overlaps and adjacency")
    func completedPiecesCoalesce() {
        var checkpoint = DownloadCheckpoint(
            jobID: 1,
            url: "https://example.com/f",
            destination: "/tmp/f",
            partialFileSize: 5 << 20,
            totalBytes: 5 << 20)

        checkpoint.recordCompletedPiece(start: 3 << 20, length: 1 << 20)
        checkpoint.recordCompletedPiece(start: 0, length: 1 << 20)
        checkpoint.recordCompletedPiece(start: 1 << 20, length: 2 << 20)
        checkpoint.recordCompletedPiece(start: 2 << 20, length: 3 << 20)
        checkpoint.recordCompletedPiece(start: 123, length: 0)

        #expect(checkpoint.completedPieces == [
            CheckpointPiece(start: 0, length: 5 << 20),
        ])
    }

    @Test("init merges unsorted/overlapping input identically to sequential recordCompletedPiece, preserving updatedAt")
    func initMergesInOnePassPreservingUpdatedAt() {
        let inputPieces = [
            CheckpointPiece(start: 3 << 20, length: 1 << 20),
            CheckpointPiece(start: 0, length: 1 << 20),
            CheckpointPiece(start: 1 << 20, length: 2 << 20),  // adjacent to start 0 piece
            CheckpointPiece(start: 2 << 20, length: 3 << 20),  // overlaps prior + closes gap to 3<<20
            CheckpointPiece(start: 123, length: 0),            // zero-length: dropped
        ]
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        let viaInit = DownloadCheckpoint(
            jobID: 1,
            url: "https://example.com/f",
            destination: "/tmp/f",
            partialFileSize: 5 << 20,
            totalBytes: 5 << 20,
            completedPieces: inputPieces,
            updatedAt: fixedDate)

        // Reference: apply the same pieces sequentially via recordCompletedPiece.
        var sequential = DownloadCheckpoint(
            jobID: 1,
            url: "https://example.com/f",
            destination: "/tmp/f",
            partialFileSize: 5 << 20,
            totalBytes: 5 << 20,
            updatedAt: fixedDate)
        for piece in inputPieces {
            sequential.recordCompletedPiece(start: piece.start, length: piece.length)
        }

        #expect(viaInit.completedPieces == sequential.completedPieces)
        #expect(viaInit.completedPieces == [CheckpointPiece(start: 0, length: 5 << 20)])
        // updatedAt is the passed-in value, NOT a fresh Date() from the merge.
        #expect(viaInit.updatedAt == fixedDate)
    }

    @Test("save then load round-trips a checkpoint")
    func saveLoadRoundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CheckpointStore(directoryURL: directory)
        let checkpoint = sampleCheckpoint()
        try store.save(checkpoint)

        let loaded = store.load(jobID: checkpoint.jobID)
        #expect(loaded.checkpoint == checkpoint)
        #expect(loaded.corruptionSidecar == nil)
    }

    @Test("loading a missing checkpoint returns nil")
    func loadMissingCheckpoint() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let loaded = CheckpointStore(directoryURL: directory).load(jobID: 404)
        #expect(loaded.checkpoint == nil)
        #expect(loaded.corruptionSidecar == nil)
    }

    @Test("a corrupt checkpoint recovers to nil and leaves a sidecar copy")
    func loadCorruptCheckpoint() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CheckpointStore(directoryURL: directory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data("not a checkpoint".utf8).write(to: store.fileURL(jobID: 9))

        let loaded = store.load(jobID: 9)
        #expect(loaded.checkpoint == nil)
        let sidecar = try #require(loaded.corruptionSidecar)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test("delete removes a checkpoint")
    func deleteRemovesCheckpoint() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CheckpointStore(directoryURL: directory)
        let checkpoint = sampleCheckpoint()
        try store.save(checkpoint)
        try store.delete(jobID: checkpoint.jobID)

        #expect(store.load(jobID: checkpoint.jobID).checkpoint == nil)
    }

    @Test("CheckpointStore save writes the checkpoint file with owner-only 0600 permissions")
    func checkpointSaveSets0600Permissions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CheckpointStore(directoryURL: directory)
        let checkpoint = sampleCheckpoint()
        try store.save(checkpoint)

        let fileURL = store.fileURL(jobID: checkpoint.jobID)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }
}
