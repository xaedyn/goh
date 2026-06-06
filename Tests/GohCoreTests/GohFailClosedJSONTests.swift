import Foundation
import Testing

import GohCore

/// Security-critical verify commands emit JSON via a shared helper that must
/// NEVER produce blank stdout with a success exit code on an encode failure —
/// otherwise `goh verify-attestation --json && deploy` could deploy on a
/// swallowed error. See `docs/security-audit-2026-06.md` finding H3.
@Suite("Fail-closed JSON emission")
struct GohFailClosedJSONTests {
    private struct Sample: Encodable { var value: Int }

    @Test("emits a JSON body with the success exit code when encoding succeeds")
    func successEmitsBody() {
        let result = GohCommandLineResult.jsonOrFailClosed(
            Sample(value: 7),
            successExitCode: 0,
            failureMessage: "sample: failed to encode JSON\n",
            encode: { try JSONEncoder().encode($0) })
        #expect(result.exitCode == 0)
        #expect(!result.standardOutput.isEmpty)
        #expect(result.standardError.isEmpty)
    }

    @Test("fails closed with exit 6 and empty stdout when encoding throws")
    func encodeFailureFailsClosed() {
        struct EncodeBoom: Error {}
        let result = GohCommandLineResult.jsonOrFailClosed(
            Sample(value: 7),
            successExitCode: 0,
            failureMessage: "sample: failed to encode JSON\n",
            encode: { _ in throw EncodeBoom() })
        #expect(result.exitCode == 6)
        #expect(result.standardOutput.isEmpty)
        #expect(!result.standardError.isEmpty)
    }
}
