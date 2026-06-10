import Foundation
import Testing
import XPC
@testable import GohCore

// MARK: - Test support

/// Builds a fake XPC sender that handles .ls and .forgetProvenance.
/// `featureLevel`: the level to report in the LsReply (nil = old daemon).
/// `forgotCount`: the count to report in ForgetProvenanceReply.
private func makeFakeSender(
    featureLevel: Int?,
    forgotCount: Int
) -> GohCommandLine.Sender {
    { requestDict in
        try requestDict.withUnsafeUnderlyingDictionary { rawRequest in
            guard let envelope = try? GohEnvelope<Command>(xpcDictionary: rawRequest) else {
                throw GohCommandClientError.malformedReply("bad request")
            }
            switch envelope.payload {
            case .ls:
                let reply = LsReply(jobs: [], featureLevel: featureLevel)
                return try XPCDictionary(GohEnvelope(
                    protocolVersion: CommandService.protocolVersion,
                    requestID: envelope.requestID,
                    messageType: .reply,
                    payload: reply).xpcDictionary())
            case .forgetProvenance:
                let reply = ForgetProvenanceReply(forgotCount: forgotCount)
                return try XPCDictionary(GohEnvelope(
                    protocolVersion: CommandService.protocolVersion,
                    requestID: envelope.requestID,
                    messageType: .reply,
                    payload: reply).xpcDictionary())
            default:
                throw GohCommandClientError.malformedReply("unexpected command")
            }
        }
    }
}

/// A spy sender that records every Command sent through it.
private final class CommandSpySender: @unchecked Sendable {
    var commands: [Command] = []
    var featureLevel: Int?
    var forgotCount: Int = 0

    lazy var send: GohCommandLine.Sender = { [weak self] requestDict in
        guard let self else { throw GohCommandClientError.malformedReply("sender deallocated") }
        return try requestDict.withUnsafeUnderlyingDictionary { rawRequest in
            guard let envelope = try? GohEnvelope<Command>(xpcDictionary: rawRequest) else {
                throw GohCommandClientError.malformedReply("bad request")
            }
            self.commands.append(envelope.payload)
            switch envelope.payload {
            case .ls:
                let reply = LsReply(jobs: [], featureLevel: self.featureLevel)
                return try XPCDictionary(GohEnvelope(
                    protocolVersion: CommandService.protocolVersion,
                    requestID: envelope.requestID,
                    messageType: .reply,
                    payload: reply).xpcDictionary())
            case .forgetProvenance(let req):
                let count = min(self.forgotCount, req.paths.count)
                let reply = ForgetProvenanceReply(forgotCount: count)
                return try XPCDictionary(GohEnvelope(
                    protocolVersion: CommandService.protocolVersion,
                    requestID: envelope.requestID,
                    messageType: .reply,
                    payload: reply).xpcDictionary())
            default:
                throw GohCommandClientError.malformedReply("unexpected command in spy")
            }
        }
    }
}

// MARK: - Provenance store helpers

private func makeTempStore() throws -> (store: ProvenanceStore, path: String) {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "goh-forget-cmd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "provenance.plist")
    let store = ProvenanceStore(fileURL: url)
    return (store, url.path)
}

private func addEntry(to store: ProvenanceStore, path: String, url: String = "https://example.com/f.bin") throws {
    let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
    try store.record(entry: ProvenanceEntry(
        url: url,
        sha256: "sha256:" + String(repeating: "a", count: 64),
        size: 1024,
        downloadedAt: Date(timeIntervalSince1970: 0),
        destinationPath: canonical,
        verifiedAt: nil))
}

// MARK: - Tests

@Suite("GohForgetCommand")
struct GohForgetCommandTests {

    // MARK: - AC3: untracked path

