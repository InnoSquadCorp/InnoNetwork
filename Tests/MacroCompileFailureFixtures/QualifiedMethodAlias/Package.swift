// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "QualifiedMethodAliasFixture",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "InnoNetwork", path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "QualifiedMethodAliasFixture",
            dependencies: [
                .product(name: "InnoNetwork", package: "InnoNetwork")
            ]
        )
    ]
)
