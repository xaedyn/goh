/// The kind of a `goh` ⇄ `gohd` XPC message.
///
/// The four raw values — `request`, `reply`, `notification`, `error` — are the
/// frozen wire strings of the IPC contract (see `DESIGN.md` §1.1, §4.3). On the
/// wire, `messageType` is the raw `String`; a receiver maps it back through
/// `MessageType(rawValue:)` and rejects an unrecognised value with an error
/// rather than crashing.
public enum MessageType: String, Codable, Sendable {
    /// A client-to-daemon request.
    case request
    /// A daemon-to-client reply to a request.
    case reply
    /// A daemon-initiated notification, such as a progress event.
    case notification
    /// An error message readable without decoding the payload, such as a
    /// protocol-version mismatch.
    case error
}