    @Test("AC3 — forget untracked path exits 1 with 'not tracked' message")
    func testForgetUntrackedPathExits1WithNotTrackedMessage() throws {
        let (_, storePath) = try makeTempStore()
        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 0
        let result = GohForgetCommand.run(
            path: "/tmp/untracked-\(UUID().uuidString).bin",
            provenanceStorePath: storePath,
            send: spy.send)
        #expect(result.exitCode == 1)
        #expect(result.standardError.contains("not tracked"))
        #expect(result.standardOutput.isEmpty)
    }

    @Test("AC3 — forget untracked path never sends a command to the daemon")
    func testForgetUntrackedNeverSendsCommand() throws {
        let (_, storePath) = try makeTempStore()
        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 0
        _ = GohForgetCommand.run(
            path: "/tmp/never-tracked-\(UUID().uuidString).bin",
            provenanceStorePath: storePath,
            send: spy.send)
        // Only .ls may be sent (as part of auto-heal); forgetProvenance must NOT be sent.
        let forgotSent = spy.commands.contains { if case .forgetProvenance = $0 { return true }; return false }
        #expect(!forgotSent, "forgetProvenance must never be sent for an untracked path")
    }

    @Test("AC3 — corrupt ledger exits 6 (not silently 'not tracked'), sends nothing")
    func testForgetCorruptLedgerExits6SendsNothing() throws {
        // Write a file at the store path that is not a valid binary plist.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "goh-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storePath = dir.appending(path: "provenance.plist").path
        try Data("not a plist at all".utf8).write(to: URL(fileURLWithPath: storePath))

        let spy = CommandSpySender()
        spy.featureLevel = 2
        let result = GohForgetCommand.run(
            path: "/tmp/any-path.bin",
            provenanceStorePath: storePath,
            send: spy.send)
        #expect(result.exitCode == 6, "corrupt ledger must exit 6, not 1")
        #expect(result.standardError.contains("corrupt") || result.standardError.contains("unreadable"))
        let forgotSent = spy.commands.contains { if case .forgetProvenance = $0 { return true }; return false }
        #expect(!forgotSent, "must not send forgetProvenance when ledger is corrupt")
    }

    // MARK: - AC1: tracked path, explicit forget

