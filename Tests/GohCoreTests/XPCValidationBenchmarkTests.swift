import Foundation
import Testing
import XPC

import GohCore

/// Benchmarks the cost of an `XPCPeerRequirement` evaluation — the work the OS
/// does to validate a peer's code signature (see `DESIGN.md` §3.1). OS
/// code-signing evaluation is cached, so the first call (cold) and steady state
/// (warm) can differ by an order of magnitude; both are measured and checked.
///
/// This times `XPCReceivedMessage.senderSatisfies` — the requirement-evaluation
/// primitive — because the production session-accept validation path needs a
/// launchd-registered Mach service and a signed binary.
@Suite("XPC peer-validation cost")
struct XPCValidationBenchmarkTests {

    /// The cold and warm requirement-evaluation costs, in milliseconds.
    struct Measurement: Codable, Sendable {
        var coldMilliseconds: Double
        var warmMedianMilliseconds: Double
    }

    struct ProbeRequest: Codable, Sendable {
        var probe = true
    }

    /// `>20 ms` on a per-connection check is a design problem on a fast-path
    /// verb like `goh ls`; the test fails the build above it (see `DESIGN.md`
    /// §3.1: ≤5 ms invisible, 5–20 ms noticeable, >20 ms needs a design response).
    static let budgetMilliseconds = 20.0

    /// Steady-state sample count.
    static let warmSampleCount = 1000

    @Test("a peer-requirement evaluation stays within the fast-path budget, cold and warm")
    func evaluationCostWithinBudget() throws {
        let listener = XPCListener(incomingSessionHandler: { request in
            request.accept(incomingMessageHandler: {
                (message: XPCReceivedMessage) -> (any Encodable)? in
                let requirement = XPCPeerRequirement.isFromSameTeam()
                let clock = ContinuousClock()

                let coldStart = clock.now
                _ = message.senderSatisfies(requirement)
                let cold = clock.now - coldStart

                var samples: [Duration] = []
                samples.reserveCapacity(Self.warmSampleCount)
                for _ in 0..<Self.warmSampleCount {
                    let start = clock.now
                    _ = message.senderSatisfies(requirement)
                    samples.append(clock.now - start)
                }
                samples.sort()

                return Measurement(
                    coldMilliseconds: cold.milliseconds,
                    warmMedianMilliseconds: samples[samples.count / 2].milliseconds)
            })
        })
        defer { listener.cancel() }

        let session = try XPCSession(endpoint: listener.endpoint)
        defer { session.cancel(reason: "benchmark finished") }

        let measured: Measurement = try session.sendSync(ProbeRequest())
        print(
            """
            XPC peer-validation cost — cold: \(measured.coldMilliseconds) ms, \
            warm median (N=\(Self.warmSampleCount)): \(measured.warmMedianMilliseconds) ms
            """)

        #expect(
            measured.coldMilliseconds < Self.budgetMilliseconds,
            "cold peer-validation cost exceeds the \(Self.budgetMilliseconds) ms fast-path budget")
        #expect(
            measured.warmMedianMilliseconds < Self.budgetMilliseconds,
            "warm peer-validation cost exceeds the \(Self.budgetMilliseconds) ms fast-path budget")
    }
}

extension Duration {
    /// This duration expressed in milliseconds.
    fileprivate var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
