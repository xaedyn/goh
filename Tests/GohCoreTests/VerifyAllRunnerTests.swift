import Foundation
import Testing
@testable import GohCore

/// Mutable box for capturing test state inside the runner's `@Sendable` progress/isCancelled
/// closures. A `@Sendable` closure cannot capture a mutable `var` by reference (it would fail
/// under -warnings-as-errors), so the closure captures this reference instead. The runner calls
/// these closures synchronously on a single thread within `verifyAll`, so `@unchecked Sendable`
/// with a plain `var` is safe in this test context.
private final class RunnerTestBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

// AC3/AC5: VerifyAllRunner tests — parity with CLI, cancel, per-file error isolation, progress.
// All tests use the temp-plist fixture pattern from GohVerifyAllCommandTests.
@Suite("VerifyAllRunner")
struct VerifyAllRunnerTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(
        in dir: URL,
        entries: [(path: String, content: Data)]
    ) throws -> (storeURL: URL, sha256s: [String]) {
        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        var sha256s: [String] = []
        for (path, content) in entries {
            try content.write(to: URL(fileURLWithPath: path))
            let (sha256, _) = try FileDigest.sha256WithSize(path: path)
            sha256s.append(sha256)
            try store.record(entry: ProvenanceEntry(
                url: "https://example.com/" + URL(fileURLWithPath: path).lastPathComponent,
                sha256: sha256,
                size: content.count,
                downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
                destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path))
        }
        return (storeURL, sha256s)
    }

    // AC5: runner produces same VerifyAllReport as the CLI for a fixture ledger (parity gate)
    @Test("AC5: runner report matches CLI report for mixed fixture ledger")
    func runnerParityWithCLI() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ok = dir.appendingPathComponent("ok.bin").path
        let failed = dir.appendingPathComponent("failed.bin").path
        let missing = dir.appendingPathComponent("missing.bin").path

        let (storeURL, _) = try makeStore(in: dir, entries: [
            (ok, Data("unchanged".utf8)),
            (failed, Data("original".utf8)),
            (missing, Data("willbedeleted".utf8)),
        ])
        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: failed))
        try FileManager.default.removeItem(atPath: missing)

        let fixedDate = Date(timeIntervalSince1970: 1_714_262_400)

        // CLI result
        let cliResult = GohVerifyAllCommand.run(
            provenanceStorePath: storeURL.path,
            json: true,
            generatedAt: fixedDate)
        let cliReport = try CommandCoding.decoder.decode(
            VerifyAllReport.self, from: Data(cliResult.standardOutput.utf8))

        // Runner result (synchronous call — acceptable in test body; not on cooperative pool)
        // NOTE: production callers dispatch this via DispatchQueue.global().async.
        let runnerReport = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: fixedDate,
            progress: nil,
            isCancelled: nil)

        // AC5: entry statuses must be identical (order, status, paths)
        #expect(runnerReport.entries.count == cliReport.entries.count)
        #expect(runnerReport.summary == cliReport.summary)
        for (runnerEntry, cliEntry) in zip(runnerReport.entries, cliReport.entries) {
            #expect(runnerEntry.path == cliEntry.path)
            #expect(runnerEntry.status == cliEntry.status)
            #expect(runnerEntry.expectedSha256 == cliEntry.expectedSha256)
            #expect(runnerEntry.actualSha256 == cliEntry.actualSha256)
        }
    }

    // AC3: cancel between files → partial report (not a throw)
    @Test("AC3: cancel after first file returns partial report with only processed entries")
    func cancelYieldsPartialReport() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("f1.bin").path
        let f2 = dir.appendingPathComponent("f2.bin").path
        let f3 = dir.appendingPathComponent("f3.bin").path

        let (storeURL, _) = try makeStore(in: dir, entries: [
            (f1, Data("data1".utf8)),
            (f2, Data("data2".utf8)),
            (f3, Data("data3".utf8)),
        ])

        // Cancel BETWEEN files, after f1 is fully processed (completed == 1).
        // isCancelled is now checked between files AND per chunk mid-file. Rather than
        // count chunk reads (brittle), cancel based on the between-files guard: allow the
        // run to proceed until exactly one file has been recorded, then cancel before the
        // next file starts. We detect "f1 done" by reading the destination of the file
        // currently being hashed via the progress stream is unavailable here (progress is
        // nil), so we instead gate on a recorded-results count exposed through the closure.
        //
        // Simplest robust signal: the runner appends f1's result and increments `completed`
        // only after f1 fully hashes; the FIRST between-files guard for f2 is the first
        // check that occurs once f1 is fully done. We flip the cancel flag from a progress
        // callback that observes completed == 1.
        let cancelAfterFirst = RunnerTestBox(false)
        let report = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: { event in
                if event.completed >= 1 { cancelAfterFirst.value = true }
            },
            isCancelled: { cancelAfterFirst.value })

        // Should have processed exactly 1 entry (f1); f2 and f3 were not started
        #expect(report.entries.count == 1)
        #expect(report.summary.total == 1)
        #expect(report.summary.ok == 1)
    }

    // AC3: per-file missing error → classified MISSING; run continues to next file
    @Test("AC3: missing file classified MISSING; run continues to remaining files")
    func missingFileIsolation() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("present.bin").path
        let f2 = dir.appendingPathComponent("missing.bin").path

        let (storeURL, _) = try makeStore(in: dir, entries: [
            (f1, Data("data".utf8)),
            (f2, Data("willbedeleted".utf8)),
        ])
        try FileManager.default.removeItem(atPath: f2)

        let report = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: nil,
            isCancelled: nil)

        #expect(report.entries.count == 2)
        #expect(report.summary.ok == 1)
        #expect(report.summary.missing == 1)
        let f2Canon = URL(fileURLWithPath: f2).standardizedFileURL.path
        let missingEntry = try #require(report.entries.first { $0.path == f2Canon })
        #expect(missingEntry.status == .missing)
    }

    // V1: progress now streams DURING hashing (start-of-file + per-file final emit).
    // For tiny files the last event of file N is the per-file-final, where completed
    // has incremented. The final overall event has completed == total.
    @Test("V1: progress streams; final per-file emits in ledger order; completed reaches total")
    func progressStreamsInOrder() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("a.bin").path
        let f2 = dir.appendingPathComponent("b.bin").path

        let (storeURL, _) = try makeStore(in: dir, entries: [
            (f1, Data("aaa".utf8)),
            (f2, Data("bbb".utf8)),
        ])
        let f1Canon = URL(fileURLWithPath: f1).standardizedFileURL.path
        let f2Canon = URL(fileURLWithPath: f2).standardizedFileURL.path

        // Boxed in a reference type so the @Sendable progress closure captures a
        // reference, not a mutable var (required under -warnings-as-errors).
        let progressEvents = RunnerTestBox<[VerifyProgress]>([])
        _ = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: { progressEvents.value.append($0) },
            isCancelled: nil)

        let events = progressEvents.value
        #expect(events.count >= 2)               // at least one per file
        #expect(events.allSatisfy { $0.total == 2 })

        // The per-file-final events (completed incremented) appear in ledger order.
        let finals = events.filter { event in
            // a final-per-file event for file N has completed == index-of-N + 1
            event.completed >= 1 && event.currentPath != nil
        }
        // currentPath of the first ledger file must be seen before the second.
        let firstF1 = events.firstIndex { $0.currentPath == f1Canon }
        let firstF2 = events.firstIndex { $0.currentPath == f2Canon }
        let i1 = try #require(firstF1)
        let i2 = try #require(firstF2)
        #expect(i1 < i2)

        // Last event reflects a fully completed run.
        let last = try #require(events.last)
        #expect(last.completed == 2)
        #expect(finals.isEmpty == false)
    }

    // V1: a non-nil progress reports cumulative bytes; final bytesHashed == totalBytes,
    // and totalBytes == sum of recorded entry sizes.
    @Test("V1: final progress has bytesHashed == totalBytes == sum of entry sizes")
    func progressBytesReachTotal() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("a.bin").path
        let f2 = dir.appendingPathComponent("b.bin").path

        // Multi-MiB files so the throttled per-chunk path fires more than once.
        let aData = Data(repeating: 0xA1, count: 3 * 1024 * 1024)
        let bData = Data(repeating: 0xB2, count: 2 * 1024 * 1024)
        let (storeURL, _) = try makeStore(in: dir, entries: [
            (f1, aData),
            (f2, bData),
        ])
        let expectedTotal = aData.count + bData.count

        let progressEvents = RunnerTestBox<[VerifyProgress]>([])
        _ = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: { progressEvents.value.append($0) },
            isCancelled: nil)

        let events = progressEvents.value
        #expect(events.allSatisfy { $0.totalBytes == expectedTotal })

        // bytesHashed must be monotonic non-decreasing.
        var prev = 0
        for event in events {
            #expect(event.bytesHashed >= prev)
            prev = event.bytesHashed
        }

        let last = try #require(events.last)
        #expect(last.bytesHashed == expectedTotal)
        #expect(last.totalBytes == expectedTotal)
    }

    // V1: mid-file cancellation (isCancelled flips true partway through a file) returns a
    // PARTIAL report without throwing; the in-progress file is NOT counted.
    @Test("V1: mid-file cancel returns partial report; in-progress file not counted")
    func midFileCancelPartialReport() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("first.bin").path
        let f2 = dir.appendingPathComponent("second.bin").path

        // f1 large enough to span many chunks so cancel lands MID-file, not between files.
        let f1Data = Data(repeating: 0xC3, count: 8 * 1024 * 1024)
        let f2Data = Data(repeating: 0xD4, count: 1 * 1024 * 1024)
        let (storeURL, _) = try makeStore(in: dir, entries: [
            (f1, f1Data),
            (f2, f2Data),
        ])

        // Allow the first few isCancelled checks (between-files guard + first chunks),
        // then flip true so cancellation happens partway through f1.
        let checks = RunnerTestBox(0)
        let report = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: nil,
            isCancelled: {
                checks.value += 1
                // First check is the between-files guard (allow), then allow two chunk
                // reads, then cancel mid-file.
                return checks.value > 3
            })

        // f1 was cancelled mid-hash → not appended, not counted. f2 never started.
        #expect(report.entries.isEmpty)
        #expect(report.summary.total == 0)
    }

    // AC4: unreadable ledger → throws (not a partial report)
    @Test("AC4: unreadable ledger causes throw, not a silent empty report")
    func unreadableLedgerThrows() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("provenance.plist")
        try Data("not a plist".utf8).write(to: url)

        // Tighter than `(any Error).self`: assert the specific runner error type, and that the
        // structured reason is `.corrupt` (decodable-file-but-not-a-plist → corrupt, not io).
        #expect(throws: VerifyAllRunnerError.self) {
            try VerifyAllRunner.verifyAll(
                provenanceStorePath: url.path,
                generatedAt: Date(),
                progress: nil,
                isCancelled: nil)
        }
        do {
            _ = try VerifyAllRunner.verifyAll(
                provenanceStorePath: url.path, generatedAt: Date(), progress: nil, isCancelled: nil)
            Issue.record("expected VerifyAllRunnerError.ledgerUnreadable")
        } catch let VerifyAllRunnerError.ledgerUnreadable(reason) {
            #expect(reason == .corrupt)
        }
    }
}

