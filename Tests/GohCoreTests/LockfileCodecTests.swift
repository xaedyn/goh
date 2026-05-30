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
}
