import Foundation
import Testing

import GohCore
@testable import GohTUI

@Suite("GohTUI bootstrap")
struct GohTUIBootstrapTests {
    // `GohTUI` is a MainActor-default target, so its members are MainActor-isolated;
    // the test runs on the main actor to read them synchronously.
    @Test("module identity is reported")
    @MainActor
    func moduleName() {
        #expect(GohTUI.moduleName == "GohTUI")
    }

    @Test("top dashboard renders a calm empty state")
    @MainActor
    func topDashboardEmptyState() {
        let rendered = GohTUI.renderTopDashboard(snapshots: [])

        #expect(rendered == """
        goh top
        0 jobs

        No downloads yet.
        """)
    }

    @Test("top dashboard sorts jobs and formats progress rows")
    @MainActor
    func topDashboardRows() {
        let snapshots = [
            ProgressSnapshot(
                job: Self.job(
                    id: 7,
                    destination: "/tmp/archive.zip",
                    state: .paused,
                    progress: JobProgress(
                        bytesCompleted: 1_572_864,
                        bytesTotal: nil,
                        bytesPerSecond: 0),
                    requestedConnectionCount: 8,
                    actualConnectionCount: 0),
                lanes: []),
            ProgressSnapshot(
                job: Self.job(
                    id: 2,
                    destination: "/tmp/video.mov",
                    state: .active,
                    progress: JobProgress(
                        bytesCompleted: 524_288,
                        bytesTotal: 1_048_576,
                        bytesPerSecond: 2_048),
                    requestedConnectionCount: 8,
                    actualConnectionCount: 4),
                lanes: []),
        ]

        let rendered = GohTUI.renderTopDashboard(snapshots: snapshots)

        #expect(rendered == """
        goh top
        2 jobs

        ID   STATE     PROGRESS              RATE       CONN   DESTINATION
        2    active    512 KB/1 MB (50%)     2 KB/s     4/8    /tmp/video.mov
        7    paused    1.5 MB/?              0 B/s      0/8    /tmp/archive.zip
        """)
    }

    @Test("top dashboard keeps long states and rates separated")
    @MainActor
    func topDashboardKeepsLongColumnsSeparated() {
        let snapshots = [
            ProgressSnapshot(
                job: Self.job(
                    id: 42,
                    destination: "/tmp/ubuntu.iso",
                    state: .completed,
                    progress: JobProgress(
                        bytesCompleted: 1_024,
                        bytesTotal: 1_024,
                        bytesPerSecond: 123_456_789),
                    requestedConnectionCount: 8,
                    actualConnectionCount: 8),
                lanes: []),
        ]

        let rendered = GohTUI.renderTopDashboard(snapshots: snapshots)

        #expect(rendered == """
        goh top
        1 job

        ID   STATE     PROGRESS              RATE       CONN   DESTINATION
        42   completed 1 KB/1 KB (100%)      117.7 MB/s 8/8    /tmp/ubuntu.iso
        """)
    }

    private static func job(
        id: UInt64,
        destination: String,
        state: JobState,
        progress: JobProgress,
        requestedConnectionCount: UInt8,
        actualConnectionCount: UInt8
    ) -> JobSummary {
        JobSummary(
            id: id,
            url: "https://example.com/\(id)",
            destination: destination,
            state: state,
            progress: progress,
            createdAt: Date(timeIntervalSince1970: 0),
            lastProgressAt: nil,
            requestedConnectionCount: requestedConnectionCount,
            actualConnectionCount: actualConnectionCount)
    }
}
