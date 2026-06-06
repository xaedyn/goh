import Foundation
import Testing
@testable import GohMenuBar

// AC3: login-item protocol + status enum; stubbed service; unsupported path.
@Suite("GohMenuLoginItem")
struct GohMenuLoginItemTests {

    // AC3: stub returns scripted status — enabled
    @Test func stubReturnsEnabled() {
        let stub = StubLoginItem(status: .enabled)
        #expect(stub.status() == .enabled)
    }

    // AC3: stub returns requiresApproval — UI must render this honestly
    @Test func stubReturnsRequiresApproval() {
        let stub = StubLoginItem(status: .requiresApproval)
        #expect(stub.status() == .requiresApproval)
    }

    // AC3: unsupported path — bare binary without .app bundle
    @Test func unsupportedLoginItemReturnsUnsupported() {
        let item = UnsupportedLoginItem()
        #expect(item.status() == .unsupported)
    }

    // AC3: unsupported register throws
    @Test func unsupportedRegisterThrows() throws {
        let item = UnsupportedLoginItem()
        #expect(throws: (any Error).self) {
            try item.register()
        }
    }

    // AC3: stub records register/unregister calls
    @Test func stubRecordsCalls() throws {
        let stub = StubLoginItem(status: .notRegistered)
        try stub.register()
        #expect(stub.registerCallCount == 1)
        try stub.unregister()
        #expect(stub.unregisterCallCount == 1)
    }
}

// MARK: - Test helpers

final class StubLoginItem: GohMenuLoginItem, @unchecked Sendable {
    private let stubbedStatus: GohLoginItemStatus
    var registerCallCount = 0
    var unregisterCallCount = 0

    nonisolated init(status: GohLoginItemStatus) {
        self.stubbedStatus = status
    }

    nonisolated func status() -> GohLoginItemStatus { stubbedStatus }
    nonisolated func register() throws { registerCallCount += 1 }
    nonisolated func unregister() throws { unregisterCallCount += 1 }
}