    @Test("AC1 — forget tracked path exits 0 with confirmation line naming the path")
    func testForgetTrackedPathExits0WithConfirmation() throws {
        let (store, storePath) = try makeTempStore()
        let path = "/tmp/tracked-\(UUID().uuidString).bin"
        try addEntry(to: store, path: path)
        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 1
        let result = GohForgetCommand.run(
            path: path,
            provenanceStorePath: storePath,
            send: spy.send)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("Forgot"))
        #expect(result.standardError.isEmpty)
    }

    @Test("AC1 — forget tracked path sends exactly one forgetProvenance command")
    func testForgetTrackedPathSendsOneForgetProvenance() throws {
        let (store, storePath) = try makeTempStore()
        let path = "/tmp/oneshot-\(UUID().uuidString).bin"
        try addEntry(to: store, path: path)
        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 1
        _ = GohForgetCommand.run(
            path: path,
            provenanceStorePath: storePath,
            send: spy.send)
        let forgetCommands = spy.commands.filter { if case .forgetProvenance = $0 { return true }; return false }
        #expect(forgetCommands.count == 1)
    }

    @Test("AC1 — forgotCount == 0 on tracked path (rare race) exits 1 — no clean success")
    func testForgotCount0OnTrackedPathIsNonSuccess() throws {
        let (store, storePath) = try makeTempStore()
        let path = "/tmp/race-\(UUID().uuidString).bin"
        try addEntry(to: store, path: path)
        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 0  // simulate: path was removed between lookup and send
        let result = GohForgetCommand.run(
            path: path,
            provenanceStorePath: storePath,
            send: spy.send)
        #expect(result.exitCode == 1)
        #expect(result.standardOutput.contains("Forgot") == false)
    }

    // MARK: - gap #1: stale daemon / unreachable daemon

    @Test("gap #1 — daemon too old (featureLevel 1) → exits 1, no forgetProvenance sent")
    func testDaemonTooOldEmitsErrorExits1SendsNothing() throws {
        let (store, storePath) = try makeTempStore()
        let path = "/tmp/stale-\(UUID().uuidString).bin"
        try addEntry(to: store, path: path)
        let spy = CommandSpySender()
        spy.featureLevel = 1  // old daemon
        spy.forgotCount = 0
        let result = GohForgetCommand.run(
            path: path,
            provenanceStorePath: storePath,
            send: spy.send)
        #expect(result.exitCode == 1)
        #expect(result.standardError.lowercased().contains("too old") ||
                result.standardError.lowercased().contains("restart"))
        let forgotSent = spy.commands.contains { if case .forgetProvenance = $0 { return true }; return false }
        #expect(!forgotSent, "forgetProvenance must never be sent to a stale daemon")
    }

    @Test("gap #1 — daemon featureLevel nil → exits 1, no forgetProvenance sent")
    func testDaemonFeatureLevelNilEmitsErrorExits1() throws {
        let (store, storePath) = try makeTempStore()
        let path = "/tmp/nilfl-\(UUID().uuidString).bin"
        try addEntry(to: store, path: path)
        let spy = CommandSpySender()
        spy.featureLevel = nil  // very old daemon, no featureLevel field
        spy.forgotCount = 0
        let result = GohForgetCommand.run(
            path: path,
            provenanceStorePath: storePath,
            send: spy.send)
        #expect(result.exitCode == 1)
        let forgotSent = spy.commands.contains { if case .forgetProvenance = $0 { return true }; return false }
        #expect(!forgotSent)
    }

    @Test("gap #1 — daemon unreachable (ls throws) → exits 1, sends nothing, 'cannot reach' message")
    func testDaemonUnreachableEmitsErrorExits1SendsNothing() throws {
        let (store, storePath) = try makeTempStore()
        let path = "/tmp/unreachable-\(UUID().uuidString).bin"
        try addEntry(to: store, path: path)
        struct UnreachableError: Error {}
        let unreachableSend: GohCommandLine.Sender = { _ in throw UnreachableError() }
        let result = GohForgetCommand.run(
            path: path,
            provenanceStorePath: storePath,
            send: unreachableSend)
        #expect(result.exitCode == 1)
        #expect(result.standardError.lowercased().contains("cannot reach") ||
                result.standardError.lowercased().contains("daemon"))
    }

    // MARK: - AC2: --missing dry-run

    @Test("AC2 — --missing dry-run never mutates the ledger (byte-identical before/after)")
    func testMissingDryRunNeverMutatesLedger() throws {
        let (store, storePath) = try makeTempStore()
        // Add one tracked entry pointing to a nonexistent path.
        let missingPath = "/tmp/definitely-does-not-exist-\(UUID().uuidString).bin"
        try addEntry(to: store, path: missingPath)
        let beforeData = try Data(contentsOf: URL(fileURLWithPath: storePath))
        let spy = CommandSpySender()
        spy.featureLevel = 2
        _ = GohForgetCommand.runMissing(
            provenanceStorePath: storePath,
            confirm: false,
            send: spy.send)
        let afterData = try Data(contentsOf: URL(fileURLWithPath: storePath))
        #expect(beforeData == afterData, "dry-run must leave the ledger byte-identical")
        let forgotSent = spy.commands.contains { if case .forgetProvenance = $0 { return true }; return false }
        #expect(!forgotSent, "dry-run must never send forgetProvenance")
    }

    @Test("AC2 — --missing dry-run lists absent paths, zero candidates → 'No missing entries.'")
    func testMissingDryRunNoCandidatesMessage() throws {
        let (_, storePath) = try makeTempStore()  // empty ledger
        let spy = CommandSpySender()
        spy.featureLevel = 2
        let result = GohForgetCommand.runMissing(
            provenanceStorePath: storePath,
            confirm: false,
            send: spy.send)
        #expect(result.exitCode == 0)
        // Empty ledger → "No tracked entries."
        #expect(result.standardOutput.contains("No tracked entries") ||
                result.standardOutput.contains("No missing entries"))
    }

    @Test("AC2 — --missing --confirm forgets all absent, leaves present entries intact")
    func testMissingConfirmForgetsAllAbsentLeavesPresent() throws {
        let (store, storePath) = try makeTempStore()
        let missingPath = "/tmp/gone-\(UUID().uuidString).bin"
        // Add a tracked missing path and a tracked present path.
        try addEntry(to: store, path: missingPath)
        // Create a real present file:
        let presentDir = FileManager.default.temporaryDirectory
            .appending(path: "goh-present-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: presentDir, withIntermediateDirectories: true)
        let presentPath = presentDir.appending(path: "present.bin").path
        try Data("content".utf8).write(to: URL(fileURLWithPath: presentPath))
        try addEntry(to: store, path: presentPath)

        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 1  // expect 1 missing path forgotten

        let result = GohForgetCommand.runMissing(
            provenanceStorePath: storePath,
            confirm: true,
            send: spy.send)
        #expect(result.exitCode == 0)
        // Exactly one forgetProvenance was sent.
        let forgetCmds = spy.commands.filter { if case .forgetProvenance = $0 { return true }; return false }
        #expect(forgetCmds.count == 1)
        // The forgetProvenance paths contained only the missing path, not the present path.
        if case .forgetProvenance(let req) = forgetCmds.first {
            let canonical = URL(fileURLWithPath: missingPath).standardizedFileURL.path
            #expect(req.paths.contains(canonical) || req.paths.contains(missingPath))
            #expect(!req.paths.contains(URL(fileURLWithPath: presentPath).standardizedFileURL.path),
                    "present-file paths must never appear in the forgetProvenance request")
        }
    }

    @Test("AC2 — --missing --confirm sends stored destinationPath strings verbatim")
    func testMissingConfirmSendsStoredPathsVerbatim() throws {
        let (store, storePath) = try makeTempStore()
        let canonical = "/tmp/verbatim-\(UUID().uuidString)/file.bin"
        // Insert with a slightly different input (trailing slash stripped) to confirm stored form.
        let entry = ProvenanceEntry(
            url: "https://example.com/f.bin",
            sha256: "sha256:" + String(repeating: "a", count: 64),
            size: 1024,
            downloadedAt: Date(timeIntervalSince1970: 0),
            destinationPath: canonical,
            verifiedAt: nil)
        try store.record(entry: entry)

        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 1
        _ = GohForgetCommand.runMissing(
            provenanceStorePath: storePath,
            confirm: true,
            send: spy.send)
        let forgetCmds = spy.commands.filter { if case .forgetProvenance = $0 { return true }; return false }
        // Guard so the verbatim-path assertion below cannot pass vacuously if nothing was sent.
        #expect(forgetCmds.count == 1)
        if case .forgetProvenance(let req) = forgetCmds.first {
            // The path in the request must be exactly the stored canonical string — not re-canonicalized.
            #expect(req.paths == [canonical],
                    "CLI must send stored destinationPath verbatim, not re-canonicalize")
        }
    }

    @Test("AC2 — forgotCount < K on --missing --confirm is a non-success (exit non-zero)")
    func testPartialForgotCountSurfacesNonSuccess() throws {
        let (store, storePath) = try makeTempStore()
        let p1 = "/tmp/partial-1-\(UUID().uuidString).bin"
        let p2 = "/tmp/partial-2-\(UUID().uuidString).bin"
        try addEntry(to: store, path: p1)
        try addEntry(to: store, path: p2)
        let spy = CommandSpySender()
        spy.featureLevel = 2
        spy.forgotCount = 1  // only 1 of 2 removed — simulate race
        let result = GohForgetCommand.runMissing(
            provenanceStorePath: storePath,
            confirm: true,
            send: spy.send)
        #expect(result.exitCode != 0)
        // Must not print a clean success line.
        #expect(!result.standardOutput.lowercased().contains("forgot 2"))
    }
}
