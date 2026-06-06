import Foundation
import Testing
@testable import GohCore

// AC5 / crypto-critical: payload_bytes == fixture bytes (no newline)
// This is B1 from the spec: payload_bytes = CommandCoding.encoder.encode(report) with NO trailing newline.
@Suite("GohVerifyAllCommand — payloadBytes seam")
struct GohVerifyAllPayloadBytesTests {

    // AC5/B1: payloadBytes returns encoder output with NO trailing newline
    @Test("AC5/B1: payloadBytes(for:) == verify-all-report-v1.json fixture bytes (no trailing newline)")
    func payloadBytesMatchFixture() throws {
        // Construct the exact same report as the golden fixture
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

        // B1: payloadBytes must equal the fixture bytes (no trailing newline)
        let payload = try #require(GohVerifyAllCommand.payloadBytes(for: report),
            "payloadBytes returned nil — encoding a valid value type should never fail")

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/verify-all-report-v1.json")
        let fixtureData = try Data(contentsOf: fixtureURL)

        // Byte-exact equality: payload_bytes must == fixture bytes
        #expect(payload == fixtureData,
            "payload_bytes differ from fixture — check CommandCoding.encoder settings or newline leakage")

        // Confirm no trailing newline (last byte must be '}' = 0x7d)
        #expect(payload.last == 0x7D, "payload_bytes must not end with a newline")
    }

    // AC5/B1: --json stdout path still appends '\n' (frozen behavior, not changed)
    @Test("AC5/B1: --json stdout output ends with '\\n' (frozen stdout behavior)")
    func jsonStdoutEndsWithNewline() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-payload-seam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixedDate = Date(timeIntervalSince1970: 1_714_262_400)
        let result = GohVerifyAllCommand.run(
            provenanceStorePath: dir.appendingPathComponent("absent.plist").path,
            json: true,
            generatedAt: fixedDate)

        // stdout MUST end with '\n' (frozen; terminal display convention)
        #expect(result.standardOutput.hasSuffix("\n"),
            "--json stdout must end with \\n (frozen stdout behavior must not change)")
    }
}
