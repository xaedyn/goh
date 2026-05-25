import Foundation
import Testing
@testable import GohMenuBar

@Suite("GohClipboardURLDetector")
struct GohClipboardURLDetectorTests {
    @Test func acceptsHTTPSURLWithWhitespace() {
        let url = GohClipboardURLDetector().url(from: " \n https://example.com/big.iso \n ")
        #expect(url == URL(string: "https://example.com/big.iso"))
    }

    @Test func acceptsHTTPURL() {
        let url = GohClipboardURLDetector().url(from: "http://example.com/file.zip")
        #expect(url == URL(string: "http://example.com/file.zip"))
    }

    @Test func rejectsNonHTTPURL() {
        #expect(GohClipboardURLDetector().url(from: "file:///tmp/file.iso") == nil)
    }

    @Test func rejectsURLWithoutHost() {
        #expect(GohClipboardURLDetector().url(from: "https:///missing-host") == nil)
    }

    @Test func rejectsMultipleLinesOfText() {
        #expect(GohClipboardURLDetector().url(from: "https://example.com/a\nhttps://example.com/b") == nil)
    }
}
