// GohCore — shared library: transport, scheduling, persistence, hashing, auth.
//
// Bootstrap stub: exposes a module identifier and re-exports the HTTP message
// types the transport layer will build on. Real functionality lands incrementally.

import HTTPTypes

/// Namespace for the `GohCore` shared library.
public enum GohCore {
    /// The module's name. A placeholder identity until real functionality lands.
    public static let moduleName = "GohCore"
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
