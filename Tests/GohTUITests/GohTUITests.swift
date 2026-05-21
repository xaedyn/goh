import Testing

@testable import GohTUI

@Suite("GohTUI bootstrap")
struct GohTUIBootstrapTests {
    // `GohTUI` is a MainActor-default target, so its members are MainActor-isolated;
    // the test runs on the main actor to read them synchronously.
    @Test("module identity is reported")
    @MainActor
    func moduleName() {
        #expect(GohTUI.moduleName == "GohTUI")
    }
}
