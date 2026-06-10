import Testing
import Foundation
import GohCore

@Suite("GohFeatureLevel")
struct DaemonFeatureLevelTests {

    @Test("current is a positive integer and equals 1")
    func currentIsOne() {
        #expect(GohFeatureLevel.current == 1)
    }

    @Test("LsReply encodes featureLevel and old decoder round-trips without it")
    func lsReplyFeatureLevelRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // New daemon → new client: featureLevel encoded and decoded.
        let withLevel = LsReply(jobs: [], featureLevel: 1)
        let data = try encoder.encode(withLevel)
        let decoded = try decoder.decode(LsReply.self, from: data)
        #expect(decoded.featureLevel == 1)

        // Old daemon (no featureLevel key) → new client: decodes as nil.
        let oldJson = #"{"jobs":[]}"#.data(using: .utf8)!
        let fromOld = try decoder.decode(LsReply.self, from: oldJson)
        #expect(fromOld.featureLevel == nil)

        // New daemon → old client: adding the key must not break decoding
        // of a shape that already ignores unknown keys (JSON decoder default).
        let newJson = #"{"jobs":[],"featureLevel":1}"#.data(using: .utf8)!
        let fromNew = try decoder.decode(LsReply.self, from: newJson)
        #expect(fromNew.featureLevel == 1)
    }

    @Test("CommandDispatcher.ls reply includes GohFeatureLevel.current")
    func dispatcherLsSetsFeatureLevel() {
        let store = JobStore()
        let dispatcher = CommandDispatcher(store: store)
        let outcome = dispatcher.reply(to: .ls)
        guard case .list(let reply) = outcome else {
            Issue.record("expected .list outcome, got \(outcome)")
            return
        }
        #expect(reply.featureLevel == GohFeatureLevel.current)
    }
}
