import Foundation
import Testing

import GohCore

/// `goh which` (and other provenance surfaces) print URLs that originated from
/// untrusted/user-supplied input. They must be sanitized before reaching the
/// terminal: control characters stripped (no ANSI-escape injection, audit L1)
/// and credential-bearing query parameters redacted (audit M5).
@Suite("URL display sanitization")
struct GohURLDisplayTests {

    @Test("a plain URL with no query and no control chars is unchanged")
    func plainURLUnchanged() {
        let url = "https://example.com/path/file.iso"
        #expect(URLDisplay.sanitized(url) == url)
    }

    @Test("ANSI escape / control characters are stripped")
    func stripsControlCharacters() {
        let malicious = "https://example.com/\u{1B}[31mEVIL\u{1B}[0m/file"
        let out = URLDisplay.sanitized(malicious)
        #expect(!out.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        #expect(!out.contains("\u{1B}"))
    }

    @Test("credential-bearing query parameter values are redacted")
    func redactsCredentialParams() {
        let out = URLDisplay.sanitized("https://h.example.com/f?token=SECRET123&v=2")
        #expect(!out.contains("SECRET123"))
        #expect(out.contains("REDACTED"))
        // A benign parameter's value survives.
        #expect(out.contains("v=2"))
    }

    @Test("a malformed URL string with a query still has its query redacted")
    func redactsMalformedQuery() {
        let out = URLDisplay.sanitized("not a url ?sig=DEADBEEF")
        #expect(!out.contains("DEADBEEF"))
    }
}
