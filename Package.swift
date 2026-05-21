// swift-tools-version:6.2
//
// goh — daemon-backed terminal download manager for Apple Silicon macOS.
//
// Toolchain notes:
//  * swift-tools-version is pinned at the 6.2 floor — the minimum that provides the
//    `.defaultIsolation` SwiftSetting used below. The repo builds with the current
//    Swift 6.3.x toolchain; the tools-version stays at the feature floor on purpose.
//  * Swift 6 language mode (the default at tools-version 6.x) already enables complete
//    strict-concurrency checking, so no `.enableUpcomingFeature("StrictConcurrency")`.
//  * The platform floor is macOS 26.0 so CI builds on the stable default Xcode. The
//    *supported* OS is macOS 26.5+ (see README/DESIGN); the floor rises to 26.5 the
//    first time code calls a 26.5-only API.

import PackageDescription

let package = Package(
    name: "goh",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "goh", targets: ["goh"]),
        .executable(name: "gohd", targets: ["gohd"]),
    ],
    dependencies: [
        // Pre-approved: HTTP message modeling. Apple-published, MIT-licensed.
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0")
    ],
    targets: [
        // CLI client — talks to the daemon over XPC, exits fast.
        // Main-thread work is the 80% case, so MainActor-default isolation.
        .executableTarget(
            name: "goh",
            dependencies: ["GohCore", "GohTUI"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Daemon — runs under launchd, owns the network, queue, and disk.
        // Off-main work is the 80% case, so the standard nonisolated default.
        .executableTarget(
            name: "gohd",
            dependencies: ["GohCore"]
        ),
        // Shared library — transport, scheduling, persistence, hashing, auth.
        // Off-main work is the 80% case, so the standard nonisolated default.
        .target(
            name: "GohCore",
            dependencies: [
                .product(name: "HTTPTypes", package: "swift-http-types")
            ]
        ),
        // Terminal UI — renders on the main thread, so MainActor-default isolation.
        .target(
            name: "GohTUI",
            dependencies: ["GohCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "GohCoreTests",
            dependencies: ["GohCore"]
        ),
        .testTarget(
            name: "GohTUITests",
            dependencies: ["GohTUI"]
        ),
    ]
)
