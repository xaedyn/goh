import Darwin
import Foundation
import Testing
@testable import GohCore

// Stub probe with a configurable return value.
private struct FixedProbe: FileStatProbing {
    let result: FileProbeResult
    nonisolated func probe(path: String) -> FileProbeResult { result }
}

// Call-counting probe to assert no content reads (AC1).
// @unchecked Sendable: single-threaded test assumption — only the test body accesses _calls.
private nonisolated final class CallCountingProbe: FileStatProbing, @unchecked Sendable {
    private var _calls: [String] = []
    var calls: [String] { _calls }

    nonisolated func probe(path: String) -> FileProbeResult {
        _calls.append(path)
        return .notFound
    }
}

// Helpers to build entries with and without a complete baseline.
private func makeEntry(
    path: String = "/tmp/a.bin",
    withBaseline baseline: FileStat? = nil
) -> ProvenanceEntry {
    ProvenanceEntry(
        url: "https://example.com/a.bin",
        sha256: "sha256:" + String(repeating: "a", count: 64),
        size: Int(baseline?.size ?? 100),
        downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
        destinationPath: path,
        verifiedAt: nil,
        recordedStatSize: baseline.map { $0.size },
        recordedMtimeSeconds: baseline.map { $0.mtimeSeconds },
        recordedMtimeNanoseconds: baseline.map { $0.mtimeNanoseconds },
        recordedInode: baseline.map { $0.inode },
        recordedDevice: baseline.map { $0.device })
}

private let referenceBaseline = FileStat(
    size: 1_048_576,
    mtimeSeconds: 1_748_000_000,
    mtimeNanoseconds: 123_456_789,
    inode: 42_000,
    device: 1,
    isRegularFile: true)

@Suite("FastCheckRunner")
struct FastCheckRunnerTests {

    // AC1: fast-check does only lstat — no content reads.
    @Test("AC1: FastCheckRunner.checkAll issues only probe calls, no content reads")
    func noContentReads() {
        let probe = CallCountingProbe()
        let entries = [
            makeEntry(path: "/tmp/a.bin", withBaseline: referenceBaseline),
            makeEntry(path: "/tmp/b.bin", withBaseline: referenceBaseline),
        ]
        _ = FastCheckRunner.checkAll(entries, probe: probe)
        // Each entry must result in exactly one lstat call — no hash/read syscalls.
        #expect(probe.calls.count == 2)
        #expect(Set(probe.calls) == Set(["/tmp/a.bin", "/tmp/b.bin"]))
    }

