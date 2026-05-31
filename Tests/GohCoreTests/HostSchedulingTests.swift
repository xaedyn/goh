import Foundation
import Testing

import GohCore

@Suite("Host key normalization")
struct HostKeyTests {

    // AC1: credentials stripped, nil host → nil, IPv6 bracketed,
    //       punycode host, default ports explicit, scheme lowercased.

    @Test("AC: credentials stripped from key")
    func ac1CredentialsStripped() {
        let key = hostKey(for: "https://user:pass@dl.example.com/file.iso")
        #expect(key == "https://dl.example.com:443")
    }

    @Test("AC: nil host returns nil key")
    func ac1NilHostReturnsNil() {
        // A URL with no host — e.g. a file URL or a bare scheme.
        let key = hostKey(for: "file:///tmp/foo")
        #expect(key == nil)
    }

    @Test("AC: IPv6 literal is bracketed in key")
    func ac1IPv6Bracketed() {
        let key = hostKey(for: "https://[2001:db8::1]/file")
        #expect(key == "https://[2001:db8::1]:443")
    }

    @Test("AC: default HTTPS port made explicit")
    func ac1DefaultHTTPSPort() {
        #expect(hostKey(for: "https://example.com/f") == "https://example.com:443")
    }

    @Test("AC: default HTTP port made explicit")
    func ac1DefaultHTTPPort() {
        #expect(hostKey(for: "http://example.com/f") == "http://example.com:80")
    }

    @Test("AC: non-default port preserved")
    func ac1NonDefaultPortPreserved() {
        #expect(hostKey(for: "https://example.com:8443/f") == "https://example.com:8443")
    }

    @Test("AC: host lowercased")
    func ac1HostLowercased() {
        #expect(hostKey(for: "https://DL.EXAMPLE.COM/f") == "https://dl.example.com:443")
    }

    @Test("AC: scheme lowercased")
    func ac1SchemeLowercased() {
        // URLComponents normalizes scheme to lowercase; confirm this holds.
        #expect(hostKey(for: "HTTPS://example.com/f") == "https://example.com:443")
    }

    @Test("AC: unparseable URL returns nil key")
    func ac1UnparseableURLReturnsNil() {
        #expect(hostKey(for: "not a url at all ://???") == nil)
    }

    @Test("AC: unknown scheme with no port returns nil key")
    func ac1UnknownSchemeNoPortReturnsNil() {
        // ftp has a host but no default port in the normalizer's table and no
        // explicit port — must return nil so the caller skips it rather than
        // mis-bucketing it under an arbitrary key.
        #expect(hostKey(for: "ftp://example.com/file") == nil)
    }

    @Test("AC: IDN host produces a stable ASCII key (deterministic, credential-free)")
    func ac1IDNHostStableASCIIKey() {
        // AC1 requires the key use the ASCII-encoded host form so the key is
        // encoding-stable and never carries raw multibyte host bytes.
        //
        // `percentEncodedHost` returns an ASCII, percent-encoded host. Its exact
        // IDN normalization is SDK-dependent (whether punycode and raw-Unicode
        // forms of one domain unify into one key varies by SDK) — so this test
        // does NOT assert a specific cross-form unification. The load-bearing,
        // SDK-stable invariants are determinism + ASCII-only + credential-free,
        // asserted below. In practice the daemon keys off the exact URL string
        // the user passed, which is consistent across repeat downloads.

        // (a) A plain ASCII host passes through unchanged and stably.
        let ascii = "https://example.com/f"
        #expect(hostKey(for: ascii) == "https://example.com:443")
        #expect(hostKey(for: ascii) == hostKey(for: ascii))  // deterministic

        // (b) A Unicode IDN host yields a deterministic, ASCII-only, credential-free key.
        let unicode = "https://κόσμος.com/f"
        let key1 = hostKey(for: unicode)
        let key2 = hostKey(for: unicode)
        #expect(key1 == key2)                          // deterministic
        let unwrapped = key1 ?? ""
        #expect(!unwrapped.isEmpty)
        #expect(unwrapped.allSatisfy { $0.isASCII })   // ASCII-only key
        #expect(!unwrapped.contains("κ"))              // no raw Unicode host bytes
    }
}

@Suite("HostScheduling on-disk types")
struct HostSchedulingTypesTests {

