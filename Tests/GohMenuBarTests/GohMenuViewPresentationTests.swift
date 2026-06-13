import Foundation
import Testing
@testable import GohMenuBar

@Suite("GohMenuView presentation")
struct GohMenuViewPresentationTests {
    @Test func rowControlButtonsHaveIconsAndHelp() {
        #expect(GohMenuControl.pause.systemImageName == "pause.fill")
        #expect(GohMenuControl.pause.helpText == "Pause")
        #expect(GohMenuControl.pause.accessibilityLabel == "Pause")
        #expect(GohMenuControl.resume.systemImageName == "play.fill")
        #expect(GohMenuControl.resume.helpText == "Resume")
        #expect(GohMenuControl.remove.systemImageName == "trash")
        #expect(GohMenuControl.remove.helpText == "Remove job, keep file")
        #expect(GohMenuControl.revealInFinder.systemImageName == "folder")
        #expect(GohMenuControl.copyURL.systemImageName == "link")
        #expect(GohMenuControl.copyDestination.systemImageName == "doc.on.doc")
    }

    @Test func recoveryActionShortTitleIsUserFacing() {
        #expect(GohMenuRecoveryAction.copyCommand("anything").shortTitle == "Copy command")
        #expect(GohMenuRecoveryAction.openDoctor.shortTitle == "Open doctor")
    }
}

@Suite("Popover header status")
struct PopoverHeaderStatusTests {
    @Test func connectedWithActiveDownloadsCountsAndShowsSpeedAndTracked() {
        let status = PopoverHeaderStatus(
            health: .connected, activeCount: 2, speedText: "6.4 MB/s", trackedCount: 48, detail: nil)
        #expect(status.title == "2 downloading")
        #expect(status.subtitle == "6.4 MB/s · 48 tracked")
        #expect(status.wordmarkState == .active)
        #expect(status.isError == false)
        #expect(status.reconnecting == false)
    }

    @Test func connectedAndIdleReadsReady() {
        let status = PopoverHeaderStatus(
            health: .connected, activeCount: 0, speedText: "0 B/s", trackedCount: 12, detail: nil)
        #expect(status.title == "Ready")
        #expect(status.subtitle == "12 tracked")
        #expect(status.wordmarkState == .idle)
    }

    @Test func connectingReconnectsWithPulsingDot() {
        let status = PopoverHeaderStatus(
            health: .connecting, activeCount: 0, speedText: "0 B/s", trackedCount: nil, detail: nil)
        #expect(status.title == "Reconnecting…")
        #expect(status.reconnecting == true)
        #expect(status.wordmarkState == .idle)
    }

    @Test func failedReadsUnreachableInError() {
        let status = PopoverHeaderStatus(
            health: .failed(.daemonUnavailable("x")), activeCount: 0,
            speedText: "0 B/s", trackedCount: 3, detail: "gohd is not responding")
        #expect(status.title == "Service unreachable")
        #expect(status.isError == true)
        #expect(status.wordmarkState == .error)
        #expect(status.subtitle == "gohd is not responding")
    }
}

@Suite("Job row grouping")
struct JobRowGroupingTests {
    private func row(_ state: GohMenuJobDisplayState) -> GohMenuJobRow {
        GohMenuJobRow(
            id: 1, title: "f", subtitle: "f", stateText: "", displayState: state,
            progressText: "", speedText: "", destination: "/f", url: "u", controls: [])
    }

    @Test func inProgressStatesGroupTogether() {
        #expect(row(.queued).isInProgress)
        #expect(row(.active).isInProgress)
        #expect(row(.paused).isInProgress)
        #expect(!row(.completed).isInProgress)
        #expect(!row(.failed).isInProgress)
    }

    @Test func terminalStatesGroupTogether() {
        #expect(row(.completed).isTerminal)
        #expect(row(.failed).isTerminal)
        #expect(!row(.active).isTerminal)
    }

    @Test func isPausedDerivesFromDisplayState() {
        #expect(row(.paused).isPaused)
        #expect(!row(.active).isPaused)
    }
}
