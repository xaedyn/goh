import Foundation
import Testing
import GohCore

@Suite("MinimalTOMLReader")
struct MinimalTOMLReaderTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "toml", subdirectory: "Fixtures"),
            "missing fixture: Fixtures/\(name).toml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("parses a full manifest fixture into named key-value sections")
    func parsesFullManifest() throws {
        let toml = try fixture("toml-manifest-full")
        let doc = try MinimalTOMLReader.parse(toml)
        let version = try #require(doc.topLevel["version"]?.intValue)
        #expect(version == 1)
        let base = try #require(doc.topLevel["base"]?.stringValue)
        #expect(base == "assets")
        #expect(doc.arrayOfTables("asset").count == 2)
    }

    @Test("parses an empty manifest (no [[asset]])")
    func parsesEmptyManifest() throws {
        let toml = try fixture("toml-manifest-empty")
        let doc = try MinimalTOMLReader.parse(toml)
        #expect(doc.arrayOfTables("asset").isEmpty)
    }

    @Test("parses a full lockfile fixture")
    func parsesFullLockfile() throws {
        let toml = try fixture("toml-lockfile-full")
        let doc = try MinimalTOMLReader.parse(toml)
        let lockfileVersion = try #require(doc.topLevel["lockfileVersion"]?.intValue)
        #expect(lockfileVersion == 1)
        #expect(doc.arrayOfTables("entry").count == 2)
    }

    @Test("rejects an unknown top-level key loudly")
    func rejectsUnknownTopLevelKey() throws {
        let toml = "version = 1\nunknownKey = \"oops\"\n"
        #expect(throws: MinimalTOMLReader.ParseError.self) {
            try MinimalTOMLReader.parse(toml, allowedTopLevelKeys: ["version", "base"])
        }
    }

    @Test("rejects an unknown per-asset key loudly")
    func rejectsUnknownAssetKey() throws {
        let toml = try fixture("toml-manifest-bad-unknown-key")
        #expect(throws: MinimalTOMLReader.ParseError.self) {
            try MinimalTOMLReader.parse(toml,
                allowedTopLevelKeys: ["version", "base"],
                allowedAssetKeys: ["url", "path", "dest", "sha256", "verify", "auth"])
        }
    }

    @Test("rejects inline table construct with named error")
    func rejectsInlineTable() throws {
        let toml = try fixture("toml-manifest-bad-inline-table")
        #expect(throws: MinimalTOMLReader.ParseError.self) { _ = try MinimalTOMLReader.parse(toml) }
    }

    @Test("rejects dotted key construct with named error")
    func rejectsDottedKey() throws {
        let toml = try fixture("toml-manifest-bad-dotted-key")
        #expect(throws: MinimalTOMLReader.ParseError.self) { _ = try MinimalTOMLReader.parse(toml) }
    }

    @Test("rejects array value construct with named error")
    func rejectsArrayValue() throws {
        let toml = try fixture("toml-manifest-bad-array-value")
        #expect(throws: MinimalTOMLReader.ParseError.self) { _ = try MinimalTOMLReader.parse(toml) }
    }

    @Test("rejects float value with named error")
    func rejectsFloat() throws {
        let toml = try fixture("toml-manifest-bad-float")
        #expect(throws: MinimalTOMLReader.ParseError.self) { _ = try MinimalTOMLReader.parse(toml) }
    }

    @Test("rejects native TOML datetime with named error")
    func rejectsNativeDatetime() throws {
        let toml = try fixture("toml-manifest-bad-native-datetime")
        #expect(throws: MinimalTOMLReader.ParseError.self) { _ = try MinimalTOMLReader.parse(toml) }
    }

    @Test("round-trips a known document through write then re-parse")
    func roundTrips() throws {
        let toml = try fixture("toml-manifest-full")
        let doc = try MinimalTOMLReader.parse(toml)
        let written = MinimalTOMLWriter.write(doc)
        let reparsed = try MinimalTOMLReader.parse(written)
        #expect(reparsed.topLevel["version"]?.intValue == doc.topLevel["version"]?.intValue)
        #expect(reparsed.arrayOfTables("asset").count == doc.arrayOfTables("asset").count)
    }

    @Test("rejects a duplicate top-level key loudly")
    func rejectsDuplicateTopLevelKey() throws {
        let toml = "version = 1\nversion = 2\n"
        #expect(throws: MinimalTOMLReader.ParseError.self) {
            _ = try MinimalTOMLReader.parse(toml)
        }
    }

    @Test("rejects a duplicate key within an array-of-tables entry loudly")
    func rejectsDuplicateKeyInTable() throws {
        let toml = """
            version = 1

            [[asset]]
            url = "https://example.org/a.bin"
            url = "https://example.org/b.bin"
            path = "a.bin"
            """
        #expect(throws: MinimalTOMLReader.ParseError.self) {
            _ = try MinimalTOMLReader.parse(toml)
        }
    }

    // MARK: - T1.2 tests

    @Test("reader admits reserved 'auth' key (domain rejection is ManifestCodec's job, Phase 2)")
    func readerAdmitsReservedAuthKey() throws {
        let toml = try fixture("toml-manifest-bad-auth-reserved")
        #expect(throws: Never.self) { _ = try MinimalTOMLReader.parse(toml) }
    }

    @Test("reader admits reserved 'chunks' key (domain rejection is LockfileCodec's job, Phase 2)")
    func readerAdmitsReservedChunksKey() throws {
        let toml = try fixture("toml-lockfile-bad-chunks-reserved")
        #expect(throws: Never.self) { _ = try MinimalTOMLReader.parse(toml) }
    }
}
