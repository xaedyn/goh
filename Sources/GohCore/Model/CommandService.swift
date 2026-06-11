import Darwin
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
    public static let protocolVersion: UInt32 = 4

    private let dispatcher: CommandDispatcher
    private let authImportSafari: (@Sendable (Int32) -> CommandOutcome)?
    private let progress: ProgressBrokerHub?

    public init(
        dispatcher: CommandDispatcher,
        authImportSafari: (@Sendable (Int32) -> CommandOutcome)? = nil,
        progress: ProgressBrokerHub? = nil
    ) {
        self.dispatcher = dispatcher
        self.authImportSafari = authImportSafari
        self.progress = progress
    }

    /// Handles a request envelope dictionary and returns the reply envelope.
    ///
    /// A request that does not decode as a `GohEnvelope<Command>` yields no reply
    /// (`nil`): a correlated error reply for a malformed request needs a
    /// primitive `requestID` read (`DESIGN.md` §4.3) and is deferred. Encoding
    /// the reply cannot fail for these well-formed payload types.
    public func handle(_ request: XPCDictionary) -> XPCDictionary? {
        handle(request, session: nil)
    }

    /// Handles a request envelope with access to the accepted XPC session for
    /// subscription commands that need server-initiated notifications.
    public func handle(
        _ request: XPCDictionary, session: GohXPCServerSession?
    ) -> XPCDictionary? {
        request.withUnsafeUnderlyingDictionary { requestObject -> XPCDictionary? in
            guard let header = try? Self.decodeHeader(requestObject) else {
                return nil
            }
            if header.protocolVersion != Self.protocolVersion {
                return try? XPCDictionary(Self.envelope(
                    requestID: header.requestID,
                    messageType: .error,
                    payload: GohError(
                        code: .protocolVersionMismatch,
                        message: "client protocol \(header.protocolVersion) does not match daemon protocol \(Self.protocolVersion)")))
            }
            if header.messageType != .request {
                return try? XPCDictionary(Self.envelope(
                    requestID: header.requestID,
                    messageType: .error,
                    payload: GohError(
                        code: .invalidArgument,
                        message: "expected request messageType, got \(header.messageType.rawValue)")))
            }
            guard let envelope = try? GohEnvelope<Command>(xpcDictionary: requestObject) else {
                return nil
            }

            let outcome: CommandOutcome
            switch envelope.payload {
            case .authImportSafari:
                outcome = replyToAuthImportSafari(requestObject)
            case .subscribe(let request):
                return replyToSubscribe(
                    request,
                    requestID: envelope.requestID,
                    session: session)
            default:
                outcome = dispatcher.reply(to: envelope.payload)
            }

            guard let reply = try? Self.encodeReply(
                for: outcome,
                requestID: envelope.requestID
            ) else {
                return nil
            }
            return XPCDictionary(reply)
        }
    }

    private func replyToSubscribe(
        _ request: SubscribeRequest,
        requestID: UUID,
        session: GohXPCServerSession?
    ) -> XPCDictionary? {
        guard let progress else {
            return errorReply(
                requestID: requestID,
                code: .invalidArgument,
                message: "subscribe requires a progress subscription handler")
        }
        guard let session else {
            return errorReply(
                requestID: requestID,
                code: .invalidArgument,
                message: "subscribe requires an XPC session")
        }

        do {
            let subscription = try progress.subscribe(request) { event in
                let notification = try Self.envelope(
                    requestID: requestID,
                    messageType: .notification,
                    payload: event)
                try session.send(XPCDictionary(notification))
            }
            session.onCancel {
                progress.unsubscribe(subscription.id)
            }
            return try XPCDictionary(Self.replyEnvelope(
                requestID: requestID,
                payload: subscription.reply))
        } catch let error as GohError {
            return errorReply(
                requestID: requestID,
                code: error.code,
                message: error.message,
                httpStatusCode: error.httpStatusCode)
        } catch {
            return errorReply(
                requestID: requestID,
                code: .cancelled,
                message: "\(error)")
        }
    }

    private func errorReply(
        requestID: UUID,
        code: ErrorCode,
        message: String?,
        httpStatusCode: Int? = nil
    ) -> XPCDictionary? {
        let error = GohError(
            code: code,
            message: message,
            httpStatusCode: httpStatusCode)
        guard let reply = try? Self.envelope(
            requestID: requestID,
            messageType: .error,
            payload: error)
        else { return nil }
        return XPCDictionary(reply)
    }

    private func replyToAuthImportSafari(_ request: xpc_object_t) -> CommandOutcome {
        guard let authImportSafari else {
            return .failure(GohError(
                code: .invalidArgument,
                message: "authImportSafari is not configured"))
        }

        do {
            let fd = try XPCEnvelope.fileDescriptor(
                request, XPCEnvelope.authSafariCookieFileKey)
            defer { close(fd) }
            return authImportSafari(fd)
        } catch {
            return .failure(GohError(
                code: .invalidArgument,
                message: "authImportSafari requires an auth.safariCookieFile XPC fd sibling"))
        }
    }

    private struct Header {
        var protocolVersion: UInt32
        var requestID: UUID
        var messageType: MessageType
    }

    /// Reads the frozen envelope keys needed for compatibility checks before
    /// decoding `payload`, so a future-version request with an incompatible
    /// payload still receives a correlated version-mismatch error.
    private static func decodeHeader(_ request: xpc_object_t) throws -> Header {
        let rawVersion = try XPCEnvelope.uint64(request, XPCEnvelope.protocolVersionKey)
        guard rawVersion <= UInt64(UInt32.max) else {
            throw XPCEnvelopeError.protocolVersionOutOfRange(rawVersion)
        }
        let rawRequestID = try XPCEnvelope.string(request, XPCEnvelope.requestIDKey)
        guard let requestID = UUID(uuidString: rawRequestID) else {
            throw XPCEnvelopeError.malformedRequestID(rawRequestID)
        }
        let rawMessageType = try XPCEnvelope.string(request, XPCEnvelope.messageTypeKey)
        guard let messageType = MessageType(rawValue: rawMessageType) else {
            throw XPCEnvelopeError.unknownMessageType(rawMessageType)
        }
        return Header(
            protocolVersion: UInt32(rawVersion),
            requestID: requestID,
            messageType: messageType)
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
        case .authImported(let reply):
            return try replyEnvelope(requestID: requestID, payload: reply)
        case .ack:
            return try replyEnvelope(requestID: requestID, payload: AckReply())
        case .forgotProvenance(let reply):
            return try replyEnvelope(requestID: requestID, payload: reply)
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
