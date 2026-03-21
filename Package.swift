// swift-tools-version: 6.2

import PackageDescription

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
            name: "InnoNetworkProtobuf",
            targets: ["InnoNetworkProtobuf"]
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
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.35.0")
    ],
    targets: [
        .target(
            name: "InnoNetwork",
            path: "Sources/InnoNetwork"
        ),
        .target(
            name: "InnoNetworkProtobuf",
            dependencies: [
                "InnoNetwork",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/InnoNetworkProtobuf"
        ),
        .target(
            name: "InnoNetworkDownload",
            dependencies: ["InnoNetwork"],
            path: "Sources/InnoNetworkDownload"
        ),
        .target(
            name: "InnoNetworkWebSocket",
            dependencies: ["InnoNetwork"],
            path: "Sources/InnoNetworkWebSocket"
        ),
        .executableTarget(
            name: "InnoNetworkBenchmarks",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkDownload",
                "InnoNetworkWebSocket",
            ],
            path: "Benchmarks/InnoNetworkBenchmarks"
        ),
        .executableTarget(
            name: "InnoNetworkDocSmoke",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkDownload",
                "InnoNetworkWebSocket",
            ],
            path: "SmokeTests/InnoNetworkDocSmoke"
        ),
        .testTarget(
            name: "InnoNetworkTests",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkProtobuf",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Tests/InnoNetworkTests"
        ),
        .testTarget(
            name: "InnoNetworkDownloadTests",
            dependencies: ["InnoNetworkDownload"],
            path: "Tests/InnoNetworkDownloadTests"
        ),
        .testTarget(
            name: "InnoNetworkWebSocketTests",
            dependencies: ["InnoNetworkWebSocket"],
            path: "Tests/InnoNetworkWebSocketTests"
        ),
    ]
)
