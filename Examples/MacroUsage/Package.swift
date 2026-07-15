// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacroUsage",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    dependencies: [
        .package(name: "InnoNetwork", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "MacroUsage",
            dependencies: [
                .product(name: "InnoNetwork", package: "InnoNetwork")
            ],
            path: "Sources/MacroUsage"
        )
    ]
)
