// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OptionalPathAliasFixture",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "InnoNetwork", path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "OptionalPathAliasFixture",
            dependencies: [
                .product(name: "InnoNetwork", package: "InnoNetwork")
            ]
        )
    ]
)
