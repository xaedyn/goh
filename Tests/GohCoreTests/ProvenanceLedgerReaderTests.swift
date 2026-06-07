import Foundation
import Testing
@testable import GohCore

// AC1/AC4/AC5: shared ledger reader used by both the CLI runner and the tray.
// Classification order must match GohVerifyAllCommand.run() exactly.
@Suite("ProvenanceLedgerReader")
struct ProvenanceLedgerReaderTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-ledgerreader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // AC1: absent file → .absent (not .unreadable)
    @Test("absent file returns .absent")
    func absentReturnsAbsent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("noexist.plist").path
        let outcome = ProvenanceLedgerReader.read(at: path)
        #expect(outcome == .absent)
    }

    // AC4: unreadable file (chmod 000) → .unreadable(.io)
    @Test("unreadable file returns .unreadable(.io)")
    func unreadableReturnsIO() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("provenance.plist")
        try Data("dummy".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let outcome = ProvenanceLedgerReader.read(at: url.path)
        #expect(outcome == .unreadable(.io))
    }

    // AC4: corrupt plist bytes → .unreadable(.corrupt)
    @Test("corrupt plist bytes returns .unreadable(.corrupt)")
    func corruptReturnscorrupt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("provenance.plist")
        try Data("not a plist at all".utf8).write(to: url)
        let outcome = ProvenanceLedgerReader.read(at: url.path)
        #expect(outcome == .unreadable(.corrupt))
    }

    // AC4: unknown-version plist → .unreadable(.versionUnknown(found: 9999))
    @Test("unknown-version record returns .unreadable(.versionUnknown(found:))")
    func unknownVersionReturnsVersionUnknown() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("provenance.plist")
        let record = ProvenanceRecord(version: 9999, entries: [])
        let data = try PropertyListEncoder().encode(record)
        try data.write(to: url)
        let outcome = ProvenanceLedgerReader.read(at: url.path)
        #expect(outcome == .unreadable(.versionUnknown(found: 9999)))
    }

    // AC1: empty entries array → .entries([]) (not .absent)
    @Test("empty entries array returns .entries([])")
    func emptyEntriesReturnsEntries() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("provenance.plist")
        let record = ProvenanceRecord(version: ProvenanceRecord.currentVersion, entries: [])
        let data = try PropertyListEncoder().encode(record)
        try data.write(to: url)
        let outcome = ProvenanceLedgerReader.read(at: url.path)
        #expect(outcome == .entries([]))
    }

    // AC5: valid ledger with entries → .entries with correct count and order preserved
    @Test("valid ledger returns .entries in stored order")
    func validLedgerReturnsEntries() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("provenance.plist")
        let entries = [
            ProvenanceEntry(url: "https://a.example.com/a.bin", sha256: "sha256:aa",
                            size: 1, downloadedAt: Date(timeIntervalSince1970: 1_000),
                            destinationPath: "/tmp/a.bin"),
            ProvenanceEntry(url: "https://b.example.com/b.bin", sha256: "sha256:bb",
                            size: 2, downloadedAt: Date(timeIntervalSince1970: 2_000),
                            destinationPath: "/tmp/b.bin"),
        ]
        let record = ProvenanceRecord(version: ProvenanceRecord.currentVersion, entries: entries)
        let data = try PropertyListEncoder().encode(record)
        try data.write(to: url)
        let outcome = ProvenanceLedgerReader.read(at: url.path)
        guard case .entries(let decoded) = outcome else {
            Issue.record("Expected .entries, got \(outcome)")
            return
        }
        #expect(decoded.count == 2)
        #expect(decoded[0].destinationPath == "/tmp/a.bin")
        #expect(decoded[1].destinationPath == "/tmp/b.bin")
    }

    // AC4: read never creates a sidecar (no side effects on disk)
    @Test("read never creates sidecar on corrupt ledger (CLI invariant)")
    func noSidecarOnCorrupt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("provenance.plist")
        try Data("not a plist".utf8).write(to: url)
        _ = ProvenanceLedgerReader.read(at: url.path)
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let sidecars = contents.filter { $0.contains(".corrupt-") }
        #expect(sidecars.isEmpty, "read must not create sidecar copies")
    }
}
