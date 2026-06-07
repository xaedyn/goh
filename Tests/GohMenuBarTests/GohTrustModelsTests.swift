import Foundation
import Testing
import GohCore
@testable import GohMenuBar

// AC1/AC2/AC4: GohTrustModels type/field correctness + ProvenanceReading protocol seam.
@Suite("GohTrustModels")
struct GohTrustModelsTests {

    // AC1: GohTrustSummary counts are correct
    @Test("GohTrustSummary stores tracked/verified/downloadOnly counts")
    func summaryStorescounts() {
        let s = GohTrustSummary(tracked: 10, verified: 7, downloadOnly: 3)
        #expect(s.tracked == 10)
        #expect(s.verified == 7)
        #expect(s.downloadOnly == 3)
    }

    // AC1: GohTrustOverview cases exist and are Equatable
    @Test("GohTrustOverview cases: empty, unavailable, summary")
    func overviewCases() {
        let e: GohTrustOverview = .empty
        let u: GohTrustOverview = .unavailable
        let s: GohTrustOverview = .summary(GohTrustSummary(tracked: 1, verified: 1, downloadOnly: 0))
        #expect(e == .empty)
        #expect(u == .unavailable)
        #expect(e != u)
        #expect(e != s)
    }

    // AC2: GohTrustEntryRow stores expected fields
    @Test("GohTrustEntryRow stores displayPath, sanitizedURL, sha256, downloadedAt, verifiedAt")
    func entryRowFields() {
        let now = Date()
        let row = GohTrustEntryRow(
            displayPath: "/Users/me/Downloads/file.bin",
            sanitizedURL: "https://example.com/file.bin",
            sha256: "sha256:aabb",
            downloadedAt: now,
            verifiedAt: nil)
        #expect(row.displayPath == "/Users/me/Downloads/file.bin")
        #expect(row.sanitizedURL == "https://example.com/file.bin")
        #expect(row.sha256 == "sha256:aabb")
        #expect(row.downloadedAt == now)
        #expect(row.verifiedAt == nil)
    }

    // AC4: ProvenanceReading protocol — stub satisfies the seam
    @Test("ProvenanceReading stub returns injected outcome")
    func provenanceReadingStub() {
        struct StubReader: ProvenanceReading {
            let outcome: ProvenanceReadOutcome
            nonisolated func read() -> ProvenanceReadOutcome { outcome }
        }
        let stub = StubReader(outcome: .absent)
        #expect(stub.read() == .absent)
        let stub2 = StubReader(outcome: .entries([]))
        #expect(stub2.read() == .entries([]))
    }
}
