import Foundation
import Testing
import GohCore
@testable import GohMenuBar

// AC1/AC2/AC5: GohTrustPresenter maps ProvenanceReadOutcome → GohTrustOverview + [GohTrustEntryRow].
@Suite("GohTrustPresenter")
struct GohTrustPresenterTests {

    private let presenter = GohTrustPresenter()

    // AC1: absent → .empty overview, empty rows
    @Test("AC1: .absent outcome → .empty overview, empty rows")
    func absentYieldsEmpty() {
        let (overview, rows) = presenter.present(.absent)
        #expect(overview == .empty)
        #expect(rows.isEmpty)
    }

    // AC1: entries([]) → .empty overview, empty rows
    @Test("AC1: .entries([]) outcome → .empty overview, empty rows")
    func emptyEntriesYieldsEmpty() {
        let (overview, rows) = presenter.present(.entries([]))
        #expect(overview == .empty)
        #expect(rows.isEmpty)
    }

    // AC5: unreadable → .unavailable overview, empty rows
    @Test("AC5: .unreadable → .unavailable overview, empty rows")
    func unreadableYieldsUnavailable() {
        for reason in [
            LedgerUnreadableReason.io,
            LedgerUnreadableReason.corrupt,
            LedgerUnreadableReason.versionUnknown(found: 99),
        ] {
            let (overview, rows) = presenter.present(.unreadable(reason))
            #expect(overview == .unavailable, "reason \(reason) should yield .unavailable")
            #expect(rows.isEmpty)
        }
    }

    // AC1: non-empty entries → .summary with correct counts
    @Test("AC1: non-empty entries → .summary with tracked/verified/downloadOnly counts")
    func nonEmptyEntriesYieldsSummary() {
        let now = Date()
        let entries = [
            makeEntry(path: "/a.bin", verifiedAt: now),    // verified
            makeEntry(path: "/b.bin", verifiedAt: now),    // verified
            makeEntry(path: "/c.bin", verifiedAt: nil),    // download-only
        ]
        let (overview, rows) = presenter.present(.entries(entries))
        guard case .summary(let s) = overview else {
            Issue.record("Expected .summary, got \(overview)")
            return
        }
        #expect(s.tracked == 3)
        #expect(s.verified == 2)
        #expect(s.downloadOnly == 1)
        #expect(rows.count == 3)
    }

    // AC2: URL is sanitized (credential redacted)
    @Test("AC2: entry URL is sanitized via URLDisplay.sanitized")
    func urlIsSanitized() {
        let entry = makeEntry(
            path: "/file.bin",
            url: "https://example.com/file?token=supersecret",
            verifiedAt: nil)
        let (_, rows) = presenter.present(.entries([entry]))
        #expect(rows.first?.sanitizedURL.contains("supersecret") == false)
        #expect(rows.first?.sanitizedURL.contains("REDACTED") == true)
    }

    // AC2: row fields map correctly
    @Test("AC2: row fields — displayPath, sha256, downloadedAt, verifiedAt mapped correctly")
    func rowFieldsCorrect() throws {
        let dl = Date(timeIntervalSince1970: 1_000)
        let vf = Date(timeIntervalSince1970: 2_000)
        let entry = ProvenanceEntry(
            url: "https://example.com/a.bin",
            sha256: "sha256:aabb",
            size: 42,
            downloadedAt: dl,
            destinationPath: "/Users/me/a.bin",
            verifiedAt: vf)
        let (_, rows) = presenter.present(.entries([entry]))
        let row = try #require(rows.first)
        #expect(row.displayPath == "/Users/me/a.bin")
        #expect(row.sha256 == "sha256:aabb")
        #expect(row.downloadedAt == dl)
        #expect(row.verifiedAt == vf)
    }

    // AC1: entry order preserved (ledger order)
    @Test("AC1: row order matches ledger entry order")
    func rowOrderPreserved() {
        let entries = [
            makeEntry(path: "/z.bin", verifiedAt: nil),
            makeEntry(path: "/a.bin", verifiedAt: nil),
        ]
        let (_, rows) = presenter.present(.entries(entries))
        #expect(rows.map(\.displayPath) == ["/z.bin", "/a.bin"])
    }

