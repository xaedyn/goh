import Foundation
import Testing
import XPC

@testable import GohCore

/// T6.5 — `goh sync` is wired into the CLI parser and run dispatch.
@Suite("GohSyncCLIWiring")
struct GohSyncCLIWiringTests {

    /// A sender that fails the test if the daemon is ever contacted: the sync
    /// paths exercised here resolve before any add/ls.
    private func unusedSender() -> GohCommandLine.Sender {
        { _ in
            Issue.record("daemon should not be contacted in this path")
            throw NSError(domain: "unused", code: 0)
        }
    }

    @Test("usage lists the goh sync verb")
    func usageListsSync() {
        let cli = GohCommandLine(arguments: ["--help"], send: unusedSender())
        let result = cli.run()
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("goh sync"))
    }

    @Test("goh sync with a missing manifest exits 64 (routed to GohSyncCommand)")
    func syncMissingManifestExits64() throws {
        let dir = try SyncTestSupport.makeDir()
        let manifestPath = dir + "/does-not-exist.toml"
        let cli = GohCommandLine(arguments: ["sync", manifestPath], send: unusedSender())
        let result = cli.run()
        #expect(result.exitCode == 64)
    }

    @Test("goh sync with an empty manifest exits 0 and writes a lock")
    func syncEmptyManifestExits0() throws {
        let dir = try SyncTestSupport.makeDir()
        let manifestPath = dir + "/gohfile.toml"
        try "version = 1\n".write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let cli = GohCommandLine(arguments: ["sync", manifestPath], send: unusedSender())
        let result = cli.run()
        #expect(result.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: dir + "/gohfile.lock"))
    }

    @Test("goh sync rejects an unknown option as a usage error (64)")
    func syncUnknownOptionExits64() {
        let cli = GohCommandLine(arguments: ["sync", "--bogus"], send: unusedSender())
        let result = cli.run()
        #expect(result.exitCode == 64)
    }

    @Test("goh sync --accept-changed and --base parse without error")
    func syncFlagsParse() throws {
        let dir = try SyncTestSupport.makeDir()
        let manifestPath = dir + "/gohfile.toml"
        try "version = 1\n".write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let cli = GohCommandLine(
            arguments: ["sync", manifestPath, "--base", dir, "--accept-changed"],
            send: unusedSender())
        let result = cli.run()
        // Empty manifest → exits 0 regardless of flags.
        #expect(result.exitCode == 0)
    }
}
