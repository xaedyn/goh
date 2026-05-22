import Foundation
import Testing

import GohCore

@Suite("Job store persistence")
struct JobStorePersistenceTests {

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goh-store-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("a store restores its jobs and id counter from a catalog")
    func restoresFromCatalog() {
        let job = JobSummary(
            id: 5,
            url: "https://example.com/restored",
            destination: "/tmp/restored",
            state: .queued,
            progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
            createdAt: Date(),
            lastProgressAt: nil,
            requestedConnectionCount: 8,
            actualConnectionCount: 0)
        let store = JobStore(catalog: JobCatalog(version: 1, nextID: 6, jobs: [job]))

        #expect(store.allJobs().map(\.id) == [5])
        // The id counter continues from the restored value.
        let created = store.create(url: "u", destination: "d", requestedConnectionCount: 8)
        #expect(created.id == 6)
    }

    @Test("a mutation is persisted and survives into a fresh store")
    func mutationSurvivesRestart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogStore = CatalogStore(fileURL: directory.appending(path: "catalog.plist"))
        let writer = CatalogWriter(store: catalogStore, window: 30)

        let storeA = JobStore(catalog: .empty, writer: writer)
        _ = storeA.create(
            url: "https://example.com/f", destination: "/tmp/f", requestedConnectionCount: 8)
        let job = storeA.create(
            url: "https://example.com/g", destination: "/tmp/g", requestedConnectionCount: 8)
        _ = try storeA.pause(id: job.id)
        writer.flush()

        // A fresh store loading the same catalog — as after a daemon restart.
        let storeB = JobStore(catalog: catalogStore.load().catalog)
        #expect(storeB.allJobs().map(\.url) == [
            "https://example.com/f", "https://example.com/g",
        ])
        #expect(storeB.job(id: job.id)?.state == .paused)
        // The counter survived: the next job is id 3.
        #expect(storeB.create(url: "u", destination: "d", requestedConnectionCount: 8).id == 3)
    }

    @Test("a removed job does not reappear after a restart")
    func removalSurvivesRestart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogStore = CatalogStore(fileURL: directory.appending(path: "catalog.plist"))
        let writer = CatalogWriter(store: catalogStore, window: 30)

        let storeA = JobStore(catalog: .empty, writer: writer)
        let job = storeA.create(url: "u", destination: "d", requestedConnectionCount: 8)
        try storeA.remove(id: job.id)
        writer.flush()

        let storeB = JobStore(catalog: catalogStore.load().catalog)
        #expect(storeB.allJobs().isEmpty)
    }
}
