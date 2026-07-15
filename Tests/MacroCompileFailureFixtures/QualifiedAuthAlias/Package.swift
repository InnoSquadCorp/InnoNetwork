// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "QualifiedAuthAliasFixture",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "InnoNetwork", path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "QualifiedAuthAliasFixture",
            dependencies: [
                .product(name: "InnoNetwork", package: "InnoNetwork")
            ]
        )
    ]
)
