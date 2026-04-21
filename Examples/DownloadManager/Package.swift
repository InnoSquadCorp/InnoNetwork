// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DownloadManagerSample",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    dependencies: [
        .package(name: "InnoNetwork", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "DownloadManagerSample",
            dependencies: [
                .product(name: "InnoNetwork", package: "InnoNetwork"),
                .product(name: "InnoNetworkDownload", package: "InnoNetwork"),
            ],
            path: "Sources/DownloadManager"
        )
    ],
    swiftLanguageModes: [.v6]
)
