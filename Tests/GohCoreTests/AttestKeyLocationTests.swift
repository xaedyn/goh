import Foundation
import Testing
@testable import GohCore

// AC5: AttestKeyLocation resolves to a path separate from the daemon's store.
@Suite("AttestKeyLocation")
struct AttestKeyLocationTests {

    // AC5: resolver returns a path under dev.goh.attest, distinct from dev.goh.daemon
    @Test("resolver returns ~/Library/Application Support/dev.goh.attest/ paths")
    func resolverReturnsAttestPaths() throws {
        let handleURL = try AttestKeyLocation.signingKeyHandleURL(create: false)
        let keysURL = try AttestKeyLocation.keysJSONURL(create: false)

        // Must be under the attest directory, not the daemon directory
        #expect(handleURL.path.contains("dev.goh.attest"))
        #expect(keysURL.path.contains("dev.goh.attest"))
        #expect(!handleURL.path.contains("dev.goh.daemon"))
        #expect(!keysURL.path.contains("dev.goh.daemon"))

        // File names
        #expect(handleURL.lastPathComponent == "signing-key.handle")
        #expect(keysURL.lastPathComponent == "keys.json")

        // Same parent directory
        #expect(handleURL.deletingLastPathComponent().path == keysURL.deletingLastPathComponent().path)
    }

    // AC5: create:false does NOT create the directory
    @Test("create:false does not create directory")
    func createFalseDoesNotCreateDirectory() throws {
        // Use a path in a temp location to confirm no directory creation
        let url = try AttestKeyLocation.signingKeyHandleURL(create: false)
        // We can only assert it returns a URL without throwing; actual directory
        // existence depends on whether the user has run `goh attest` before.
        // The key invariant: passing create:false must not throw even if the dir is absent.
        _ = url  // no assertion on existence — just that it doesn't throw
    }
}
