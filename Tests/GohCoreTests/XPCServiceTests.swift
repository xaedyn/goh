import Foundation
import Testing

import GohCore

@Suite("XPC service identity and peer-validation policy")
struct XPCServiceTests {

    @Test("peer validation is enforced by default")
    func enforcedByDefault() {
        #expect(GohXPCService.peerValidationMode(environment: [:]) == .enforced)
    }

    @Test("peer validation is enforced when the relaxation variable is absent")
    func enforcedWithoutRelaxationVariable() {
        #expect(
            GohXPCService.peerValidationMode(environment: ["PATH": "/usr/bin"]) == .enforced)
    }

    #if DEBUG
    @Test("the development relaxation activates only with the opt-in variable")
    func relaxationActivatesWithOptInVariable() {
        let environment = [GohXPCService.developmentRelaxationEnvironmentKey: "1"]
        #expect(
            GohXPCService.peerValidationMode(environment: environment) == .relaxedForDevelopment)
    }
    #endif

    @Test("the Mach service name matches the LaunchAgent plist's MachServices key")
    func machServiceNameMatchesPlist() throws {
        let plistURL = Self.repositoryRoot.appending(path: "Resources/dev.goh.daemon.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any])
        let machServices = try #require(plist["MachServices"] as? [String: Any])
        #expect(machServices[GohXPCService.machServiceName] != nil)
    }

    /// The repository root, located relative to this test source file
    /// (`Tests/GohCoreTests/XPCServiceTests.swift`).
    static let repositoryRoot: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()  // Tests/GohCoreTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // repository root
}
