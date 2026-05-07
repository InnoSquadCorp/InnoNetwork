// swift-tools-version: 6.2

import PackageDescription

// Standalone SwiftPM package living outside the root InnoNetwork
// package so the runtime library never resolves codegen
// dependencies. Adopters opt in by cd-ing into this directory and
// running `swift run openapi-to-innonetwork ...`. The companion
// docs live in `docs/CodeGeneration.md`.
//
// External dependencies live here, not in the root package, so the
// InnoNetwork library itself never has to resolve a YAML parser
// or schema generator. Yams is the only runtime dependency for the
// 5.0 expansion that adds YAML input + typed Parameter / Response
// generation.

let package = Package(
    name: "openapi-to-innonetwork",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "openapi-to-innonetwork", targets: ["openapi-to-innonetwork"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6")
    ],
    targets: [
        .executableTarget(
            name: "openapi-to-innonetwork",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/openapi-to-innonetwork"
        ),
        .testTarget(
            name: "OpenAPIToInnoNetworkTests",
            dependencies: ["openapi-to-innonetwork"],
            path: "Tests/OpenAPIToInnoNetworkTests"
        ),
    ]
)
