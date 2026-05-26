import Foundation
import Testing
import XPC

@testable import GohCore

@Suite("XPCReplyDecoder")
struct XPCReplyDecoderTests {

    private func makeDictionary<Payload: Codable & Sendable>(
        requestID: UUID,
        messageType: MessageType,
        payload: Payload
    ) throws -> XPCDictionary {
        let envelope = GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: messageType,
            payload: payload)
        return XPCDictionary(try envelope.xpcDictionary())
    }

    @Test("a reply envelope decodes into .reply with the originating requestID")
    func decodesReply() throws {
        let requestID = UUID()
        let payload = LsReply(jobs: [])
        let dictionary = try makeDictionary(
            requestID: requestID, messageType: .reply, payload: payload)

        let outcome = dictionary.decodeGohReply(as: LsReply.self)
        guard case .reply(let id, let decoded) = outcome else {
            Issue.record("expected .reply, got \(outcome)")
            return
        }
        #expect(id == requestID)
        #expect(decoded == payload)
    }

    @Test("an error envelope decodes into .daemonError with the originating requestID")
    func decodesDaemonError() throws {
        let requestID = UUID()
        let error = GohError(
            code: .protocolVersionMismatch,
            message: "client and daemon builds differ")
        let dictionary = try makeDictionary(
            requestID: requestID, messageType: .error, payload: error)

        let outcome = dictionary.decodeGohReply(as: LsReply.self)
        guard case .daemonError(let id, let decoded) = outcome else {
            Issue.record("expected .daemonError, got \(outcome)")
            return
        }
        #expect(id == requestID)
        #expect(decoded == error)
    }

    @Test("a request-direction envelope decodes into .malformed")
    func requestDirectionIsMalformed() throws {
        let dictionary = try makeDictionary(
            requestID: UUID(),
            messageType: .request,
            payload: Command.ls)

        let outcome = dictionary.decodeGohReply(as: LsReply.self)
        guard case .malformed = outcome else {
            Issue.record("expected .malformed for a .request envelope, got \(outcome)")
            return
        }
    }

    @Test("a notification-direction envelope decodes into .malformed for a reply consumer")
    func notificationDirectionIsMalformed() throws {
        let event = ProgressEvent(
            sequence: 0,
            revision: 0,
            emittedAt: Date(timeIntervalSince1970: 0),
            updateKind: .fullSnapshot,
            snapshot: [])
        let dictionary = try makeDictionary(
            requestID: UUID(),
            messageType: .notification,
            payload: event)

        let outcome = dictionary.decodeGohReply(as: LsReply.self)
        guard case .malformed = outcome else {
            Issue.record("expected .malformed for a .notification envelope, got \(outcome)")
            return
        }
    }

    @Test("a payload whose shape does not match Reply decodes into .malformed")
    func wrongPayloadShapeIsMalformed() throws {
        // Wire shape is a reply, but its payload is a GohError — neither matches
        // the LsReply consumer (the payload is the wrong shape for `Reply`) nor
        // the error branch (the messageType is `.reply`, not `.error`).
        let dictionary = try makeDictionary(
            requestID: UUID(),
            messageType: .reply,
            payload: GohError(code: .invalidArgument))

        let outcome = dictionary.decodeGohReply(as: LsReply.self)
        guard case .malformed = outcome else {
            Issue.record("expected .malformed for a payload-shape mismatch, got \(outcome)")
            return
        }
    }
}
