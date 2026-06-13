import Foundation
import GohCore

/// Pure presenter: `ProvenanceReadOutcome` → `(GohTrustOverview, [GohTrustEntryRow])`.
///
/// No disk access, no framework, no Swift concurrency — unit-testable with stubs.
/// Entry order is preserved (ledger order). URLs are sanitized via `URLDisplay.sanitized`.
nonisolated public struct GohTrustPresenter: Sendable {

    public init() {}

    /// Maps a ledger read outcome to the overview and per-file rows for display.
    ///
    /// - `.absent` / `.entries([])` → `.empty`, `[]`
    /// - `.entries(n)` → `.summary(GohTrustSummary)`, `[GohTrustEntryRow]` in ledger order
    /// - `.unreadable(_)` → `.unavailable`, `[]` (all three reasons collapse to unavailable)
    public func present(_ outcome: ProvenanceReadOutcome) -> (GohTrustOverview, [GohTrustEntryRow]) {
        switch outcome {
        case .absent:
            return (.empty, [])

        case .entries(let entries) where entries.isEmpty:
            return (.empty, [])

        case .entries(let entries):
            let verified = entries.filter { $0.verifiedAt != nil }.count
            let downloadOnly = entries.count - verified
            let summary = GohTrustSummary(
                tracked: entries.count,
                verified: verified,
                downloadOnly: downloadOnly)
            let rows = entries.map(makeRow(_:))
            return (.summary(summary), rows)

        case .unreadable:
            return (.unavailable, [])
        }
    }

    /// Maps a single `ProvenanceEntry` and its optional fast-check result to a
    /// `TrustDisplayStatus` for rendering.
    ///
    /// Mapping:
    /// - `entry.verifiedAt` non-nil → `.verified(at:)` (deep proof wins)
    /// - fast `.unchanged` → `.looksUnchanged`
    /// - fast `.changed(r)` → `.changed(r)`
    /// - fast `.missing` → `.missing`
    /// - fast `.indeterminate` → `.indeterminate`
    /// - fast `.notBaselined` → `.notBaselined`
    /// - `fastStatus == nil` and `verifiedAt == nil` → `.recordedOnly`
    public static func displayStatus(
        entry: ProvenanceEntry,
        fastStatus: FastCheckStatus?
    ) -> TrustDisplayStatus {
        if let verifiedAt = entry.verifiedAt {
            return .verified(at: verifiedAt)
        }
        guard let fast = fastStatus else {
            return .recordedOnly
        }
        switch fast {
        case .unchanged:    return .looksUnchanged
        case .changed(let r): return .changed(r)
        case .missing:      return .missing
        case .indeterminate: return .indeterminate
        case .notBaselined: return .notBaselined
        }
    }

    /// Convenience overload for call sites that already have `verifiedAt: Date?`
    /// (e.g. `TrustWindowView` which reads from `GohTrustEntryRow.verifiedAt`
    /// without needing to reconstruct a full `ProvenanceEntry`).
    public static func displayStatus(
        verifiedAt: Date?,
        fastStatus: FastCheckStatus?
    ) -> TrustDisplayStatus {
        if let verifiedAt { return .verified(at: verifiedAt) }
        guard let fast = fastStatus else { return .recordedOnly }
        switch fast {
        case .unchanged:    return .looksUnchanged
        case .changed(let r): return .changed(r)
        case .missing:      return .missing
        case .indeterminate: return .indeterminate
        case .notBaselined: return .notBaselined
        }
    }

    // MARK: - Private

    private func makeRow(_ entry: ProvenanceEntry) -> GohTrustEntryRow {
        GohTrustEntryRow(
            displayPath: entry.destinationPath,
            sanitizedURL: URLDisplay.sanitized(entry.url),
            sha256: entry.sha256,
            downloadedAt: entry.downloadedAt,
            verifiedAt: entry.verifiedAt,
            size: entry.size)
    }
}
