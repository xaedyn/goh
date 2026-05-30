import Foundation

// MARK: - TOMLValue

/// The subset of TOML value types accepted by the goh minimal reader.
///
/// Accepted: double-quoted strings, decimal integers, booleans.
/// All other TOML value forms are rejected with a named `ParseError`.
public enum TOMLValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case boolean(Bool)

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        if case .integer(let i) = self { return i }
        return nil
    }

    public var boolValue: Bool? {
        if case .boolean(let b) = self { return b }
        return nil
    }
}

// MARK: - MinimalTOMLDocument

/// A parsed TOML document restricted to the goh accepted subset.
///
/// Contains top-level key/value pairs and zero or more named array-of-tables sections.
public struct MinimalTOMLDocument: Sendable {
    /// Top-level key/value pairs (outside any `[[section]]` header).
    public var topLevel: [String: TOMLValue]

    /// Backing storage for array-of-tables entries, ordered by appearance.
    ///
    /// Named with a leading underscore to signal this is an internal implementation
    /// detail exposed for `MinimalTOMLWriter` (same module). Do not use from outside GohCore.
    internal var _tables: [(name: String, fields: [String: TOMLValue])]

    public init(
        topLevel: [String: TOMLValue] = [:],
        tables: [(name: String, fields: [String: TOMLValue])] = []
    ) {
        self.topLevel = topLevel
        self._tables = tables
    }

    /// Returns all entries for the named array-of-tables section, in document order.
    public func arrayOfTables(_ name: String) -> [[String: TOMLValue]] {
        _tables.filter { $0.name == name }.map { $0.fields }
    }
}

// MARK: - MinimalTOMLReader

/// Hand-rolled parser for the strict TOML subset accepted by goh.
///
/// Accepted subset (spec §9.5 contract):
/// - UTF-8, LF line endings.
/// - Top-level `key = value` where value is a basic double-quoted string, decimal
///   integer, or boolean (`true`/`false`).
/// - `[[asset]]` and `[[entry]]` array-of-tables headers; same scalar types inside.
/// - `#` line comments and blank lines.
///
/// Explicitly rejected (loud named error, not silent mis-parse):
/// dotted keys, inline tables, array values, standard `[table]` headers,
/// multiline/literal/multiline-literal strings, native TOML datetimes,
/// float values, hex/octal/binary integers.
public struct MinimalTOMLReader {

    // MARK: ParseError

    /// A parse error with a human-readable message identifying the offending
    /// construct and the supported subset.
    public struct ParseError: Error, Equatable {
        public var message: String
        public var line: Int?

        public init(_ message: String, line: Int? = nil) {
            self.message = message
            self.line = line
        }
    }

    // MARK: Public API

    /// Parses `input` into a `MinimalTOMLDocument`.
    ///
    /// - Parameters:
    ///   - input: UTF-8 TOML text using LF line endings.
    ///   - allowedTopLevelKeys: When non-nil, any top-level key not in this set
    ///     throws a `ParseError`. Pass `nil` (the default) to skip key validation.
    ///   - allowedAssetKeys: When non-nil, any key inside an array-of-tables entry
    ///     not in this set throws a `ParseError`. Pass `nil` to skip.
    /// - Returns: The parsed document.
    /// - Throws: `ParseError` for any construct outside the accepted subset, or for
    ///   unknown keys when `allowedTopLevelKeys` / `allowedAssetKeys` are supplied.
    public static func parse(
        _ input: String,
        allowedTopLevelKeys: Set<String>? = nil,
        allowedAssetKeys: Set<String>? = nil
    ) throws -> MinimalTOMLDocument {
        var topLevel: [String: TOMLValue] = [:]
        var tables: [(name: String, fields: [String: TOMLValue])] = []
        var currentTable: (name: String, fields: [String: TOMLValue])? = nil

        let lines = input.components(separatedBy: "\n")
        for (lineIndex, rawLine) in lines.enumerated() {
            let lineNumber = lineIndex + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Skip blank lines and comments.
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Array-of-tables header: [[name]]
            if line.hasPrefix("[[") {
                guard line.hasSuffix("]]") else {
                    throw ParseError(
                        "malformed array-of-tables header at line \(lineNumber)",
                        line: lineNumber)
                }
                let name = String(line.dropFirst(2).dropLast(2))
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else {
                    throw ParseError(
                        "empty array-of-tables name at line \(lineNumber)",
                        line: lineNumber)
                }
                guard !name.contains(".") else {
                    throw ParseError(
                        "unsupported TOML construct 'dotted key' at line \(lineNumber); "
                        + "goh accepts only simple [[sectionName]] headers",
                        line: lineNumber)
                }
                if let prev = currentTable { tables.append(prev) }
                currentTable = (name: name, fields: [:])
                continue
            }

            // Standard table header: [name] — rejected
            if line.hasPrefix("[") {
                throw ParseError(
                    "unsupported TOML construct 'standard table' at line \(lineNumber); "
                    + "goh accepts only [[arrayOfTables]] headers",
                    line: lineNumber)
            }

            // Key = value line
            guard let eqIdx = line.firstIndex(of: "=") else {
                throw ParseError(
                    "unparseable line at line \(lineNumber): \(line)",
                    line: lineNumber)
            }
            let rawKey = line[..<eqIdx].trimmingCharacters(in: .whitespaces)
            let rawVal = line[line.index(after: eqIdx)...]
                .trimmingCharacters(in: .whitespaces)

            if rawKey.contains(".") {
                throw ParseError(
                    "unsupported TOML construct 'dotted key' at line \(lineNumber); "
                    + "goh accepts only simple keys",
                    line: lineNumber)
            }

            let value = try parseValue(rawVal, lineNumber: lineNumber)

            if var table = currentTable {
                table.fields[rawKey] = value
                currentTable = table
            } else {
                if let allowed = allowedTopLevelKeys, !allowed.contains(rawKey) {
                    throw ParseError(
                        "unknown top-level key '\(rawKey)' at line \(lineNumber)",
                        line: lineNumber)
                }
                topLevel[rawKey] = value
            }
        }

        // Flush the last open table.
        if let prev = currentTable { tables.append(prev) }

        // Per-entry key validation (optional).
        if let allowed = allowedAssetKeys {
            for table in tables {
                for key in table.fields.keys where !allowed.contains(key) {
                    throw ParseError(
                        "unknown key '\(key)' in [[\(table.name)]]")
                }
            }
        }

        return MinimalTOMLDocument(topLevel: topLevel, tables: tables)
    }