    // displayStatus: verifiedAt + .unchanged fast → .verified(at:)
    @Test("displayStatus: verifiedAt non-nil → .verified(at:) regardless of fast status")
    func displayStatusVerifiedAtWins() {
        let verifiedDate = Date(timeIntervalSince1970: 2_000_000)
        let entry = makeEntry(path: "/a.bin", verifiedAt: verifiedDate)
        let status = GohTrustPresenter.displayStatus(entry: entry, fastStatus: .unchanged)
        guard case .verified(let at) = status else {
            Issue.record("Expected .verified, got \(status)")
            return
        }
        #expect(at == verifiedDate)
    }

    // displayStatus: no verifiedAt, fast .unchanged → .looksUnchanged
    @Test("displayStatus: no verifiedAt + fast .unchanged → .looksUnchanged")
    func displayStatusLooksUnchanged() {
        let entry = makeEntry(path: "/a.bin", verifiedAt: nil)
        let status = GohTrustPresenter.displayStatus(entry: entry, fastStatus: .unchanged)
        #expect(status == .looksUnchanged)
    }

    // displayStatus: no verifiedAt, fast .changed → .changed
    @Test("displayStatus: no verifiedAt + fast .changed(.size) → .changed(.size)")
    func displayStatusChanged() {
        let entry = makeEntry(path: "/a.bin", verifiedAt: nil)
        let status = GohTrustPresenter.displayStatus(entry: entry, fastStatus: .changed(.size))
        #expect(status == .changed(.size))
    }

    // displayStatus: no verifiedAt, fast .missing → .missing
    @Test("displayStatus: no verifiedAt + fast .missing → .missing")
    func displayStatusMissing() {
        let entry = makeEntry(path: "/a.bin", verifiedAt: nil)
        let status = GohTrustPresenter.displayStatus(entry: entry, fastStatus: .missing)
        #expect(status == .missing)
    }

    // displayStatus: no verifiedAt, fast .notBaselined → .notBaselined
    @Test("displayStatus: no verifiedAt + fast .notBaselined → .notBaselined")
    func displayStatusNotBaselined() {
        let entry = makeEntry(path: "/a.bin", verifiedAt: nil)
        let status = GohTrustPresenter.displayStatus(entry: entry, fastStatus: .notBaselined)
        #expect(status == .notBaselined)
    }

    // displayStatus: no verifiedAt, nil fast status → .recordedOnly
    @Test("displayStatus: no verifiedAt + nil fast status → .recordedOnly")
    func displayStatusRecordedOnly() {
        let entry = makeEntry(path: "/a.bin", verifiedAt: nil)
        let status = GohTrustPresenter.displayStatus(entry: entry, fastStatus: nil)
        #expect(status == .recordedOnly)
    }

    // AC8: .looksUnchanged and .verified(at:) must be DISTINCT display tokens.
    // This test asserts the model layer enforces non-collapsibility — a future
    // UI change cannot accidentally present a heuristic result as a cryptographic proof.
    @Test("AC8: TrustDisplayStatus.looksUnchanged and .verified(at:) have distinct label and icon")
    func looksUnchangedAndVerifiedAreDistinctTokens() {
        let verifiedDate = Date(timeIntervalSince1970: 1_748_000_000)

        let verifiedToken = TrustDisplayStatus.verified(at: verifiedDate)
        let looksUnchangedToken = TrustDisplayStatus.looksUnchanged

        // The two cases must not be equal (enforces model-layer distinctness).
        #expect(verifiedToken != looksUnchangedToken)

        // Their labels must be different strings.
        #expect(verifiedToken.label != looksUnchangedToken.label)

        // Their system image names must be different strings.
        #expect(verifiedToken.systemImage != looksUnchangedToken.systemImage)

        // Sanity: looksUnchanged label must mention "looks" or "unchanged" to
        // communicate the heuristic limitation.
        let label = looksUnchangedToken.label.lowercased()
        #expect(label.contains("looks") || label.contains("unchanged"),
            "looksUnchanged label must communicate the heuristic limitation")

        // Sanity: verified label must mention "verified" or the date.
        let verifiedLabel = verifiedToken.label.lowercased()
        #expect(verifiedLabel.contains("verif"),
            "verified label must communicate the cryptographic claim")
    }

    // Helper
    private func makeEntry(
        path: String,
        url: String = "https://example.com/file.bin",
        verifiedAt: Date?
    ) -> ProvenanceEntry {
        ProvenanceEntry(
            url: url,
            sha256: "sha256:aabb",
            size: 1,
            downloadedAt: Date(timeIntervalSince1970: 1_000),
            destinationPath: path,
            verifiedAt: verifiedAt)
    }
}
