// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CoreSmoke",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    dependencies: [
        .package(name: "InnoNetwork", path: "../..", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "CoreSmoke",
            dependencies: [
                .product(name: "InnoNetwork", package: "InnoNetwork")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
