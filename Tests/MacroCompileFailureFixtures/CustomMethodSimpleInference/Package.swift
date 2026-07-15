// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CustomMethodSimpleInferenceFixture",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "InnoNetwork", path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "CustomMethodSimpleInferenceFixture",
            dependencies: [
                .product(name: "InnoNetwork", package: "InnoNetwork")
            ]
        )
    ]
)
