import Foundation

/// The uniform `goh` ⇄ `gohd` message envelope.
///
/// Every message — request, reply, and daemon notification alike — is this
/// envelope: the four frozen keys of the XPC IPC contract (see `DESIGN.md`
/// §1.1, §4.3). It is generic over its `payload`, whose concrete type depends
/// on `messageType`; per-command payload shapes are defined separately.
///
/// The four key names and their types are part of the frozen wire contract and
/// must never be renamed or retyped (see `DESIGN.md` §4.3).
public struct GohEnvelope<Payload: Codable & Sendable>: Codable, Sendable {

    /// The wire-protocol version. The daemon accepts only its current exact
    /// version; older golden fixtures remain in the test suite as immutable
    /// compatibility references.
    public let protocolVersion: UInt32

    /// Correlates a reply or notification to its originating request.
    public let requestID: UUID

    /// The kind of this message.
    public let messageType: MessageType

    /// The kind-specific body.
    public let payload: Payload

    /// Creates an envelope around `payload`.
    public init(
        protocolVersion: UInt32,
        requestID: UUID,
        messageType: MessageType,
        payload: Payload
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.messageType = messageType
        self.payload = payload
    }

    /// The frozen wire key names. Renaming any case is a wire-incompatible
    /// change (see `DESIGN.md` §4.3).
    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID
        case messageType
        case payload
    }
}

extension GohEnvelope: Equatable where Payload: Equatable {}
