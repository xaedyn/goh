import Foundation
import Testing
@testable import GohMenuBar

@Suite("GohMenuView presentation")
struct GohMenuViewPresentationTests {
    @Test func primaryActionCopyIsUserFacing() {
        #expect(GohMenuPrimaryAction.addClipboardURL(URL(string: "https://example.com/big.iso")!).buttonTitle == "Get over here!")
        #expect(GohMenuPrimaryAction.addClipboardURL(URL(string: "https://example.com/big.iso")!).systemImageName == "arrow.down.circle.fill")
        #expect(GohMenuPrimaryAction.pasteURL.buttonTitle == "Copy a download URL")
        #expect(GohMenuPrimaryAction.pasteURL.systemImageName == "doc.on.clipboard")
        #expect(GohMenuPrimaryAction.diagnose.buttonTitle == "Open doctor")
        #expect(GohMenuPrimaryAction.diagnose.systemImageName == "stethoscope")
    }

    @Test func rowControlButtonsHaveIconsAndHelp() {
        #expect(GohMenuControl.pause.systemImageName == "pause.fill")
        #expect(GohMenuControl.pause.helpText == "Pause")
        #expect(GohMenuControl.resume.systemImageName == "play.fill")
        #expect(GohMenuControl.resume.helpText == "Resume")
        #expect(GohMenuControl.remove.systemImageName == "trash")
        #expect(GohMenuControl.remove.helpText == "Remove job, keep file")
        #expect(GohMenuControl.revealInFinder.systemImageName == "folder")
        #expect(GohMenuControl.revealInFinder.helpText == "Reveal in Finder")
        #expect(GohMenuControl.copyURL.systemImageName == "link")
        #expect(GohMenuControl.copyURL.helpText == "Copy URL")
        #expect(GohMenuControl.copyDestination.systemImageName == "doc.on.doc")
        #expect(GohMenuControl.copyDestination.helpText == "Copy destination")
    }
}
