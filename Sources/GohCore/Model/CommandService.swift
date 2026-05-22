import Foundation
import XPC

/// The daemon's XPC command adapter (`DESIGN.md` §3).
///
/// `handle` is a message handler for a ``GohXPCListener``: it decodes the request
/// envelope into a ``Command``, runs the ``CommandDispatcher``, and encodes the
/// outcome as a reply envelope — `messageType` `reply` for a success, `error`
/// for a ``GohError`` — correlated to the request by `requestID`.
public struct CommandService: Sendable {

    /// The protocol version this daemon speaks.
    public static let protocolVersion: UInt32 = 1

    private let dispatcher: CommandDispatcher

    public init(dispatcher: CommandDispatcher) {
        self.dispatcher = dispatcher
    }

    /// Handles a request envelope dictionary and returns the reply envelope.
    ///
    /// A request that does not decode as a `GohEnvelope<Command>` yields no reply
    /// (`nil`): a correlated error reply for a malformed request needs a
    /// primitive `requestID` read (`DESIGN.md` §4.3) and is deferred. Encoding
    /// the reply cannot fail for these well-formed payload types.
    public func handle(_ request: XPCDictionary) -> XPCDictionary? {
        request.withUnsafeUnderlyingDictionary { requestObject -> XPCDictionary? in
            guard
                let envelope = try? GohEnvelope<Command>(xpcDictionary: requestObject),
                let reply = try? Self.encodeReply(
                    for: dispatcher.reply(to: envelope.payload),
                    requestID: envelope.requestID)
            else {
                return nil
            }
            return XPCDictionary(reply)
        }
    }

    /// Encodes `outcome` as a reply envelope dictionary, correlated by
    /// `requestID`.
    private static func encodeReply(
        for outcome: CommandOutcome, requestID: UUID
    ) throws -> xpc_object_t {
        switch outcome {
        case .job(let summary):
            return try replyEnvelope(requestID: requestID, payload: summary)
        case .list(let list):
            return try replyEnvelope(requestID: requestID, payload: list)
        case .removed(let removed):
            return try replyEnvelope(requestID: requestID, payload: removed)
        case .failure(let error):
            return try envelope(
                requestID: requestID, messageType: .error, payload: error)
        }
    }

    private static func replyEnvelope<Payload: Codable & Sendable>(
        requestID: UUID, payload: Payload
    ) throws -> xpc_object_t {
        try envelope(requestID: requestID, messageType: .reply, payload: payload)
    }

    private static func envelope<Payload: Codable & Sendable>(
        requestID: UUID, messageType: MessageType, payload: Payload
    ) throws -> xpc_object_t {
        try GohEnvelope(
            protocolVersion: protocolVersion,
            requestID: requestID,
            messageType: messageType,
            payload: payload
        ).xpcDictionary()
    }
}
