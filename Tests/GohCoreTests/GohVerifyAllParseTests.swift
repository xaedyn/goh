import Foundation
import Testing
import XPC

@testable import GohCore

@Suite("GohCommandLine — verify --all parse and dispatch")
struct GohVerifyAllParseTests {

    private struct TestTransportError: Error {}

    // BLOCK-1: an empty, isolated TEMP store path — NEVER the real default.
    // No unit test in this suite may resolve `ProvenanceStoreLocation.defaultURL`:
    // doing so would re-hash and read the user's real ~/Library/Application Support
    // provenance ledger inside a unit test (non-deterministic + privacy violation).
    private func emptyTempStorePath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-verifyall-parse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The file does NOT exist → GohVerifyAllCommand reports "0 recorded entries".
        return dir.appendingPathComponent("provenance.plist").path
    }

    // T7b: `verify --all` parses to .verifyAll; dispatches to GohVerifyAllCommand.
    @Test("T7b: 'verify --all' parses and dispatches to the verify-all runner (not GohVerifyCommand)")
    func verifyAllParsesAndDispatches() throws {
        // BLOCK-1: inject an EMPTY TEMP store path via the resolver seam — never the
        // real default. With no store file, verify --all returns exit 0
        // ("0 recorded entries"). This confirms routing: exit 0 means verifyAll ran,
        // NOT GohVerifyCommand. (GohVerifyCommand returns exit 6 when no lockfile is found.)
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        // Exit 0 = verifyAll ran with an empty store (no daemon, no lockfile checked).
        // Exit 6 = verify (lock path) was routed instead — test fails.
        #expect(r.exitCode == 0)
        #expect(r.standardOutput.contains("0 recorded"))
    }

    // T7b: Frozen `verify` without --all still routes to GohVerifyCommand (exit 6 = no lockfile).
    // BLOCK-2: pass an explicit ABSOLUTE positional lockfile path pointing at a
    // guaranteed-absent file in a fresh temp dir. The `verify` parse arm accepts a
    // positional lockfile path, so `["verify", absentLock]` routes to
    // `.verify(lockPath: absentLock, …)` → `GohVerifyCommand.run` → exit 6 without
    // consulting the cwd at all. Zero cwd mutation.
    //
    // NOTE: do NOT mark this suite `.serialized` to fix cwd races — the racing tests live
    // in OTHER non-serialized suites (`GohCommandLineTests`, `GohSyncCommandTests`,
    // `GohVerifyCommandTests`, `GohWhichCommandTests`, `GohSyncCLIWiringTests`), so
    // per-suite serialization does not order them. The correct fix is removing the cwd
    // dependency entirely, which is what this implementation does.
    @Test("T7b: 'verify' without --all routes to GohVerifyCommand (frozen path, exit 6 no lockfile)")
    func verifyWithoutAllStillFrozen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-verify-frozen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Point at a guaranteed-absent lockfile — never create it.
        let absentLock = dir.appendingPathComponent("gohfile.lock").path

        let storePath = try emptyTempStorePath()  // BLOCK-1: still never the real default
        let r = GohCommandLine(
            arguments: ["verify", absentLock],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        // GohVerifyCommand with no lockfile at the explicit absolute path returns exit 6.
        // Exit 0 would mean verifyAll ran instead — which would be a routing bug.
        #expect(r.exitCode == 6)
    }

    // T7b: `verify --all --strict-untracked` is a parse error.
    // Parse errors are detected before the resolver runs, but inject the empty temp
    // path anyway so no code path can reach the real default.
    @Test("T7b: 'verify --all --strict-untracked' is a parse error (exit 64)")
    func verifyAllWithStrictUntrackedIsError() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all", "--strict-untracked"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
    }

    // T7b: `verify --all <path>` is a parse error.
    @Test("T7b: 'verify --all <path>' is a parse error (exit 64)")
    func verifyAllWithPositionalIsError() throws {
        let storePath = try emptyTempStorePath()
        let r = GohCommandLine(
            arguments: ["verify", "--all", "/some/lockfile.lock"],
            provenanceStorePathResolver: { storePath },
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.exitCode == 64)
    }

    // Usage text documents --all.
    @Test("usage text mentions 'verify --all'")
    func usageTextMentionsVerifyAll() {
        let r = GohCommandLine(
            arguments: ["--help"],
            send: { _ in throw TestTransportError() }
        ).run()
        #expect(r.standardOutput.contains("--all"))
    }
}
