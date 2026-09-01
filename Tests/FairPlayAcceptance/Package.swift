// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "InnoNetworkFairPlayAcceptance",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .testTarget(
            name: "FairPlayAcceptanceTests",
            dependencies: [
                .product(
                    name: "InnoNetworkHLSAVFoundation",
                    package: "InnoNetwork"
                )
            ],
            path: "Tests/FairPlayAcceptanceTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
