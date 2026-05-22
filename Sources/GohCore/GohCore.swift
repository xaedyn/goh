// GohCore — shared library: transport, scheduling, persistence, hashing, auth.
//
// Exposes a module identifier, the download client's HTTP identity, and
// re-exports the HTTP message types the transport layer builds on.

import Foundation
import HTTPTypes

/// Namespace for the `GohCore` shared library.
public enum GohCore {
    /// The module's name. A placeholder identity until real functionality lands.
    public static let moduleName = "GohCore"

    /// The `User-Agent` every `goh` HTTP request carries. A download manager
    /// fetches from arbitrary servers; identifying the client — and giving
    /// operators a contact point through the repository — is basic courtesy.
    public static let userAgent = "goh/0.1 (+https://github.com/xaedyn/goh)"

    /// The `URLSessionConfiguration` for the download engine's session.
    ///
    /// `httpMaximumConnectionsPerHost` is raised so range-parallel downloads get
    /// real HTTP/1.1 concurrency — HTTP/2 multiplexes regardless of the cap —
    /// and ``userAgent`` is set as a default header, so every request the engine
    /// makes (the `HEAD` probe, each ranged `GET`, and the single-connection
    /// `GET`) carries it without per-request wiring.
    public static func downloadSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return configuration
    }
}

// MARK: - Re-exported HTTP message types
//
// `goh` and `gohd` depend on `GohCore`, not on `swift-http-types` directly. The
// typealiases below give downstream targets the HTTP message vocabulary through a
// single import. (`@_exported import HTTPTypes` would do this implicitly, but it
// relies on an underscored, unsupported attribute — explicit typealiases are
// stable across toolchains and make the re-export surface deliberate.)

/// An HTTP request message. Re-exported from `apple/swift-http-types`.
public typealias HTTPRequest = HTTPTypes.HTTPRequest

/// An HTTP response message. Re-exported from `apple/swift-http-types`.
public typealias HTTPResponse = HTTPTypes.HTTPResponse

/// A collection of HTTP fields — headers or trailers. Re-exported from
/// `apple/swift-http-types`.
public typealias HTTPFields = HTTPTypes.HTTPFields

/// A single HTTP field — one header or trailer. Re-exported from
/// `apple/swift-http-types`.
public typealias HTTPField = HTTPTypes.HTTPField