    // AC2: all five fields match → .unchanged
    @Test("AC2: matching FileStat → .unchanged")
    func allFieldsMatchYieldsUnchanged() {
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(referenceBaseline))
        let status = FastCheckRunner.check(entry, probe: probe)
        #expect(status == .unchanged)
    }

    // AC3: size differs → .changed(.size)
    @Test("AC3: size mismatch → .changed(.size)")
    func sizeMismatchYieldsChangedSize() {
        let current = FileStat(
            size: referenceBaseline.size + 1,
            mtimeSeconds: referenceBaseline.mtimeSeconds,
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds,
            inode: referenceBaseline.inode,
            device: referenceBaseline.device,
            isRegularFile: true)
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        let status = FastCheckRunner.check(entry, probe: probe)
        #expect(status == .changed(.size))
    }

    // AC3: mtime seconds differ → .changed(.mtime)
    @Test("AC3: mtime seconds mismatch → .changed(.mtime)")
    func mtimeSecondsMismatch() {
        let current = FileStat(
            size: referenceBaseline.size,
            mtimeSeconds: referenceBaseline.mtimeSeconds + 1,
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds,
            inode: referenceBaseline.inode,
            device: referenceBaseline.device,
            isRegularFile: true)
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        #expect(FastCheckRunner.check(entry, probe: probe) == .changed(.mtime))
    }

    // AC3: mtime nanoseconds differ → .changed(.mtime)
    @Test("AC3: mtime nanoseconds mismatch → .changed(.mtime)")
    func mtimeNanosMismatch() {
        let current = FileStat(
            size: referenceBaseline.size,
            mtimeSeconds: referenceBaseline.mtimeSeconds,
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds + 1,
            inode: referenceBaseline.inode,
            device: referenceBaseline.device,
            isRegularFile: true)
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        #expect(FastCheckRunner.check(entry, probe: probe) == .changed(.mtime))
    }

    // AC3: inode differs → .changed(.identity)
    @Test("AC3: inode mismatch → .changed(.identity)")
    func inodeMismatch() {
        let current = FileStat(
            size: referenceBaseline.size,
            mtimeSeconds: referenceBaseline.mtimeSeconds,
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds,
            inode: referenceBaseline.inode + 1,
            device: referenceBaseline.device,
            isRegularFile: true)
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        #expect(FastCheckRunner.check(entry, probe: probe) == .changed(.identity))
    }

    // AC3: device differs → .changed(.identity)
    @Test("AC3: device mismatch → .changed(.identity)")
    func deviceMismatch() {
        let current = FileStat(
            size: referenceBaseline.size,
            mtimeSeconds: referenceBaseline.mtimeSeconds,
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds,
            inode: referenceBaseline.inode,
            device: referenceBaseline.device + 1,
            isRegularFile: true)
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        #expect(FastCheckRunner.check(entry, probe: probe) == .changed(.identity))
    }

    // AC3: precedence — identity > size > mtime.
    // inode+size both wrong → identity wins.
    @Test("AC3: identity takes precedence over size and mtime")
    func identityPrecedence() {
        let current = FileStat(
            size: referenceBaseline.size + 99,          // size wrong too
            mtimeSeconds: referenceBaseline.mtimeSeconds + 1, // mtime wrong too
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds,
            inode: referenceBaseline.inode + 1,          // identity wrong
            device: referenceBaseline.device,
            isRegularFile: true)
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        #expect(FastCheckRunner.check(entry, probe: probe) == .changed(.identity))
    }

    // AC3: size > mtime when inode/device match.
    @Test("AC3: size takes precedence over mtime when identity matches")
    func sizePrecedence() {
        let current = FileStat(
            size: referenceBaseline.size + 1,           // size wrong
            mtimeSeconds: referenceBaseline.mtimeSeconds + 1, // mtime wrong too
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds,
            inode: referenceBaseline.inode,
            device: referenceBaseline.device,
            isRegularFile: true)
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        #expect(FastCheckRunner.check(entry, probe: probe) == .changed(.size))
    }

    // AC4: probe → .notFound → .missing
    @Test("AC4: probe .notFound → .missing")
    func notFoundYieldsMissing() {
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .notFound)
        #expect(FastCheckRunner.check(entry, probe: probe) == .missing)
    }

    // AC5: probe → .unreadable → .indeterminate (NOT .missing)
    @Test("AC5: probe .unreadable → .indeterminate, not .missing")
    func unreadableYieldsIndeterminate() {
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .unreadable(EACCES))
        #expect(FastCheckRunner.check(entry, probe: probe) == .indeterminate)
    }

    // AC6: missing any baseline field → .notBaselined (never silently .unchanged)
    @Test("AC6: entry with nil recordedStatSize → .notBaselined")
    func partialBaselineIsNotBaselined_missingSize() {
        var entry = makeEntry(withBaseline: referenceBaseline)
        entry.recordedStatSize = nil   // punch out one field
        let probe = FixedProbe(result: .stat(referenceBaseline))
        #expect(FastCheckRunner.check(entry, probe: probe) == .notBaselined)
    }

    @Test("AC6: entry with nil recordedMtimeSeconds → .notBaselined")
    func partialBaselineIsNotBaselined_missingMtimeSec() {
        var entry = makeEntry(withBaseline: referenceBaseline)
        entry.recordedMtimeSeconds = nil
        let probe = FixedProbe(result: .stat(referenceBaseline))
        #expect(FastCheckRunner.check(entry, probe: probe) == .notBaselined)
    }

    @Test("AC6: entry with nil recordedMtimeNanoseconds → .notBaselined")
    func partialBaselineIsNotBaselined_missingMtimeNsec() {
        var entry = makeEntry(withBaseline: referenceBaseline)
        entry.recordedMtimeNanoseconds = nil
        let probe = FixedProbe(result: .stat(referenceBaseline))
        #expect(FastCheckRunner.check(entry, probe: probe) == .notBaselined)
    }

    @Test("AC6: entry with nil recordedInode → .notBaselined")
    func partialBaselineIsNotBaselined_missingInode() {
        var entry = makeEntry(withBaseline: referenceBaseline)
        entry.recordedInode = nil
        let probe = FixedProbe(result: .stat(referenceBaseline))
        #expect(FastCheckRunner.check(entry, probe: probe) == .notBaselined)
    }

    @Test("AC6: entry with nil recordedDevice → .notBaselined")
    func partialBaselineIsNotBaselined_missingDevice() {
        var entry = makeEntry(withBaseline: referenceBaseline)
        entry.recordedDevice = nil
        let probe = FixedProbe(result: .stat(referenceBaseline))
        #expect(FastCheckRunner.check(entry, probe: probe) == .notBaselined)
    }

    @Test("AC6: entry with ALL baseline fields nil → .notBaselined")
    func noBaselineAtAllIsNotBaselined() {
        let entry = makeEntry(withBaseline: nil)  // no baseline
        let probe = FixedProbe(result: .stat(referenceBaseline))
        #expect(FastCheckRunner.check(entry, probe: probe) == .notBaselined)
    }

    // AC7: path is not a regular file (symlink, dir, device) → .changed(.identity)
    @Test("AC7: non-regular file (isRegularFile == false) → .changed(.identity)")
    func nonRegularFileYieldsChangedIdentity() {
        let current = FileStat(
            size: referenceBaseline.size,
            mtimeSeconds: referenceBaseline.mtimeSeconds,
            mtimeNanoseconds: referenceBaseline.mtimeNanoseconds,
            inode: referenceBaseline.inode,
            device: referenceBaseline.device,
            isRegularFile: false)            // symlink or dir
        let entry = makeEntry(withBaseline: referenceBaseline)
        let probe = FixedProbe(result: .stat(current))
        #expect(FastCheckRunner.check(entry, probe: probe) == .changed(.identity))
    }

    // checkAll returns results in INPUT order, 1:1.
    @Test("FastCheckRunner.checkAll returns results in input order")
    func checkAllOrder() {
        let entryA = makeEntry(path: "/tmp/a.bin", withBaseline: referenceBaseline)
        let entryB = makeEntry(path: "/tmp/b.bin", withBaseline: nil)  // no baseline
        let probe = FixedProbe(result: .stat(referenceBaseline))
        let results = FastCheckRunner.checkAll([entryA, entryB], probe: probe)
        #expect(results.count == 2)
        #expect(results[0].0.destinationPath == "/tmp/a.bin")
        #expect(results[0].1 == .unchanged)
        #expect(results[1].0.destinationPath == "/tmp/b.bin")
        #expect(results[1].1 == .notBaselined)
    }
}
