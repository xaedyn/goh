import Foundation
import Testing

@testable import GohCore

@Suite("GohCore bootstrap")
struct GohCoreBootstrapTests {
    @Test("module identity is reported")
    func moduleName() {
        #expect(GohCore.moduleName == "GohCore")
    }

    @Test("the User-Agent identifies goh and carries a contact URL")
    func userAgentIdentifiesClient() {
        #expect(GohCore.userAgent.hasPrefix("goh/"))
        #expect(GohCore.userAgent.contains("github.com/xaedyn/goh"))
    }

    @Test("the download session configuration sets the User-Agent and the per-host cap")
    func downloadSessionConfigurationIsConfigured() {
        let configuration = GohCore.downloadSessionConfiguration()
        #expect(
            configuration.httpAdditionalHeaders?["User-Agent"] as? String == GohCore.userAgent)
        #expect(configuration.httpMaximumConnectionsPerHost == 16)
    }
}
