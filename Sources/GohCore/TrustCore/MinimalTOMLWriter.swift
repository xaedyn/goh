import Foundation

/// Serializes a `MinimalTOMLDocument` back to TOML text in the goh accepted subset.
///
/// Output is deterministic: top-level keys are sorted alphabetically, and within
/// each array-of-tables entry the keys are also sorted. The `[[section]]` group
/// ordering follows the document's original table order.
public struct MinimalTOMLWriter {

    /// Converts `doc` to a TOML string.
    ///
    /// The output is stable and round-trip safe: `parse(write(doc))` reproduces the
    /// same logical document (same top-level values and same array-of-tables entries).
    public static func write(_ doc: MinimalTOMLDocument) -> String {
        var out = ""

        // Top-level key/value pairs, sorted for determinism.
        for key in doc.topLevel.keys.sorted() {
            out += "\(key) = \(encode(doc.topLevel[key]!))\n"
        }

        // Array-of-tables sections, in document order.
        // Emit a blank line before the first entry of each new section name.
        var seenSections: Set<String> = []
        for table in doc._tables {
            if !seenSections.contains(table.name) {
                seenSections.insert(table.name)
                out += "\n"
            }
            out += "[[\(table.name)]]\n"
            for key in table.fields.keys.sorted() {
                out += "\(key) = \(encode(table.fields[key]!))\n"
            }
        }

        return out
    }

    // MARK: Private helpers

    private static func encode(_ value: TOMLValue) -> String {
        switch value {
        case .string(let s):
            return "\"\(s)\""
        case .integer(let i):
            return "\(i)"
        case .boolean(let b):
            return b ? "true" : "false"
        }
    }
}
