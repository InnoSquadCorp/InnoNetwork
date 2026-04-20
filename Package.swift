// swift-tools-version: 6.2

import PackageDescription

/// Swift 6 language mode is enabled for every target so strict concurrency
/// checking is a permanent part of the build contract (no opt-in flag
/// required). CI no longer passes `-strict-concurrency=complete` explicitly —
/// this setting carries the same semantics and stays enforced for consumers
/// that build from source.
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "InnoNetwork",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    products: [
        .library(
            name: "InnoNetwork",
            targets: ["InnoNetwork"]
        ),
        .library(
            name: "InnoNetworkDownload",
            targets: ["InnoNetworkDownload"]
        ),
        .library(
            name: "InnoNetworkWebSocket",
            targets: ["InnoNetworkWebSocket"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "InnoNetwork",
            path: "Sources/InnoNetwork",
            swiftSettings: strictSettings
        ),
        .target(
            name: "InnoNetworkDownload",
            dependencies: ["InnoNetwork"],
            path: "Sources/InnoNetworkDownload",
            swiftSettings: strictSettings
        ),
        .target(
            name: "InnoNetworkWebSocket",
            dependencies: ["InnoNetwork"],
            path: "Sources/InnoNetworkWebSocket",
            swiftSettings: strictSettings
        ),
        // Package-internal test helpers. Intentionally NOT exposed as a
        // `.library(...)` product so external consumers never see these
        // symbols. Imported only from the three test targets below.
        .target(
            name: "InnoNetworkTestSupport",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkDownload",
                "InnoNetworkWebSocket",
            ],
            path: "Sources/InnoNetworkTestSupport",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "InnoNetworkBenchmarks",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkDownload",
                "InnoNetworkWebSocket",
            ],
            path: "Benchmarks/InnoNetworkBenchmarks",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "InnoNetworkDocSmoke",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkDownload",
                "InnoNetworkWebSocket",
            ],
            path: "SmokeTests/InnoNetworkDocSmoke",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkTests",
            dependencies: ["InnoNetwork", "InnoNetworkTestSupport"],
            path: "Tests/InnoNetworkTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkDownloadTests",
            dependencies: ["InnoNetworkDownload", "InnoNetworkTestSupport"],
            path: "Tests/InnoNetworkDownloadTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkWebSocketTests",
            dependencies: ["InnoNetworkWebSocket", "InnoNetworkTestSupport"],
            path: "Tests/InnoNetworkWebSocketTests",
            swiftSettings: strictSettings
        ),
    ]
)
