import Foundation

/// The canonical JSON coders for command payloads (`DESIGN.md` §4).
///
/// `Date` fields are encoded as ISO-8601 strings (the daemon emits UTC); keys
/// are sorted so output is deterministic. Each access returns a fresh coder —
/// `JSONEncoder` / `JSONDecoder` are not thread-safe to share.
public enum CommandCoding {
    /// A fresh encoder configured for the command-payload wire format.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// A fresh decoder configured for the command-payload wire format.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
