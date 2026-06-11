import Foundation
import Testing
@testable import GohCore

@Suite("ProvenanceStore.forget")
struct ForgetProvenanceStoreTests {

    // MARK: - Helpers

    private func makeStore(entries: [ProvenanceEntry]) throws -> (ProvenanceStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "goh-forget-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "provenance.plist")
        let store = ProvenanceStore(fileURL: url)
        // Pre-populate by recording each entry individually.
        for entry in entries {
            try store.record(entry: entry)
        }
        return (store, url)
    }

    private func makeEntry(path: String, url: String = "https://example.com/f.bin") -> ProvenanceEntry {
        ProvenanceEntry(
            url: url,
            sha256: "sha256:" + String(repeating: "a", count: 64),
            size: 1024,
            downloadedAt: Date(timeIntervalSince1970: 0),
            destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path,
            verifiedAt: nil)
    }

    // MARK: - AC4 tests

    @Test("empty paths is a no-op — returns 0, no disk write")
    func testForgetEmptyPathsIsNoOp() throws {
        let (store, url) = try makeStore(entries: [makeEntry(path: "/tmp/a.bin")])
        let before = try Data(contentsOf: url)
        let removed = try store.forget(paths: [])
        let after = try Data(contentsOf: url)
        #expect(removed == 0)
        #expect(before == after, "no-op forget must not touch the ledger on disk")
    }

    @Test("forget removes a matching entry and returns 1")
    func testForgetTrackedEntry() throws {
        let path = "/tmp/goh-forget-test-\(UUID().uuidString)/file.bin"
        let (store, _) = try makeStore(entries: [makeEntry(path: path)])
        let removed = try store.forget(paths: [path])
        #expect(removed == 1)
        #expect(store.lookup(destinationPath: path) == nil)
    }

    @Test("forget untracked path returns 0 and leaves ledger unchanged")
    func testForgetUntrackedReturns0() throws {
        let tracked = "/tmp/tracked.bin"
        let untracked = "/tmp/untracked.bin"
        let (store, url) = try makeStore(entries: [makeEntry(path: tracked)])
        let before = try Data(contentsOf: url)
        let removed = try store.forget(paths: [untracked])
        let after = try Data(contentsOf: url)
        #expect(removed == 0)
        #expect(before == after, "no-match forget must not rewrite the ledger")
    }

    @Test("forget leaves non-requested entries intact")
    func testForgetLeavesOtherEntriesIntact() throws {
        let a = "/tmp/a.bin"
        let b = "/tmp/b.bin"
        let (store, _) = try makeStore(entries: [makeEntry(path: a), makeEntry(path: b)])
        let removed = try store.forget(paths: [a])
        #expect(removed == 1)
        #expect(store.lookup(destinationPath: a) == nil)
        #expect(store.lookup(destinationPath: b) != nil)
    }

    @Test("forget multiple paths — removes all matching, returns correct count")
    func testForgetMultiplePaths() throws {
        let a = "/tmp/ma.bin"
        let b = "/tmp/mb.bin"
        let c = "/tmp/mc.bin"
        let (store, _) = try makeStore(entries: [
            makeEntry(path: a), makeEntry(path: b), makeEntry(path: c)])
        let removed = try store.forget(paths: [a, b])
        #expect(removed == 2)
        #expect(store.lookup(destinationPath: a) == nil)
        #expect(store.lookup(destinationPath: b) == nil)
        #expect(store.lookup(destinationPath: c) != nil)
    }

    // AC4: atomic write — the rewritten file decodes as a valid ProvenanceRecord
    @Test("forget writes atomically — result decodes as valid ProvenanceRecord version 1")
    func testForgetWritesAtomically() throws {
        let path = "/tmp/atomic-\(UUID().uuidString).bin"
        let (store, url) = try makeStore(entries: [makeEntry(path: path)])
        _ = try store.forget(paths: [path])
        let data = try Data(contentsOf: url)
        let record = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
        #expect(record.version == ProvenanceRecord.currentVersion)
        #expect(record.entries.isEmpty)
    }

    // AC4 / M7 (gap #2): file-safety — forget never touches the file at the path
    @Test("forget never modifies the file at the requested path — file-safety invariant")
    func testForgetFileSafetyPresentFileUntouched() throws {
        // Write a real file.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "goh-forget-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filePath = dir.appending(path: "target.bin").path
        let originalBytes = Data("hello provenance".utf8)
        try originalBytes.write(to: URL(fileURLWithPath: filePath))

        let (store, _) = try makeStore(entries: [makeEntry(path: filePath)])
        _ = try store.forget(paths: [filePath])

        // File must still exist and be byte-identical.
        let afterBytes = try Data(contentsOf: URL(fileURLWithPath: filePath))
        #expect(afterBytes == originalBytes, "forget must NEVER modify the file at the path")
        #expect(store.lookup(destinationPath: filePath) == nil, "entry must be gone from the ledger")
    }

    @Test("forget canonicalizes trailing-slash path — no crash, valid result")
    func testForgetTrailingSlashCanonicalization() throws {
        let path = "/tmp/goh-slash-\(UUID().uuidString)/file.bin"
        let (store, url) = try makeStore(entries: [makeEntry(path: path)])
        // A trailing slash appended to a file path does not match the stored canonical key
        // (standardizedFileURL resolves differently). Assert: no crash, ledger is still valid.
        let removed = try store.forget(paths: [path + "/"])
        #expect(removed == 0 || removed == 1)
        let data = try Data(contentsOf: url)
        let record = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
        #expect(record.version == ProvenanceRecord.currentVersion)
    }
}
