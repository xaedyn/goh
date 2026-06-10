// Tests/GohCoreTests/Support/LsReplyTestSupport.swift
import Foundation
import XPC
@testable import GohCore

/// Encodes an LsReply into the wire format `GohCommandClient.send` expects,
/// echoing the request's requestID (required by `decodeGohReply`).
///
/// Usage: `makeLsSender(reply: LsReply(jobs: [], featureLevel: 1))`
func makeLsSender(reply: LsReply) -> GohCommandLine.Sender {
    { requestDict in
        // Decode the incoming request envelope to extract the requestID.
        let envelope = try requestDict.withUnsafeUnderlyingDictionary { dict in
            try GohEnvelope<Command>(xpcDictionary: dict)
        }
        let replyDict = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: envelope.requestID,
            messageType: .reply,
            payload: reply)
            .xpcDictionary()
        return XPCDictionary(replyDict)
    }
}

/// A sender that returns a sequence of LsReplies, one per call.
/// After the sequence is exhausted, repeats the last reply.
final class SequencedLsSender: @unchecked Sendable {
    private var replies: [LsReply]
    private var index = 0

    init(replies: [LsReply]) {
        precondition(!replies.isEmpty)
        self.replies = replies
    }

    func sender() -> GohCommandLine.Sender {
        { [weak self] requestDict in
            guard let self else { fatalError("SequencedLsSender deallocated") }
            let reply = self.replies[min(self.index, self.replies.count - 1)]
            self.index += 1
            return try makeLsSender(reply: reply)(requestDict)
        }
    }
}

/// Shared stub restarter for DaemonAutoHeal and verify-command tests.
/// Defined here (not private) so it is accessible across all GohCoreTests files.
final class StubRestarter: DaemonRestarting, @unchecked Sendable {
    private(set) var kickstartCalled = 0
    var shouldSucceed: Bool
    init(shouldSucceed: Bool = true) { self.shouldSucceed = shouldSucceed }
    func kickstart() throws {
        kickstartCalled += 1
        if !shouldSucceed {
            throw DaemonRestartError.launchctlFailed(exitCode: 1, stderr: "stub")
        }
    }
}