// ── Backfill: onVerified callback (AC2, AC3, AC6, AC9) ─────────────────────

@Suite("VerifyAllRunner.onVerified")
struct VerifyAllRunnerOnVerifiedTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goh-runner-ov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(
        in dir: URL,
        entries: [(path: String, content: Data)]
    ) throws -> (storeURL: URL, sha256s: [String]) {
        let storeURL = dir.appendingPathComponent("provenance.plist")
        let store = ProvenanceStore(fileURL: storeURL)
        _ = store.load()
        var sha256s: [String] = []
        for (path, content) in entries {
            try content.write(to: URL(fileURLWithPath: path))
            let (sha256, _) = try FileDigest.sha256WithSize(path: path)
            sha256s.append(sha256)
            try store.record(entry: ProvenanceEntry(
                url: "https://example.com/\(URL(fileURLWithPath: path).lastPathComponent)",
                sha256: sha256,
                size: content.count,
                downloadedAt: Date(timeIntervalSince1970: 1_748_000_000),
                destinationPath: URL(fileURLWithPath: path).standardizedFileURL.path))
        }
        return (storeURL, sha256s)
    }

    // AC2: .failed entry does NOT fire onVerified.
    @Test("AC2: failed entry does not fire onVerified")
    func failedEntryNoCallback() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("mutated.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [(f, Data("original".utf8))])
        try Data("MUTATED".utf8).write(to: URL(fileURLWithPath: f))

        let fired = RunnerTestBox<[VerifiedBaseline]>([])
        _ = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: nil,
            isCancelled: nil,
            onVerified: { fired.value.append($0) })

        #expect(fired.value.isEmpty, "onVerified must not fire for a failed entry")
    }

    // AC3: .missing entry does NOT fire onVerified.
    @Test("AC3: missing entry does not fire onVerified")
    func missingEntryNoCallback() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("willbedeleted.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [(f, Data("content".utf8))])
        try FileManager.default.removeItem(atPath: f)

        let fired = RunnerTestBox<[VerifiedBaseline]>([])
        _ = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: nil,
            isCancelled: nil,
            onVerified: { fired.value.append($0) })

        #expect(fired.value.isEmpty, "onVerified must not fire for a missing entry")
    }

    // AC6: VerifyAllReport is unchanged when onVerified is wired (frozen contract).
    @Test("AC6: report is byte-identical with and without onVerified")
    func reportUnchangedWithCallback() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("ok.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [(f, Data("ok-content".utf8))])
        let fixedDate = Date(timeIntervalSince1970: 1_714_262_400)

        let reportWithout = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: fixedDate,
            progress: nil,
            isCancelled: nil)

        let reportWith = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: fixedDate,
            progress: nil,
            isCancelled: nil,
            onVerified: { _ in })

        #expect(reportWith == reportWithout,
            "VerifyAllReport must be unchanged when onVerified is present (AC6 — frozen contract)")
    }

    // AC9: cancelled run fires onVerified for entries verified before the cancel.
    @Test("AC9: cancelled run backfills entries verified before cancel")
    func cancelledRunFiresCollectedBaselines() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("first.bin").path
        let f2 = dir.appendingPathComponent("second.bin").path
        let (storeURL, _) = try makeStore(in: dir, entries: [
            (f1, Data("data1".utf8)),
            (f2, Data("data2".utf8)),
        ])

        // Cancel after f1 is processed.
        let cancelAfterFirst = RunnerTestBox(false)
        let fired = RunnerTestBox<[VerifiedBaseline]>([])
        _ = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: { event in
                if event.completed >= 1 { cancelAfterFirst.value = true }
            },
            isCancelled: { cancelAfterFirst.value },
            onVerified: { fired.value.append($0) })

        // f1 was verified before cancel → onVerified fired once.
        #expect(fired.value.count == 1, "onVerified must fire for entries verified before cancel")
        #expect(fired.value[0].sha256.hasPrefix("sha256:"))
    }

    // Happy path: onVerified fires once per .ok entry, with the correct fields.
    @Test("onVerified fires once per ok entry with correct sha256 and stat")
    func firesPerOkEntry() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("a.bin").path
        let f2 = dir.appendingPathComponent("b.bin").path
        let (storeURL, sha256s) = try makeStore(in: dir, entries: [
            (f1, Data("aaaa".utf8)),
            (f2, Data("bbbb".utf8)),
        ])

        let fired = RunnerTestBox<[VerifiedBaseline]>([])
        _ = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: nil,
            isCancelled: nil,
            onVerified: { fired.value.append($0) })

        #expect(fired.value.count == 2)
        let paths = fired.value.map(\.destinationPath)
        let f1Canon = URL(fileURLWithPath: f1).standardizedFileURL.path
        let f2Canon = URL(fileURLWithPath: f2).standardizedFileURL.path
        #expect(paths.contains(f1Canon))
        #expect(paths.contains(f2Canon))
        // sha256s match recorded hashes.
        for baseline in fired.value {
            #expect(sha256s.contains(baseline.sha256))
        }
        // stat fields are populated.
        for baseline in fired.value {
            #expect(baseline.stat.size > 0)
            #expect(baseline.stat.isRegularFile == true)
        }
    }
}
