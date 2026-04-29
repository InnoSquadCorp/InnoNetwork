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
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "MacroUsage",
            dependencies: [
                .product(name: "InnoNetwork", package: "InnoNetwork"),
                .product(name: "InnoNetworkCodegen", package: "InnoNetwork"),
            ],
            path: "Sources/MacroUsage"
        )
    ]
)
