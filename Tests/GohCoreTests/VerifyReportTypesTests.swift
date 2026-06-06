import Foundation
import Testing
@testable import GohCore

@Suite("VerifyReportTypes")
struct VerifyReportTypesTests {

    // AC5 — raw values are the frozen --json contract; do NOT rename.
    @Test("AC5: VerifyStatus raw values are frozen")
    func verifyStatusRawValuesFrozen() {
        // If any raw value is renamed, the golden fixture + downstream scripts break.
        #expect(VerifyStatus.ok.rawValue == "ok")
        #expect(VerifyStatus.failed.rawValue == "failed")
        #expect(VerifyStatus.missing.rawValue == "missing")
    }

    // AC5 — error-envelope raw values frozen.
    @Test("AC5: VerifyErrorCode raw values are frozen")
    func verifyErrorCodeRawValuesFrozen() {
        #expect(VerifyErrorCode.ledgerUnreadable.rawValue == "ledgerUnreadable")
        #expect(VerifyErrorCode.ledgerCorrupt.rawValue == "ledgerCorrupt")
        #expect(VerifyErrorCode.ledgerVersionUnknown.rawValue == "ledgerVersionUnknown")
    }

    // AC1 — summary is derived by folding over entries (not maintained as parallel tallies).
    @Test("AC1: VerifySummary counts match per-status filter of entries")
    func summaryCounts() throws {
        let entries: [VerifyEntryResult] = [
            VerifyEntryResult(path: "/a", url: "https://x.com/a", status: .ok,
                              expectedSha256: "sha256:aa", actualSha256: nil),
            VerifyEntryResult(path: "/b", url: "https://x.com/b", status: .failed,
                              expectedSha256: "sha256:bb", actualSha256: "sha256:cc"),
            VerifyEntryResult(path: "/c", url: "https://x.com/c", status: .missing,
                              expectedSha256: "sha256:dd", actualSha256: nil),
        ]
        let summary = VerifySummary(
            total: entries.count,
            ok: entries.filter { $0.status == .ok }.count,
            failed: entries.filter { $0.status == .failed }.count,
            missing: entries.filter { $0.status == .missing }.count)

        // Each count MUST equal its per-status filter — not just that they sum.
        #expect(summary.total == entries.count)
        #expect(summary.ok == entries.filter { $0.status == .ok }.count)
        #expect(summary.failed == entries.filter { $0.status == .failed }.count)
        #expect(summary.missing == entries.filter { $0.status == .missing }.count)
    }

    // AC5 — encode-equals golden fixture (compact, CommandCoding.encoder).
    @Test("AC5: VerifyAllReport encodes to golden fixture byte-for-byte")
    func encodeEqualsGoldenFixture() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_714_262_400)
        let report = VerifyAllReport(
            reportVersion: 1,
            generatedAt: fixedDate,
            summary: VerifySummary(total: 3, ok: 1, failed: 1, missing: 1),
            entries: [
                VerifyEntryResult(
                    path: "/private/tmp/goh-fixture/ok.bin",
                    url: "https://example.com/ok.bin",
                    status: .ok,
                    expectedSha256: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    actualSha256: nil),
                VerifyEntryResult(
                    path: "/private/tmp/goh-fixture/failed.bin",
                    url: "https://example.com/failed.bin",
                    status: .failed,
                    expectedSha256: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    actualSha256: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
                VerifyEntryResult(
                    path: "/private/tmp/goh-fixture/missing.bin",
                    url: "https://example.com/missing.bin",
                    status: .missing,
                    expectedSha256: "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                    actualSha256: nil),
            ])

        let data = try CommandCoding.encoder.encode(report)
        let actualJSON = String(decoding: data, as: UTF8.self)

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/verify-all-report-v1.json")

        try #require(
            FileManager.default.fileExists(atPath: fixtureURL.path),
            "Golden fixture missing at \(fixtureURL.path). It is a committed baseline; restore it (or, for an intentional wire change, bump reportVersion and regenerate).")

        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixtureJSON = String(decoding: fixtureData, as: UTF8.self)
        #expect(
            actualJSON == fixtureJSON,
            "VerifyAllReport --json output differs from golden fixture. If this is intentional, bump reportVersion and delete the fixture to regenerate.")
    }

    // AC5 — error envelope encodes correctly.
    @Test("AC5: VerifyErrorReport encodes reportVersion and error code")
    func errorReportEncodesCorrectly() throws {
        let r = VerifyErrorReport(reportVersion: 1, error: .ledgerCorrupt)
        let data = try CommandCoding.encoder.encode(r)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"reportVersion\":1"))
        #expect(json.contains("\"error\":\"ledgerCorrupt\""))
    }
}
