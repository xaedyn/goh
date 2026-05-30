import Foundation
import Testing
import GohCore

@Suite("ManifestCodec")
struct ManifestCodecTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "toml", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("parses a full manifest with pinned and unpinned assets")
    func parsesFullManifest() throws {
        let m = try ManifestCodec.parse(try fixture("toml-manifest-full"))
        #expect(m.assets.count == 2)
        #expect(m.assets[0].url == "https://example.org/datasets/mnist.tar.gz")
        #expect(m.assets[0].path == "datasets/mnist.tar.gz")
        #expect(m.assets[0].sha256 == "sha256:6f1e2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f")
        #expect(m.assets[1].sha256 == nil)
    }

    @Test("parses an empty manifest (zero assets)")
    func parsesEmptyManifest() throws {
        #expect(try ManifestCodec.parse(try fixture("toml-manifest-empty")).assets.isEmpty)
    }

    @Test("rejects unknown asset key loudly")
    func rejectsUnknownAssetKey() throws {
        let toml = try fixture("toml-manifest-bad-unknown-key")
        #expect(throws: ManifestCodec.CodecError.self) { try ManifestCodec.parse(toml) }
    }

    @Test("rejects malformed sha256")
    func rejectsMalformedSha256() throws {
        let toml = try fixture("toml-manifest-bad-sha256-shape")
        #expect(throws: ManifestCodec.CodecError.self) { try ManifestCodec.parse(toml) }
    }

    @Test("rejects reserved 'auth' key present/non-null (§4.4/§7.1)")
    func rejectsReservedAuthKey() throws {
        let toml = try fixture("toml-manifest-bad-auth-reserved")
        #expect(throws: ManifestCodec.CodecError.self) { try ManifestCodec.parse(toml) }
    }

    @Test("rejects unknown manifest version")
    func rejectsUnknownVersion() throws {
        let toml = "version = 99\n[[asset]]\nurl = \"http://x.com/f\"\npath = \"f\"\n"
        #expect(throws: ManifestCodec.CodecError.self) { try ManifestCodec.parse(toml) }
    }

    @Test("accepts 'dest' as alias for 'path'")
    func acceptsDestAlias() throws {
        let toml = "version = 1\n[[asset]]\nurl  = \"https://example.org/f.bin\"\ndest = \"subdir/f.bin\"\n"
        #expect(try ManifestCodec.parse(toml).assets[0].path == "subdir/f.bin")
    }

    @Test("rejects both 'path' and 'dest' present")
    func rejectsBothPathAndDest() throws {
        let toml = "version = 1\n[[asset]]\nurl  = \"https://example.org/f.bin\"\npath = \"a/f.bin\"\ndest = \"b/f.bin\"\n"
        #expect(throws: ManifestCodec.CodecError.self) { try ManifestCodec.parse(toml) }
    }

    @Test("computes sha256 of manifest bytes for manifestHash")
    func computesManifestHash() throws {
        let m = try ManifestCodec.parse(try fixture("toml-manifest-full"))
        #expect(m.manifestHash.hasPrefix("sha256:"))
        #expect(m.manifestHash.count == 7 + 64)
    }
}
