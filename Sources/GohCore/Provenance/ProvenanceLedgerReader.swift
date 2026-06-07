import Foundation

/// The structured reason a ledger file could not be decoded.
///
/// Structured (not a free-form String) because the CLI's frozen --json output
/// emits three distinct, separately-tested VerifyErrorCodes — and versionUnknown
/// embeds the int — so callers must discriminate, not string-parse.
nonisolated public enum LedgerUnreadableReason: Sendable, Equatable {
    /// `Data(contentsOf:)` failed — file present but unreadable (I/O or permissions).
    /// Maps to `.ledgerUnreadable` / "provenance ledger unreadable" / exit 6.
    case io
    /// `PropertyListDecoder` failed — data present but malformed.
    /// Maps to `.ledgerCorrupt` / "provenance ledger corrupt" / exit 6.
    case corrupt
    /// Decoded cleanly but `record.version != currentVersion`.
    /// Maps to `.ledgerVersionUnknown` / "provenance ledger version \(n) is unknown" / exit 6.
    case versionUnknown(found: Int)
}

/// The outcome of a read-only ledger read.
nonisolated public enum ProvenanceReadOutcome: Sendable, Equatable {
    /// File does not exist — treat as empty (exit-0 analog; never an error).
    case absent
    /// Decoded successfully. Array may be empty.
    case entries([ProvenanceEntry])
    /// File present but unreadable / corrupt / unknown version.
    case unreadable(LedgerUnreadableReason)
}

/// Read-only ledger reader — the single decode+version-check shared by both
/// `VerifyAllRunner` and the tray's `ProvenanceReading` protocol.
///
/// Classification order MUST match `GohVerifyAllCommand.run()` exactly:
///   1. fileExists == false        → .absent
///   2. Data(contentsOf:) throws   → .unreadable(.io)
///   3. PropertyListDecoder throws  → .unreadable(.corrupt)
///   4. record.version != current   → .unreadable(.versionUnknown(found:))
///   5. else                        → .entries(record.entries) in stored order
///
/// Never writes, never throws, never creates a sidecar (only the daemon's
/// `load()` performs recovery).
nonisolated public enum ProvenanceLedgerReader {

    /// Read-only decode of the provenance ledger at `path`.
    ///
    /// - Parameter path: Absolute path to `provenance.plist`
    ///   (from `ProvenanceStoreLocation.defaultURL(create: false)`).
    /// - Returns: The classified outcome; never throws.
    public static func read(at path: String) -> ProvenanceReadOutcome {
        guard FileManager.default.fileExists(atPath: path) else {
            return .absent
        }

        let storeURL = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: storeURL) else {
            return .unreadable(.io)
        }

        let record: ProvenanceRecord
        do {
            record = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
        } catch {
            return .unreadable(.corrupt)
        }

        guard record.version == ProvenanceRecord.currentVersion else {
            return .unreadable(.versionUnknown(found: record.version))
        }

        return .entries(record.entries)
    }
}
