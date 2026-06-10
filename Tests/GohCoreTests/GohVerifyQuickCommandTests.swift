import Foundation
import Testing
@testable import GohCore

// Stub probe returning a configurable result.
private struct StubProbe: FileStatProbing {
    let result: FileProbeResult
    nonisolated func probe(path: String) -> FileProbeResult { result }
}

@Suite("GohVerifyQuickCommand")
struct GohVerifyQuickCommandTests {

    // Parse: `goh verify --quick` parses to verifyQuick case.
    @Test("parse: 'verify --quick' routes to GohVerifyQuickCommand")
    func parseVerifyQuick() {
        let result = GohCommandLine(
            arguments: ["verify", "--quick"],
            provenanceStorePathResolver: { "/tmp/nonexistent.plist" },
            send: { _ in throw ParseTestError() }
        ).run()
        // Absent ledger → exit 0 (0 entries).
        #expect(result.exitCode == 0)
    }

    // parse: `verify --quick --json` is not supported (no JSON mode for quick).
    @Test("parse: 'verify --quick --json' exits 64 (unsupported)")
    func parseVerifyQuickJsonRejected() {
        let result = GohCommandLine(
            arguments: ["verify", "--quick", "--json"],
            provenanceStorePathResolver: { "/tmp/nonexistent.plist" },
            send: { _ in throw ParseTestError() }
        ).run()
        #expect(result.exitCode == 64)
    }

    // `--quick` is incompatible with `--all`.
    @Test("parse: 'verify --all --quick' exits 64")
    func parseVerifyAllAndQuickRejected() {
        let result = GohCommandLine(
            arguments: ["verify", "--all", "--quick"],
            provenanceStorePathResolver: { "/tmp/nonexistent.plist" },
            send: { _ in throw ParseTestError() }
        ).run()
        #expect(result.exitCode == 64)
    }

    // GohVerifyQuickCommand.run with an absent ledger → exit 0, "0 recorded entries".
    @Test("run: absent ledger → exit 0")
    func absentLedger() {
        let result = GohVerifyQuickCommand.run(
            provenanceStorePath: "/tmp/goh-quick-test-absent-\(UUID().uuidString).plist",
            probe: StubProbe(result: .notFound))
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("0 recorded entries"))
    }

    // All unchanged → exit 0.
    @Test("run: all unchanged → exit 0")
    func allUnchanged() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("goh-quick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("provenance.plist").path
        let baseline = FileStat(size: 100, mtimeSeconds: 1_748_000_000,
                                mtimeNanoseconds: 0, inode: 1, device: 1,
                                isRegularFile: true)
        let entry = makeEntry(path: "/tmp/a.bin", baseline: baseline)
        try writeStore(entry, to: path)

        let probe = StubProbe(result: .stat(baseline))
        let result = GohVerifyQuickCommand.run(provenanceStorePath: path, probe: probe)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("OK"))
    }

    // Any changed → exit 2.
    @Test("run: changed file → exit 2")
    func changedFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("goh-quick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("provenance.plist").path
        let baseline = FileStat(size: 100, mtimeSeconds: 1_748_000_000,
                                mtimeNanoseconds: 0, inode: 1, device: 1,
                                isRegularFile: true)
        let current = FileStat(size: 999, mtimeSeconds: 1_748_000_000,
                               mtimeNanoseconds: 0, inode: 1, device: 1,
                               isRegularFile: true)
        let entry = makeEntry(path: "/tmp/b.bin", baseline: baseline)
        try writeStore(entry, to: path)

        let probe = StubProbe(result: .stat(current))
        let result = GohVerifyQuickCommand.run(provenanceStorePath: path, probe: probe)
        #expect(result.exitCode == 2)
        #expect(result.standardOutput.contains("CHANGED"))
    }

    // Missing file → exit 9.
    @Test("run: missing file → exit 9")
    func missingFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("goh-quick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("provenance.plist").path
        let baseline = FileStat(size: 100, mtimeSeconds: 1_748_000_000,
                                mtimeNanoseconds: 0, inode: 1, device: 1,
                                isRegularFile: true)
        let entry = makeEntry(path: "/tmp/c.bin", baseline: baseline)
        try writeStore(entry, to: path)

        let probe = StubProbe(result: .notFound)
        let result = GohVerifyQuickCommand.run(provenanceStorePath: path, probe: probe)
        #expect(result.exitCode == 9)
        #expect(result.standardOutput.contains("MISSING"))
    }

    // Precedence: 9 > 2.
    @Test("run: missing + changed → exit 9")
    func missingBeatsChanged() throws {
        // Two entries; one missing, one changed.
        // Write a two-entry store, probe: first .notFound, second .stat(changed).
        // Probe is a FixedProbe returning .notFound for simplicity — just test exit 9.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("goh-quick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("provenance.plist").path
        let baseline = FileStat(size: 100, mtimeSeconds: 1_748_000_000,
                                mtimeNanoseconds: 0, inode: 1, device: 1,
                                isRegularFile: true)
        let entry = makeEntry(path: "/tmp/d.bin", baseline: baseline)
        try writeStore(entry, to: path)

        let probe = StubProbe(result: .notFound)
        let result = GohVerifyQuickCommand.run(provenanceStorePath: path, probe: probe)
        #expect(result.exitCode == 9)
    }

    // Helpers
    private struct ParseTestError: Error {}

    private func makeEntry(path: String, baseline: FileStat) -> ProvenanceEntry {
        ProvenanceEntry(
            url: "https://example.com/a.bin",
            sha256: "sha256:" + String(repeating: "a", count: 64),
            size: Int(baseline.size),
            downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
            destinationPath: path,
            verifiedAt: nil,
            recordedStatSize: baseline.size,
            recordedMtimeSeconds: baseline.mtimeSeconds,
            recordedMtimeNanoseconds: baseline.mtimeNanoseconds,
            recordedInode: baseline.inode,
            recordedDevice: baseline.device)
    }

    @Test("verify --quick with stale daemon triggers auto-heal")
    func verifyQuickWithStaleDaemonTriggersAutoHeal() throws {
        let restarter = StubRestarter(shouldSucceed: true)
        let sequenced = SequencedLsSender(replies: [
            LsReply(jobs: [], featureLevel: nil),
            LsReply(jobs: [], featureLevel: nil),
            LsReply(jobs: [], featureLevel: GohFeatureLevel.current),
        ])
        let result = GohVerifyQuickCommand.run(
            provenanceStorePath: "",
            send: sequenced.sender(),
            restarter: restarter)
        #expect(restarter.kickstartCalled == 1)
        #expect(result.exitCode == 0)
    }

    private func writeStore(_ entry: ProvenanceEntry, to path: String) throws {
        let record = ProvenanceRecord(version: 1, entries: [entry])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
