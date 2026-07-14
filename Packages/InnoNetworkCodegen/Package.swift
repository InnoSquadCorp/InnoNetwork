// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

// Experimental, repository-local package. SwiftPM resolves the manifest at a
// repository URL's root, so an InnoNetwork release tag does not expose this
// nested package as a remotely consumable product. The path dependency below
// intentionally supports development from a complete repository checkout.
// Keep these deployment floors aligned with the root package while codegen is
// maintained in this monorepo.
let package = Package(
    name: "InnoNetworkCodegen",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "InnoNetworkCodegen",
            targets: ["InnoNetworkCodegen"]
        )
    ],
    dependencies: [
        .package(name: "InnoNetwork", path: "../.."),
        // Macro expansion formatting and diagnostic locations are part of the
        // generated-code contract, and they can change across SwiftSyntax patch releases.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.1"),
    ],
    targets: [
        .target(
            name: "InnoNetworkCodegen",
            dependencies: [
                .product(name: "InnoNetwork", package: "InnoNetwork"),
                "InnoNetworkMacros",
            ],
            path: "Sources/InnoNetworkCodegen",
            swiftSettings: strictSettings
        ),
        .macro(
            name: "InnoNetworkMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/InnoNetworkMacros",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkMacroTests",
            dependencies: [
                .product(name: "InnoNetwork", package: "InnoNetwork"),
                "InnoNetworkCodegen",
                "InnoNetworkMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/InnoNetworkMacroTests",
            swiftSettings: strictSettings
        ),
    ]
)
