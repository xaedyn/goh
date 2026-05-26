import Foundation
import GohCore

nonisolated public struct GohMenuPresenter: Sendable {
    public init() {}

    public func state(
        health: GohMenuHealth,
        snapshots: [ProgressSnapshot],
        clipboardURL: URL?
    ) -> GohMenuState {
        let jobs = snapshots.map(\.job).sorted { $0.id < $1.id }
        let activeJobs = jobs.filter { $0.state == .active }
        let aggregateSpeed = activeJobs.reduce(UInt64(0)) {
            $0 + $1.progress.bytesPerSecond
        }
        let healthCopy = copy(for: health)

        return GohMenuState(
            health: health,
            healthTitle: healthCopy.title,
            healthDetail: healthCopy.detail,
            activeCount: activeJobs.count,
            aggregateSpeedText: Self.formatBytes(aggregateSpeed) + "/s",
            primaryAction: primaryAction(
                clipboardURL: clipboardURL,
                recoveryAction: healthCopy.recovery),
            recoveryAction: healthCopy.recovery,
            rows: jobs.map(row(for:)))
    }

    private func primaryAction(
        clipboardURL: URL?,
        recoveryAction: GohMenuRecoveryAction?
    ) -> GohMenuPrimaryAction {
        switch recoveryAction {
        case .openDoctor:
            return .diagnose
        case .copyCommand, nil:
            return clipboardURL.map(GohMenuPrimaryAction.addClipboardURL) ?? .pasteURL
        }
    }

    private func row(for job: JobSummary) -> GohMenuJobRow {
        let destinationURL = URL(filePath: job.destination)
        return GohMenuJobRow(
            id: job.id,
            title: destinationURL.lastPathComponent.isEmpty
                ? job.destination
                : destinationURL.lastPathComponent,
            subtitle: job.destination,
            stateText: stateDisplay(for: job.state),
            progressText: Self.progressText(job.progress),
            speedText: Self.formatBytes(job.progress.bytesPerSecond) + "/s",
            destination: job.destination,
            url: job.url,
            controls: controls(for: job))
    }

    private func stateDisplay(for state: JobState) -> String {
        switch state {
        case .queued:
            return "Queued"
        case .active:
            return "Active"
        case .paused:
            return "Paused"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }

    private func controls(for job: JobSummary) -> Set<GohMenuControl> {
        switch job.state {
        case .queued:
            return [.remove, .copyURL, .copyDestination]
        case .active:
            return [.pause, .copyURL, .copyDestination]
        case .paused:
            return [.resume, .remove, .copyURL, .copyDestination]
        case .completed:
            return [.revealInFinder, .remove, .copyURL, .copyDestination]
        case .failed:
            return [.remove, .copyURL, .copyDestination]
        }
    }

    private func copy(for health: GohMenuHealth) -> (
        title: String,
        detail: String?,
        recovery: GohMenuRecoveryAction?
    ) {
        switch health {
        case .connecting:
            return ("Connecting to gohd", nil, nil)
        case .connected:
            return ("gohd connected", nil, nil)
        case .reconnecting:
            return (
                "Reconnecting to gohd",
                "Downloads continue in the daemon while the companion reconnects.",
                nil)
        case .failed(.peerValidation(let detail)):
            return (
                "Peer validation blocked",
                "\(detail). For unsigned dogfood builds, run: export GOH_XPC_ALLOW_UNVALIDATED_PEERS=1",
                .copyCommand("export GOH_XPC_ALLOW_UNVALIDATED_PEERS=1"))
        case .failed(.protocolMismatch(let detail)):
            return (
                "Builds differ",
                "\(detail). Restart the daemon after rebuilding.",
                .copyCommand("brew services restart goh"))
        case .failed(.daemonUnavailable(let detail)):
            return (
                "gohd unavailable",
                "\(detail). Run goh doctor for exact recovery.",
                .openDoctor)
        case .failed(.daemon(let error)):
            return ("gohd error", error.message ?? error.code.rawValue, .openDoctor)
        case .failed(.malformedReply(let detail)):
            return ("Invalid daemon reply", detail, .openDoctor)
        }
    }

    private static func progressText(_ progress: JobProgress) -> String {
        guard let total = progress.bytesTotal else {
            return "\(formatBytes(progress.bytesCompleted))/?"
        }
        let percent: Int
        if total == 0 {
            percent = 100
        } else {
            let rawPercent = Int((Double(progress.bytesCompleted) / Double(total) * 100).rounded())
            percent = min(100, max(0, rawPercent))
        }
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
}
