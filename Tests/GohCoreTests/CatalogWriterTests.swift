import Foundation
import Testing

import GohCore

@Suite("Catalog writer")
struct CatalogWriterTests {

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goh-writer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func catalog(nextID: UInt64) -> JobCatalog {
        JobCatalog(version: JobCatalog.currentVersion, nextID: nextID, jobs: [])
    }

    @Test("rapid saves coalesce to a single write of the latest snapshot")
    func coalescesToLatest() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "catalog.plist")
        // A long window so nothing lands until flush() forces it.
        let writer = CatalogWriter(store: CatalogStore(fileURL: fileURL), window: 30)

        writer.scheduleSave(catalog(nextID: 2))
        writer.scheduleSave(catalog(nextID: 3))
        writer.scheduleSave(catalog(nextID: 9))
        writer.flush()

        #expect(CatalogStore(fileURL: fileURL).load().catalog.nextID == 9)
    }

    @Test("a scheduled save lands on disk after the coalescing window")
    func scheduledSaveLands() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "catalog.plist")
        let writer = CatalogWriter(store: CatalogStore(fileURL: fileURL), window: 0.02)

        writer.scheduleSave(catalog(nextID: 7))
        Thread.sleep(forTimeInterval: 0.3)

        #expect(CatalogStore(fileURL: fileURL).load().catalog.nextID == 7)
    }

    @Test("flush with nothing pending is a harmless no-op")
    func flushWhenIdle() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "catalog.plist")
        let writer = CatalogWriter(store: CatalogStore(fileURL: fileURL), window: 30)

        writer.flush()
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }
}
