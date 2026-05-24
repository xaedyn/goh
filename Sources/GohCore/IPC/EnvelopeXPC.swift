import Foundation
import XPC

/// A failure decoding a ``GohEnvelope`` from an XPC dictionary.
///
/// A purpose-built error for the XPC wire codec; it folds into the project-wide
/// `GohError` hierarchy when that lands (see `DESIGN.md` §1.2).
public enum XPCEnvelopeError: Error {
    /// A required envelope key was absent from the dictionary.
    case missingKey(String)
    /// An envelope key held a value of the wrong XPC type.
    case wrongType(String)
    /// `requestID` was not a well-formed UUID string.
    case malformedRequestID(String)
    /// `messageType` held a string that is not a known ``MessageType``.
    case unknownMessageType(String)
    /// `protocolVersion` held a value outside the `UInt32` range.
    case protocolVersionOutOfRange(UInt64)
    /// The `payload` bytes could not be decoded into the expected type.
    case payloadDecodingFailed(underlying: any Error)
    /// A native XPC fd object could not be duplicated into this process.
    case fileDescriptorDupFailed(String)
}

/// The XPC-dictionary wire mapping for ``GohEnvelope`` (see `DESIGN.md` §1.1,
/// §4.3, §5.1).
public enum XPCEnvelope {
    static let protocolVersionKey = "protocolVersion"
    static let requestIDKey = "requestID"
    static let messageTypeKey = "messageType"
    static let payloadKey = "payload"
    public static let authSafariCookieFileKey = "auth.safariCookieFile"

    /// The four canonical envelope keys; the set is frozen by the wire contract.
    static let canonicalKeys: Set<String> = [
        protocolVersionKey, requestIDKey, messageTypeKey, payloadKey,
    ]

    /// The keys present in `dictionary` that are not one of the four canonical
    /// envelope keys — the slots reserved for native XPC sibling values such as
    /// file descriptors (see `DESIGN.md` §5.2).
    public static func siblingKeys(in dictionary: xpc_object_t) -> Set<String> {
        var siblings: Set<String> = []
        xpc_dictionary_apply(dictionary) { key, _ in
            let name = String(cString: key)
            if !canonicalKeys.contains(name) {
                siblings.insert(name)
            }
            return true
        }
        return siblings
    }

    /// Returns the value at `key`, or throws if it is absent or not `expected`.
    private static func requireValue(
        _ dictionary: xpc_object_t, _ key: String, _ expected: xpc_type_t
    ) throws -> xpc_object_t {
        guard let value = xpc_dictionary_get_value(dictionary, key) else {
            throw XPCEnvelopeError.missingKey(key)
        }
        guard xpc_get_type(value) == expected else {
            throw XPCEnvelopeError.wrongType(key)
        }
        return value
    }

    static func uint64(_ dictionary: xpc_object_t, _ key: String) throws -> UInt64 {
        _ = try requireValue(dictionary, key, XPC_TYPE_UINT64)
        return xpc_dictionary_get_uint64(dictionary, key)
    }

    static func string(_ dictionary: xpc_object_t, _ key: String) throws -> String {
        _ = try requireValue(dictionary, key, XPC_TYPE_STRING)
        guard let cString = xpc_dictionary_get_string(dictionary, key) else {
            throw XPCEnvelopeError.wrongType(key)
        }
        return String(cString: cString)
    }

    static func data(_ dictionary: xpc_object_t, _ key: String) throws -> Data {
        _ = try requireValue(dictionary, key, XPC_TYPE_DATA)
        var length = 0
        guard let bytes = xpc_dictionary_get_data(dictionary, key, &length) else {
            throw XPCEnvelopeError.wrongType(key)
        }
        return Data(bytes: bytes, count: length)
    }

    public static func setFileDescriptor(
        _ fileDescriptor: Int32,
        forKey key: String,
        in dictionary: xpc_object_t
    ) {
        let fdObject = xpc_fd_create(fileDescriptor)
        xpc_dictionary_set_value(dictionary, key, fdObject)
    }

    public static func fileDescriptor(_ dictionary: xpc_object_t, _ key: String) throws -> Int32 {
        let fdObject = try requireValue(dictionary, key, XPC_TYPE_FD)
        let duplicated = xpc_fd_dup(fdObject)
        guard duplicated >= 0 else {
            throw XPCEnvelopeError.fileDescriptorDupFailed(key)
        }
        return duplicated
    }
}

extension GohEnvelope {

    /// Encodes the envelope as the fixed-key XPC dictionary defined by the IPC
    /// contract (see `DESIGN.md` §1.1, §4.3, §5.1): `protocolVersion` as an XPC
    /// `uint64`, `requestID` and `messageType` as XPC strings, and `payload` as
    /// an XPC `data` value holding the `Codable`-encoded body.
    public func xpcDictionary() throws -> xpc_object_t {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(
            dictionary, XPCEnvelope.protocolVersionKey, UInt64(protocolVersion))
        xpc_dictionary_set_string(
            dictionary, XPCEnvelope.requestIDKey, requestID.uuidString)
        xpc_dictionary_set_string(
            dictionary, XPCEnvelope.messageTypeKey, messageType.rawValue)

        // `CommandCoding` is the canonical payload codec — ISO-8601 dates
        // (`DESIGN.md` §4) and sorted keys (§5.1).
        let payloadBytes = try CommandCoding.encoder.encode(payload)
        // `payload` is a `Codable` value, so its JSON encoding is never empty
        // and the buffer always has a base address. Unwrapping it here passes a
        // non-optional pointer, which `xpc_dictionary_set_data` accepts whether
        // the SDK annotates the parameter as nullable or not.
        payloadBytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                xpc_dictionary_set_data(
                    dictionary, XPCEnvelope.payloadKey, base, raw.count)
            }
        }
        return dictionary
    }

    /// Decodes an envelope from a fixed-key XPC dictionary. The three non-payload
    /// keys are read with primitive accessors and validated — including the
    /// `UInt32` range of `protocolVersion` — before `payload` is decoded (see
    /// `DESIGN.md` §4.3). Sibling keys (see `DESIGN.md` §5.2) are ignored.
    public init(xpcDictionary dictionary: xpc_object_t) throws {
        let rawVersion = try XPCEnvelope.uint64(dictionary, XPCEnvelope.protocolVersionKey)
        guard rawVersion <= UInt64(UInt32.max) else {
            throw XPCEnvelopeError.protocolVersionOutOfRange(rawVersion)
        }

        let rawRequestID = try XPCEnvelope.string(dictionary, XPCEnvelope.requestIDKey)
        guard let requestID = UUID(uuidString: rawRequestID) else {
            throw XPCEnvelopeError.malformedRequestID(rawRequestID)
        }

        let rawMessageType = try XPCEnvelope.string(dictionary, XPCEnvelope.messageTypeKey)
        guard let messageType = MessageType(rawValue: rawMessageType) else {
            throw XPCEnvelopeError.unknownMessageType(rawMessageType)
        }

        let payloadBytes = try XPCEnvelope.data(dictionary, XPCEnvelope.payloadKey)
        let payload: Payload
        do {
            payload = try CommandCoding.decoder.decode(Payload.self, from: payloadBytes)
        } catch {
            throw XPCEnvelopeError.payloadDecodingFailed(underlying: error)
        }

        self.init(
            protocolVersion: UInt32(rawVersion),
            requestID: requestID,
            messageType: messageType,
            payload: payload)
    }
}
