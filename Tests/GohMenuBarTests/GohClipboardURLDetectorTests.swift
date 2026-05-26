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

    @Test func acceptsPercentEncodedPath() {
        let url = GohClipboardURLDetector().url(from: "https://example.com/file%20name.iso")
        #expect(url == URL(string: "https://example.com/file%20name.iso"))
    }

    @Test func rejectsNilClipboardText() {
        #expect(GohClipboardURLDetector().url(from: nil) == nil)
    }

    @Test func rejectsEmptyClipboardText() {
        #expect(GohClipboardURLDetector().url(from: "") == nil)
        #expect(GohClipboardURLDetector().url(from: " \n\t ") == nil)
    }

    @Test func rejectsNonHTTPURL() {
        #expect(GohClipboardURLDetector().url(from: "file:///tmp/file.iso") == nil)
    }

    @Test func rejectsURLWithoutHost() {
        #expect(GohClipboardURLDetector().url(from: "https:///missing-host") == nil)
    }

    @Test func rejectsPercentEncodedHostEscapes() {
        #expect(GohClipboardURLDetector().url(from: "https://exa%20mple.com/file.iso") == nil)
        #expect(GohClipboardURLDetector().url(from: "https://%65xample.com/file.iso") == nil)
    }

    @Test func rejectsMultipleLinesOfText() {
        #expect(GohClipboardURLDetector().url(from: "https://example.com/a\nhttps://example.com/b") == nil)
    }

    @Test func rejectsSameLineProseAfterURL() {
        #expect(GohClipboardURLDetector().url(from: "https://example.com/file.iso more text") == nil)
    }

    @Test func rejectsInteriorWhitespaceAndControlCharacters() {
        #expect(GohClipboardURLDetector().url(from: "https://example.com/file\tname.iso") == nil)
        #expect(GohClipboardURLDetector().url(from: "https://example.com/file\u{0007}name.iso") == nil)
    }

    @Test func rejectsOutOfRangePort() {
        #expect(GohClipboardURLDetector().url(from: "https://example.com:99999/file.iso") == nil)
    }

    @Test func rejectsExplicitEmptyPort() {
        #expect(GohClipboardURLDetector().url(from: "https://example.com:/file.iso") == nil)
    }

    @Test func rejectsMalformedPercentEscape() {
        #expect(GohClipboardURLDetector().url(from: "https://example.com/file%ZZ.iso") == nil)
    }
}
