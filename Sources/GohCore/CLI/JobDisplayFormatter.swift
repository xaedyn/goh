import Foundation

/// Shared formatting helpers for byte counts and per-job progress text.
///
/// Used by the `goh` CLI table view, foreground download lines, `goh top`
/// dashboard, and the menu bar companion. Centralised so all four surfaces
/// agree on the same units, rounding, and percent clamping.
public enum JobDisplayFormatter {

    /// Formats a byte count in human-readable units (`B`, `KB`, `MB`, …).
    ///
    /// Values under 1 KiB use the integer-byte form; larger values use one
    /// decimal place unless they round cleanly to a whole unit. Output is
    /// locale-independent (`en_US_POSIX`) so the wire-adjacent text is stable
    /// across user locales.
    public static func formatBytes(_ bytes: UInt64) -> String {
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

    /// Formats a job's progress as `bytesCompleted/bytesTotal (percent%)`,
    /// or `bytesCompleted/?` when the total is unknown.
    ///
    /// The percentage is clamped to `[0, 100]`. An overrun — typically a
    /// server that sent more bytes than `Content-Length` advertised — would
    /// otherwise render as `105%` in the CLI and `100%` in the menu bar,
    /// which we deliberately make consistent.
    public static func progressText(_ progress: JobProgress) -> String {
        guard let total = progress.bytesTotal else {
            return "\(formatBytes(progress.bytesCompleted))/?"
        }
        let percent: Int
        if total == 0 {
            percent = 100
        } else {
            let rawPercent = Int(
                (Double(progress.bytesCompleted) / Double(total) * 100).rounded())
            percent = min(100, max(0, rawPercent))
        }
        return "\(formatBytes(progress.bytesCompleted))/\(formatBytes(total)) (\(percent)%)"
    }
}
