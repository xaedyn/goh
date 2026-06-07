import Foundation
import GohCore

// MARK: - Trust summary types

/// At-rest provenance summary for the popover (AC1).
/// Derived from ProvenanceEntry.verifiedAt — NOT a live re-hash.
nonisolated public struct GohTrustSummary: Sendable, Equatable {
    /// Total entries in the ledger.
    public let tracked: Int
    /// Entries where verifiedAt != nil.
    public let verified: Int
    /// Entries where verifiedAt == nil (downloaded but never verified via sync).
    public let downloadOnly: Int

    public init(tracked: Int, verified: Int, downloadOnly: Int) {
        self.tracked = tracked
        self.verified = verified
        self.downloadOnly = downloadOnly
    }
}

/// The at-rest trust overview shown in the popover (AC1).
nonisolated public enum GohTrustOverview: Sendable, Equatable {
    /// No ledger present, or the ledger is present but empty — "No downloads recorded yet".
    case empty
    /// Ledger present but unreadable / corrupt / unknown version — "Trust data unavailable".
    case unavailable
    /// Ledger decoded successfully with one or more entries.
    case summary(GohTrustSummary)
}

/// One row in the Trust window's per-file list (AC2).
nonisolated public struct GohTrustEntryRow: Sendable, Equatable {
    /// The destinationPath as stored in the ledger (full canonical path).
    public let displayPath: String
    /// URLDisplay.sanitized applied to entry.url (control chars stripped, credentials redacted).
    public let sanitizedURL: String
    /// entry.sha256 verbatim ("sha256:"-prefixed).
    public let sha256: String
    /// entry.downloadedAt.
    public let downloadedAt: Date
    /// entry.verifiedAt (nil = downloaded-only; non-nil = last-verified date).
    public let verifiedAt: Date?

    public init(
        displayPath: String,
        sanitizedURL: String,
        sha256: String,
        downloadedAt: Date,
        verifiedAt: Date?
    ) {
        self.displayPath = displayPath
        self.sanitizedURL = sanitizedURL
        self.sha256 = sha256
        self.downloadedAt = downloadedAt
        self.verifiedAt = verifiedAt
    }
}

// MARK: - Read seam

/// Read seam allowing GohMenuBar unit tests to inject a stub ledger reader
/// (no disk, no XPC) while the live goh-menu target uses the real
/// ProvenanceLedgerReader. Returns the same ProvenanceReadOutcome trichotomy
/// as the runner so the corrupt/empty boundary is identical across the tray
/// and `verify --all`.
nonisolated public protocol ProvenanceReading: Sendable {
    /// Returns the read outcome — never throws (errors mapped to .unreadable).
    func read() -> ProvenanceReadOutcome
}
