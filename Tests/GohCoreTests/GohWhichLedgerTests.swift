import Foundation
import Testing

@testable import GohCore

@Suite("GohWhichCommand — ledger branch")
struct GohWhichLedgerTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-which-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func storeWithEntry(
        in dir: URL,
        destPath: String,
        sha256: String = "sha256:" + String(repeating: "f", count: 64),
        url: String = "https://example.com/file.bin",
        downloadedAt: Date = Date(timeIntervalSince1970: 1_748_000_000)
    ) throws -> ProvenanceStore {
        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        let canonical = URL(fileURLWithPath: destPath).standardizedFileURL.path
        try store.record(entry: ProvenanceEntry(
            url: url,
            sha256: sha256,
            size: 1024,
            downloadedAt: downloadedAt,
            destinationPath: canonical))
        return store
    }

    // AC2/T6: `goh which` reads sha256 from the ledger for an ad-hoc file.
    @Test("AC2/T6: which with populated ledger prints sha256 from the record, not (not recorded)")
    func whichReadsFromLedger() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destPath = dir.appendingPathComponent("a.bin").path
        try Data("hello".utf8).write(to: URL(fileURLWithPath: destPath))

        let sha256 = "sha256:" + String(repeating: "a", count: 64)
        let store = try storeWithEntry(in: dir, destPath: destPath, sha256: sha256,
                                       url: "https://example.com/a.bin")
        let storePath = dir.appendingPathComponent("provenance.plist").path

        let r = GohWhichCommand.run(
            filePath: destPath,
            lockPath: dir.appendingPathComponent("gohfile.lock").path,
            provenanceStorePath: storePath)

        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("https://example.com/a.bin"))
        #expect(r.standardOutput.contains(sha256))
        #expect(!r.standardOutput.contains("(not recorded)"))
        // No network: the test runs offline by construction (no URLSession on this path).
        _ = store  // retain store
    }

    // AC2/T6b: Canonical-path match — `..`-laden CLI arg matches the stored canonical key.
    @Test("AC2/T6b: which matches entry when CLI arg canonicalizes to the same path as stored key")
    func canonicalPathMatch() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Store the entry under the canonical absolute path.
        let canonical = dir.appendingPathComponent("b.bin").path
        try Data("data".utf8).write(to: URL(fileURLWithPath: canonical))

        let sha256 = "sha256:" + String(repeating: "b", count: 64)
        let store = try storeWithEntry(in: dir, destPath: canonical, sha256: sha256)
        let storePath = dir.appendingPathComponent("provenance.plist").path

        // Construct a `..`-laden path that standardizedFileURL.path collapses to canonical.
        let dotdotPath = dir.appendingPathComponent("sub/../b.bin").path

        let r = GohWhichCommand.run(
            filePath: dotdotPath,
            lockPath: dir.appendingPathComponent("gohfile.lock").path,
            provenanceStorePath: storePath)

        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains(sha256))
        _ = store
    }

    // Nil provenanceStorePath skips the ledger branch (BLOCK-A: existing call sites unaffected).
    @Test("nil provenanceStorePath skips ledger and falls through to exit 4")
    func nilProvenanceStorePathSkipsLedger() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destPath = dir.appendingPathComponent("c.bin").path
        try Data("c".utf8).write(to: URL(fileURLWithPath: destPath))

        // Ledger HAS an entry, but provenanceStorePath is nil → skip.
        _ = try storeWithEntry(in: dir, destPath: destPath)

        let r = GohWhichCommand.run(
            filePath: destPath,
            lockPath: dir.appendingPathComponent("gohfile.lock").path
            // provenanceStorePath defaults to nil
        )
        // Falls through to xattr / exit 4 — the ledger is NOT consulted.
        #expect(r.exitCode == 4)
    }

    // Missing ledger file → silent fall-through.
    @Test("missing or corrupt ledger file falls through silently to exit 4")
    func missingLedgerFallsThrough() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destPath = dir.appendingPathComponent("d.bin").path
        try Data("d".utf8).write(to: URL(fileURLWithPath: destPath))

        let r = GohWhichCommand.run(
            filePath: destPath,
            lockPath: dir.appendingPathComponent("gohfile.lock").path,
            provenanceStorePath: dir.appendingPathComponent("absent.plist").path)
        #expect(r.exitCode == 4)
    }

    // Ledger-first precedence: ledger takes precedence over lock for the same path.
    @Test("ledger takes precedence over lock when both have an entry for the same path")
    func lockPrecedence() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockText = """
            lockfileVersion = 1
            manifestHash = "sha256:\(String(repeating: "0", count: 64))"

            [[entry]]
            url = "https://lock.example.com/f.bin"
            path = "f.bin"
            sha256 = "sha256:\(String(repeating: "1", count: 64))"
            size = 1
            downloadedAt = "2026-06-01T00:00:00Z"
            """
        let lockURL = dir.appendingPathComponent("gohfile.lock")
        try lockText.write(to: lockURL, atomically: true, encoding: .utf8)
        let target = dir.appendingPathComponent("f.bin")
        try Data("x".utf8).write(to: target)

        // Ledger has a DIFFERENT sha256 for the same file.
        let sha256Ledger = "sha256:" + String(repeating: "2", count: 64)
        let store = try storeWithEntry(in: dir, destPath: target.path, sha256: sha256Ledger)
        let storePath = dir.appendingPathComponent("provenance.plist").path

        let r = GohWhichCommand.run(
            filePath: target.path,
            lockPath: lockURL.path,
            provenanceStorePath: storePath)

        // Ledger-first: output contains LEDGER's sha (2...2), NOT lock's (1...1).
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains(String(repeating: "2", count: 64)))
        #expect(!r.standardOutput.contains(String(repeating: "1", count: 64)))
        _ = store
    }

    // Lock fallback: file present only in lock (ledger empty) → falls back to lock.
    @Test("lock fallback when file not in ledger — falls back to lock, exit 0, lock sha present")
    func lockFallbackWhenNotInLedger() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sha256Lock = "sha256:" + String(repeating: "9", count: 64)
        let lockText = """
            lockfileVersion = 1
            manifestHash = "sha256:\(String(repeating: "0", count: 64))"

            [[entry]]
            url = "https://lock.example.com/g.bin"
            path = "g.bin"
            sha256 = "\(sha256Lock)"
            size = 1
            downloadedAt = "2026-06-01T00:00:00Z"
            """
        let lockURL = dir.appendingPathComponent("gohfile.lock")
        try lockText.write(to: lockURL, atomically: true, encoding: .utf8)
        let target = dir.appendingPathComponent("g.bin")
        try Data("y".utf8).write(to: target)

        // Write an EMPTY ledger (no entry for this file).
        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        let storePath = storeURL.path

        let r = GohWhichCommand.run(
            filePath: target.path,
            lockPath: lockURL.path,
            provenanceStorePath: storePath)

        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains(String(repeating: "9", count: 64)))
        _ = store
    }

    // M5: download-only entry (verifiedAt == nil) → shows "downloaded", not "verified present".
    @Test("M5: download-only entry shows 'downloaded' line, not 'verified present'")
    func whichDownloadOnlyShowsDownloadedDate() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destPath = dir.appendingPathComponent("dl.bin").path
        try Data("dl".utf8).write(to: URL(fileURLWithPath: destPath))

        // storeWithEntry records verifiedAt = nil (default)
        let store = try storeWithEntry(in: dir, destPath: destPath,
                                       sha256: "sha256:" + String(repeating: "d", count: 64))
        let storePath = dir.appendingPathComponent("provenance.plist").path

        let r = GohWhichCommand.run(
            filePath: destPath,
            lockPath: dir.appendingPathComponent("gohfile.lock").path,
            provenanceStorePath: storePath)

        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("downloaded"))
        #expect(!r.standardOutput.contains("verified present"))
        #expect(!r.standardOutput.contains("last verified"))
        _ = store
    }

    // M5: entry with downloadedAt == verifiedAt → shows "verified present", NOT "downloaded".
    @Test("M5: entry with downloadedAt == verifiedAt shows 'verified present', not 'downloaded'")
    func whichVerifiedPresentShowsVerifiedDate() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destPath = dir.appendingPathComponent("vp.bin").path
        try Data("vp".utf8).write(to: URL(fileURLWithPath: destPath))

        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        let canonical = URL(fileURLWithPath: destPath).standardizedFileURL.path
        let ts = Date(timeIntervalSince1970: 1_748_000_000)
        // downloadedAt == verifiedAt → sync-recorded, never downloaded by goh
        try store.record(entry: ProvenanceEntry(
            url: "https://example.com/vp.bin",
            sha256: "sha256:" + String(repeating: "e", count: 64),
            size: 2,
            downloadedAt: ts,
            destinationPath: canonical,
            verifiedAt: ts))
        let storePath = storeURL.path

        let r = GohWhichCommand.run(
            filePath: destPath,
            lockPath: dir.appendingPathComponent("gohfile.lock").path,
            provenanceStorePath: storePath)

        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("verified present"))
        #expect(!r.standardOutput.contains("downloaded"))
        #expect(!r.standardOutput.contains("last verified"))
        _ = store
    }

    // M5: entry with downloadedAt < verifiedAt → shows BOTH "downloaded" AND "last verified".
    @Test("M5: entry with downloadedAt < verifiedAt shows both 'downloaded' and 'last verified'")
    func whichBothShowsBothDates() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destPath = dir.appendingPathComponent("both.bin").path
        try Data("both".utf8).write(to: URL(fileURLWithPath: destPath))

        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        let canonical = URL(fileURLWithPath: destPath).standardizedFileURL.path
        let downloadedAt = Date(timeIntervalSince1970: 1_748_000_000)
        let verifiedAt   = Date(timeIntervalSince1970: 1_748_100_000)  // later
        try store.record(entry: ProvenanceEntry(
            url: "https://example.com/both.bin",
            sha256: "sha256:" + String(repeating: "3", count: 64),
            size: 4,
            downloadedAt: downloadedAt,
            destinationPath: canonical,
            verifiedAt: verifiedAt))
        let storePath = storeURL.path

        let r = GohWhichCommand.run(
            filePath: destPath,
            lockPath: dir.appendingPathComponent("gohfile.lock").path,
            provenanceStorePath: storePath)

        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("downloaded"))
        #expect(r.standardOutput.contains("last verified"))
        #expect(!r.standardOutput.contains("verified present"))
        _ = store
    }
}
