import Foundation

/// Sanitizes URLs for safe display in a terminal.
///
/// Provenance URLs originate from untrusted/user-supplied input (a download
/// argument, a `gohfile`, the clipboard) and are stored verbatim in
/// `provenance.plist` / `gohfile.lock` / Spotlight xattrs. Before such a URL is
/// printed it must be sanitized, because:
///
/// - **Control characters** (notably `ESC`, `\u{1B}`) let a crafted URL inject
///   ANSI escape sequences into the terminal when the user later runs
///   `goh which` (audit L1). All control characters are stripped.
/// - **Query-string credentials** (presigned-URL tokens, `?token=…`, AWS
///   `X-Amz-*`, SAS `sig=…`) would leak to stdout, shell history, and logs
///   (audit M5). Values of credential-named query parameters are redacted.
public enum URLDisplay {

    /// Marker substituted for a redacted credential value. Plain alphanumerics so
    /// `URLComponents` round-tripping never percent-encodes it.
    private static let redactionMarker = "REDACTED"

    /// Case-insensitive substrings that mark a query parameter as credential-bearing.
    /// Covers the common presigned-URL conventions (AWS `X-Amz-*`, Azure SAS `sig`,
    /// GCS `Signature`, bearer/api tokens) without disturbing benign parameters.
    private static let sensitiveNameMarkers = [
        "token", "key", "secret", "password", "passwd", "pwd",
        "auth", "sig", "signature", "credential", "cred",
        "access", "session", "apikey", "amz", "goog",
    ]

    /// Returns `raw` made safe to print: credential query values redacted, then
    /// all control characters removed.
    public static func sanitized(_ raw: String) -> String {
        stripControlCharacters(redactQueryCredentials(raw))
    }

    private static func redactQueryCredentials(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else {
            // Unparseable, but a query may still be present — redact everything
            // after the first '?' rather than risk leaking a credential.
            if let mark = raw.firstIndex(of: "?") {
                return String(raw[..<mark]) + "?" + redactionMarker
            }
            return raw
        }
        guard let items = components.queryItems, !items.isEmpty else { return raw }
        components.queryItems = items.map { item in
            let lowered = item.name.lowercased()
            if sensitiveNameMarkers.contains(where: lowered.contains) {
                return URLQueryItem(name: item.name, value: redactionMarker)
            }
            return item
        }
        return components.string ?? raw
    }

    private static func stripControlCharacters(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
