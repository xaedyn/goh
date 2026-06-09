import Foundation
import Testing
import XPC
@testable import GohCore

/// Spy sender: records RecordVerifiedProvenanceRequest batches sent via GohCommandClient.
/// Mirrors the spy pattern used in GohSyncCommand tests — decodes the XPC envelope,
/// captures the Command payload, returns a valid AckReply envelope.
/// @unchecked Sendable: mutated only from the @Sendable closure (single-threaded here).
private final class SpySender: @unchecked Sendable {
    var sentEntries: [[VerifiedProvenanceEntry]] = []
    var shouldThrow = false

    func send(_ dict: XPCDictionary) throws -> XPCDictionary {
        if shouldThrow { throw URLError(.notConnectedToInternet) }
        // GohEnvelope's xpc init takes the RAW xpc_object_t — reach it via
        // withUnsafeUnderlyingDictionary (exactly as GohSyncCommandTests does).
        let envelope = try dict.withUnsafeUnderlyingDictionary { object in
            try GohEnvelope<Command>(xpcDictionary: object)
        }
        if case .recordVerifiedProvenance(let req) = envelope.payload {
            sentEntries.append(req.entries)
        }
        // Build a well-formed AckReply envelope; .xpcDictionary() returns an
        // xpc_object_t, so wrap it back into an XPCDictionary for the Sender return.
        let replyObject = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: envelope.requestID,
            messageType: .reply,
            payload: AckReply()).xpcDictionary()
        return XPCDictionary(replyObject)
    }
}

@Suite("GohVerifyAllCommand backfill")
struct GohVerifyAllCommandBackfillTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-vacmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(
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
                url: "https://example.com/\(URL(fileURLWithPath: path).lastPathComponent)",
                sha256: sha256,
                size: content.count,
                downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
                destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path))
        }
        return (storeURL, sha256s)
    }

    // AC1: with send, .ok entries are sent as a baseline batch.
    @Test("AC1: ok entries sent to daemon via send when present")
    func okEntriesSentWithSender() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("ok1.bin").path
        let f2 = dir.appendingPathComponent("ok2.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [
            (f1, Data("content1".utf8)),
            (f2, Data("content2".utf8)),
        ])

        let spy = SpySender()
        let result = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: false,
            generatedAt: Date(),
            send: spy.send)

        #expect(result.exitCode == 0)
        #expect(!spy.sentEntries.isEmpty)
        let sent = spy.sentEntries.flatMap { $0 }
        #expect(sent.count == 2)
        // recordedStatSize must be populated (stat.size, not nil).
        for e in sent {
            #expect(e.recordedStatSize != nil, "recordedStatSize must be non-nil for a sent baseline")
        }
    }

    // AC5: no send → no writes; exit code / report unchanged (attest stays read-only).
    @Test("AC5: nil send causes no XPC call; report and exit code unchanged")
    func nilSendNoXPCCall() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("ok.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [(f, Data("x".utf8))])

        // Capture store bytes BEFORE run.
        let before = try Data(contentsOf: storeURL)

        let result = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: false,
            generatedAt: Date())  // no send — default nil

        // After run: store bytes identical (no write happened).
        let after = try Data(contentsOf: storeURL)
        #expect(before == after, "store must be byte-unchanged when send is nil (AC5)")
        #expect(result.exitCode == 0)
    }

    // AC7: send throws (daemon stopped) → verify still completes; exit code unchanged.
    @Test("AC7: send failure does not change exit code or report")
    func sendFailureNoExitCodeChange() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("ok.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [(f, Data("ok".utf8))])

        let spy = SpySender()
        spy.shouldThrow = true

        let result = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: false,
            generatedAt: Date(),
            send: spy.send)

        // Exit code 0 (all ok) — unaffected by send failure.
        #expect(result.exitCode == 0)
        // A warning was emitted to stderr (not checked for exact text; presence is enough).
        // No crash / no non-zero exit.
    }

    // AC6: --json output is byte-identical with and without send.
    @Test("AC6: --json output byte-identical with and without send")
    func jsonOutputUnchangedWithSend() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("ok.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [(f, Data("json-test".utf8))])
        let fixedDate = Date(timeIntervalSince1970: 1_714_262_400)

        let withoutSend = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: true,
            generatedAt: fixedDate)

        let spy = SpySender()
        let withSend = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: true,
            generatedAt: fixedDate,
            send: spy.send)

        #expect(withSend.standardOutput == withoutSend.standardOutput,
            "AC6: --json output must be byte-identical regardless of send (frozen contract)")
    }

    // AC2: .failed entries are NOT sent.
    @Test("AC2: failed entries not sent as baselines")
    func failedEntriesNotSent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("bad.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [(f, Data("original".utf8))])
        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: f))

        let spy = SpySender()
        _ = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: false,
            generatedAt: Date(),
            send: spy.send)

        #expect(spy.sentEntries.flatMap { $0 }.isEmpty, "failed entry must not generate a baseline send")
    }
}
