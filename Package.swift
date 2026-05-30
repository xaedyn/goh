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
//  * The platform floor is macOS 26.0, and it is a HARD requirement, not a CI
//    convenience: the daemon's secure XPC peer validation depends on macOS 26.0 API
//    (XPCPeerRequirement, XPCRequirement.isFromSameTeam, and the requirement-carrying
//    XPCListener/XPCSession initializers in IPC/XPCTransport.swift). Lower-versioned
//    APIs in use — Synchronization.Mutex (15.0), base XPCSession/XPCListener (14.0) —
//    are not binding. Apple Silicon never ran anything below macOS 11. The floor rises
//    only when code adopts a higher-versioned API (see DESIGN §Platform support).

import PackageDescription

let package = Package(
    name: "goh",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "goh", targets: ["goh"]),
        .executable(name: "gohd", targets: ["gohd"]),
        .executable(name: "goh-menu", targets: ["goh-menu"]),
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
        // Benchmark driver for the Slice 3b range-parallel work — times a
        // goh-engine download (for the goh vs aria2c vs curl harness) and the
        // unified-vs-inline hashing comparison. Not a shipped product.
        .executableTarget(
            name: "goh-bench",
            dependencies: ["GohCore"],
            path: "Benchmarks/goh-bench"
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
        .executableTarget(
            name: "goh-menu",
            dependencies: ["GohCore", "GohMenuBar"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .target(
            name: "GohMenuBar",
            dependencies: ["GohCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "GohCoreTests",
            dependencies: ["GohCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "GohMenuBarTests",
            dependencies: ["GohMenuBar"]
        ),
        .testTarget(
            name: "GohTUITests",
            dependencies: ["GohTUI"]
        ),
    ]
)
