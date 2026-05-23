import Foundation
import Synchronization
import Testing

@testable import GohCore

@Suite("Download engine")
struct DownloadEngineTests {

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goh-engine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("a successful download lands the bytes on disk and completes the job")
    func successfulDownload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<200_000).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .completed)
        #expect(final?.completedAt != nil)
        #expect(final?.progress.bytesCompleted == UInt64(payload.count))
        #expect(try Data(contentsOf: URL(filePath: destination)) == payload)
    }

    @Test("an HTTP error status fails the job with httpStatus")
    func httpErrorFailsJob() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, status: 404, body: Data("not found".utf8))

        let store = JobStore()
        let job = store.create(
            url: url, destination: directory.appending(path: "out.bin").path,
            requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .failed)
        #expect(final?.error?.code == .httpStatus)
        #expect(final?.error?.httpStatusCode == 404)
    }

    @Test("a transport failure fails the job with the mapped error code")
    func networkErrorFailsJob() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        MockURLProtocol.stub(url, failure: URLError(.timedOut))

        let store = JobStore()
        let job = store.create(
            url: url, destination: directory.appending(path: "out.bin").path,
            requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .failed)
        #expect(final?.error?.code == .timedOut)
        #expect(final?.retryEligible == true)
    }

    @Test("a dispatched add drives the engine to completion")
    func dispatchedAddDrivesEngine() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<120_000).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload)

        let store = JobStore()
        let engine = DownloadEngine(session: mockSession())
        let engineTask = Mutex<Task<Void, Never>?>(nil)
        let dispatcher = CommandDispatcher(store: store, onJobQueued: { id in
            engineTask.withLock { $0 = Task { await engine.run(jobID: id, in: store) } }
        })

        let destination = directory.appending(path: "out.bin").path
        _ = dispatcher.reply(to: .add(request: AddRequest(url: url, destination: destination)))
        await engineTask.withLock { $0 }?.value

        #expect(store.job(id: 1)?.state == .completed)
        #expect(try Data(contentsOf: URL(filePath: destination)) == payload)
    }

    @Test("a large file downloads across multiple ranges")
    func multiRangeDownload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        // 4 MiB against a 1 MiB minimum chunk → four ranges.
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .completed)
        #expect(final?.actualConnectionCount == 4)
        #expect(try Data(contentsOf: URL(filePath: destination)) == payload)
    }

    @Test("a server without range support falls back to a single connection")
    func fallbackWhenNoRangeSupport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload, acceptsRanges: false)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        let final = store.job(id: job.id)
        #expect(final?.state == .completed)
        #expect(final?.actualConnectionCount == 1)
        #expect(try Data(contentsOf: URL(filePath: destination)) == payload)
    }

    @Test("streamingResponse delivers the response and yields the body via async stream")
    func streamingResponseDeliversChunks() async throws {
        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<4096).map { UInt8($0 & 0xff) })
        MockURLProtocol.stub(url, body: payload)

        let (http, stream) = try await mockSession()
            .streamingResponse(for: URLRequest(url: URL(string: url)!))

        #expect(http.statusCode == 200)
        var received = Data()
        for try await chunk in stream {
            received.append(chunk)
        }
        #expect(received == payload)
    }

    @Test("a failing range fails the whole job")
    func failingRangeFailsJob() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = "https://test.local/\(UUID().uuidString).bin"
        let payload = Data((0..<(4 << 20)).map { UInt8($0 & 0xff) })
        // Four 1 MiB ranges; fail the one beginning at 2 MiB.
        MockURLProtocol.stub(url, body: payload, failRangeStartingAt: 2 << 20)

        let store = JobStore()
        let destination = directory.appending(path: "out.bin").path
        let job = store.create(url: url, destination: destination, requestedConnectionCount: 8)

        await DownloadEngine(session: mockSession()).run(jobID: job.id, in: store)

        #expect(store.job(id: job.id)?.state == .failed)
    }
}
