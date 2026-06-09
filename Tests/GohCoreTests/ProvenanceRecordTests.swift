import Foundation
import Testing

@testable import GohCore

@Suite("ProvenanceRecord")
struct ProvenanceRecordTests {

    // MARK: - AC4: golden fixture round-trip (T1)

    // AC4: New store has its own version field; golden round-trip passes.
    @Test("AC4/T1: golden fixture decodes to known value; round-trip encode/decode is stable")
    func goldenFixtureRoundTrip() throws {
        let fixtureURL = Bundle.module.url(
            forResource: "provenance-v1", withExtension: "plist",
            subdirectory: "Fixtures")
        let fixtureData = try Data(contentsOf: #require(fixtureURL))

        let decoded = try PropertyListDecoder().decode(ProvenanceRecord.self, from: fixtureData)

        // AC5: v1 fixture has no verifiedAt key — must decode with verifiedAt == nil.
        #expect(decoded.entries.allSatisfy { $0.verifiedAt == nil })

        // Version sentinel
        #expect(decoded.version == 1)
        #expect(decoded.version == ProvenanceRecord.currentVersion)

        // Two entries: one normal, one zero-size
        #expect(decoded.entries.count == 2)

        let first = decoded.entries[0]
        #expect(first.url == "https://dl.example.com/a.bin")
        #expect(first.sha256 == "sha256:aabbccdd" + String(repeating: "0", count: 56))
        #expect(first.size == 1_048_576)
        #expect(first.destinationPath == "/Users/testuser/Downloads/a.bin")

        let second = decoded.entries[1]
        #expect(second.url == "https://cdn.example.net/empty.bin")
        #expect(second.sha256 == "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(second.size == 0)
        #expect(second.destinationPath == "/Users/testuser/Downloads/empty.bin")

        // Round-trip: re-encode the decoded value, then decode again — the two decoded
        // values must be equal. We do NOT assert byte-identity vs the fixture because
        // binary-plist encoding is not guaranteed bit-stable across SDK versions (the
        // cross-SDK-skew gotcha). This mirrors the host-scheduling golden test pattern.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let reencoded = try encoder.encode(decoded)
        let redecoded = try PropertyListDecoder().decode(ProvenanceRecord.self, from: reencoded)
        #expect(redecoded == decoded)
    }

    // AC4: empty is the correct zero value.
    @Test("AC4/T1: ProvenanceRecord.empty has version == currentVersion and no entries")
    func emptyIsCorrect() {
        let empty = ProvenanceRecord.empty
        #expect(empty.version == ProvenanceRecord.currentVersion)
        #expect(empty.entries.isEmpty)
    }

    // Codable round-trip (encode then decode — separate from the golden fixture).
    @Test("T1: encode/decode round-trip is lossless")
    func encodeDecodeRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_748_000_000)
        let record = ProvenanceRecord(
            version: ProvenanceRecord.currentVersion,
            entries: [
                ProvenanceEntry(
                    url: "https://example.com/f.bin",
                    sha256: "sha256:" + String(repeating: "a", count: 64),
                    size: 512,
                    downloadedAt: fixedDate,
                    destinationPath: "/tmp/f.bin")
            ])

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        let decoded = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
        #expect(decoded == record)
    }

    // AC9: adding the 5 optional baseline fields does NOT break the golden fixture.
    // The fixture must still decode (nil baseline), round-trip unchanged, and
    // ProvenanceRecord.currentVersion must remain 1.
    @Test("AC9: golden fixture still round-trips after adding 5 optional baseline fields")
    func baselineFieldsAreAdditivePONilDecodes() throws {
        // Re-read the fixture.
        let fixtureURL = Bundle.module.url(
            forResource: "provenance-v1", withExtension: "plist",
            subdirectory: "Fixtures")
        let fixtureData = try Data(contentsOf: #require(fixtureURL))
        let decoded = try PropertyListDecoder().decode(ProvenanceRecord.self, from: fixtureData)

        // Version must not have changed.
        #expect(ProvenanceRecord.currentVersion == 1)
        #expect(decoded.version == 1)

        // All five new fields must decode as nil (not present in the old fixture).
        for entry in decoded.entries {
            #expect(entry.recordedStatSize == nil,
                "recordedStatSize should be nil for pre-feature entries")
            #expect(entry.recordedMtimeSeconds == nil,
                "recordedMtimeSeconds should be nil for pre-feature entries")
            #expect(entry.recordedMtimeNanoseconds == nil,
                "recordedMtimeNanoseconds should be nil for pre-feature entries")
            #expect(entry.recordedInode == nil,
                "recordedInode should be nil for pre-feature entries")
            #expect(entry.recordedDevice == nil,
                "recordedDevice should be nil for pre-feature entries")
        }

        // Round-trip the decoded value — encode→decode must be identity.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let reencoded = try encoder.encode(decoded)
        let redecoded = try PropertyListDecoder().decode(ProvenanceRecord.self, from: reencoded)
        #expect(redecoded == decoded)

        // Round-trip an entry WITH baseline fields set — they must survive.
        var entryWithBaseline = decoded.entries[0]
        entryWithBaseline.recordedStatSize = 1_048_576
        entryWithBaseline.recordedMtimeSeconds = 1_748_000_000
        entryWithBaseline.recordedMtimeNanoseconds = 123_456_789
        entryWithBaseline.recordedInode = 42_000
        entryWithBaseline.recordedDevice = 1
        let recordWithBaseline = ProvenanceRecord(version: 1, entries: [entryWithBaseline])
        let data2 = try encoder.encode(recordWithBaseline)
        let decoded2 = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data2)
        #expect(decoded2.entries[0].recordedStatSize == 1_048_576)
        #expect(decoded2.entries[0].recordedMtimeSeconds == 1_748_000_000)
        #expect(decoded2.entries[0].recordedMtimeNanoseconds == 123_456_789)
        #expect(decoded2.entries[0].recordedInode == 42_000)
        #expect(decoded2.entries[0].recordedDevice == 1)
    }

    // AC5: verifiedAt is additive-optional — nil encodes identically to no key;
    // re-decoded verifiedAt is nil; existing golden fixture bytes decode unchanged.
    @Test("AC5: verifiedAt nil round-trips stably; existing entries decode with verifiedAt==nil")
    func verifiedAtNilRoundTrip() throws {
        #expect(ProvenanceRecord.currentVersion == 1)
        let entry = ProvenanceEntry(
            url: "https://example.com/f.bin",
            sha256: "sha256:" + String(repeating: "a", count: 64),
            size: 512,
            downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
            destinationPath: "/tmp/f.bin",
            verifiedAt: nil)
        let record = ProvenanceRecord(version: 1, entries: [entry])
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        let decoded = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
        #expect(decoded.entries[0].verifiedAt == nil)

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let entryWithDate = ProvenanceEntry(
            url: "https://example.com/f.bin",
            sha256: "sha256:" + String(repeating: "a", count: 64),
            size: 512,
            downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
            destinationPath: "/tmp/f.bin",
            verifiedAt: now)
        let record2 = ProvenanceRecord(version: 1, entries: [entryWithDate])
        let data2 = try encoder.encode(record2)
        let decoded2 = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data2)
        #expect(decoded2.entries[0].verifiedAt == now)
    }
}
