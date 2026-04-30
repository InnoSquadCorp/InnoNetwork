// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacroUsage",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    dependencies: [
        .package(name: "InnoNetwork", path: "../.."),
        .package(name: "InnoNetworkCodegen", path: "../../Packages/InnoNetworkCodegen"),
    ],
    targets: [
        .executableTarget(
            name: "MacroUsage",
            dependencies: [
                .product(name: "InnoNetwork", package: "InnoNetwork"),
                .product(name: "InnoNetworkCodegen", package: "InnoNetworkCodegen"),
            ],
            path: "Sources/MacroUsage"
        )
    ]
)
