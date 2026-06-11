import Foundation
import Testing

@testable import GohCore

@Suite("GohCommandLine.parse — forget verb")
struct GohCommandLineForgetParseTests {

    private func makeResult(_ args: [String]) -> GohCommandLineResult {
        GohCommandLine(
            arguments: args,
            send: { _ in throw URLError(.cancelled) }
        ).run()
    }

    @Test("forget <path> parses to forgetPath")
    func testParseForgetPath() {
        let result = makeResult(["forget", "/tmp/file.bin"])
        // Will fail with "cannot reach gohd" because no real daemon — but must not be exit 64.
        #expect(result.exitCode != 64)
    }

    @Test("forget --missing parses to forgetMissing(confirm:false)")
    func testParseForgetMissing() {
        let result = makeResult(["forget", "--missing"])
        // Dry run — no daemon needed. Empty ledger → exit 0.
        #expect(result.exitCode == 0 || result.exitCode == 6)
    }

    @Test("forget --missing --confirm parses to forgetMissing(confirm:true)")
    func testParseForgetMissingConfirm() {
        let result = makeResult(["forget", "--missing", "--confirm"])
        // No real daemon but also empty ledger → "No tracked entries" → exit 0 (no send needed).
        #expect(result.exitCode == 0 || result.exitCode == 1)
    }

    @Test("forget --confirm without --missing is exit 64")
    func testForgetConfirmWithoutMissingIsUsageError() {
        let result = makeResult(["forget", "--confirm"])
        #expect(result.exitCode == 64)
    }

    @Test("forget --missing /tmp/x.bin (both selectors) is exit 64")
    func testForgetBothSelectorsIsUsageError() {
        let result = makeResult(["forget", "--missing", "/tmp/x.bin"])
        #expect(result.exitCode == 64)
    }

    @Test("forget with unknown flag is exit 64")
    func testForgetUnknownFlagIsUsageError() {
        let result = makeResult(["forget", "--zap"])
        #expect(result.exitCode == 64)
    }

    @Test("forget with no arguments is exit 64")
    func testForgetNoArguments() {
        let result = makeResult(["forget"])
        #expect(result.exitCode == 64)
    }

    @Test("forget with two positional paths is exit 64")
    func testForgetTwoPositionalsIsUsageError() {
        let result = makeResult(["forget", "/tmp/a.bin", "/tmp/b.bin"])
        #expect(result.exitCode == 64)
    }
}
