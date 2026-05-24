import Foundation
import Testing

import GohCore

@Suite("Command schema wire forms")
struct CommandTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try CommandCoding.decoder.decode(T.self, from: CommandCoding.encoder.encode(value))
    }

    @Test("AddRequest round-trips, minimal and full")
    func addRequestRoundTrip() throws {
        let minimal = AddRequest(url: "https://example.com/f.iso")
        #expect(try roundTrip(minimal) == minimal)

        let full = AddRequest(
            url: "https://example.com/f.iso",
            destination: "/tmp/f.iso",
            connectionCount: 16,
            useImportedCookies: false,
            priority: .high)
        #expect(try roundTrip(full) == full)
    }

    @Test("RmRequest round-trips, with and without keepPartialFile")
    func rmRequestRoundTrip() throws {
        let bare = RmRequest(jobID: 7)
        #expect(try roundTrip(bare) == bare)
        let kept = RmRequest(jobID: 7, keepPartialFile: true)
        #expect(try roundTrip(kept) == kept)
    }

    @Test("AuthImportSafari request and reply round-trip")
    func authImportSafariRequestAndReplyRoundTrip() throws {
        let request = AuthImportSafariRequest()
        #expect(try roundTrip(request) == request)

        let reply = AuthImportSafariReply(importedCookieCount: 42)
        #expect(try roundTrip(reply) == reply)
    }

    @Test("every Command case round-trips")
    func commandRoundTrip() throws {
        let commands: [Command] = [
            .add(request: AddRequest(url: "https://example.com/f")),
            .ls,
            .pause(jobID: 3),
            .resume(jobID: 3),
            .rm(request: RmRequest(jobID: 3)),
            .authImportSafari(request: AuthImportSafariRequest()),
        ]
        for command in commands {
            #expect(try roundTrip(command) == command)
        }
    }

    @Test("LsReply and RmReply round-trip")
    func replyRoundTrip() throws {
        let rm = RmReply(removedJobID: 9)
        #expect(try roundTrip(rm) == rm)
        let ls = LsReply(jobs: [])
        #expect(try roundTrip(ls) == ls)
    }
}