    // MARK: Private helpers

    private static func parseValue(_ raw: String, lineNumber: Int) throws -> TOMLValue {
        let stripped = stripInlineComment(raw)

        // Multiline basic string — rejected before single-line check.
        if stripped.hasPrefix("\"\"\"") {
            throw ParseError(
                "unsupported TOML construct 'multiline string' at line \(lineNumber); "
                + "goh accepts only basic single-line double-quoted strings",
                line: lineNumber)
        }

        // Basic double-quoted string.
        if stripped.hasPrefix("\"") {
            guard stripped.hasSuffix("\""), stripped.count >= 2 else {
                throw ParseError(
                    "unclosed string at line \(lineNumber)",
                    line: lineNumber)
            }
            return .string(String(stripped.dropFirst().dropLast()))
        }

        // Literal (single-quoted) string — rejected.
        if stripped.hasPrefix("'") {
            throw ParseError(
                "unsupported TOML construct 'literal string' at line \(lineNumber); "
                + "goh accepts only double-quoted strings",
                line: lineNumber)
        }

        // Inline table — rejected.
        if stripped.hasPrefix("{") {
            throw ParseError(
                "unsupported TOML construct 'inline table' at line \(lineNumber); "
                + "goh accepts only scalar values and [[arrayOfTables]]",
                line: lineNumber)
        }

        // Array value — rejected.
        if stripped.hasPrefix("[") {
            throw ParseError(
                "unsupported TOML construct 'array' at line \(lineNumber); "
                + "goh accepts only scalar values and [[arrayOfTables]]",
                line: lineNumber)
        }

        // Booleans.
        if stripped == "true" { return .boolean(true) }
        if stripped == "false" { return .boolean(false) }

        // Decimal integer (must come before float/datetime heuristics).
        if let i = Int(stripped) { return .integer(i) }

        // Non-decimal integer — rejected.
        if stripped.hasPrefix("0x") || stripped.hasPrefix("0o") || stripped.hasPrefix("0b") {
            throw ParseError(
                "unsupported value type 'non-decimal integer' at line \(lineNumber); "
                + "goh accepts only decimal integers",
                line: lineNumber)
        }

        // Native datetime heuristic (contains "T" and "-" and ":").
        // Must be checked before float because datetimes also contain "." (fractional seconds).
        if (stripped.contains("T") && stripped.contains("-") && stripped.contains(":"))
            || stripped.contains("Z")
        {
            throw ParseError(
                "unsupported value type 'datetime' at line \(lineNumber); "
                + "goh stores timestamps as plain strings",
                line: lineNumber)
        }

        // Float heuristic: contains "." or case-insensitive "e" (scientific notation).
        if stripped.contains(".") || stripped.lowercased().contains("e") {
            throw ParseError(
                "unsupported value type 'float' at line \(lineNumber); "
                + "goh accepts only integer, string, and boolean scalars",
                line: lineNumber)
        }

        throw ParseError(
            "unrecognised value '\(stripped)' at line \(lineNumber)",
            line: lineNumber)
    }

    /// Strips a trailing `# comment` from a raw value string, respecting quoted strings.
    private static func stripInlineComment(_ s: String) -> String {
        var inString = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == "\"" { inString.toggle() }
            if ch == "#", !inString {
                return String(s[..<idx]).trimmingCharacters(in: .whitespaces)
            }
            idx = s.index(after: idx)
        }
        return s
    }
}
