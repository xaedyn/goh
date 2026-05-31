import Foundation

/// D1 — Normalizes a URL string to its scheme+host+port key:
/// `"{scheme}://{host-lowercased}:{port}"`.
///
/// - Returns `nil` when the host is absent (malformed URL, nil-host form) —
///   the caller must skip observation recording entirely; never bucket nil-host
///   URLs into a shared empty key.
/// - Credentials (userinfo) are stripped unconditionally.
/// - IPv6 literals are preserved in canonical bracketed form.
/// - The percent-encoded ASCII host form is used so the key is encoding-stable
///   and never carries raw multibyte host bytes.
/// - Default ports are made explicit (`:443` for https, `:80` for http).
public func hostKey(for urlString: String) -> String? {
    guard var components = URLComponents(string: urlString) else { return nil }

    // Strip credentials before any keying — a credential must never reach
    // the persisted key (D1: hard rule, not a leaning).
    components.user = nil
    components.password = nil

    // `percentEncodedHost` gives the wire-form host: for IPv6 the bracketed
    // form [addr], and for an IDN host an ASCII, percent-encoded form. (The
    // exact IDN encoding is SDK-dependent — Unicode↔punycode normalization
    // varies — but it is always ASCII and deterministic for a given input,
    // which is all the key requires.)
    guard let rawHost = components.percentEncodedHost, !rawHost.isEmpty else {
        return nil
    }
    let host = rawHost.lowercased()

    let scheme = (components.scheme ?? "").lowercased()
    let port: Int
    if let explicit = components.port {
        port = explicit
    } else {
        switch scheme {
        case "https": port = 443
        case "http":  port = 80
        default:      return nil   // unknown scheme with no port → skip
        }
    }

    return "\(scheme)://\(host):\(port)"
}
