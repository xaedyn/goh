import Foundation
import GohCore

nonisolated public struct GohMenuPresenter: Sendable {
    public init() {}

    public func state(
        health: GohMenuHealth,
        snapshots: [ProgressSnapshot],
        clipboardURL: URL?,
        ledgerOutcome: ProvenanceReadOutcome? = nil
    ) -> GohMenuState {
        let jobs = snapshots.map(\.job).sorted { $0.id < $1.id }
        let activeJobs = jobs.filter { $0.state == .active }
        let aggregateSpeed = activeJobs.reduce(UInt64(0)) {
            $0 + $1.progress.bytesPerSecond
        }
        let healthCopy = copy(for: health)

        // Key the ledger by the canonical destination path (matches the daemon's
        // write side and ProvenanceStore.lookup, which both canonicalize via
        // URL(fileURLWithPath:).standardizedFileURL.path). Looking up below with the
        // same canonicalization guarantees a hit regardless of trailing slashes,
        // "..", or symlink segments in either path.
        let ledgerMap: [String: ProvenanceEntry]
        if let outcome = ledgerOutcome, case .entries(let entries) = outcome {
            ledgerMap = Dictionary(
                entries.map { (Self.canonicalPath($0.destinationPath), $0) },
                uniquingKeysWith: { _, last in last })
        } else {
            ledgerMap = [:]
        }

        return GohMenuState(
            health: health,
            healthTitle: healthCopy.title,
            healthDetail: healthCopy.detail,
            activeCount: activeJobs.count,
            aggregateSpeedText: JobDisplayFormatter.formatBytes(aggregateSpeed) + "/s",
            primaryAction: primaryAction(
                clipboardURL: clipboardURL,
                recoveryAction: healthCopy.recovery),
            recoveryAction: healthCopy.recovery,
            rows: jobs.map { row(for: $0, ledgerMap: ledgerMap) })
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

    private func row(for job: JobSummary, ledgerMap: [String: ProvenanceEntry]) -> GohMenuJobRow {
        let destinationURL = URL(filePath: job.destination)

        let progressFraction: Double? = job.progress.bytesTotal.map { total in
            total > 0 ? min(1.0, Double(job.progress.bytesCompleted) / Double(total)) : 1.0
        }

        let etaText: String?
        if job.state == .active, let total = job.progress.bytesTotal, job.progress.bytesPerSecond > 0 {
            let remaining = total >= job.progress.bytesCompleted ? total - job.progress.bytesCompleted : 0
            let eta = remaining / job.progress.bytesPerSecond
            etaText = etaString(seconds: eta)
        } else {
            etaText = nil
        }

        let referenceDate: Date = job.completedAt ?? job.lastProgressAt ?? Date()
        let elapsedSeconds = max(0, referenceDate.timeIntervalSince(job.createdAt))
        let elapsedText: String? = elapsedSeconds > 0 ? elapsedString(seconds: elapsedSeconds) : nil

        let connectionText: String? = job.actualConnectionCount > 0
            ? "\(job.actualConnectionCount) connection\(job.actualConnectionCount == 1 ? "" : "s")"
            : nil

        let verifyStatus: String?
        if job.state == .completed, let entry = ledgerMap[Self.canonicalPath(job.destination)] {
            if let verifiedAt = entry.verifiedAt {
                let formatted = DateFormatter.localizedString(from: verifiedAt, dateStyle: .short, timeStyle: .none)
                verifyStatus = "verified \(formatted)"
            } else {
                verifyStatus = "recorded"
            }
        } else {
            verifyStatus = nil
        }

        return GohMenuJobRow(
            id: job.id,
            title: destinationURL.lastPathComponent.isEmpty
                ? job.destination
                : destinationURL.lastPathComponent,
            subtitle: job.destination,
            stateText: stateDisplay(for: job.state),
            progressText: JobDisplayFormatter.progressText(job.progress),
            speedText: JobDisplayFormatter.formatBytes(job.progress.bytesPerSecond) + "/s",
            destination: job.destination,
            url: job.url,
            controls: controls(for: job),
            progressFraction: progressFraction,
            sizeText: JobDisplayFormatter.progressText(job.progress),
            etaText: etaText,
            elapsedText: elapsedText,
            connectionText: connectionText,
            verifyStatus: verifyStatus)
    }

    private func etaString(seconds: UInt64) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    private func elapsedString(seconds: Double) -> String {
        let s = UInt64(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    /// Canonicalize a filesystem path for ledger-key matching, mirroring the
    /// daemon's write side and `ProvenanceStore.lookup`.
    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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

}
