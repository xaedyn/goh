import Foundation
import Testing
@testable import GohCore

@Suite("CommandDispatcher — forgetProvenance")
struct CommandDispatcherForgetTests {

    private func makeTempStore(entries: [ProvenanceEntry] = []) throws -> ProvenanceStore {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "goh-dispatcher-forget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "provenance.plist")
        let store = ProvenanceStore(fileURL: url)
        for entry in entries { try store.record(entry: entry) }
        return store
    }

    private func entry(path: String) -> ProvenanceEntry {
        ProvenanceEntry(
            url: "https://example.com/f.bin",
            sha256: "sha256:" + String(repeating: "a", count: 64),
            size: 1024,
            downloadedAt: Date(timeIntervalSince1970: 0),
            destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path,
            verifiedAt: nil)
    }

    @Test("forgetProvenance removes matching entry — returns .forgotProvenance(count: 1)")
    func testForgetMatchingEntry() throws {
        let path = "/tmp/dispatch-\(UUID().uuidString).bin"
        let store = try makeTempStore(entries: [entry(path: path)])
        let dispatcher = CommandDispatcher(
            store: JobStore(),
            provenanceStore: store)
        let outcome = dispatcher.reply(to: .forgetProvenance(
            request: ForgetProvenanceRequest(paths: [path])))
        if case .forgotProvenance(let reply) = outcome {
            #expect(reply.forgotCount == 1)
        } else {
            Issue.record("expected .forgotProvenance, got \(outcome)")
        }
    }

    @Test("forgetProvenance with no matching path — returns .forgotProvenance(count: 0)")
    func testForgetNoMatchReturns0() throws {
        let store = try makeTempStore()
        let dispatcher = CommandDispatcher(store: JobStore(), provenanceStore: store)
        let outcome = dispatcher.reply(to: .forgetProvenance(
            request: ForgetProvenanceRequest(paths: ["/tmp/never-tracked.bin"])))
        if case .forgotProvenance(let reply) = outcome {
            #expect(reply.forgotCount == 0)
        } else {
            Issue.record("expected .forgotProvenance, got \(outcome)")
        }
    }

    @Test("forgetProvenance with no store configured — returns .forgotProvenance(count: 0), no crash")
    func testForgetNoStoreCaseForgotCount0() {
        let dispatcher = CommandDispatcher(store: JobStore(), provenanceStore: nil)
        let outcome = dispatcher.reply(to: .forgetProvenance(
            request: ForgetProvenanceRequest(paths: ["/tmp/x.bin"])))
        if case .forgotProvenance(let reply) = outcome {
            #expect(reply.forgotCount == 0)
        } else {
            Issue.record("expected .forgotProvenance, got \(outcome)")
        }
    }

    @Test("forgetProvenance multiple paths — returns correct count")
    func testForgetMultiplePaths() throws {
        let p1 = "/tmp/dm1-\(UUID().uuidString).bin"
        let p2 = "/tmp/dm2-\(UUID().uuidString).bin"
        let p3 = "/tmp/dm3-\(UUID().uuidString).bin"
        let store = try makeTempStore(entries: [entry(path: p1), entry(path: p2), entry(path: p3)])
        let dispatcher = CommandDispatcher(store: JobStore(), provenanceStore: store)
        let outcome = dispatcher.reply(to: .forgetProvenance(
            request: ForgetProvenanceRequest(paths: [p1, p2])))
        if case .forgotProvenance(let reply) = outcome {
            #expect(reply.forgotCount == 2)
        } else {
            Issue.record("expected .forgotProvenance, got \(outcome)")
        }
    }
}
