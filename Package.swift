// swift-tools-version: 6.2

import PackageDescription

/// Swift 6 language mode is enabled for every target so strict concurrency
/// checking is a permanent part of the build contract (no opt-in flag
/// required). CI no longer passes `-strict-concurrency=complete` explicitly —
/// this setting carries the same semantics and stays enforced for consumers
/// that build from source.
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

// Platform policy: InnoNetwork is intentionally Apple-only. The library
// depends on URLSession, OSAllocatedUnfairLock, OSLog, Network.framework,
// and UniformTypeIdentifiers, none of which match Apple-platform behaviour
// on Linux. See `docs/PlatformSupport.md` for the rationale and for
// guidance on sharing models with Linux server code (e.g. Vapor).

let package = Package(
    name: "InnoNetwork",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    products: [
        .library(
            name: "InnoNetwork",
            targets: ["InnoNetwork"]
        ),
        .library(
            name: "InnoNetworkDownload",
            targets: ["InnoNetworkDownload"]
        ),
        .library(
            name: "InnoNetworkWebSocket",
            targets: ["InnoNetworkWebSocket"]
        ),
        .library(
            name: "InnoNetworkPersistentCache",
            targets: ["InnoNetworkPersistentCache"]
        ),
        // Test helpers that consumers can pull into *their* test targets to
        // assert on InnoNetwork integrations (for example
        // ``MockURLSession``, ``StubNetworkClient``, and
        // ``WebSocketEventRecorder``). Most internals remain `package`-scoped
        // so they only stay visible to the package's own test targets; only
        // the explicitly `public` symbols cross the library boundary.
        // Promoted to a public product in PR-1; see API_STABILITY.md for the
        // contract scope (Provisionally Stable).
        .library(
            name: "InnoNetworkTestSupport",
            targets: ["InnoNetworkTestSupport"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "InnoNetwork",
            path: "Sources/InnoNetwork",
            // Bundles the `Resources/{en,ko}.lproj/Localizable.strings`
            // catalogues that back ``NetworkError.errorDescription``. The
            // catalogue ships en + ko today; additional locales can be added
            // by dropping new `<lang>.lproj/Localizable.strings` siblings.
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "InnoNetworkDownload",
            dependencies: ["InnoNetwork"],
            path: "Sources/InnoNetworkDownload",
            swiftSettings: strictSettings
        ),
        .target(
            name: "InnoNetworkWebSocket",
            dependencies: ["InnoNetwork"],
            path: "Sources/InnoNetworkWebSocket",
            swiftSettings: strictSettings
        ),
        .target(
            name: "InnoNetworkPersistentCache",
            dependencies: ["InnoNetwork"],
            path: "Sources/InnoNetworkPersistentCache",
            swiftSettings: strictSettings
        ),
        // Test helpers. Public symbols here form a Provisionally Stable
        // contract; the library is intended for *consumer* test targets and
        // should not be linked into production binaries. Internal helpers
        // (TestClock, anything depending on `package`-scope abstractions like
        // ``InnoNetworkClock``) remain `package`-visible for now and stay
        // available to this package's own test targets.
        .target(
            name: "InnoNetworkTestSupport",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkDownload",
                "InnoNetworkPersistentCache",
                "InnoNetworkWebSocket",
            ],
            path: "Sources/InnoNetworkTestSupport",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "InnoNetworkBenchmarks",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkDownload",
                "InnoNetworkWebSocket",
            ],
            path: "Benchmarks/InnoNetworkBenchmarks",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "InnoNetworkDocSmoke",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkDownload",
                "InnoNetworkPersistentCache",
                "InnoNetworkWebSocket",
            ],
            path: "SmokeTests/InnoNetworkDocSmoke",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "InnoNetworkDownloadSmoke",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkDownload",
            ],
            path: "SmokeTests/InnoNetworkDownloadSmoke",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkTests",
            dependencies: ["InnoNetwork", "InnoNetworkTestSupport"],
            path: "Tests/InnoNetworkTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkDownloadTests",
            dependencies: ["InnoNetworkDownload", "InnoNetworkTestSupport"],
            path: "Tests/InnoNetworkDownloadTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkWebSocketTests",
            dependencies: ["InnoNetworkWebSocket", "InnoNetworkTestSupport"],
            path: "Tests/InnoNetworkWebSocketTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkPersistentCacheTests",
            dependencies: ["InnoNetwork", "InnoNetworkPersistentCache"],
            path: "Tests/InnoNetworkPersistentCacheTests",
            swiftSettings: strictSettings
        ),
        // Live-endpoint smoke tests. Builds unconditionally so the test
        // target stays in package resolution, but every test guards on the
        // INNO_LIVE environment variable so a default `swift test` run is
        // a fast no-op. Run with `INNO_LIVE=1 swift test --filter InnoNetworkLiveTests`
        // — typically wired into a nightly GitHub Actions schedule rather
        // than the per-PR CI to keep builds deterministic.
        .testTarget(
            name: "InnoNetworkLiveTests",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkDownload",
                "InnoNetworkWebSocket",
                "InnoNetworkTestSupport",
            ],
            path: "Tests/InnoNetworkLiveTests",
            swiftSettings: strictSettings
        ),
    ]
)
