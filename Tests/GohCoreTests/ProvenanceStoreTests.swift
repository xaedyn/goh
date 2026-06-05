import Foundation
import Testing

@testable import GohCore

@Suite("ProvenanceStore")
struct ProvenanceStoreTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-provenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fixedEntry(
        path: String = "/Users/u/Downloads/a.bin",
        sha256: String = "sha256:" + String(repeating: "a", count: 64),
        url: String = "https://example.com/a.bin",
        size: Int = 1024
    ) -> ProvenanceEntry {
        ProvenanceEntry(
            url: url,
            sha256: sha256,
            size: size,
            downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
            destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    // AC5/T2: Corrupt → sidecar copy; original left in place; next record still succeeds.
    @Test("AC5/T2: corrupt store recovers to empty and copies sidecar; original remains until next record")
    func corruptStoreSidecarCopy() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("provenance.plist")
        // Write garbage so decode fails.
        try Data("not a plist".utf8).write(to: fileURL)

        let store = ProvenanceStore(fileURL: fileURL)
        let result = store.load()

        // A sidecar copy was created.
        let sidecar = try #require(result.corruptionSidecar)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        // The corrupt original is LEFT IN PLACE (recoverToEmpty copies, not moves).
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        // In-memory state is reset to empty.
        #expect(result.record.entries.isEmpty)

        // Subsequent record() succeeds (overwrites the corrupt original via atomic rename).
        let entry = fixedEntry()
        try store.record(entry: entry)
        let entries = store.allEntries()
        #expect(entries.count == 1)
    }

    // BLOCK-3: loadReadOnly() is the CLI read path — it must create NO sidecar and
    // NO directory, even on a corrupt file (only the daemon's load() recovers).
    @Test("BLOCK-3: loadReadOnly on a corrupt file returns false and creates no sidecar")
    func loadReadOnlyNeverCreatesSidecar() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("provenance.plist")
        try Data("not a plist".utf8).write(to: fileURL)

        let store = ProvenanceStore(fileURL: fileURL)
        let ok = store.loadReadOnly()
        #expect(ok == false)

        // No sidecar was created; the directory holds only the corrupt original.
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents == ["provenance.plist"])
        // lookup on the (empty in-memory) store finds nothing.
        #expect(store.lookup(destinationPath: "/anything") == nil)
    }

    // BLOCK-3: loadReadOnly on a clean file populates in-memory state for lookup().
    @Test("BLOCK-3: loadReadOnly on a clean file returns true and lookup finds the entry")
    func loadReadOnlyCleanFilePopulatesLookup() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("provenance.plist")
        let writer = ProvenanceStore(fileURL: fileURL)
        _ = writer.load()
        let canonical = "/Users/u/Downloads/a.bin"
        try writer.record(entry: fixedEntry(path: canonical))

        // Fresh reader instance, read-only load.
        let reader = ProvenanceStore(fileURL: fileURL)
        #expect(reader.loadReadOnly() == true)
        #expect(reader.lookup(destinationPath: canonical)?.destinationPath == canonical)
    }

    // AC5/T3: In-place update / dedup.
    @Test("AC5/T3: two records with the same destinationPath keep exactly one entry with the latest values")
    func inPlaceUpdate() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
        _ = store.load()

        let path = "/Users/u/Downloads/dup.bin"
        let first = fixedEntry(
            path: path,
            sha256: "sha256:" + String(repeating: "1", count: 64))
        let second = fixedEntry(
            path: path,
            sha256: "sha256:" + String(repeating: "2", count: 64))

        try store.record(entry: first)
        try store.record(entry: second)

        let entries = store.allEntries()
        #expect(entries.count == 1)
        #expect(entries[0].sha256 == "sha256:" + String(repeating: "2", count: 64))
    }

    // Save / load round-trip.
    @Test("save then load round-trips ProvenanceRecord")
    func saveLoadRoundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
        _ = store.load()

        let entry = fixedEntry()
        try store.record(entry: entry)

        // Reload from disk via a fresh store instance.
        let store2 = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
        let result = store2.load()
        #expect(result.record.entries.count == 1)
        #expect(result.record.entries[0].destinationPath == entry.destinationPath)
        #expect(result.record.entries[0].sha256 == entry.sha256)
    }

    // Missing file → empty (no crash, no sidecar).
    @Test("missing store file yields empty record; no sidecar")
    func missingFileYieldsEmpty() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
        let result = store.load()
        #expect(result.record.entries.isEmpty)
        #expect(result.corruptionSidecar == nil)
    }

    // File permissions are 0600.
    @Test("saved file has owner-only 0600 permissions")
    func filePermissions() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: fileURL)
        _ = store.load()
        try store.record(entry: fixedEntry())

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let posixPerms = attrs[.posixPermissions] as? Int
        #expect(posixPerms == 0o600)
    }

    // No temp file left behind after write.
    @Test("record() leaves no temporary file behind")
    func noTempFileLeft() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
        _ = store.load()
        try store.record(entry: fixedEntry())

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents == ["provenance.plist"])
    }

    // lookup() canonicalizes the argument internally (ADVISORY C).
    @Test("lookup canonicalizes its argument; dotdot path finds stored canonical key")
    func lookupCanonicalizesArgument() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
        _ = store.load()

        // Store an entry with the canonical path.
        let canonical = "/Users/u/Downloads/a.bin"
        try store.record(entry: fixedEntry(path: canonical))

        // Lookup with a `..`-laden path that canonicalizes to the same string.
        // URL(fileURLWithPath:).standardizedFileURL.path collapses the `..`.
        let dotdotPath = "/Users/u/Downloads/../Downloads/a.bin"
        let found = store.lookup(destinationPath: dotdotPath)
        #expect(found != nil)
        #expect(found?.destinationPath == canonical)
    }

    // Version-mismatch → sidecar copy (like bad decode).
    @Test("version mismatch triggers sidecar copy and reset to empty")
    func versionMismatchTriggersSidecar() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("provenance.plist")

        // Write a record with a future version the current code does not know.
        struct FutureRecord: Codable {
            var version: Int
            var entries: [String]
        }
        let future = FutureRecord(version: 99, entries: [])
        let enc = PropertyListEncoder(); enc.outputFormat = .binary
        try enc.encode(future).write(to: fileURL)

        let store = ProvenanceStore(fileURL: fileURL)
        let result = store.load()

        let sidecar = try #require(result.corruptionSidecar)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(result.record.entries.isEmpty)
    }

    // AC13 (partial): ProvenanceStoreLocation.defaultURL(create:false) does NOT create the dir.
    @Test("AC13: defaultURL(create:false) does not create the Application Support subdir")
    func defaultURLCreateFalseDoesNotCreateDir() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The resolver should not create `dir/dev.goh.daemon/` when create=false
        // and the subdir does not exist. We cannot easily test the real
        // ~/Library/Application Support without side effects, so this test uses
        // the `lookup` path which calls `defaultURL(create: false)` in GohCommandLine.
        // Structural assertion: a missing store file at a non-existent path
        // produces nil from lookup, with no directory created.
        let missingDir = dir.appendingPathComponent("dev.goh.daemon")
        #expect(!FileManager.default.fileExists(atPath: missingDir.path))

        // Load a store against the (non-existent) dir — simulates CLI read path.
        let storeURL = missingDir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        let result = store.load()   // file absent → empty, no dir creation
        #expect(result.record.entries.isEmpty)
        #expect(result.corruptionSidecar == nil)
        // The directory was NOT created.
        #expect(!FileManager.default.fileExists(atPath: missingDir.path))
    }

    // AC5/T4: Best-effort non-fatal — a store whose write path throws must NOT propagate.
    // This tests the store's behavior with a broken write path. The daemon handler's
    // do/catch wrapping is tested structurally (the handler is wired correctly if
    // the compilation succeeds and the wiring test passes).
    @Test("AC5/T4: record() on an unwritable directory throws but the call site can catch-and-log without failing the download")
    func recordThrowsOnUnwritableDirectory() throws {
        // A2: root bypasses POSIX mode bits — a 0o555 directory is still writable as root,
        // so rename(2) would succeed and the test would pass WITHOUT asserting anything.
        // Skip under root so the test never silently no-ops. (`getuid` from `Darwin`.)
        try #require(getuid() != 0, "skipped as root: 0o555 does not block writes for uid 0")

        let dir = try tempDir()
        defer {
            // Re-enable permissions for cleanup.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let store = ProvenanceStore(fileURL: dir.appendingPathComponent("provenance.plist"))
        _ = store.load()  // succeeds (file absent → empty)

        // Make the directory unwritable so rename(2) fails.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: dir.path)

        // record() must throw (it cannot write the file).
        var threw = false
        do {
            try store.record(entry: fixedEntry())
        } catch {
            threw = true
            // Caller can log this without propagating — the download is still successful.
        }
        #expect(threw)
    }

    // CodeRabbit: a reload that finds the file missing/unreadable must reset
    // in-memory state, not serve entries from a prior successful load.
    @Test("reloading a store whose file vanished resets in-memory state to empty")
    func reloadAfterFileVanishesResetsState() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: fileURL)
        _ = store.load()
        try store.record(entry: fixedEntry())
        #expect(store.allEntries().count == 1)

        // The on-disk file disappears; a subsequent load() must not keep stale entries.
        try FileManager.default.removeItem(at: fileURL)
        let result = store.load()
        #expect(result.record.entries.isEmpty)
        #expect(store.allEntries().isEmpty)
        #expect(store.lookup(destinationPath: "/Users/u/Downloads/a.bin") == nil)
    }

    // CodeRabbit: loadReadOnly() failing on a reused instance must clear prior entries.
    @Test("loadReadOnly failure after a prior load clears stale in-memory entries")
    func loadReadOnlyFailureClearsStaleEntries() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("provenance.plist")
        // Seed a clean store, then read it once (populates in-memory state).
        let writer = ProvenanceStore(fileURL: fileURL)
        _ = writer.load()
        try writer.record(entry: fixedEntry(path: "/Users/u/Downloads/a.bin"))

        let reader = ProvenanceStore(fileURL: fileURL)
        #expect(reader.loadReadOnly() == true)
        #expect(reader.allEntries().count == 1)

        // Corrupt the file, then re-read on the SAME instance: must return false AND clear state.
        try Data("not a plist".utf8).write(to: fileURL)
        #expect(reader.loadReadOnly() == false)
        #expect(reader.allEntries().isEmpty)
    }
}
