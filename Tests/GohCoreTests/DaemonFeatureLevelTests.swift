import Testing
import GohCore

@Suite("GohFeatureLevel")
struct DaemonFeatureLevelTests {

    @Test("current is a positive integer and equals 1")
    func currentIsOne() {
        #expect(GohFeatureLevel.current == 1)
    }
}
