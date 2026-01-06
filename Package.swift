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
    ],
    targets: [
        .target(
            name: "InnoNetwork",
            path: "Sources/InnoNetwork"
        ),
        .target(
            name: "InnoNetworkDownload",
            dependencies: ["InnoNetwork"],
            path: "Sources/InnoNetworkDownload"
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
    ]
)
