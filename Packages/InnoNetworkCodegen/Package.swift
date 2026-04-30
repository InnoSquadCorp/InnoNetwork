// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "InnoNetworkCodegen",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "InnoNetworkCodegen",
            targets: ["InnoNetworkCodegen"]
        ),
    ],
    dependencies: [
        .package(name: "InnoNetwork", path: "../.."),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.1"),
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
