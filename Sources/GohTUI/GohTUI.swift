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
                progress: progressText(job.progress),
                rate: "\(formatBytes(job.progress.bytesPerSecond))/s",
                connectionCount: "\(job.actualConnectionCount)/\(job.requestedConnectionCount)",
                destination: job.destination))
        }
        return lines.joined(separator: "\n")
    }

    private static func progressText(_ progress: JobProgress) -> String {
        guard let total = progress.bytesTotal else {
            return "\(formatBytes(progress.bytesCompleted))/?"
        }
        let percent = total == 0
            ? 100
            : Int((Double(progress.bytesCompleted) / Double(total) * 100).rounded())
        return "\(formatBytes(progress.bytesCompleted))/\(formatBytes(total)) (\(percent)%)"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        guard bytes >= 1024 else {
            return "\(bytes) B"
        }

        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            return "\(Int(rounded)) \(units[unitIndex])"
        }
        return String(
            format: "%.1f %@",
            locale: Locale(identifier: "en_US_POSIX"),
            value,
            units[unitIndex])
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
