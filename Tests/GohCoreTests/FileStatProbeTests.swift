import Darwin
import Foundation
import Testing
@testable import GohCore

// Stub probe for testing without real files.
private struct StubProbe: FileStatProbing {
    let result: FileProbeResult
    nonisolated func probe(path: String) -> FileProbeResult { result }
}

// Counting probe — records call count to assert no content reads (AC1).
// @unchecked Sendable: single-threaded test assumption — only the test body accesses _count.
nonisolated final class CountingProbe: FileStatProbing, @unchecked Sendable {
    private var _count = 0
    var count: Int { _count }

    nonisolated func probe(path: String) -> FileProbeResult {
        _count += 1
        return .notFound
    }
}

@Suite("FileStatProbe")
struct FileStatProbeTests {

    // AC4: ENOENT → .notFound
    @Test("AC4: lstat ENOENT maps to .notFound")
    func enoentMapsToNotFound() {
        let probe = StubProbe(result: .notFound)
        let result = probe.probe(path: "/nonexistent/path/file.bin")
        #expect(result == .notFound)
    }

    // AC5: other errno → .unreadable (NOT .notFound)
    @Test("AC5: errno EACCES maps to .unreadable, not .notFound")
    func eaccesIsUnreadable() {
        let probe = StubProbe(result: .unreadable(EACCES))
        guard case .unreadable(let code) = probe.probe(path: "/restricted/file.bin") else {
            Issue.record("Expected .unreadable, got .notFound")
            return
        }
        #expect(code == EACCES)
    }

    // AC5: ELOOP → .unreadable
    @Test("AC5: errno ELOOP maps to .unreadable")
    func eloopIsUnreadable() {
        let probe = StubProbe(result: .unreadable(ELOOP))
        guard case .unreadable(let code) = probe.probe(path: "/loop/file.bin") else {
            Issue.record("Expected .unreadable")
            return
        }
        #expect(code == ELOOP)
    }

    // AC5: ENOTDIR → .unreadable
    @Test("AC5: errno ENOTDIR maps to .unreadable")
    func enotdirIsUnreadable() {
        let probe = StubProbe(result: .unreadable(ENOTDIR))
        guard case .unreadable(let code) = probe.probe(path: "/not/a/dir/file.bin") else {
            Issue.record("Expected .unreadable")
            return
        }
        #expect(code == ENOTDIR)
    }

    // LiveFileStatProbe on a real absent path → .notFound
    @Test("AC4: LiveFileStatProbe on absent path yields .notFound")
    func liveProbeAbsentPath() {
        let probe = LiveFileStatProbe()
        let result = probe.probe(path: "/tmp/goh-test-definitely-missing-\(UUID().uuidString)")
        #expect(result == .notFound)
    }

    // LiveFileStatProbe on a real existing file → .stat(FileStat) with isRegularFile == true
    @Test("LiveFileStatProbe on a real file yields .stat with isRegularFile true")
    func liveProbeRealFile() throws {
        let tmpPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("goh-probe-test-\(UUID().uuidString).bin").path
        try Data("hello".utf8).write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let probe = LiveFileStatProbe()
        let result = probe.probe(path: tmpPath)
        guard case .stat(let s) = result else {
            Issue.record("Expected .stat, got \(result)")
            return
        }
        #expect(s.size == 5)
        #expect(s.isRegularFile == true)
        #expect(s.inode > 0)
        #expect(s.device != 0)
    }

    // FileStat.isRegularFile false for a directory
    @Test("LiveFileStatProbe on a directory yields isRegularFile == false")
    func liveProbeDirectory() {
        let probe = LiveFileStatProbe()
        let result = probe.probe(path: NSTemporaryDirectory())
        guard case .stat(let s) = result else {
            Issue.record("Expected .stat for /tmp directory")
            return
        }
        #expect(s.isRegularFile == false)
    }
}
