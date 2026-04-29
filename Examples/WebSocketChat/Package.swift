// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WebSocketChat",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    dependencies: [
        .package(name: "InnoNetwork", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "WebSocketChat",
            dependencies: [
                .product(name: "InnoNetwork", package: "InnoNetwork"),
                .product(name: "InnoNetworkWebSocket", package: "InnoNetwork"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
