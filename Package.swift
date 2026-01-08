// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "InnoNetwork",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26)
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
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0")
    ],
    targets: [
        .target(
            name: "InnoNetwork",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            path: "Sources/InnoNetwork"
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
        .testTarget(
            name: "InnoNetworkTests",
            dependencies: ["InnoNetwork"],
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
