// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Consumer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/InnoSquadCorp/InnoNetwork.git", exact: "6.1.0")
    ],
    targets: [
        .target(
            name: "NetworkSkillExample",
            dependencies: [.product(name: "InnoNetwork", package: "InnoNetwork")]
        ),
        .testTarget(
            name: "NetworkSkillExampleTests",
            dependencies: [
                "NetworkSkillExample",
                .product(name: "InnoNetwork", package: "InnoNetwork"),
                .product(name: "InnoNetworkTestSupport", package: "InnoNetwork")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
