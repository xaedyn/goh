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

    // MARK: - Private

    private func makeRow(_ entry: ProvenanceEntry) -> GohTrustEntryRow {
        GohTrustEntryRow(
            displayPath: entry.destinationPath,
            sanitizedURL: URLDisplay.sanitized(entry.url),
            sha256: entry.sha256,
            downloadedAt: entry.downloadedAt,
            verifiedAt: entry.verifiedAt)
    }
}
