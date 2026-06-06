import Foundation
import Testing
@testable import GohCore

@Suite("GohVerifyAllCommand — --json mode")
struct GohVerifyAllCommandJSONTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-verifyall-json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func storeWithEntries(
        in dir: URL,
        entries: [(path: String, content: Data)]
    ) throws -> (storeURL: URL, sha256s: [String]) {
        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        var sha256s: [String] = []
        for (path, content) in entries {
            try content.write(to: URL(fileURLWithPath: path))
            let (sha256, _) = try FileDigest.sha256WithSize(path: path)
            sha256s.append(sha256)
            try store.record(entry: ProvenanceEntry(
                url: "https://example.com/" + URL(fileURLWithPath: path).lastPathComponent,
                sha256: sha256,
                size: content.count,
                downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
                destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path))
        }
        return (storeURL, sha256s)
    }

    // AC1 — Mixed ledger: parses, reportVersion:1, entries count, status values, summary fold.
    @Test("AC1: mixed ledger emits valid JSON with reportVersion:1 and per-status summary counts")
    func mixedLedgerJSON() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ok = dir.appendingPathComponent("ok.bin").path
        let failed = dir.appendingPathComponent("failed.bin").path
        let missing = dir.appendingPathComponent("missing.bin").path

        let (storeURL, _) = try storeWithEntries(in: dir, entries: [
            (ok, Data("unchanged".utf8)),
            (failed, Data("original".utf8)),
            (missing, Data("willbedeleted".utf8)),
        ])
        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: failed))
        try FileManager.default.removeItem(atPath: missing)

        let fixedDate = Date(timeIntervalSince1970: 1_714_262_400)
        let r = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: true,
            generatedAt: fixedDate)

        #expect(r.exitCode == 9)  // MISSING present — precedence 9

        // Must parse as JSON — no leading/trailing non-JSON.
        // Use CommandCoding.decoder to match the ISO-8601 date strategy used by the encoder.
        let data = Data(r.standardOutput.utf8)
        let report = try CommandCoding.decoder.decode(VerifyAllReport.self, from: data)

        // reportVersion must be 1.
        #expect(report.reportVersion == 1)

        // Entries count matches ledger.
        #expect(report.entries.count == 3)

        // AC1 summary fold invariant: each count == per-status filter of entries[].
        #expect(report.summary.total == report.entries.count)
        #expect(report.summary.ok == report.entries.filter { $0.status == .ok }.count)
        #expect(report.summary.failed == report.entries.filter { $0.status == .failed }.count)
        #expect(report.summary.missing == report.entries.filter { $0.status == .missing }.count)

        // Entry statuses are correct.
        let statuses = Dictionary(uniqueKeysWithValues:
            report.entries.map { ($0.path, $0.status) })
        #expect(statuses[URL(fileURLWithPath: ok).standardizedFileURL.path] == .ok)
        #expect(statuses[URL(fileURLWithPath: failed).standardizedFileURL.path] == .failed)
        #expect(statuses[URL(fileURLWithPath: missing).standardizedFileURL.path] == .missing)

        // Failed entry has actualSha256; missing and ok entries do not.
        let failedEntry = try #require(report.entries.first { $0.status == .failed })
        #expect(failedEntry.actualSha256 != nil)
        let okEntry = try #require(report.entries.first { $0.status == .ok })
        #expect(okEntry.actualSha256 == nil)
        let missingEntry = try #require(report.entries.first { $0.status == .missing })
        #expect(missingEntry.actualSha256 == nil)
    }

    // AC2 — --json exit code == human exit code for every ledger state.
    @Test("AC2: --json exit code equals human exit code (all-ok, failed-only, missing-present)")
    func jsonExitCodeEqualsHuman() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // All-OK
        let okPath = dir.appendingPathComponent("allok.bin").path
        let (storeOK, _) = try storeWithEntries(in: dir, entries: [(okPath, Data("data".utf8))])
        let humanOK = GohVerifyAllCommand.run(provenanceStorePath: storeOK.path)
        let jsonOK = GohVerifyAllCommand.run(provenanceStorePath: storeOK.path, json: true)
        #expect(humanOK.exitCode == jsonOK.exitCode)
        #expect(humanOK.exitCode == 0)

        // Failed-only (mismatch, no missing)
        let dir2 = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir2) }
        let failPath = dir2.appendingPathComponent("fail.bin").path
        let (storeF, _) = try storeWithEntries(in: dir2, entries: [(failPath, Data("orig".utf8))])
        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: failPath))
        let humanF = GohVerifyAllCommand.run(provenanceStorePath: storeF.path)
        let jsonF = GohVerifyAllCommand.run(provenanceStorePath: storeF.path, json: true)
        #expect(humanF.exitCode == jsonF.exitCode)
        #expect(humanF.exitCode == 2)

        // Missing present (exit 9)
        let dir3 = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir3) }
        let missingPath = dir3.appendingPathComponent("miss.bin").path
        let (storeM, _) = try storeWithEntries(in: dir3, entries: [(missingPath, Data("x".utf8))])
        try FileManager.default.removeItem(atPath: missingPath)
        let humanM = GohVerifyAllCommand.run(provenanceStorePath: storeM.path)
        let jsonM = GohVerifyAllCommand.run(provenanceStorePath: storeM.path, json: true)
        #expect(humanM.exitCode == jsonM.exitCode)
        #expect(humanM.exitCode == 9)
    }

    // AC3 — M3 regression gate: human output is byte-identical for mixed ledger.
    // This NEW test asserts the FULL joined output string (not .contains())
    // to catch line-order or separator regressions after the refactor.
    @Test("AC3: human output is byte-identical after compute-once-render-twice refactor")
    func humanOutputByteIdentical() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ok = dir.appendingPathComponent("ok.bin").path
        let failed = dir.appendingPathComponent("failed.bin").path
        let missing = dir.appendingPathComponent("missing.bin").path

        let (storeURL, sha256s) = try storeWithEntries(in: dir, entries: [
            (ok, Data("unchanged".utf8)),
            (failed, Data("original".utf8)),
            (missing, Data("willbedeleted".utf8)),
        ])
        // sha256s[0] = ok hash, sha256s[1] = original hash, sha256s[2] = missing hash

        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: failed))
        try FileManager.default.removeItem(atPath: missing)

        let (mutatedHash, _) = try FileDigest.sha256WithSize(path: failed)

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path)

        // Canonicalized paths (as stored by storeWithEntries)
        let okCanon = URL(fileURLWithPath: ok).standardizedFileURL.path
        let failedCanon = URL(fileURLWithPath: failed).standardizedFileURL.path
        let missingCanon = URL(fileURLWithPath: missing).standardizedFileURL.path

        // Pre-refactor exact strings (per-line \n, lines.joined() no separator):
        let expectedOutput = [
            "OK \(okCanon)\n",
            "FAILED \(failedCanon) expected \(sha256s[1]) actual \(mutatedHash)\n",
            "MISSING \(missingCanon) (expected \(sha256s[2]))\n",
        ].joined()

        // Assert FULL joined string — not .contains() — to catch line-order/separator regressions.
        #expect(r.standardOutput == expectedOutput)
        #expect(r.exitCode == 9)
    }

    // AC4 — Empty ledger → valid empty report, exit 0.
    @Test("AC4: absent ledger with --json emits valid empty report, exit 0")
    func absentLedgerJSON() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let r = GohVerifyAllCommand.run(
            provenanceStorePath: dir.appendingPathComponent("absent.plist").path,
            json: true)

        #expect(r.exitCode == 0)
        let data = Data(r.standardOutput.utf8)
        // Use CommandCoding.decoder to match the ISO-8601 date strategy used by the encoder.
        let report = try CommandCoding.decoder.decode(VerifyAllReport.self, from: data)
        #expect(report.reportVersion == 1)
        #expect(report.entries.isEmpty)
        #expect(report.summary.total == 0)
        #expect(report.summary.ok == 0)
        #expect(report.summary.failed == 0)
        #expect(report.summary.missing == 0)
    }

    // AC4 — Unreadable ledger → error envelope, exit 6.
    // Note: relies on running as non-root (chmod 0o000 only blocks non-root reads).
    @Test("AC4: unreadable ledger with --json emits error envelope {reportVersion:1, error:\"ledgerUnreadable\"}, exit 6")
    func unreadableLedgerEnvelope() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        // Create a file but make it unreadable.
        try Data("dummy".utf8).write(to: storeURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: storeURL.path)
        defer { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: storeURL.path) }

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path, json: true)
        #expect(r.exitCode == 6)

        let data = Data(r.standardOutput.utf8)
        let envelope = try JSONDecoder().decode(VerifyErrorReport.self, from: data)
        #expect(envelope.reportVersion == 1)
        #expect(envelope.error == .ledgerUnreadable)
    }

    // AC4 — Corrupt ledger → error envelope, exit 6.
    @Test("AC4: corrupt ledger with --json emits error envelope {error:\"ledgerCorrupt\"}, exit 6")
    func corruptLedgerEnvelope() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        try Data("not a plist at all".utf8).write(to: storeURL)

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path, json: true)
        #expect(r.exitCode == 6)

        let data = Data(r.standardOutput.utf8)
        let envelope = try JSONDecoder().decode(VerifyErrorReport.self, from: data)
        #expect(envelope.reportVersion == 1)
        #expect(envelope.error == .ledgerCorrupt)
    }

    // AC4 — Unknown-version ledger → error envelope, exit 6.
    @Test("AC4: unknown-version ledger with --json emits error envelope {error:\"ledgerVersionUnknown\"}, exit 6")
    func unknownVersionEnvelope() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        // Build a valid-format plist with a future version number.
        let record = ProvenanceRecord(version: 9999, entries: [])
        let data = try PropertyListEncoder().encode(record)
        try data.write(to: storeURL)

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path, json: true)
        #expect(r.exitCode == 6)

        let jsonData = Data(r.standardOutput.utf8)
        let envelope = try JSONDecoder().decode(VerifyErrorReport.self, from: jsonData)
        #expect(envelope.reportVersion == 1)
        #expect(envelope.error == .ledgerVersionUnknown)
    }

    // AC4 — Empty store record (entries: []) → valid empty report, exit 0.
    @Test("AC4: empty store (entries:[]) with --json emits valid empty report, exit 0")
    func emptyStoreJSON() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        let emptyRecord = ProvenanceRecord(version: ProvenanceRecord.currentVersion, entries: [])
        let data = try PropertyListEncoder().encode(emptyRecord)
        try data.write(to: storeURL)

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path, json: true)
        #expect(r.exitCode == 0)
        let jsonData = Data(r.standardOutput.utf8)
        // Use CommandCoding.decoder to match the ISO-8601 date strategy used by the encoder.
        let report = try CommandCoding.decoder.decode(VerifyAllReport.self, from: jsonData)
        #expect(report.entries.isEmpty)
        #expect(report.summary.total == 0)
    }
}
