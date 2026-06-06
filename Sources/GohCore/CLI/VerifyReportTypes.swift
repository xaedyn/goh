import Foundation

// MARK: - VerifyAllReport (frozen --json v1 contract)
//
// reportVersion bumps on ANY breaking change to this shape.
// Field names and `status` / `error` raw values are FROZEN — do NOT rename.
// The golden fixture Tests/GohCoreTests/Fixtures/verify-all-report-v1.json
// enforces this: any schema change will fail the encode-equals test.

/// Root document for `goh verify --all --json`. Frozen at reportVersion 1.
public struct VerifyAllReport: Codable, Equatable, Sendable {
    /// Always 1 for v1; bump only if a field name/type or enum raw value changes.
    public var reportVersion: Int          // = 1 — do NOT rename
    /// Injected by run(); ISO-8601 UTC on the wire via CommandCoding.encoder.
    public var generatedAt: Date           // do NOT rename
    /// Derived by folding over entries[]; never maintained as a parallel tally.
    public var summary: VerifySummary      // do NOT rename
    /// One element per provenance-ledger entry, in ledger order.
    public var entries: [VerifyEntryResult] // do NOT rename

    public init(
        reportVersion: Int = 1,
        generatedAt: Date,
        summary: VerifySummary,
        entries: [VerifyEntryResult]
    ) {
        self.reportVersion = reportVersion
        self.generatedAt = generatedAt
        self.summary = summary
        self.entries = entries
    }
}

/// Aggregate counts block. Each field is derived by folding over entries[].
public struct VerifySummary: Codable, Equatable, Sendable {
    public var total: Int    // do NOT rename
    public var ok: Int       // do NOT rename
    public var failed: Int   // do NOT rename
    public var missing: Int  // do NOT rename

    public init(total: Int, ok: Int, failed: Int, missing: Int) {
        self.total = total
        self.ok = ok
        self.failed = failed
        self.missing = missing
    }
}

/// Per-entry result in the `entries[]` array.
public struct VerifyEntryResult: Codable, Equatable, Sendable {
    /// entry.destinationPath (canonical, as stored in the ledger).
    public var path: String              // do NOT rename
    /// entry.url exactly as stored.
    public var url: String               // do NOT rename
    /// ok / failed / missing — FROZEN raw values.
    public var status: VerifyStatus      // do NOT rename
    /// entry.sha256 verbatim ("sha256:"-prefixed).
    public var expectedSha256: String    // do NOT rename
    /// Present ONLY when status == .failed. Nil is OMITTED (no key in JSON).
    public var actualSha256: String?     // do NOT rename; nil → key absent

    public init(
        path: String,
        url: String,
        status: VerifyStatus,
        expectedSha256: String,
        actualSha256: String?
    ) {
        self.path = path
        self.url = url
        self.status = status
        self.expectedSha256 = expectedSha256
        self.actualSha256 = actualSha256
    }
}

/// Per-entry verification status.
/// FROZEN raw values — do NOT rename (scripts branch on these).
public enum VerifyStatus: String, Codable, Equatable, Sendable {
    case ok       // do NOT rename
    case failed   // do NOT rename
    case missing  // do NOT rename
}

// MARK: - Error envelope

/// Emitted on stdout by `--json` when the ledger is unreadable / corrupt /
/// unknown-version. Exit code remains 6. Never mixed with plain-text output.
public struct VerifyErrorReport: Codable, Equatable, Sendable {
    public var reportVersion: Int  // = 1 — do NOT rename
    public var error: VerifyErrorCode  // do NOT rename

    public init(reportVersion: Int = 1, error: VerifyErrorCode) {
        self.reportVersion = reportVersion
        self.error = error
    }
}

/// Stable machine codes for the three ledger-level error conditions.
/// FROZEN raw values — do NOT rename.
public enum VerifyErrorCode: String, Codable, Equatable, Sendable {
    case ledgerUnreadable     // file present but cannot be read as Data — do NOT rename
    case ledgerCorrupt        // Data present but PropertyListDecoder fails — do NOT rename
    case ledgerVersionUnknown // decoded OK but version != ProvenanceRecord.currentVersion — do NOT rename
}
