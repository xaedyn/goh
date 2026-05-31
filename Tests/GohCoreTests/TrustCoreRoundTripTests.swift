import Foundation
import Testing

@testable import GohCore

/// Frozen-format round-trip guard (CI gate).
///
/// `gohfile.toml` (manifest, hand-written) and `gohfile.lock` (machine-written)
/// are frozen on-disk formats other tools may read. A value that survives
/// `encode` but is corrupted by `decode` — or vice versa — is a contract bug.
/// This suite drives a corpus of "tricky" strings (the characters that have
/// structural meaning in the accepted TOML subset: `"`, `\`, `#`, plus `=`, `?`,
/// spaces, unicode) through both codecs and asserts byte-exact preservation.
///
/// If you add a character class the format must carry, add it to `corpus`. If a
/// future writer/reader change breaks round-trip, these tests fail in CI before
/// the format ships a corruption.
@Suite("TrustCore frozen-format round-trip")
struct TrustCoreRoundTripTests {

    /// Strings the frozen formats must round-trip exactly. Each is a plausible
    /// `url` or `path` value.
    static let corpus: [String] = [
        "https://example.org/f.bin",
        "https://example.org/f?a=1&b=2",              // query: `=` and `&`
        "https://example.org/f?a=1#section",          // fragment: `#` inside a value
        "https://example.org/path with spaces/f.bin", // spaces
        "https://example.org/a\"quoted\"/f.bin",      // literal double quotes
        "https://example.org/back\\slash/f.bin",      // literal backslash
        "https://example.org/both\"and\\here#x",      // quote + backslash + hash
        "weights/modèle-aigüe.bin",                   // unicode
        "dir/sub/deep/file.name.ext",
        "a#b\"c\\d=e?f g",                            // all structural chars at once
    ]

    private static func validLockSha() -> String {
        "sha256:" + String(repeating: "a", count: 64)
    }

    @Test("LockfileCodec encode -> decode preserves url and path exactly")
    func lockRoundTripsCorpus() throws {
        for value in Self.corpus {
            let entry = LockfileCodec.LockEntry(
                url: value, path: value,
                sha256: Self.validLockSha(), size: 7,
                downloadedAt: "2026-05-29T00:00:00Z")
            let lock = LockfileCodec.Lockfile(
                manifestHash: Self.validLockSha(), entries: [entry])
            let decoded = try LockfileCodec.decode(LockfileCodec.encode(lock))
            let got = try #require(decoded.entries.first)
            #expect(got.url == value, "url round-trip failed for \(value.debugDescription)")
            #expect(got.path == value, "path round-trip failed for \(value.debugDescription)")
            #expect(got.sha256 == entry.sha256)
            #expect(got.size == entry.size)
            #expect(got.downloadedAt == entry.downloadedAt)
        }
    }

    @Test("MinimalTOMLReader decodes \\\" and \\\\ escapes")
    func readerHonorsEscapes() throws {
        // url = "a\"b\\c"  ->  a"b\c
        let toml = "url = \"a\\\"b\\\\c\"\n"
        let doc = try MinimalTOMLReader.parse(toml)
        #expect(doc.topLevel["url"]?.stringValue == "a\"b\\c")
    }

    @Test("MinimalTOMLReader rejects an unknown escape with a named error")
    func readerRejectsUnknownEscape() {
        let toml = "url = \"bad\\xescape\"\n"  // \x is not a supported escape
        #expect(throws: MinimalTOMLReader.ParseError.self) {
            _ = try MinimalTOMLReader.parse(toml)
        }
    }

    @Test("LockfileCodec round-trips a url/path containing a tab and newline")
    func lockRoundTripsControlChars() throws {
        let value = "weights/a\tb\nc.bin"
        let entry = LockfileCodec.LockEntry(
            url: value, path: value,
            sha256: Self.validLockSha(), size: 9,
            downloadedAt: "2026-05-29T00:00:00Z")
        let lock = LockfileCodec.Lockfile(
            manifestHash: Self.validLockSha(), entries: [entry])
        let decoded = try LockfileCodec.decode(LockfileCodec.encode(lock))
        let got = try #require(decoded.entries.first)
        #expect(got.url == value)
        #expect(got.path == value)
    }

    @Test("hand-written manifest: a url with a # fragment is preserved (not comment-stripped)")
    func manifestPreservesFragment() throws {
        let toml = """
            version = 1
            [[asset]]
            url  = "https://example.org/model.bin?rev=3#weights"
            path = "model.bin"
            """
        let manifest = try ManifestCodec.parse(toml)
        let asset = try #require(manifest.assets.first)
        #expect(asset.url == "https://example.org/model.bin?rev=3#weights")
    }

    @Test("hand-written manifest: a real trailing comment after a quoted value is still stripped")
    func manifestStripsTrailingComment() throws {
        let toml = """
            version = 1
            [[asset]]
            url  = "https://example.org/f.bin"  # the model
            path = "f.bin"
            """
        let manifest = try ManifestCodec.parse(toml)
        let asset = try #require(manifest.assets.first)
        #expect(asset.url == "https://example.org/f.bin")
    }
}
