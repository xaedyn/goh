import Foundation
import Testing
import GohCore
@testable import GohMenuBar

@Suite @MainActor struct TrustWindowViewModelHashTests {
    private struct StubReader: ProvenanceReading {
        func read() -> ProvenanceReadOutcome { .absent }
    }
    private struct StubProbe: FileStatProbing {
        func probe(path: String) -> FileProbeResult { .notFound }
    }

    private func makeVM() -> TrustWindowViewModel {
        TrustWindowViewModel(reader: StubReader(), provenanceStorePath: "/tmp/none", probe: StubProbe())
    }

    @Test func computeCurrentHashMatchesFileDigest() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-hash-\(UUID().uuidString).bin")
        try Data("the on-disk bytes".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let expected = try FileDigest.sha256WithSize(path: tmp.path).0

        let vm = makeVM()
        vm.computeCurrentHash(forPath: tmp.path)

        // Await the off-main hash + MainActor hop (a tiny file resolves in ms).
        var waited = 0
        while vm.currentHashes[tmp.path] == nil && waited < 300 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(vm.currentHashes[tmp.path] == expected)
        #expect(vm.hashingPath == nil)
    }

    @Test func computeCurrentHashSetsHashingPathSynchronouslyAndCancelClears() {
        let vm = makeVM()
        vm.computeCurrentHash(forPath: "/nonexistent/huge.bin")
        #expect(vm.hashingPath == "/nonexistent/huge.bin")   // set before the async dispatch
        vm.cancelHashing()
        #expect(vm.hashingPath == nil)
    }

    @Test func cachedHashIsNotRecomputed() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-hash-\(UUID().uuidString).bin")
        try Data("abc".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vm = makeVM()
        vm.computeCurrentHash(forPath: tmp.path)
        var waited = 0
        while vm.currentHashes[tmp.path] == nil && waited < 300 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        // Second call while cached is a no-op — does not re-enter hashing.
        vm.computeCurrentHash(forPath: tmp.path)
        #expect(vm.hashingPath == nil)
    }
}
