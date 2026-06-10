import Foundation
import Testing

@testable import GohCore

@Suite("GohVerifyAllCommand")
struct GohVerifyAllCommandTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-verifyall-\(UUID().uuidString)")
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
            let fileURL = URL(fileURLWithPath: path)
            try content.write(to: fileURL)
            let (sha256, _) = try FileDigest.sha256WithSize(path: path)
            sha256s.append(sha256)
            try store.record(entry: ProvenanceEntry(
                url: "https://example.com/" + fileURL.lastPathComponent,
                sha256: sha256,
                size: content.count,
                downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
                destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path))
        }
        return (storeURL, sha256s)
    }

    // AC3/T7: OK / FAILED / MISSING with correct exit codes and precedence 9>2.
    @Test("AC3/T7: OK intact / FAILED mutated / MISSING deleted — exit 9 (precedence 9>2)")
    func okFailedMissing() throws {
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

        // Mutate `failed`.
        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: failed))
        // Delete `missing`.
        try FileManager.default.removeItem(atPath: missing)

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path)

        #expect(r.standardOutput.contains("OK \(ok)"))
        #expect(r.standardOutput.contains("FAILED \(failed)"))
        #expect(r.standardOutput.contains("MISSING \(missing)"))
        // MISSING dominates FAILED: exit 9.
        #expect(r.exitCode == 9)
        // Network never touched (structural — no URLSession on this path).
    }

    // AC3/T7: FAILED only → exit 2.
    @Test("AC3/T7: FAILED only → exit 2")
    func failedOnlyExitTwo() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("mutated.bin").path
        let (storeURL, _) = try storeWithEntries(in: dir, entries: [
            (path, Data("original".utf8))
        ])
        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: path))

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path)
        #expect(r.exitCode == 2)
        #expect(r.standardOutput.contains("FAILED \(path)"))
    }

    // AC3/T7: All OK → exit 0.
    @Test("AC3/T7: all entries OK → exit 0")
    func allOkExitZero() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("intact.bin").path
        let (storeURL, _) = try storeWithEntries(in: dir, entries: [
            (path, Data("data".utf8))
        ])

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path)
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("OK \(path)"))
    }

    // T8: Empty / absent ledger → exit 0, "0 recorded entries".
    @Test("T8: absent ledger → exit 0 and 0 recorded entries message")
    func absentLedgerExitZero() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let r = GohVerifyAllCommand.run(
            provenanceStorePath: dir.appendingPathComponent("absent.plist").path)
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("0 recorded"))
    }

    // T8: Corrupt ledger on CLI read → exit 6; NO sidecar copy; NO reset by CLI.
    @Test("T8: corrupt ledger on CLI read → exit 6; no sidecar copy created by CLI")
    func corruptLedgerExitSix() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("provenance.plist")
        try Data("not a plist at all".utf8).write(to: storeURL)

        let r = GohVerifyAllCommand.run(provenanceStorePath: storeURL.path)
        #expect(r.exitCode == 6)
        // Non-JSON human diagnostic goes to stderr, never stdout.
        #expect(r.standardError.contains("provenance ledger"))
        #expect(r.standardOutput.isEmpty)

        // The CLI must NOT have created a sidecar — only the daemon's load() does that.
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let sidecars = contents.filter { $0.contains(".corrupt-") }
        #expect(sidecars.isEmpty, "CLI must not create sidecar copies")
    }

    // T7b: Frozen `verify` command is unmodified — its parse/dispatch is tested in GohCommandLine.
    // The structural check: verify GohVerifyCommand compiles and the run() signature is unchanged.
    @Test("T7b: GohVerifyCommand.run signature is frozen and unmodified")
    func verifyCommandFrozenSignature() {
        // If GohVerifyCommand.run had its signature changed, this would fail to compile.
        let _: (String, Bool) -> GohCommandLineResult = GohVerifyCommand.run(lockPath:strictUntracked:)
        // Test passes by compilation alone.
    }

    @Test("verify --all with stale idle daemon triggers auto-heal before verification")
    func verifyAllWithStaleIdleDaemonTriggersAutoHeal() throws {
        let restarter = StubRestarter(shouldSucceed: true)
        // Sequence: stale (initial classify), stale (re-check idle), current (poll)
        let sequenced = SequencedLsSender(replies: [
            LsReply(jobs: [], featureLevel: nil),
            LsReply(jobs: [], featureLevel: nil),
            LsReply(jobs: [], featureLevel: GohFeatureLevel.current),
        ])
        let result = GohVerifyAllCommand.run(
            provenanceStorePath: "",
            send: sequenced.sender(),
            restarter: restarter)
        #expect(restarter.kickstartCalled == 1)
        #expect(result.exitCode == 0)   // no entries → 0; auto-heal never changes exit code
    }
}
