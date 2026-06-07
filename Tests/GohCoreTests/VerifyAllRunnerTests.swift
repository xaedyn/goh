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

        // Cancel after f1 is processed (completed == 1). The flag is boxed in a
        // reference type because a `@Sendable` closure cannot capture a mutable
        // `var` by reference (it would fail under -warnings-as-errors). The runner
        // calls isCancelled synchronously on one thread, so the @unchecked box is
        // safe here. (See RunnerTestBox below.)
        let cancelCounter = RunnerTestBox(1)
        let report = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: nil,
            isCancelled: {
                if cancelCounter.value > 0 { cancelCounter.value -= 1; return false }
                return true
            })

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

    // AC3: progress callback fires once per file, after it completes
    @Test("AC3: progress callback fires once per file in order; completed increments")
    func progressFiresAfterEachFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = dir.appendingPathComponent("a.bin").path
        let f2 = dir.appendingPathComponent("b.bin").path

        let (storeURL, _) = try makeStore(in: dir, entries: [
            (f1, Data("aaa".utf8)),
            (f2, Data("bbb".utf8)),
        ])

        // Boxed in a reference type so the @Sendable progress closure captures a
        // reference, not a mutable var (required under -warnings-as-errors).
        let progressEvents = RunnerTestBox<[VerifyProgress]>([])
        _ = try VerifyAllRunner.verifyAll(
            provenanceStorePath: storeURL.path,
            generatedAt: Date(),
            progress: { progressEvents.value.append($0) },
            isCancelled: nil)

        #expect(progressEvents.value.count == 2)
        #expect(progressEvents.value[0].completed == 1)
        #expect(progressEvents.value[0].total == 2)
        #expect(progressEvents.value[1].completed == 2)
        #expect(progressEvents.value[1].total == 2)
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
