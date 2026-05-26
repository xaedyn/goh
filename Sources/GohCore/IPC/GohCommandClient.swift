import Foundation
import XPC

public enum GohCommandClientError: Error, Sendable, Equatable {
    case daemon(GohError)
    case malformedReply(String)
}

public struct GohCommandClient {
    public typealias Sender = (XPCDictionary) throws -> XPCDictionary

    private let sendEnvelope: Sender

    public init(send: @escaping Sender) {
        self.sendEnvelope = send
    }

    public func send<Reply: Codable & Sendable>(
        _ command: Command,
        expecting _: Reply.Type
    ) throws -> Reply {
        try sendWithRequestID(command, expecting: Reply.self).reply
    }

    public func sendWithRequestID<Reply: Codable & Sendable>(
        _ command: Command,
        expecting _: Reply.Type
    ) throws -> (requestID: UUID, reply: Reply) {
        let requestID = UUID()
        let request = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .request,
            payload: command)
            .xpcDictionary()
        let response = try sendEnvelope(XPCDictionary(request))

        switch response.decodeGohReply(as: Reply.self) {
        case .reply(let id, let payload):
            guard id == requestID else {
                throw GohCommandClientError.malformedReply(
                    "daemon reply requestID did not match the request")
            }
            return (requestID, payload)
        case .daemonError(let id, let error):
            guard id == requestID else {
                throw GohCommandClientError.malformedReply(
                    "daemon error requestID did not match the request")
            }
            throw GohCommandClientError.daemon(error)
        case .malformed:
            throw GohCommandClientError.malformedReply(
                "daemon returned an unrecognized reply")
        }
    }
}
