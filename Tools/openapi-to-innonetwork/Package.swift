// swift-tools-version: 6.2

import PackageDescription

// Standalone SwiftPM package living outside the root InnoNetwork
// package so the runtime library never resolves codegen
// dependencies. Adopters opt in by cd-ing into this directory and
// running `swift run openapi-to-innonetwork ...`. The companion
// docs live in `docs/CodeGeneration.md`.
//
// External dependencies are deliberately avoided in this 4.x preview
// — the parser handles a JSON subset of OpenAPI 3 directly through
// Foundation's JSONDecoder so adopters can try it without adding a
// YAML parser dependency. A 5.0 follow-up may add Yams support
// behind a flag for full OpenAPI YAML compatibility.

let package = Package(
    name: "openapi-to-innonetwork",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "openapi-to-innonetwork", targets: ["openapi-to-innonetwork"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "openapi-to-innonetwork",
            path: "Sources/openapi-to-innonetwork"
        ),
        .testTarget(
            name: "OpenAPIToInnoNetworkTests",
            dependencies: ["openapi-to-innonetwork"],
            path: "Tests/OpenAPIToInnoNetworkTests"
        ),
    ]
)
