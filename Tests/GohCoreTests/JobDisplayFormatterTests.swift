import Foundation
import Testing

@testable import GohCore

@Suite("JobDisplayFormatter")
struct JobDisplayFormatterTests {

    @Test("formatBytes uses integer-byte form below 1 KiB")
    func formatBytesUnderOneKibibyte() {
        #expect(JobDisplayFormatter.formatBytes(0) == "0 B")
        #expect(JobDisplayFormatter.formatBytes(512) == "512 B")
        #expect(JobDisplayFormatter.formatBytes(1023) == "1023 B")
    }

    @Test("formatBytes rolls up to KB/MB/GB and rounds cleanly to whole units")
    func formatBytesUnitRollup() {
        #expect(JobDisplayFormatter.formatBytes(1024) == "1 KB")
        #expect(JobDisplayFormatter.formatBytes(1024 * 1024) == "1 MB")
        #expect(JobDisplayFormatter.formatBytes(1024 * 1024 * 1024) == "1 GB")
        // 1.5 KiB renders with one decimal place
        #expect(JobDisplayFormatter.formatBytes(1024 + 512) == "1.5 KB")
    }

    @Test("formatBytes is locale-independent — decimal is `.` regardless of user locale")
    func formatBytesLocaleIndependent() {
        // 1.5 KB stays as "1.5 KB" even if the user locale is e.g. de_DE
        // (which would otherwise render as "1,5 KB").
        #expect(JobDisplayFormatter.formatBytes(1536) == "1.5 KB")
    }

    @Test("progressText renders `bytesCompleted/?` when total is unknown")
    func progressTextUnknownTotal() {
        let progress = JobProgress(
            bytesCompleted: 2048, bytesTotal: nil, bytesPerSecond: 0)
        #expect(JobDisplayFormatter.progressText(progress) == "2 KB/?")
    }

    @Test("progressText shows 100% when total is zero")
    func progressTextZeroTotal() {
        let progress = JobProgress(
            bytesCompleted: 0, bytesTotal: 0, bytesPerSecond: 0)
        #expect(JobDisplayFormatter.progressText(progress) == "0 B/0 B (100%)")
    }

    @Test("progressText shows the rounded percentage in normal range")
    func progressTextNormalRange() {
        let progress = JobProgress(
            bytesCompleted: 512, bytesTotal: 1024, bytesPerSecond: 0)
        #expect(JobDisplayFormatter.progressText(progress) == "512 B/1 KB (50%)")
    }

    @Test("progressText clamps an overrun (completed > total) to 100%")
    func progressTextClampsOverrun() {
        // A server that sent more bytes than Content-Length advertised used to
        // render `200%` in the CLI and `100%` in the menu bar — now both
        // surfaces agree.
        let progress = JobProgress(
            bytesCompleted: 2048, bytesTotal: 1024, bytesPerSecond: 0)
        #expect(JobDisplayFormatter.progressText(progress) == "2 KB/1 KB (100%)")
    }

    @Test("sizeText renders downloaded/total without the percent suffix")
    func sizeTextOmitsPercent() {
        let progress = JobProgress(
            bytesCompleted: 512, bytesTotal: 1024, bytesPerSecond: 0)
        #expect(JobDisplayFormatter.sizeText(progress) == "512 B/1 KB")
    }

    @Test("sizeText renders `bytesCompleted/?` when total is unknown")
    func sizeTextUnknownTotal() {
        let progress = JobProgress(
            bytesCompleted: 2048, bytesTotal: nil, bytesPerSecond: 0)
        #expect(JobDisplayFormatter.sizeText(progress) == "2 KB/?")
    }

    @Test("durationText renders seconds, minutes+seconds, and hours+minutes")
    func durationTextTiers() {
        #expect(JobDisplayFormatter.durationText(seconds: 0) == "0s")
        #expect(JobDisplayFormatter.durationText(seconds: 45) == "45s")
        #expect(JobDisplayFormatter.durationText(seconds: 59) == "59s")
        #expect(JobDisplayFormatter.durationText(seconds: 90) == "1m 30s")
        #expect(JobDisplayFormatter.durationText(seconds: 3599) == "59m 59s")
        #expect(JobDisplayFormatter.durationText(seconds: 3600) == "1h 0m")
        #expect(JobDisplayFormatter.durationText(seconds: 7380) == "2h 3m")
    }
}
