import Foundation
import Testing
import GohCore

@Suite("LockfileCodec")
struct LockfileCodecTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "toml", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("decodes a full lockfile fixture with two entries")
    func decodesFullLockfile() throws {
        let lock = try LockfileCodec.decode(try fixture("toml-lockfile-full"))
        #expect(lock.lockfileVersion == 1)
        #expect(lock.manifestHash.hasPrefix("sha256:"))
        #expect(lock.entries.count == 2)
        #expect(lock.entries[0].url == "https://example.org/datasets/mnist.tar.gz")
        #expect(lock.entries[0].sha256.hasPrefix("sha256:"))
        #expect(lock.entries[0].size == 11594722)
        #expect(lock.entries[0].downloadedAt == "2026-05-29T14:08:51Z")
    }

    @Test("rejects unknown lockfileVersion loudly")
    func rejectsUnknownVersion() throws {
        #expect(throws: LockfileCodec.CodecError.self) { try LockfileCodec.decode(try fixture("toml-lockfile-bad-unknown-version")) }
    }

    @Test("rejects missing manifestHash field")
    func rejectsMissingManifestHash() throws {
        #expect(throws: LockfileCodec.CodecError.self) { try LockfileCodec.decode(try fixture("toml-lockfile-bad-missing-manifestHash")) }
    }

    @Test("rejects a malformed manifestHash shape (not sha256:<64-hex>)")
    func rejectsMalformedManifestHash() throws {
        let toml = """
            lockfileVersion = 1
            manifestHash = "not-a-valid-hash"
            """
        #expect(throws: LockfileCodec.CodecError.self) {
            try LockfileCodec.decode(toml)
        }
    }

    @Test("rejects reserved 'chunks' field present/non-null (§8.1)")
    func rejectsReservedChunksField() throws {
        #expect(throws: LockfileCodec.CodecError.self) { try LockfileCodec.decode(try fixture("toml-lockfile-bad-chunks-reserved")) }
    }

    @Test("encodes and round-trips a lockfile")
    func roundTrips() throws {
        let entry = LockfileCodec.LockEntry(
            url: "https://example.org/f.bin",
            path: "f.bin",
            sha256: "sha256:6f1e2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f",
            size: 1024,
            downloadedAt: "2026-05-29T12:00:00Z"
        )
        let lock = LockfileCodec.Lockfile(
            manifestHash: "sha256:a3f9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1",
            entries: [entry]
        )
        let decoded = try LockfileCodec.decode(LockfileCodec.encode(lock))
        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].url == entry.url)
        #expect(decoded.entries[0].sha256 == entry.sha256)
        #expect(decoded.entries[0].size == entry.size)
        #expect(decoded.entries[0].downloadedAt == entry.downloadedAt)
    }

    @Test("lockfileVersion is the first field in encoded output")
    func lockfileVersionIsFirst() throws {
        let lock = LockfileCodec.Lockfile(
            manifestHash: "sha256:a3f9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1",
            entries: []
        )
        let first = LockfileCodec.encode(lock).components(separatedBy: "\n").first!
        #expect(first.hasPrefix("lockfileVersion"))
    }

    // A round-trip (encode→decode) proves the encoder is *parseable*, not that
    // its byte layout is *frozen*. `gohfile.lock` is the on-disk wire format an
    // external tool may read, so a field-order / whitespace / quoting drift that
    // still round-trips would ship silently. This pins the encoder output
    // byte-for-byte against a committed golden — calibration approach: the
    // fixture was produced once by this exact encoder, then frozen.
    @Test("encoder output is byte-for-byte stable against the committed golden")
    func encoderByteGolden() throws {
        // Representative lockfile: two entries; the second URL carries an
        // embedded double-quote so the golden also pins TOML string escaping.
        let entry1 = LockfileCodec.LockEntry(
            url: "https://example.org/datasets/mnist.tar.gz",
            path: "data/mnist.tar.gz",
            sha256: "sha256:6f1e2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f",
            size: 11594722,
            downloadedAt: "2026-05-29T14:08:51Z"
        )
        let entry2 = LockfileCodec.LockEntry(
            url: "https://example.org/datasets/labels \"v2\".csv",
            path: "data/labels.csv",
            sha256: "sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
            size: 4096,
            downloadedAt: "2026-05-29T14:09:03Z"
        )
        let lock = LockfileCodec.Lockfile(
            manifestHash: "sha256:a3f9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1",
            entries: [entry1, entry2]
        )

        let encoded = LockfileCodec.encode(lock)
        let golden = try fixture("toml-lockfile-encoded-golden")

        #expect(encoded == golden,
            "lockfile encoder output drifted from the committed golden — the on-disk wire format changed")
    }
}
