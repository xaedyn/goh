import Foundation
import Testing

import GohCore

@Suite("Catalog store")
struct CatalogStoreTests {

    /// A fresh temporary directory; the caller removes it.
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goh-catalog-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sampleCatalog() -> JobCatalog {
        let job = JobSummary(
            id: 1,
            url: "https://example.com/f.iso",
            destination: "/tmp/f.iso",
            state: .queued,
            progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastProgressAt: nil,
            requestedConnectionCount: 8,
            actualConnectionCount: 0)
        return JobCatalog(version: JobCatalog.currentVersion, nextID: 2, jobs: [job])
    }

    @Test("save then load round-trips the catalog")
    func saveLoadRoundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CatalogStore(fileURL: directory.appending(path: "catalog.plist"))
        let catalog = sampleCatalog()
        try store.save(catalog)

        let loaded = store.load()
        #expect(loaded.catalog == catalog)
        #expect(loaded.corruptionSidecar == nil)
    }

    @Test("loading a missing catalog yields an empty catalog")
    func loadMissingFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CatalogStore(fileURL: directory.appending(path: "catalog.plist"))
        let loaded = store.load()
        #expect(loaded.catalog.jobs.isEmpty)
        #expect(loaded.catalog.nextID == 1)
        #expect(loaded.corruptionSidecar == nil)
    }

    @Test("a corrupt catalog recovers to empty and leaves a sidecar copy")
    func loadCorruptFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "catalog.plist")
        try Data("this is not a property list".utf8).write(to: fileURL)

        let store = CatalogStore(fileURL: fileURL)
        let loaded = store.load()
        #expect(loaded.catalog.jobs.isEmpty)
        let sidecar = try #require(loaded.corruptionSidecar)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test("save leaves no temporary file behind")
    func saveLeavesNoTempFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CatalogStore(fileURL: directory.appending(path: "catalog.plist"))
        try store.save(sampleCatalog())

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents == ["catalog.plist"])
    }

    @Test("save writes catalog.plist with owner-only 0600 permissions")
    func saveSets0600Permissions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "catalog.plist")
        let store = CatalogStore(fileURL: fileURL)
        try store.save(sampleCatalog())

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }
}
