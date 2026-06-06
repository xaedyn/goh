import Foundation
import Testing
import XPC
@testable import GohCore

@Suite("GohCommandLine — verify --all --json parse boundary")
struct GohVerifyAllParseJSONTests {

    private struct TestTransportError: Error {}

    private func emptyTempStorePath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-verifyall-parsejson-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The file does NOT exist → GohVerifyAllCommand reports an empty result.
        return dir.appendingPathComponent("provenance.plist").path
    }

    // AC5 (parse boundary) — `verify --all --json` sets json=true.
    @Test("AC5/parse: 'verify --all --json' routes to verifyAll with json=true")
    func verifyAllJsonParsesAndDispatches() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all", "--json"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        // With an empty store, --json emits a valid empty report, exit 0.
        #expect(r.exitCode == 0)
        // Output must parse as JSON with an empty entries array.
        let data = Data(r.standardOutput.utf8)
        let report = try CommandCoding.decoder.decode(VerifyAllReport.self, from: data)
        #expect(report.entries.isEmpty)
    }

    // AC5 (parse boundary) — `verify --all` (no --json) still works as before.
    @Test("AC5/parse: 'verify --all' (no --json) still routes to verifyAll with json=false")
    func verifyAllNoJsonStillWorks() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("0 recorded"))
    }

    // AC5 (parse boundary) — `verify --json --all` (wrong order) → exit 64.
    @Test("AC5/parse: 'verify --json --all' is a parse error (exit 64)")
    func verifyJsonBeforeAllIsError() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--json", "--all"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        // Falls through to frozen verify arm → unknown option --json → exit 64.
        #expect(r.exitCode == 64)
    }

    // AC5 (parse boundary) — `verify --json` (no --all) → exit 64.
    @Test("AC5/parse: 'verify --json' is a parse error (exit 64)")
    func verifyJsonAloneIsError() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--json"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
    }

    // AC5 (parse boundary) — `verify --all --json --json` (duplicate) → exit 64.
    @Test("AC5/parse: 'verify --all --json --json' (duplicate flag) is a parse error (exit 64)")
    func verifyAllJsonDuplicateIsError() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all", "--json", "--json"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
    }

    // AC5 (parse boundary) — `verify --all --strict-untracked` → exit 64 (unchanged).
    @Test("AC5/parse: 'verify --all --strict-untracked' is still a parse error (exit 64)")
    func verifyAllStrictUntrackedStillError() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all", "--strict-untracked"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
    }

    // AC5 (parse boundary) — `verify --all <path>` → exit 64 (unchanged).
    @Test("AC5/parse: 'verify --all <path>' is still a parse error (exit 64)")
    func verifyAllWithPositionalStillError() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all", "/some/path"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
    }

    // Usage text includes the exact string `verify --all [--json]`.
    // Asserting the full phrase (not just "--json" alone) avoids a vacuous match —
    // "--json" already appears in other usage lines (e.g. `goh ls [--json]`).
    @Test("usage text includes 'verify --all [--json]'")
    func usageTextIncludesJsonFlag() {
        let r = GohCommandLine(
            arguments: ["--help"],
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.standardOutput.contains("verify --all [--json]"))
    }
}
