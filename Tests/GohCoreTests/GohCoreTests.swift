import Testing

@testable import GohCore

@Suite("GohCore bootstrap")
struct GohCoreBootstrapTests {
    @Test("module identity is reported")
    func moduleName() {
        #expect(GohCore.moduleName == "GohCore")
    }
}
