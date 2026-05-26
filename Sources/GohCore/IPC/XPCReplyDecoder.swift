import Foundation
import XPC

/// The outcome of decoding a daemon response into either the expected reply
/// payload or a typed `GohError`.
///
/// Every CLI verb shares the same reply-or-error dispatch over the XPC
/// envelope (see `DESIGN.md` §1.1, §1.2). Callers translate the outcome into
/// their own error type; the `requestID` is returned so each caller can apply
/// its own correlation policy.
public enum GohReplyOutcome<Reply: Codable & Sendable>: Sendable {
    case reply(requestID: UUID, payload: Reply)
    case daemonError(requestID: UUID, error: GohError)
    case malformed
}

extension XPCDictionary {
    /// Decodes this XPC response into a typed reply or a typed `GohError`,
    /// returning `.malformed` if neither envelope shape parses.
    ///
    /// The four envelope keys are read via primitive XPC accessors before the
    /// payload is decoded (see `DESIGN.md` §4.3), so a future-version payload
    /// that fails to decode still yields a `.daemonError` if the daemon
    /// emitted an error envelope.
    public func decodeGohReply<Reply: Codable & Sendable>(
        as _: Reply.Type
    ) -> GohReplyOutcome<Reply> {
        withUnsafeUnderlyingDictionary { object in
            if let reply = try? GohEnvelope<Reply>(xpcDictionary: object),
               reply.messageType == .reply
            {
                return .reply(requestID: reply.requestID, payload: reply.payload)
            }
            if let error = try? GohEnvelope<GohError>(xpcDictionary: object),
               error.messageType == .error
            {
                return .daemonError(requestID: error.requestID, error: error.payload)
            }
            return .malformed
        }
    }
}