    private func sampleScheduling() -> HostScheduling {
        HostScheduling(
            version: HostScheduling.currentVersion,
            hosts: [
                HostProfile(
                    host: "https://dl.example.com:443",
                    arms: [
                        ConnObservation(
                            connectionCount: 8,
                            throughputEWMA: 10_000_000,
                            sampleCount: 3,
                            updatedAt: Date(timeIntervalSince1970: 1_748_700_000)),
                        ConnObservation(
                            connectionCount: 16,
                            throughputEWMA: 15_000_000,
                            sampleCount: 2,
                            updatedAt: Date(timeIntervalSince1970: 1_748_700_100)),
                    ],
                    updatedAt: Date(timeIntervalSince1970: 1_748_700_100)),
                HostProfile(
                    host: "http://cdn.example.com:80",
                    arms: [
                        ConnObservation(
                            connectionCount: 4,
                            throughputEWMA: 5_000_000,
                            sampleCount: 1,
                            updatedAt: Date(timeIntervalSince1970: 1_748_700_200)),
                    ],
                    updatedAt: Date(timeIntervalSince1970: 1_748_700_200)),
            ])
    }

    // AC2: Codable round-trip.
    @Test("AC: HostScheduling Codable round-trips losslessly")
    func ac2CodableRoundTrip() throws {
        let original = sampleScheduling()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(original)
        let decoded = try PropertyListDecoder().decode(HostScheduling.self, from: data)
        #expect(decoded == original)
    }

    // AC2: Golden fixture round-trip.
    // PRIMARY guard: decoded-value equality (SDK-stable). ROUND-TRIP STABILITY guard:
    // re-encode the just-decoded value and decode again, comparing to the first decode.
    @Test("AC: golden fixture decodes to known value; round-trip encode/decode is stable")
    func ac2GoldenFixtureRoundTrip() throws {
        let fixtureURL = Bundle.module.url(
            forResource: "host-scheduling-v1", withExtension: "plist",
            subdirectory: "Fixtures")
        let fixtureData = try Data(contentsOf: #require(fixtureURL))

        let decoded = try PropertyListDecoder().decode(HostScheduling.self, from: fixtureData)

        #expect(decoded.version == 1)
        #expect(decoded.hosts.count == 2)
        #expect(decoded.hosts[0].host == "https://dl.example.com:443")
        #expect(decoded.hosts[0].arms.count == 2)
        #expect(decoded.hosts[0].arms[0].connectionCount == 8)
        #expect(abs(decoded.hosts[0].arms[0].throughputEWMA - 10_000_000) < 1)
        #expect(decoded.hosts[0].arms[0].sampleCount == 3)
        #expect(decoded.hosts[0].arms[1].connectionCount == 16)
        #expect(decoded.hosts[1].host == "http://cdn.example.com:80")
        #expect(decoded.hosts[1].arms.count == 1)
        #expect(decoded.hosts[1].arms[0].connectionCount == 4)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let reencoded = try encoder.encode(decoded)
        let redecoded = try PropertyListDecoder().decode(HostScheduling.self, from: reencoded)
        #expect(redecoded == decoded)
    }

    @Test("AC: EWMA fold updates throughput and increments sampleCount")
    func ac2EWMAFold() {
        let arm = ConnObservation(
            connectionCount: 8, throughputEWMA: 10_000_000, sampleCount: 3,
            updatedAt: Date(timeIntervalSince1970: 1_000_000))
        let updated = arm.foldingIn(throughput: 20_000_000, alpha: 0.3)
        // new = 0.3 * 20_000_000 + 0.7 * 10_000_000 = 13_000_000
        #expect(abs(updated.throughputEWMA - 13_000_000) < 1)
        #expect(updated.sampleCount == 4)
        #expect(updated.connectionCount == 8)
    }

    @Test("AC: EWMA fold on a zero-sample arm seeds the EWMA directly")
    func ac2EWMAFoldSeedsWhenZeroSamples() {
        let arm = ConnObservation(
            connectionCount: 8, throughputEWMA: 0, sampleCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_000_000))
        let seeded = arm.foldingIn(throughput: 5_000_000, alpha: 0.3)
        // sampleCount == 0 → seed directly, ignoring alpha and the old (0) EWMA.
        #expect(abs(seeded.throughputEWMA - 5_000_000) < 1)
        #expect(seeded.sampleCount == 1)
        #expect(seeded.connectionCount == 8)
    }
}
