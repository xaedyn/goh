import Foundation
import GohCore

// GohTUI — terminal UI module. Used by `goh top` and `goh <url>` progress.
//
// Bootstrap stub: exposes a module identifier. Real rendering lands in a later
// slice.

/// Namespace for the `GohTUI` terminal UI module.
public enum GohTUI {
    /// The module's name. A placeholder identity until real functionality lands.
    public static let moduleName = "GohTUI"

    public static func renderTopDashboard(snapshots: [ProgressSnapshot]) -> String {
        let sorted = snapshots.sorted { $0.job.id < $1.job.id }
        var lines = [
            "goh top",
            "\(sorted.count) \(sorted.count == 1 ? "job" : "jobs")",
            "",
        ]

        guard !sorted.isEmpty else {
            lines.append("No downloads yet.")
            return lines.joined(separator: "\n")
        }

        lines.append(tableRow(
            id: "ID",
            state: "STATE",
            progress: "PROGRESS",
            rate: "RATE",
            connectionCount: "CONN",
            destination: "DESTINATION"))
        for snapshot in sorted {
            let job = snapshot.job
            lines.append(tableRow(
                id: String(job.id),
                state: job.state.rawValue,
                progress: JobDisplayFormatter.progressText(job.progress),
                rate: "\(JobDisplayFormatter.formatBytes(job.progress.bytesPerSecond))/s",
                connectionCount: "\(job.actualConnectionCount)/\(job.requestedConnectionCount)",
                destination: job.destination))
        }
        return lines.joined(separator: "\n")
    }

    private static func pad(_ text: String, to width: Int) -> String {
        if text.count >= width {
            return text
        }
        return text + String(repeating: " ", count: width - text.count)
    }

    private static func tableRow(
        id: String,
        state: String,
        progress: String,
        rate: String,
        connectionCount: String,
        destination: String
    ) -> String {
        [
            pad(id, to: 4),
            pad(state, to: 9),
            pad(progress, to: 21),
            pad(rate, to: 10),
            pad(connectionCount, to: 6),
            destination,
        ].joined(separator: " ")
    }
}
